use std::{
    collections::HashMap,
    path::PathBuf,
    sync::{Arc, Mutex},
    time::Duration,
};

use async_trait::async_trait;
use chrono::Utc;
use pnevma_agents::{
    AdapterRegistry, AgentAdapter, AgentConfig, AgentError, AgentEvent, AgentHandle, AgentStatus,
    CostRecord, DispatchPool, TaskPayload,
};
use pnevma_commands::{event_emitter::EventEmitter, AppState, ProjectContext};
use pnevma_core::{
    config::{
        AgentsSection, AutomationSection, BranchesSection, PathSection, ProjectSection,
        RedactionSection, RetentionSection,
    },
    GlobalConfig, Priority, ProjectConfig, RemoteSection, TrackerSection,
};
use pnevma_db::{AutomationRunRow, Db, TaskRow};
use pnevma_git::GitService;
use pnevma_session::SessionSupervisor;
use serde_json::Value;
use sqlx::sqlite::SqlitePoolOptions;
use tempfile::TempDir;
use tokio::sync::{broadcast, Notify, RwLock};
use uuid::Uuid;

pub struct RecordingEmitter {
    pub events: Mutex<Vec<(String, Value)>>,
    pub notify: Notify,
}

impl RecordingEmitter {
    pub fn new() -> Self {
        Self {
            events: Mutex::new(Vec::new()),
            notify: Notify::new(),
        }
    }

    pub async fn wait_for_event(&self, name: &str) -> Value {
        loop {
            if let Some(payload) = self
                .events
                .lock()
                .expect("recording emitter lock poisoned")
                .iter()
                .find_map(|(event_name, payload)| {
                    if event_name == name {
                        Some(payload.clone())
                    } else {
                        None
                    }
                })
            {
                return payload;
            }

            self.notify.notified().await;
        }
    }
}

impl EventEmitter for RecordingEmitter {
    fn emit(&self, event: &str, payload: Value) {
        self.events
            .lock()
            .expect("recording emitter lock poisoned")
            .push((event.to_string(), payload));
        self.notify.notify_waiters();
    }
}

pub struct StreamingFakeAdapter {
    pub release_completion: Arc<Notify>,
    send_error: Option<String>,
    channels: Mutex<HashMap<Uuid, broadcast::Sender<AgentEvent>>>,
}

impl StreamingFakeAdapter {
    pub fn new(release_completion: Arc<Notify>) -> Self {
        Self {
            release_completion,
            send_error: None,
            channels: Mutex::new(HashMap::new()),
        }
    }

    pub fn failing(message: &str) -> Self {
        Self {
            release_completion: Arc::new(Notify::new()),
            send_error: Some(message.to_string()),
            channels: Mutex::new(HashMap::new()),
        }
    }
}

#[async_trait]
impl AgentAdapter for StreamingFakeAdapter {
    async fn spawn(&self, config: AgentConfig) -> Result<AgentHandle, AgentError> {
        let handle = AgentHandle {
            id: Uuid::new_v4(),
            provider: config.provider,
            task_id: Uuid::new_v4(),
            thread_id: None,
            turn_id: None,
        };
        let (tx, _rx) = broadcast::channel(32);
        self.channels
            .lock()
            .expect("adapter channel lock poisoned")
            .insert(handle.id, tx);
        Ok(handle)
    }

    async fn send(&self, handle: &AgentHandle, input: TaskPayload) -> Result<(), AgentError> {
        if let Some(message) = &self.send_error {
            return Err(AgentError::Spawn(message.clone()));
        }

        let tx = self
            .channels
            .lock()
            .expect("adapter channel lock poisoned")
            .get(&handle.id)
            .cloned()
            .expect("channel for handle");
        let release_completion = Arc::clone(&self.release_completion);

        tokio::spawn(async move {
            let _ = tx.send(AgentEvent::StatusChange(AgentStatus::Running));
            let _ = tx.send(AgentEvent::OutputChunk(
                "hello from fake adapter".to_string(),
            ));
            let output_path = PathBuf::from(&input.worktree_path).join("fake-output.txt");
            let _ = tokio::fs::write(&output_path, "hello from fake adapter\n").await;
            release_completion.notified().await;
            let _ = tx.send(AgentEvent::Complete {
                summary: "fake adapter finished".to_string(),
            });
        });

        Ok(())
    }

    async fn interrupt(&self, _handle: &AgentHandle) -> Result<(), AgentError> {
        Ok(())
    }

    async fn stop(&self, _handle: &AgentHandle) -> Result<(), AgentError> {
        Ok(())
    }

    fn events(&self, handle: &AgentHandle) -> broadcast::Receiver<AgentEvent> {
        self.channels
            .lock()
            .expect("adapter channel lock poisoned")
            .get(&handle.id)
            .expect("channel for handle")
            .subscribe()
    }

    async fn parse_usage(&self, handle: &AgentHandle) -> Result<CostRecord, AgentError> {
        Ok(CostRecord {
            provider: "claude-code".to_string(),
            model: None,
            tokens_in: 1,
            tokens_out: 1,
            estimated_cost_usd: 0.01,
            timestamp: Utc::now(),
            task_id: handle.task_id,
            session_id: handle.id,
        })
    }
}

pub struct TestHarness {
    pub task_id: String,
    pub project_id: String,
    pub db: Db,
    pub state: AppState,
    pub emitter: Arc<RecordingEmitter>,
    pub pool: Arc<DispatchPool>,
    pub _tempdir: TempDir,
}

impl TestHarness {
    pub async fn new(adapter: Arc<dyn AgentAdapter>) -> Self {
        let tempdir = tempfile::tempdir().expect("tempdir");
        let db = open_test_db().await;
        let project_id = Uuid::new_v4();
        let project_root = tempdir.path().join("project");
        std::fs::create_dir_all(&project_root).expect("project root");
        std::fs::write(project_root.join("README.md"), "# test\n").expect("seed project");
        std::process::Command::new("git")
            .args(["init", "-b", "main"])
            .current_dir(&project_root)
            .output()
            .expect("init git repo");
        std::process::Command::new("git")
            .args(["config", "user.name", "Pnevma Tests"])
            .current_dir(&project_root)
            .output()
            .expect("configure git user");
        std::process::Command::new("git")
            .args(["config", "user.email", "tests@pnevma.local"])
            .current_dir(&project_root)
            .output()
            .expect("configure git email");
        std::process::Command::new("git")
            .args(["add", "README.md"])
            .current_dir(&project_root)
            .output()
            .expect("stage readme");
        std::process::Command::new("git")
            .args(["commit", "-m", "initial"])
            .current_dir(&project_root)
            .output()
            .expect("commit readme");

        db.upsert_project(
            &project_id.to_string(),
            "dispatch-test",
            project_root.to_string_lossy().as_ref(),
            None,
            None,
        )
        .await
        .expect("seed project");

        let task = make_task(&project_id.to_string());
        let task_id = task.id.clone();
        db.create_task(&task).await.expect("create task");

        let mut adapters = AdapterRegistry::default();
        adapters.register("claude-code", adapter);

        let pool = DispatchPool::new(1);
        let (shutdown_tx, _shutdown_rx) = tokio::sync::watch::channel(false);
        let ctx = ProjectContext {
            project_id,
            project_root_path: project_root.clone(),
            project_path: project_root.clone(),
            checkout_path: project_root.clone(),
            config: make_project_config(),
            global_config: GlobalConfig {
                default_provider: Some("claude-code".to_string()),
                ..GlobalConfig::default()
            },
            db: db.clone(),
            sessions: SessionSupervisor::new(project_root.join(".pnevma/data")),
            redaction_secrets: Arc::new(RwLock::new(Vec::new())),
            git: Arc::new(GitService::new(&project_root)),
            adapters,
            pool: pool.clone(),
            tracker: None,
            workflow_store: Arc::new(
                pnevma_commands::automation::workflow_store::WorkflowStore::new(&project_root),
            ),
            coordinator: None,
            shutdown_tx,
        };

        let emitter = Arc::new(RecordingEmitter::new());
        let emitter_trait: Arc<dyn EventEmitter> = emitter.clone();
        let state = AppState::new(emitter_trait);
        *state.current.lock().await = Some(ctx);

        Self {
            task_id,
            project_id: project_id.to_string(),
            db,
            state,
            emitter,
            pool,
            _tempdir: tempdir,
        }
    }
}

pub async fn wait_for_manual_run(db: &Db, project_id: &str) -> AutomationRunRow {
    tokio::time::timeout(Duration::from_secs(5), async {
        loop {
            let runs = db
                .list_automation_runs(project_id, 10)
                .await
                .expect("list automation runs");
            if let Some(run) = runs.into_iter().find(|run| run.origin == "manual") {
                return run;
            }
            tokio::time::sleep(Duration::from_millis(25)).await;
        }
    })
    .await
    .expect("manual automation run should appear")
}

pub async fn wait_for_manual_run_status(
    db: &Db,
    project_id: &str,
    status: &str,
) -> AutomationRunRow {
    let result = tokio::time::timeout(Duration::from_secs(5), async {
        loop {
            let run = wait_for_manual_run(db, project_id).await;
            let refreshed = db
                .get_automation_run(&run.id)
                .await
                .expect("get automation run")
                .expect("automation run exists");
            if refreshed.status == status {
                return refreshed;
            }
            tokio::time::sleep(Duration::from_millis(25)).await;
        }
    })
    .await;

    match result {
        Ok(run) => run,
        Err(_) => {
            let last_seen = db
                .list_automation_runs(project_id, 10)
                .await
                .expect("list automation runs")
                .into_iter()
                .find(|run| run.origin == "manual")
                .map(|run| {
                    format!(
                        "status={} summary={:?} error={:?}",
                        run.status, run.summary, run.error_message
                    )
                })
                .unwrap_or_else(|| "<missing>".to_string());
            panic!("manual automation run should reach target status; last_seen={last_seen}");
        }
    }
}

pub async fn open_test_db() -> Db {
    let pool = SqlitePoolOptions::new()
        .max_connections(1)
        .connect("sqlite::memory:")
        .await
        .expect("memory sqlite");
    let db = Db::from_pool_and_path(pool, PathBuf::from(":memory:"));
    db.migrate().await.expect("migrate");
    db
}

pub fn make_project_config() -> ProjectConfig {
    ProjectConfig {
        project: ProjectSection {
            name: "dispatch-test".to_string(),
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
            naming: "feat/{slug}".to_string(),
        },
        rules: PathSection::default(),
        conventions: PathSection::default(),
        remote: RemoteSection::default(),
        tracker: TrackerSection::default(),
        redaction: RedactionSection::default(),
    }
}

pub fn make_task(project_id: &str) -> TaskRow {
    let now = Utc::now();
    TaskRow {
        id: Uuid::new_v4().to_string(),
        project_id: project_id.to_string(),
        title: "Dispatch test".to_string(),
        goal: "Verify async dispatch".to_string(),
        scope_json: "[]".to_string(),
        dependencies_json: "[]".to_string(),
        acceptance_json: "[]".to_string(),
        constraints_json: "[]".to_string(),
        priority: match Priority::P2 {
            Priority::P0 => "P0",
            Priority::P1 => "P1",
            Priority::P2 => "P2",
            Priority::P3 => "P3",
        }
        .to_string(),
        status: "Ready".to_string(),
        branch: None,
        worktree_id: None,
        handoff_summary: None,
        created_at: now,
        updated_at: now,
        auto_dispatch: false,
        agent_profile_override: None,
        execution_mode: Some("worktree".to_string()),
        timeout_minutes: None,
        max_retries: None,
        loop_iteration: 0,
        loop_context_json: None,
    }
}

/// Wrapper around RecordingEmitter for cleaner test assertions.
pub struct EventVerifier {
    emitter: Arc<RecordingEmitter>,
}

impl EventVerifier {
    pub fn new(emitter: Arc<RecordingEmitter>) -> Self {
        Self { emitter }
    }

    /// Assert that the recorded events contain all the given event names (in any order).
    pub fn assert_events_contain(&self, expected: &[&str]) {
        let events = self.emitter.events.lock().expect("lock");
        let names: Vec<&str> = events.iter().map(|(name, _)| name.as_str()).collect();
        for exp in expected {
            assert!(
                names.contains(exp),
                "expected event '{}' not found in {:?}",
                exp,
                names
            );
        }
    }

    /// Assert that the given event names appear in the recorded events in the specified order
    /// (they don't need to be consecutive, but ordering must be preserved).
    pub fn assert_event_order(&self, expected_order: &[&str]) {
        let events = self.emitter.events.lock().expect("lock");
        let names: Vec<&str> = events.iter().map(|(name, _)| name.as_str()).collect();
        let mut search_from = 0;
        for exp in expected_order {
            let pos = names[search_from..].iter().position(|n| n == exp);
            assert!(
                pos.is_some(),
                "expected event '{}' not found after index {} in {:?}",
                exp,
                search_from,
                names
            );
            search_from += pos.unwrap() + 1;
        }
    }
}

/// Factory for creating tasks with a specific status.
pub fn make_task_with_status(project_id: &str, status: &str) -> TaskRow {
    let mut task = make_task(project_id);
    task.status = status.to_string();
    task
}
