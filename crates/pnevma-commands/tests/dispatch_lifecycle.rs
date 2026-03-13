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
use pnevma_commands::{
    commands::dispatch_task, event_emitter::EventEmitter, AppState, ProjectContext,
};
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

struct RecordingEmitter {
    events: Mutex<Vec<(String, Value)>>,
    notify: Notify,
}

impl RecordingEmitter {
    fn new() -> Self {
        Self {
            events: Mutex::new(Vec::new()),
            notify: Notify::new(),
        }
    }

    async fn wait_for_event(&self, name: &str) -> Value {
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

struct StreamingFakeAdapter {
    release_completion: Arc<Notify>,
    send_error: Option<String>,
    channels: Mutex<HashMap<Uuid, broadcast::Sender<AgentEvent>>>,
}

impl StreamingFakeAdapter {
    fn new(release_completion: Arc<Notify>) -> Self {
        Self {
            release_completion,
            send_error: None,
            channels: Mutex::new(HashMap::new()),
        }
    }

    fn failing(message: &str) -> Self {
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

struct TestHarness {
    task_id: String,
    project_id: String,
    db: Db,
    state: AppState,
    emitter: Arc<RecordingEmitter>,
    pool: Arc<DispatchPool>,
    _tempdir: TempDir,
}

impl TestHarness {
    async fn new(adapter: Arc<dyn AgentAdapter>) -> Self {
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
            project_path: project_root.clone(),
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

async fn wait_for_manual_run(db: &Db, project_id: &str) -> AutomationRunRow {
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

async fn wait_for_manual_run_status(db: &Db, project_id: &str, status: &str) -> AutomationRunRow {
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

async fn open_test_db() -> Db {
    let pool = SqlitePoolOptions::new()
        .max_connections(1)
        .connect("sqlite::memory:")
        .await
        .expect("memory sqlite");
    let db = Db::from_pool_and_path(pool, PathBuf::from(":memory:"));
    db.migrate().await.expect("migrate");
    db
}

fn make_project_config() -> ProjectConfig {
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

fn make_task(project_id: &str) -> TaskRow {
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

#[tokio::test]
async fn dispatch_returns_before_completion_and_streams_output() {
    let release_completion = Arc::new(Notify::new());
    let harness = TestHarness::new(Arc::new(StreamingFakeAdapter::new(Arc::clone(
        &release_completion,
    ))))
    .await;

    let status = tokio::time::timeout(
        Duration::from_secs(2),
        dispatch_task(
            harness.task_id.clone(),
            &harness.state.emitter,
            &harness.state,
        ),
    )
    .await
    .expect("dispatch should return before adapter completion")
    .expect("dispatch succeeded");

    assert_eq!(status, "started");

    let session_output = tokio::time::timeout(
        Duration::from_secs(2),
        harness.emitter.wait_for_event("session_output"),
    )
    .await
    .expect("session output should be emitted before completion");
    assert_eq!(
        session_output.get("chunk").and_then(Value::as_str),
        Some("hello from fake adapter")
    );

    let (_, active_before, _, _) = harness.pool.state().await;
    assert_eq!(
        active_before, 1,
        "dispatch permit should remain held while running"
    );

    release_completion.notify_waiters();

    tokio::time::timeout(Duration::from_secs(2), async {
        loop {
            let (_, active, _, _) = harness.pool.state().await;
            if active == 0 {
                break;
            }
            tokio::time::sleep(Duration::from_millis(25)).await;
        }
    })
    .await
    .expect("dispatch permit should be released after completion");

    let run = wait_for_manual_run_status(&harness.db, &harness.project_id, "completed").await;
    assert_eq!(run.origin, "manual");
    assert_eq!(run.status, "completed");
    assert!(
        run.finished_at.is_some(),
        "completed run should have finished_at"
    );
    assert_eq!(run.summary.as_deref(), Some("fake adapter finished"));

    let sessions = harness
        .db
        .list_sessions(&harness.project_id)
        .await
        .expect("list sessions");
    let agent_session = sessions
        .iter()
        .find(|session| session.r#type.as_deref() == Some("agent"))
        .expect("agent session exists");
    assert_eq!(agent_session.status, "completed");
}

#[tokio::test]
async fn launch_failure_marks_task_failed_and_releases_permit() {
    let harness = TestHarness::new(Arc::new(StreamingFakeAdapter::failing(
        "simulated launch failure",
    )))
    .await;

    let err = dispatch_task(
        harness.task_id.clone(),
        &harness.state.emitter,
        &harness.state,
    )
    .await
    .expect_err("launch failure should bubble up");
    assert!(err.contains("simulated launch failure"));

    let (_, active, _, _) = harness.pool.state().await;
    assert_eq!(
        active, 0,
        "dispatch permit must be released on launch failure"
    );

    let task = harness
        .db
        .get_task(&harness.task_id)
        .await
        .expect("task lookup")
        .expect("task exists");
    assert_eq!(task.status, "Failed");
    assert_eq!(
        task.handoff_summary.as_deref(),
        Some("spawn failed: simulated launch failure")
    );

    let run = wait_for_manual_run_status(&harness.db, &harness.project_id, "failed").await;
    assert_eq!(run.origin, "manual");
    assert_eq!(run.status, "failed");
    assert!(
        run.finished_at.is_some(),
        "failed run should have finished_at"
    );
    assert_eq!(
        run.error_message.as_deref(),
        Some("spawn failed: simulated launch failure")
    );

    let sessions = harness
        .db
        .list_sessions(&harness.project_id)
        .await
        .expect("list sessions");
    let agent_session = sessions
        .iter()
        .find(|session| session.r#type.as_deref() == Some("agent"))
        .expect("agent session exists");
    assert_eq!(agent_session.status, "failed");
}
