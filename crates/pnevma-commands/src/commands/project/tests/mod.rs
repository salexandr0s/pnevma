use super::*;

mod lifecycle;
mod overview;
mod sessions;
mod settings;
mod workspace;

use crate::event_emitter::NullEmitter;
use pnevma_agents::AdapterRegistry;
use pnevma_core::config::{
    AgentsSection, AutomationSection, BranchesSection, PathSection, ProjectSection,
    RedactionSection, RetentionSection,
};
use pnevma_core::{RemoteSection, TrackerSection};
use pnevma_db::{AutomationRetryRow, AutomationRunRow, GlobalDb, WorktreeRow};
use serde_json::Value;
use sqlx::sqlite::SqlitePoolOptions;
use std::ffi::OsString;
use std::fs;
use std::os::unix::fs::PermissionsExt;
use std::process::Command;
use std::sync::OnceLock;
use std::time::Duration;
use tempfile::tempdir;
use tokio::sync::{Mutex, MutexGuard};

fn home_env_lock() -> &'static Mutex<()> {
    static LOCK: OnceLock<Mutex<()>> = OnceLock::new();
    LOCK.get_or_init(|| Mutex::new(()))
}

fn redaction_config_lock() -> &'static Mutex<()> {
    static LOCK: OnceLock<Mutex<()>> = OnceLock::new();
    LOCK.get_or_init(|| Mutex::new(()))
}

struct HomeOverride {
    previous_home: Option<OsString>,
    _guard: MutexGuard<'static, ()>,
}

impl HomeOverride {
    async fn new(path: &Path) -> Self {
        let guard = home_env_lock().lock().await;
        let previous_home = std::env::var_os("HOME");
        std::env::set_var("HOME", path);
        Self {
            previous_home,
            _guard: guard,
        }
    }
}

impl Drop for HomeOverride {
    fn drop(&mut self) {
        if let Some(previous_home) = self.previous_home.as_ref() {
            std::env::set_var("HOME", previous_home);
        } else {
            std::env::remove_var("HOME");
        }
    }
}

async fn open_test_db() -> Db {
    let pool = SqlitePoolOptions::new()
        .max_connections(1)
        .connect("sqlite::memory:")
        .await
        .expect("memory sqlite");
    let db = Db::from_pool_and_path(pool, std::path::PathBuf::from(":memory:"));
    db.migrate().await.expect("migrate");
    db
}

fn write_test_project_config(project_root: &Path, extra_patterns: &[&str]) {
    let encoded_patterns = extra_patterns
        .iter()
        .map(|pattern| format!("{pattern:?}"))
        .collect::<Vec<_>>()
        .join(", ");
    let config = format!(
        r#"[project]
name = "test-project"
brief = "test brief"

[agents]
default_provider = "claude-code"
max_concurrent = 1

[automation]
socket_enabled = false

[branches]
target = "main"
naming = "task/{{slug}}"

[redaction]
extra_patterns = [{encoded_patterns}]
enable_entropy_guard = false
"#
    );
    std::fs::write(project_root.join("pnevma.toml"), config).expect("write project config");
}

fn write_fake_executable(path: &Path, body: &str) {
    fs::write(path, body).expect("write fake executable");
    let mut permissions = fs::metadata(path).expect("metadata").permissions();
    permissions.set_mode(0o755);
    fs::set_permissions(path, permissions).expect("set permissions");
}

fn make_task(pid: &str, title: &str) -> TaskRow {
    let now = chrono::Utc::now();
    TaskRow {
        id: Uuid::new_v4().to_string(),
        project_id: pid.to_string(),
        title: title.to_string(),
        goal: String::new(),
        scope_json: "[]".to_string(),
        dependencies_json: "[]".to_string(),
        acceptance_json: "[]".to_string(),
        constraints_json: "[]".to_string(),
        priority: "P2".to_string(),
        status: "Ready".to_string(),
        branch: None,
        worktree_id: None,
        handoff_summary: None,
        created_at: now,
        updated_at: now,
        auto_dispatch: false,
        agent_profile_override: None,
        execution_mode: None,
        timeout_minutes: None,
        max_retries: None,
        loop_iteration: 0,
        loop_context_json: None,
        forked_from_task_id: None,
        lineage_summary: None,
        lineage_depth: 0,
    }
}

fn make_project_config() -> ProjectConfig {
    ProjectConfig {
        project: ProjectSection {
            name: "test-project".to_string(),
            brief: String::new(),
        },
        agents: AgentsSection {
            default_provider: "claude-code".to_string(),
            max_concurrent: 1,
            claude_code: None,
            codex: None,
        },
        automation: AutomationSection::default(),
        retention: RetentionSection::default(),
        branches: BranchesSection {
            target: "main".to_string(),
            naming: "task/{slug}".to_string(),
        },
        rules: PathSection::default(),
        conventions: PathSection::default(),
        remote: RemoteSection::default(),
        tracker: TrackerSection::default(),
        redaction: RedactionSection::default(),
    }
}

fn make_session_metadata(
    project_id: Uuid,
    session_id: Uuid,
    cwd: &Path,
    status: SessionStatus,
) -> SessionMetadata {
    SessionMetadata {
        id: session_id,
        project_id,
        name: "shell".to_string(),
        status: status.clone(),
        health: match status {
            SessionStatus::Running => SessionHealth::Active,
            SessionStatus::Waiting => SessionHealth::Waiting,
            SessionStatus::Error => SessionHealth::Error,
            SessionStatus::Complete => SessionHealth::Complete,
        },
        pid: Some(42),
        cwd: cwd.to_string_lossy().to_string(),
        command: "/bin/zsh".to_string(),
        branch: None,
        worktree_id: None,
        started_at: Utc::now(),
        last_heartbeat: Utc::now(),
        scrollback_path: cwd
            .join(".pnevma/data/scrollback")
            .join(format!("{session_id}.log"))
            .to_string_lossy()
            .to_string(),
        exit_code: (status == SessionStatus::Complete).then_some(0),
        ended_at: (status == SessionStatus::Complete).then_some(Utc::now()),
    }
}

fn make_command_center_task(
    project_id: Uuid,
    title: &str,
    status: &str,
    branch: Option<&str>,
    worktree_id: Option<&str>,
) -> TaskRow {
    let mut task = make_task(&project_id.to_string(), title);
    task.status = status.to_string();
    task.branch = branch.map(str::to_string);
    task.worktree_id = worktree_id.map(str::to_string);
    task
}

async fn make_state_with_project(
    project_id: Uuid,
    project_root: &Path,
    db: Db,
    sessions: SessionSupervisor,
) -> AppState {
    let emitter: Arc<dyn EventEmitter> = Arc::new(NullEmitter);
    let state = AppState::new(emitter);
    let (shutdown_tx, _shutdown_rx) = tokio::sync::watch::channel(false);
    state
        .replace_current_project(
            "tests.make_state_with_project",
            ProjectContext {
                project_id,
                project_path: project_root.to_path_buf(),
                config: make_project_config(),
                global_config: GlobalConfig::default(),
                db,
                sessions,
                redaction_secrets: Arc::new(RwLock::new(Vec::new())),
                git: Arc::new(GitService::new(project_root)),
                adapters: AdapterRegistry::default(),
                pool: DispatchPool::new(1),
                tracker: None,
                workflow_store: Arc::new(crate::automation::workflow_store::WorkflowStore::new(
                    project_root,
                )),
                coordinator: None,
                shutdown_tx,
            },
        )
        .await;
    state
}

fn run_git(project_root: &Path, args: &[&str]) {
    let status = Command::new("git")
        .args(args)
        .current_dir(project_root)
        .status()
        .expect("git command should start");
    assert!(status.success(), "git {:?} should succeed", args);
}
