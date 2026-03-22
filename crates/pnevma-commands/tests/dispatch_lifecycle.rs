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
use sqlx::sqlite::{SqliteConnectOptions, SqlitePoolOptions};
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
        forked_from_task_id: None,
        lineage_summary: None,
        lineage_depth: 0,
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

    // Verify event ordering: session_output must appear in the recorded events.
    {
        let events = harness.emitter.events.lock().expect("emitter lock");
        let names: Vec<&str> = events.iter().map(|(n, _)| n.as_str()).collect();
        assert!(
            names.contains(&"session_output"),
            "session_output must appear in event stream, got: {names:?}"
        );
    }

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

#[tokio::test]
async fn completed_task_unblocks_blocked_dependent_task() {
    let release_completion = Arc::new(Notify::new());
    let harness = TestHarness::new(Arc::new(StreamingFakeAdapter::new(Arc::clone(
        &release_completion,
    ))))
    .await;

    let mut main_task = harness
        .db
        .get_task(&harness.task_id)
        .await
        .expect("main task lookup")
        .expect("main task exists");
    main_task.loop_context_json = Some("{\"mode\":\"until_complete\"}".to_string());
    main_task.updated_at = Utc::now();
    harness
        .db
        .update_task(&main_task)
        .await
        .expect("update main task");

    let dependent_id = Uuid::new_v4().to_string();
    let dependent = TaskRow {
        id: dependent_id.clone(),
        project_id: harness.project_id.clone(),
        title: "Dependent task".to_string(),
        goal: "Should unblock after main task completes".to_string(),
        scope_json: "[]".to_string(),
        dependencies_json: serde_json::to_string(&vec![harness.task_id.clone()])
            .expect("dependency json"),
        acceptance_json: "[]".to_string(),
        constraints_json: "[]".to_string(),
        priority: "P2".to_string(),
        status: "Blocked".to_string(),
        branch: None,
        worktree_id: None,
        handoff_summary: None,
        created_at: Utc::now(),
        updated_at: Utc::now(),
        auto_dispatch: false,
        agent_profile_override: None,
        execution_mode: Some("worktree".to_string()),
        timeout_minutes: None,
        max_retries: None,
        loop_iteration: 0,
        loop_context_json: None,
        forked_from_task_id: None,
        lineage_summary: None,
        lineage_depth: 0,
    };
    harness
        .db
        .create_task(&dependent)
        .await
        .expect("create dependent");
    harness
        .db
        .replace_task_dependencies(&dependent_id, std::slice::from_ref(&harness.task_id))
        .await
        .expect("replace dependencies");

    let status = dispatch_task(
        harness.task_id.clone(),
        &harness.state.emitter,
        &harness.state,
    )
    .await
    .expect("dispatch succeeded");
    assert_eq!(status, "started");

    tokio::time::timeout(
        Duration::from_secs(2),
        harness.emitter.wait_for_event("session_output"),
    )
    .await
    .expect("session output should be emitted before completion");

    release_completion.notify_waiters();

    // CI runners under load may need more time for the full async pipeline:
    // event receive → status update → dependency refresh → DB write.
    let result = tokio::time::timeout(Duration::from_secs(15), async {
        loop {
            let dependent = harness
                .db
                .get_task(&dependent_id)
                .await
                .expect("dependent lookup")
                .expect("dependent task exists");
            let main = harness
                .db
                .get_task(&harness.task_id)
                .await
                .expect("main lookup")
                .expect("main task exists");
            if main.status == "Done" && dependent.status == "Ready" {
                break;
            }
            tokio::time::sleep(Duration::from_millis(50)).await;
        }
    })
    .await;

    if result.is_err() {
        let dependent = harness
            .db
            .get_task(&dependent_id)
            .await
            .expect("dependent lookup")
            .expect("dependent task exists");
        let main = harness
            .db
            .get_task(&harness.task_id)
            .await
            .expect("main lookup")
            .expect("main task exists");
        let run = harness
            .db
            .list_automation_runs(&harness.project_id, 10)
            .await
            .expect("list automation runs")
            .into_iter()
            .find(|run| run.origin == "manual");
        panic!(
            "dependent task should unblock after main task reaches Done; main_status={} dependent_status={} run_status={:?} run_summary={:?} dependent_handoff={:?}",
            main.status,
            dependent.status,
            run.as_ref().map(|r| r.status.as_str()),
            run.as_ref().and_then(|r| r.summary.as_deref()),
            dependent.handoff_summary
        );
    }
}

/// Validates the persist-restart-restore path: task and automation-run state
/// written to a file-backed SQLite database survive a full pool close and
/// reconnect, simulating a supervisor restart.
#[tokio::test]
async fn dispatch_state_survives_db_reconnect() {
    let tempdir = tempfile::tempdir().expect("tempdir");
    let db_path = tempdir.path().join("pnevma-test.db");

    let project_id = Uuid::new_v4().to_string();
    let task_id = Uuid::new_v4().to_string();
    let run_id = Uuid::new_v4().to_string();
    let now = Utc::now();

    // ── Phase 1: open DB, seed data, close ──────────────────────────────
    {
        let options = SqliteConnectOptions::new()
            .filename(&db_path)
            .create_if_missing(true);
        let pool = SqlitePoolOptions::new()
            .max_connections(1)
            .connect_with(options)
            .await
            .expect("open file-backed sqlite");
        let db = Db::from_pool_and_path(pool, db_path.clone());
        db.migrate().await.expect("migrate");

        // Seed project (required FK parent).
        db.upsert_project(&project_id, "reconnect-test", "/tmp/reconnect", None, None)
            .await
            .expect("seed project");

        // Create task in InProgress state.
        let task = TaskRow {
            id: task_id.clone(),
            project_id: project_id.clone(),
            title: "Reconnect test task".to_string(),
            goal: "Verify state survives reconnect".to_string(),
            scope_json: "[]".to_string(),
            dependencies_json: "[]".to_string(),
            acceptance_json: "[]".to_string(),
            constraints_json: "[]".to_string(),
            priority: "P1".to_string(),
            status: "InProgress".to_string(),
            branch: Some("feat/reconnect".to_string()),
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
            forked_from_task_id: None,
            lineage_summary: None,
            lineage_depth: 0,
        };
        db.create_task(&task).await.expect("create task");

        // Create automation run in running state.
        let run = AutomationRunRow {
            id: run_id.clone(),
            project_id: project_id.clone(),
            task_id: task_id.clone(),
            run_id: Uuid::new_v4().to_string(),
            origin: "manual".to_string(),
            provider: "claude-code".to_string(),
            model: Some("opus".to_string()),
            status: "running".to_string(),
            attempt: 1,
            started_at: now,
            finished_at: None,
            duration_seconds: None,
            tokens_in: 100,
            tokens_out: 50,
            cost_usd: 0.05,
            summary: None,
            error_message: None,
            created_at: now,
        };
        db.create_automation_run(&run)
            .await
            .expect("create automation run");

        // Verify data is readable before close.
        let pre_task = db
            .get_task(&task_id)
            .await
            .expect("pre-close task lookup")
            .expect("task exists before close");
        assert_eq!(pre_task.status, "InProgress");

        // Close the pool, dropping all connections.
        db.pool().close().await;
    }

    // ── Phase 2: reopen the same file, verify state persisted ───────────
    {
        let options = SqliteConnectOptions::new()
            .filename(&db_path)
            .create_if_missing(false);
        let pool = SqlitePoolOptions::new()
            .max_connections(1)
            .connect_with(options)
            .await
            .expect("reopen file-backed sqlite");
        let db2 = Db::from_pool_and_path(pool, db_path.clone());
        // No migrate needed — schema already exists from phase 1.

        // Verify task state survived.
        let restored_task = db2
            .get_task(&task_id)
            .await
            .expect("post-reconnect task lookup")
            .expect("task exists after reconnect");
        assert_eq!(
            restored_task.status, "InProgress",
            "task status must survive reconnect"
        );
        assert_eq!(
            restored_task.title, "Reconnect test task",
            "task title must survive reconnect"
        );
        assert_eq!(
            restored_task.branch.as_deref(),
            Some("feat/reconnect"),
            "task branch must survive reconnect"
        );
        assert_eq!(
            restored_task.priority, "P1",
            "task priority must survive reconnect"
        );

        // Verify automation run state survived.
        let restored_run = db2
            .get_automation_run(&run_id)
            .await
            .expect("post-reconnect run lookup")
            .expect("automation run exists after reconnect");
        assert_eq!(
            restored_run.status, "running",
            "run status must survive reconnect"
        );
        assert_eq!(
            restored_run.task_id, task_id,
            "run task_id must survive reconnect"
        );
        assert_eq!(
            restored_run.origin, "manual",
            "run origin must survive reconnect"
        );
        assert_eq!(
            restored_run.provider, "claude-code",
            "run provider must survive reconnect"
        );
        assert_eq!(
            restored_run.model.as_deref(),
            Some("opus"),
            "run model must survive reconnect"
        );
        assert!(
            restored_run.finished_at.is_none(),
            "running run should have no finished_at"
        );

        // Verify list query also works on the restored connection.
        let runs = db2
            .list_automation_runs(&project_id, 10)
            .await
            .expect("list automation runs after reconnect");
        assert_eq!(runs.len(), 1, "should find exactly one run after reconnect");
        assert_eq!(runs[0].id, run_id);
        // Verify automation run_id (the internal unique identifier) is consistent
        assert_eq!(
            restored_run.run_id, runs[0].run_id,
            "run_id must be consistent across get and list after reconnect"
        );

        db2.pool().close().await;
    }
}
