use super::*;
use crate::models::{
    AutomationRetryRow, AutomationRunRow, ContextRuleUsageRow, CostRow, ErrorSignatureRow,
    FeedbackRow, NotificationRow, OnboardingStateRow, ReviewRow, RuleRow, SecretRefRow, SessionRow,
    TaskRow, TelemetryEventRow, WorkflowInstanceRow, WorktreeRow,
};
use chrono::Utc;
use sqlx::sqlite::SqlitePoolOptions;
use uuid::Uuid;

async fn open_test_db() -> Db {
    let pool = SqlitePoolOptions::new()
        .max_connections(1)
        .connect("sqlite::memory:")
        .await
        .expect("memory sqlite");
    let db = Db {
        pool,
        path: PathBuf::from(":memory:"),
    };
    db.migrate().await.expect("migrate");
    db
}

// ── Helper to create a project that foreign keys can reference ──────────
async fn seed_project(db: &Db, project_id: &str) {
    db.upsert_project(project_id, "test", "/tmp/test", None, None)
        .await
        .expect("seed project");
}

// ── D1: Task roundtrip ──────────────────────────────────────────────────

#[tokio::test]
async fn task_roundtrip() {
    let db = open_test_db().await;
    let project_id = Uuid::new_v4().to_string();
    seed_project(&db, &project_id).await;

    let now = Utc::now();
    let task = TaskRow {
        id: Uuid::new_v4().to_string(),
        project_id: project_id.clone(),
        title: "Implement feature X".to_string(),
        goal: "Deliver feature X".to_string(),
        scope_json: "[]".to_string(),
        dependencies_json: "[]".to_string(),
        acceptance_json: "[]".to_string(),
        constraints_json: "[]".to_string(),
        priority: "P1".to_string(),
        status: "Planned".to_string(),
        branch: Some("feat/x".to_string()),
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
    };

    db.create_task(&task).await.expect("create task");

    let loaded = db
        .get_task(&task.id)
        .await
        .expect("get task")
        .expect("task should exist");
    assert_eq!(loaded.id, task.id);
    assert_eq!(loaded.title, "Implement feature X");
    assert_eq!(loaded.priority, "P1");
    assert_eq!(loaded.status, "Planned");
    assert_eq!(loaded.branch.as_deref(), Some("feat/x"));
    assert!(!loaded.auto_dispatch);

    // Update and verify
    let mut updated = loaded.clone();
    updated.status = "InProgress".to_string();
    updated.updated_at = Utc::now();
    db.update_task(&updated).await.expect("update task");

    let reloaded = db
        .get_task(&task.id)
        .await
        .expect("get task after update")
        .expect("task should still exist");
    assert_eq!(reloaded.status, "InProgress");

    // list_tasks
    let tasks = db.list_tasks(&project_id).await.expect("list tasks");
    assert_eq!(tasks.len(), 1);

    // delete
    db.delete_task(&task.id).await.expect("delete task");
    let gone = db.get_task(&task.id).await.expect("get deleted task");
    assert!(gone.is_none());
}

#[tokio::test]
async fn secret_ref_roundtrip_supports_multiple_backends() {
    let db = open_test_db().await;
    let project_id = Uuid::new_v4().to_string();
    seed_project(&db, &project_id).await;

    let now = Utc::now();
    let keychain = SecretRefRow {
        id: Uuid::new_v4().to_string(),
        project_id: Some(project_id.clone()),
        scope: "project".to_string(),
        name: "OPENAI_API_KEY".to_string(),
        backend: "keychain".to_string(),
        keychain_service: Some(format!("pnevma.project.{project_id}")),
        keychain_account: Some("OPENAI_API_KEY".to_string()),
        env_file_path: None,
        created_at: now,
        updated_at: now,
    };
    db.upsert_secret_ref(&keychain)
        .await
        .expect("insert keychain secret");

    let env_file = SecretRefRow {
        id: Uuid::new_v4().to_string(),
        project_id: Some(project_id.clone()),
        scope: "project".to_string(),
        name: "DATABASE_URL".to_string(),
        backend: "env_file".to_string(),
        keychain_service: None,
        keychain_account: None,
        env_file_path: Some(".env.local".to_string()),
        created_at: now,
        updated_at: now,
    };
    db.upsert_secret_ref(&env_file)
        .await
        .expect("insert env file secret");

    let rows = db
        .list_secret_refs(&project_id, None)
        .await
        .expect("list secret refs");
    assert_eq!(rows.len(), 2);
    assert!(rows.iter().any(|row| {
        row.name == "OPENAI_API_KEY"
            && row.backend == "keychain"
            && row.keychain_service.as_deref() == Some(&format!("pnevma.project.{project_id}"))
    }));
    assert!(rows.iter().any(|row| {
        row.name == "DATABASE_URL"
            && row.backend == "env_file"
            && row.env_file_path.as_deref() == Some(".env.local")
    }));

    let fetched = db
        .get_secret_ref(&env_file.id)
        .await
        .expect("get secret ref")
        .expect("secret ref exists");
    assert_eq!(fetched.name, "DATABASE_URL");
    assert_eq!(fetched.backend, "env_file");

    db.delete_secret_ref(&env_file.id)
        .await
        .expect("delete secret ref");
    let remaining = db
        .list_secret_refs(&project_id, None)
        .await
        .expect("list secret refs after delete");
    assert_eq!(remaining.len(), 1);
    assert_eq!(remaining[0].name, "OPENAI_API_KEY");
}

#[tokio::test]
async fn update_secret_ref_allows_renaming_existing_secret() {
    let db = open_test_db().await;
    let project_id = Uuid::new_v4().to_string();
    seed_project(&db, &project_id).await;

    let now = Utc::now();
    let mut row = SecretRefRow {
        id: Uuid::new_v4().to_string(),
        project_id: Some(project_id.clone()),
        scope: "project".to_string(),
        name: "OPENAI_API_KEY".to_string(),
        backend: "keychain".to_string(),
        keychain_service: Some(format!("pnevma.project.{project_id}")),
        keychain_account: Some("OPENAI_API_KEY".to_string()),
        env_file_path: None,
        created_at: now,
        updated_at: now,
    };
    db.upsert_secret_ref(&row).await.expect("insert secret ref");

    row.name = "ANTHROPIC_API_KEY".to_string();
    row.keychain_account = Some("ANTHROPIC_API_KEY".to_string());
    row.updated_at = Utc::now();
    db.update_secret_ref(&row).await.expect("rename secret ref");

    let rows = db
        .list_secret_refs(&project_id, Some("project"))
        .await
        .expect("list renamed secret refs");
    assert_eq!(rows.len(), 1);
    assert_eq!(rows[0].id, row.id);
    assert_eq!(rows[0].name, "ANTHROPIC_API_KEY");
    assert_eq!(
        rows[0].keychain_account.as_deref(),
        Some("ANTHROPIC_API_KEY")
    );
}

#[tokio::test]
async fn upsert_review_reuses_existing_task_row_without_unique_constraint() {
    let db = open_test_db().await;
    let project_id = Uuid::new_v4().to_string();
    seed_project(&db, &project_id).await;

    let now = Utc::now();
    let task = TaskRow {
        id: Uuid::new_v4().to_string(),
        project_id,
        title: "Review me".to_string(),
        goal: "Generate review pack".to_string(),
        scope_json: "[]".to_string(),
        dependencies_json: "[]".to_string(),
        acceptance_json: "[]".to_string(),
        constraints_json: "[]".to_string(),
        priority: "P2".to_string(),
        status: "Review".to_string(),
        branch: Some("feat/review".to_string()),
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
    };
    db.create_task(&task).await.expect("create task");

    let first = ReviewRow {
        id: Uuid::new_v4().to_string(),
        task_id: task.id.clone(),
        status: "Ready".to_string(),
        review_pack_path: "/tmp/review-pack-1.json".to_string(),
        reviewer_notes: None,
        approved_at: None,
    };
    db.upsert_review(&first).await.expect("insert review");

    let second = ReviewRow {
        id: Uuid::new_v4().to_string(),
        task_id: task.id.clone(),
        status: "Approved".to_string(),
        review_pack_path: "/tmp/review-pack-2.json".to_string(),
        reviewer_notes: Some("looks good".to_string()),
        approved_at: Some(Utc::now()),
    };
    db.upsert_review(&second).await.expect("update review");

    let loaded = db
        .get_review_by_task(&task.id)
        .await
        .expect("load review")
        .expect("review exists");
    assert_eq!(loaded.id, second.id);
    assert_eq!(loaded.status, "Approved");
    assert_eq!(loaded.review_pack_path, "/tmp/review-pack-2.json");
    assert_eq!(loaded.reviewer_notes.as_deref(), Some("looks good"));
}

#[tokio::test]
async fn append_cost_accepts_automation_run_foreign_key() {
    let db = open_test_db().await;
    let project_id = Uuid::new_v4().to_string();
    seed_project(&db, &project_id).await;

    let now = Utc::now();
    let task = TaskRow {
        id: Uuid::new_v4().to_string(),
        project_id: project_id.clone(),
        title: "Track cost".to_string(),
        goal: "Persist usage".to_string(),
        scope_json: "[]".to_string(),
        dependencies_json: "[]".to_string(),
        acceptance_json: "[]".to_string(),
        constraints_json: "[]".to_string(),
        priority: "P2".to_string(),
        status: "InProgress".to_string(),
        branch: Some("feat/cost".to_string()),
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
    };
    db.create_task(&task).await.expect("create task");

    let session = SessionRow {
        id: Uuid::new_v4().to_string(),
        project_id: project_id.clone(),
        name: "agent".to_string(),
        r#type: Some("agent".to_string()),
        status: "running".to_string(),
        pid: Some(42),
        cwd: "/tmp".to_string(),
        command: "claude".to_string(),
        branch: None,
        worktree_id: None,
        started_at: now,
        last_heartbeat: now,
        restore_status: None,
        exit_code: None,
        ended_at: None,
    };
    db.upsert_session(&session).await.expect("create session");

    let run = AutomationRunRow {
        id: Uuid::new_v4().to_string(),
        project_id: project_id.clone(),
        task_id: task.id.clone(),
        run_id: Uuid::new_v4().to_string(),
        origin: "manual".to_string(),
        provider: "claude-code".to_string(),
        model: None,
        status: "running".to_string(),
        attempt: 1,
        started_at: now,
        finished_at: None,
        duration_seconds: None,
        tokens_in: 0,
        tokens_out: 0,
        cost_usd: 0.0,
        summary: None,
        error_message: None,
        created_at: now,
    };
    db.create_automation_run(&run)
        .await
        .expect("create automation run");

    let cost = CostRow {
        id: Uuid::new_v4().to_string(),
        agent_run_id: Some(run.id.clone()),
        task_id: task.id.clone(),
        session_id: session.id.clone(),
        provider: "claude-code".to_string(),
        model: None,
        tokens_in: 12,
        tokens_out: 34,
        estimated_usd: 0.56,
        tracked: true,
        timestamp: now,
    };
    db.append_cost(&cost).await.expect("append cost");

    let loaded = sqlx::query_as::<_, CostRow>(
        r#"
        SELECT id, agent_run_id, task_id, session_id, provider, model,
               tokens_in, tokens_out, estimated_usd, tracked, timestamp
        FROM costs
        WHERE task_id = ?1
        "#,
    )
    .bind(&task.id)
    .fetch_all(&db.pool)
    .await
    .expect("list costs");
    assert_eq!(loaded.len(), 1);
    assert_eq!(loaded[0].agent_run_id.as_deref(), Some(run.id.as_str()));
    assert_eq!(loaded[0].estimated_usd, 0.56);
}

#[tokio::test]
async fn task_dependencies_roundtrip() {
    let db = open_test_db().await;
    let project_id = Uuid::new_v4().to_string();
    seed_project(&db, &project_id).await;

    let now = Utc::now();
    let make_task = |id: &str| TaskRow {
        id: id.to_string(),
        project_id: project_id.clone(),
        title: format!("Task {id}"),
        goal: "goal".to_string(),
        scope_json: "[]".to_string(),
        dependencies_json: "[]".to_string(),
        acceptance_json: "[]".to_string(),
        constraints_json: "[]".to_string(),
        priority: "P2".to_string(),
        status: "Planned".to_string(),
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
    };

    let t1_id = Uuid::new_v4().to_string();
    let t2_id = Uuid::new_v4().to_string();
    db.create_task(&make_task(&t1_id)).await.expect("create t1");
    db.create_task(&make_task(&t2_id)).await.expect("create t2");

    db.replace_task_dependencies(&t2_id, std::slice::from_ref(&t1_id))
        .await
        .expect("replace deps");

    let deps = db.list_task_dependencies(&t2_id).await.expect("list deps");
    assert_eq!(deps, vec![t1_id.clone()]);

    // replace with empty clears deps
    db.replace_task_dependencies(&t2_id, &[])
        .await
        .expect("clear deps");
    let empty = db
        .list_task_dependencies(&t2_id)
        .await
        .expect("list empty deps");
    assert!(empty.is_empty());
}

// ── D1: Session roundtrip ───────────────────────────────────────────────

#[tokio::test]
async fn session_roundtrip() {
    let db = open_test_db().await;
    let project_id = Uuid::new_v4().to_string();
    seed_project(&db, &project_id).await;

    let now = Utc::now();
    let session = SessionRow {
        id: Uuid::new_v4().to_string(),
        project_id: project_id.clone(),
        name: "claude-session".to_string(),
        r#type: Some("claude".to_string()),
        status: "running".to_string(),
        pid: Some(12345),
        cwd: "/tmp/project".to_string(),
        command: "claude".to_string(),
        branch: Some("main".to_string()),
        worktree_id: None,
        started_at: now,
        last_heartbeat: now,
        restore_status: None,
        exit_code: None,
        ended_at: None,
    };

    db.upsert_session(&session).await.expect("upsert session");

    let sessions = db.list_sessions(&project_id).await.expect("list sessions");
    assert_eq!(sessions.len(), 1);
    let loaded = &sessions[0];
    assert_eq!(loaded.id, session.id);
    assert_eq!(loaded.name, "claude-session");
    assert_eq!(loaded.pid, Some(12345));
    assert_eq!(loaded.status, "running");

    // upsert updates status
    let mut updated = session.clone();
    updated.status = "stopped".to_string();
    updated.pid = None;
    db.upsert_session(&updated).await.expect("upsert update");

    let sessions2 = db
        .list_sessions(&project_id)
        .await
        .expect("list sessions after update");
    assert_eq!(sessions2[0].status, "stopped");
    assert_eq!(sessions2[0].pid, None);
}

// ── D1: Event roundtrip ─────────────────────────────────────────────────

#[tokio::test]
async fn event_roundtrip_and_filter() {
    let db = open_test_db().await;
    let project_id = Uuid::new_v4().to_string();
    seed_project(&db, &project_id).await;

    let task_id = Uuid::new_v4().to_string();
    let session_id = Uuid::new_v4().to_string();

    let ev1 = NewEvent {
        id: Uuid::new_v4().to_string(),
        project_id: project_id.clone(),
        task_id: Some(task_id.clone()),
        session_id: Some(session_id.clone()),
        trace_id: "trace-1".to_string(),
        source: "agent".to_string(),
        event_type: "task.start".to_string(),
        payload: serde_json::json!({"key": "value"}),
    };
    let ev2 = NewEvent {
        id: Uuid::new_v4().to_string(),
        project_id: project_id.clone(),
        task_id: Some(task_id.clone()),
        session_id: None,
        trace_id: "trace-2".to_string(),
        source: "system".to_string(),
        event_type: "task.complete".to_string(),
        payload: serde_json::json!({}),
    };

    db.append_event(ev1).await.expect("append ev1");
    db.append_event(ev2).await.expect("append ev2");

    // Unfiltered query
    let all = db
        .query_events(EventQueryFilter {
            project_id: project_id.clone(),
            ..Default::default()
        })
        .await
        .expect("query all events");
    assert_eq!(all.len(), 2);

    // Filter by event_type
    let filtered = db
        .query_events(EventQueryFilter {
            project_id: project_id.clone(),
            event_type: Some("task.start".to_string()),
            ..Default::default()
        })
        .await
        .expect("query filtered events");
    assert_eq!(filtered.len(), 1);
    assert_eq!(filtered[0].event_type, "task.start");
    assert_eq!(filtered[0].source, "agent");

    // limit
    let limited = db
        .query_events(EventQueryFilter {
            project_id: project_id.clone(),
            limit: Some(1),
            ..Default::default()
        })
        .await
        .expect("query limited events");
    assert_eq!(limited.len(), 1);

    // list_recent_events returns in ascending order
    let recent = db
        .list_recent_events(&project_id, 10)
        .await
        .expect("list recent");
    assert_eq!(recent.len(), 2);
}

// ── D1: Workflow roundtrip ──────────────────────────────────────────────

#[tokio::test]
async fn workflow_instance_roundtrip() {
    let db = open_test_db().await;
    let project_id = Uuid::new_v4().to_string();
    seed_project(&db, &project_id).await;

    let now = Utc::now();
    let instance = WorkflowInstanceRow {
        id: Uuid::new_v4().to_string(),
        project_id: project_id.clone(),
        workflow_name: "deploy".to_string(),
        description: Some("Deploy to prod".to_string()),
        status: "pending".to_string(),
        created_at: now,
        updated_at: now,
        params_json: None,
        stage_results_json: None,
        expanded_steps_json: None,
    };

    db.create_workflow_instance(&instance)
        .await
        .expect("create workflow instance");

    let loaded = db
        .get_workflow_instance(&instance.id)
        .await
        .expect("get workflow instance")
        .expect("instance should exist");
    assert_eq!(loaded.workflow_name, "deploy");
    assert_eq!(loaded.status, "pending");
    assert_eq!(loaded.description.as_deref(), Some("Deploy to prod"));

    // Update status
    db.update_workflow_instance_status(&instance.id, "running")
        .await
        .expect("update status");
    let updated = db
        .get_workflow_instance(&instance.id)
        .await
        .expect("get after update")
        .expect("instance");
    assert_eq!(updated.status, "running");

    // workflow_tasks
    let now2 = Utc::now();
    let task_row = TaskRow {
        id: Uuid::new_v4().to_string(),
        project_id: project_id.clone(),
        title: "wf task".to_string(),
        goal: "goal".to_string(),
        scope_json: "[]".to_string(),
        dependencies_json: "[]".to_string(),
        acceptance_json: "[]".to_string(),
        constraints_json: "[]".to_string(),
        priority: "P3".to_string(),
        status: "Planned".to_string(),
        branch: None,
        worktree_id: None,
        handoff_summary: None,
        created_at: now2,
        updated_at: now2,
        auto_dispatch: false,
        agent_profile_override: None,
        execution_mode: None,
        timeout_minutes: None,
        max_retries: None,
        loop_iteration: 0,
        loop_context_json: None,
        forked_from_task_id: None,
        lineage_depth: 0,
        lineage_summary: None,
    };
    db.create_task(&task_row).await.expect("create wf task");
    db.add_workflow_task(&instance.id, 0, 0, &task_row.id)
        .await
        .expect("add wf task");

    let wf_tasks = db
        .list_workflow_tasks(&instance.id)
        .await
        .expect("list wf tasks");
    assert_eq!(wf_tasks.len(), 1);
    assert_eq!(wf_tasks[0].task_id, task_row.id);
    assert_eq!(wf_tasks[0].step_index, 0);

    // find_workflow_by_task
    let found = db
        .find_workflow_by_task(&task_row.id)
        .await
        .expect("find wf by task")
        .expect("should be found");
    assert_eq!(found.workflow_id, instance.id);

    // list_workflow_instances
    let list = db
        .list_workflow_instances(&project_id)
        .await
        .expect("list instances");
    assert_eq!(list.len(), 1);
}

// ── D1: Notification roundtrip ──────────────────────────────────────────

#[tokio::test]
async fn notification_roundtrip() {
    let db = open_test_db().await;
    let project_id = Uuid::new_v4().to_string();
    seed_project(&db, &project_id).await;

    let n1 = NotificationRow {
        id: Uuid::new_v4().to_string(),
        project_id: project_id.clone(),
        task_id: None,
        session_id: None,
        title: "Task complete".to_string(),
        body: "Task completed successfully".to_string(),
        level: "info".to_string(),
        unread: true,
        created_at: Utc::now(),
    };
    let n2 = NotificationRow {
        id: Uuid::new_v4().to_string(),
        project_id: project_id.clone(),
        task_id: None,
        session_id: None,
        title: "Error".to_string(),
        body: "Something went wrong".to_string(),
        level: "error".to_string(),
        unread: true,
        created_at: Utc::now(),
    };

    db.create_notification(&n1).await.expect("create n1");
    db.create_notification(&n2).await.expect("create n2");

    // list all
    let all = db
        .list_notifications(&project_id, false)
        .await
        .expect("list all");
    assert_eq!(all.len(), 2);

    // list unread only
    let unread = db
        .list_notifications(&project_id, true)
        .await
        .expect("list unread");
    assert_eq!(unread.len(), 2);

    // mark one read
    db.mark_notification_read(&n1.id).await.expect("mark read");
    let unread_after = db
        .list_notifications(&project_id, true)
        .await
        .expect("list unread after mark");
    assert_eq!(unread_after.len(), 1);
    assert_eq!(unread_after[0].id, n2.id);

    // clear all
    db.clear_notifications(&project_id)
        .await
        .expect("clear notifications");
    let unread_cleared = db
        .list_notifications(&project_id, true)
        .await
        .expect("list after clear");
    assert!(unread_cleared.is_empty());
}

// ── D1: Worktree roundtrip ──────────────────────────────────────────────

#[tokio::test]
async fn worktree_roundtrip() {
    let db = open_test_db().await;
    let project_id = Uuid::new_v4().to_string();
    seed_project(&db, &project_id).await;

    let now = Utc::now();
    let task_id = Uuid::new_v4().to_string();
    // create a task first (worktrees have FK to tasks with ON DELETE CASCADE)
    let task = TaskRow {
        id: task_id.clone(),
        project_id: project_id.clone(),
        title: "t".to_string(),
        goal: "g".to_string(),
        scope_json: "[]".to_string(),
        dependencies_json: "[]".to_string(),
        acceptance_json: "[]".to_string(),
        constraints_json: "[]".to_string(),
        priority: "P3".to_string(),
        status: "Planned".to_string(),
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
        lineage_depth: 0,
        lineage_summary: None,
    };
    db.create_task(&task).await.expect("create task for wt");

    let wt = WorktreeRow {
        id: Uuid::new_v4().to_string(),
        project_id: project_id.clone(),
        task_id: task_id.clone(),
        path: "/tmp/worktrees/feat-x".to_string(),
        branch: "feat/x".to_string(),
        lease_status: "Active".to_string(),
        lease_started: now,
        last_active: now,
    };
    db.upsert_worktree(&wt).await.expect("upsert worktree");

    let loaded = db
        .find_worktree_by_task(&task_id)
        .await
        .expect("find worktree")
        .expect("should exist");
    assert_eq!(loaded.id, wt.id);
    assert_eq!(loaded.branch, "feat/x");
    assert_eq!(loaded.lease_status, "Active");

    let list = db
        .list_worktrees(&project_id)
        .await
        .expect("list worktrees");
    assert_eq!(list.len(), 1);

    db.remove_worktree_by_task(&task_id)
        .await
        .expect("remove worktree");
    let gone = db
        .find_worktree_by_task(&task_id)
        .await
        .expect("find after remove");
    assert!(gone.is_none());
}

#[tokio::test]
async fn phase5_ops_roundtrip() {
    let db = open_test_db().await;
    let project_id = Uuid::new_v4().to_string();

    db.upsert_project(
        &project_id,
        "test-project",
        "/tmp/test-project",
        Some("brief"),
        None,
    )
    .await
    .expect("upsert project");

    let onboarding = OnboardingStateRow {
        project_id: project_id.clone(),
        step: "dispatch_task".to_string(),
        completed: false,
        dismissed: false,
        updated_at: Utc::now(),
    };
    db.upsert_onboarding_state(&onboarding)
        .await
        .expect("onboarding upsert");
    let loaded_onboarding = db
        .get_onboarding_state(&project_id)
        .await
        .expect("onboarding get")
        .expect("onboarding row");
    assert_eq!(loaded_onboarding.step, "dispatch_task");

    let rule_id = Uuid::new_v4().to_string();
    db.upsert_rule(&RuleRow {
        id: rule_id.clone(),
        project_id: project_id.clone(),
        name: "security".to_string(),
        path: ".pnevma/rules/security.md".to_string(),
        scope: Some("rule".to_string()),
        active: true,
    })
    .await
    .expect("rule upsert");
    db.create_context_rule_usage(&ContextRuleUsageRow {
        id: Uuid::new_v4().to_string(),
        project_id: project_id.clone(),
        run_id: "run-1".to_string(),
        rule_id: rule_id.clone(),
        included: true,
        reason: "active".to_string(),
        created_at: Utc::now(),
    })
    .await
    .expect("rule usage insert");
    let usage = db
        .list_context_rule_usage(&project_id, &rule_id, 100)
        .await
        .expect("rule usage list");
    assert_eq!(usage.len(), 1);
    assert!(usage[0].included);

    db.append_telemetry_event(&TelemetryEventRow {
        id: Uuid::new_v4().to_string(),
        project_id: project_id.clone(),
        event_type: "project.open".to_string(),
        payload_json: "{\"ok\":true}".to_string(),
        anonymized: true,
        created_at: Utc::now(),
    })
    .await
    .expect("append telemetry");
    db.append_telemetry_event(&TelemetryEventRow {
        id: Uuid::new_v4().to_string(),
        project_id: project_id.clone(),
        event_type: "task.dispatch".to_string(),
        payload_json: "{\"ok\":true}".to_string(),
        anonymized: true,
        created_at: Utc::now(),
    })
    .await
    .expect("append telemetry");
    assert_eq!(
        db.count_telemetry_events(&project_id)
            .await
            .expect("telemetry count"),
        2
    );
    db.clear_telemetry_events(&project_id)
        .await
        .expect("telemetry clear");
    assert_eq!(
        db.count_telemetry_events(&project_id)
            .await
            .expect("telemetry count after clear"),
        0
    );

    db.create_feedback(&FeedbackRow {
        id: Uuid::new_v4().to_string(),
        project_id: project_id.clone(),
        category: "ux".to_string(),
        body: "keyboard flow friction".to_string(),
        contact: Some("partner@example.com".to_string()),
        artifact_path: Some(".pnevma/data/feedback/ux.md".to_string()),
        created_at: Utc::now(),
    })
    .await
    .expect("feedback insert");
    let feedback = db
        .list_feedback(&project_id, 100)
        .await
        .expect("feedback list");
    assert_eq!(feedback.len(), 1);
    assert_eq!(feedback[0].category, "ux");
}

// ── D1: Workflow definition roundtrip ───────────────────────────────────

#[tokio::test]
async fn workflow_definition_roundtrip() {
    let db = open_test_db().await;
    let project_id = Uuid::new_v4().to_string();
    seed_project(&db, &project_id).await;

    let now = Utc::now();
    let wf = crate::models::WorkflowRow {
        id: Uuid::new_v4().to_string(),
        project_id: project_id.clone(),
        name: "ci-pipeline".to_string(),
        description: Some("Runs CI steps".to_string()),
        definition_yaml: "steps:\n  - name: lint\n    goal: run linter\n".to_string(),
        source: "user".to_string(),
        created_at: now,
        updated_at: now,
    };

    // list before any inserts
    let empty = db
        .list_workflows(&project_id)
        .await
        .expect("list before insert");
    assert!(empty.is_empty());

    db.create_workflow(&wf).await.expect("create workflow");

    // get by id
    let loaded = db
        .get_workflow(&wf.id)
        .await
        .expect("get workflow")
        .expect("workflow should exist");
    assert_eq!(loaded.id, wf.id);
    assert_eq!(loaded.name, "ci-pipeline");
    assert_eq!(loaded.description.as_deref(), Some("Runs CI steps"));
    assert_eq!(loaded.source, "user");

    // get by name
    let by_name = db
        .get_workflow_by_name(&project_id, "ci-pipeline")
        .await
        .expect("get by name")
        .expect("should find by name");
    assert_eq!(by_name.id, wf.id);

    // get by name -- not found
    let missing = db
        .get_workflow_by_name(&project_id, "nonexistent")
        .await
        .expect("get missing by name");
    assert!(missing.is_none());

    // list_workflows returns one entry
    let list = db
        .list_workflows(&project_id)
        .await
        .expect("list after insert");
    assert_eq!(list.len(), 1);
    assert_eq!(list[0].name, "ci-pipeline");

    // add a second workflow, verify list grows
    let wf2 = crate::models::WorkflowRow {
        id: Uuid::new_v4().to_string(),
        project_id: project_id.clone(),
        name: "deploy".to_string(),
        description: None,
        definition_yaml: "steps:\n  - name: ship\n    goal: deploy\n".to_string(),
        source: "user".to_string(),
        created_at: now,
        updated_at: now,
    };
    db.create_workflow(&wf2).await.expect("create workflow 2");
    let list2 = db
        .list_workflows(&project_id)
        .await
        .expect("list after second insert");
    assert_eq!(list2.len(), 2);
    // list is ordered by name ASC
    assert_eq!(list2[0].name, "ci-pipeline");
    assert_eq!(list2[1].name, "deploy");
}

#[tokio::test]
async fn workflow_definition_update_and_delete() {
    let db = open_test_db().await;
    let project_id = Uuid::new_v4().to_string();
    seed_project(&db, &project_id).await;

    let now = Utc::now();
    let wf = crate::models::WorkflowRow {
        id: Uuid::new_v4().to_string(),
        project_id: project_id.clone(),
        name: "release".to_string(),
        description: Some("Release workflow".to_string()),
        definition_yaml: "steps:\n  - name: build\n    goal: build artifacts\n".to_string(),
        source: "user".to_string(),
        created_at: now,
        updated_at: now,
    };
    db.create_workflow(&wf).await.expect("create");

    // update -- replace definition_yaml and name
    let updated = crate::models::WorkflowRow {
        id: wf.id.clone(),
        project_id: project_id.clone(),
        name: "release-v2".to_string(),
        description: Some("Updated release workflow".to_string()),
        definition_yaml:
            "steps:\n  - name: build\n    goal: build\n  - name: publish\n    goal: publish\n"
                .to_string(),
        source: "user".to_string(),
        created_at: now,
        updated_at: Utc::now(),
    };
    db.update_workflow(&updated).await.expect("update");

    let reloaded = db
        .get_workflow(&wf.id)
        .await
        .expect("get after update")
        .expect("should still exist");
    assert_eq!(reloaded.name, "release-v2");
    assert_eq!(
        reloaded.description.as_deref(),
        Some("Updated release workflow")
    );
    assert!(reloaded.definition_yaml.contains("publish"));

    // delete
    db.delete_workflow(&wf.id).await.expect("delete");
    let gone = db.get_workflow(&wf.id).await.expect("get after delete");
    assert!(gone.is_none());

    let list = db
        .list_workflows(&project_id)
        .await
        .expect("list after delete");
    assert!(list.is_empty());
}

#[tokio::test]
async fn workflow_instance_list_roundtrip() {
    let db = open_test_db().await;
    let project_id = Uuid::new_v4().to_string();
    seed_project(&db, &project_id).await;

    let now = Utc::now();

    // empty list before any inserts
    let empty = db
        .list_workflow_instances(&project_id)
        .await
        .expect("list empty instances");
    assert!(empty.is_empty());

    let inst1 = WorkflowInstanceRow {
        id: Uuid::new_v4().to_string(),
        project_id: project_id.clone(),
        workflow_name: "pipeline-a".to_string(),
        description: Some("first run".to_string()),
        status: "pending".to_string(),
        created_at: now,
        updated_at: now,
        params_json: Some("{\"env\":\"staging\"}".to_string()),
        stage_results_json: None,
        expanded_steps_json: None,
    };
    let inst2 = WorkflowInstanceRow {
        id: Uuid::new_v4().to_string(),
        project_id: project_id.clone(),
        workflow_name: "pipeline-b".to_string(),
        description: None,
        status: "running".to_string(),
        created_at: now,
        updated_at: now,
        params_json: None,
        stage_results_json: None,
        expanded_steps_json: None,
    };

    db.create_workflow_instance(&inst1)
        .await
        .expect("create inst1");
    db.create_workflow_instance(&inst2)
        .await
        .expect("create inst2");

    let list = db
        .list_workflow_instances(&project_id)
        .await
        .expect("list instances");
    assert_eq!(list.len(), 2);

    // get_workflow_instance for each
    let loaded1 = db
        .get_workflow_instance(&inst1.id)
        .await
        .expect("get inst1")
        .expect("inst1 exists");
    assert_eq!(loaded1.workflow_name, "pipeline-a");
    assert_eq!(
        loaded1.params_json.as_deref(),
        Some("{\"env\":\"staging\"}")
    );

    let loaded2 = db
        .get_workflow_instance(&inst2.id)
        .await
        .expect("get inst2")
        .expect("inst2 exists");
    assert_eq!(loaded2.workflow_name, "pipeline-b");
    assert_eq!(loaded2.status, "running");

    // get non-existent
    let missing = db
        .get_workflow_instance("no-such-id")
        .await
        .expect("get missing");
    assert!(missing.is_none());
}

#[tokio::test]
async fn open_creates_database_file_for_fresh_project_root() {
    let project_root = std::env::temp_dir().join(format!("pnevma-db-open-{}", Uuid::new_v4()));
    tokio::fs::create_dir_all(&project_root)
        .await
        .expect("create temp project root");

    let db = Db::open(&project_root)
        .await
        .expect("open db in fresh root");
    assert_eq!(db.path(), project_root.join(".pnevma/pnevma.db").as_path());
    assert!(
        db.path().exists(),
        "Db::open should create the SQLite file for a fresh project root"
    );

    let projects = db.list_projects().await.expect("list migrated projects");
    assert!(
        projects.is_empty(),
        "fresh database should be migrated and empty"
    );

    drop(db);
    let _ = tokio::fs::remove_dir_all(&project_root).await;
}

#[tokio::test]
async fn update_task_conditional_succeeds_when_status_matches() {
    let db = open_test_db().await;
    let project_id = Uuid::new_v4().to_string();
    seed_project(&db, &project_id).await;

    let now = Utc::now();
    let mut task = TaskRow {
        id: Uuid::new_v4().to_string(),
        project_id,
        title: "task".to_string(),
        goal: "goal".to_string(),
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
        lineage_depth: 0,
        lineage_summary: None,
    };
    db.create_task(&task).await.expect("create task");

    task.status = "InProgress".to_string();
    task.updated_at = Utc::now();
    task.handoff_summary = Some("claimed".to_string());

    let updated = db
        .update_task_conditional(&task, "Ready")
        .await
        .expect("conditional update");
    assert!(updated, "expected conditional update to succeed");

    let loaded = db
        .get_task(&task.id)
        .await
        .expect("get task")
        .expect("task exists");
    assert_eq!(loaded.status, "InProgress");
    assert_eq!(loaded.handoff_summary.as_deref(), Some("claimed"));
}

#[tokio::test]
async fn update_task_conditional_rejects_stale_status() {
    let db = open_test_db().await;
    let project_id = Uuid::new_v4().to_string();
    seed_project(&db, &project_id).await;

    let now = Utc::now();
    let original = TaskRow {
        id: Uuid::new_v4().to_string(),
        project_id,
        title: "task".to_string(),
        goal: "goal".to_string(),
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
        lineage_depth: 0,
        lineage_summary: None,
    };
    db.create_task(&original).await.expect("create task");

    let mut external = original.clone();
    external.status = "Done".to_string();
    external.updated_at = Utc::now();
    db.update_task(&external).await.expect("external update");

    let mut stale = original.clone();
    stale.status = "InProgress".to_string();
    stale.updated_at = Utc::now();

    let updated = db
        .update_task_conditional(&stale, "Ready")
        .await
        .expect("conditional update");
    assert!(
        !updated,
        "stale conditional update must be rejected when status drifted"
    );

    let loaded = db
        .get_task(&original.id)
        .await
        .expect("get task")
        .expect("task exists");
    assert_eq!(loaded.status, "Done");
}

#[tokio::test]
async fn list_recoverable_in_progress_tasks_detects_live_agent_session_by_worktree() {
    let db = open_test_db().await;
    let project_id = Uuid::new_v4().to_string();
    seed_project(&db, &project_id).await;

    let now = Utc::now();
    let recoverable_task = TaskRow {
        id: Uuid::new_v4().to_string(),
        project_id: project_id.clone(),
        title: "recoverable".to_string(),
        goal: "stay in progress".to_string(),
        scope_json: "[]".to_string(),
        dependencies_json: "[]".to_string(),
        acceptance_json: "[]".to_string(),
        constraints_json: "[]".to_string(),
        priority: "P1".to_string(),
        status: "InProgress".to_string(),
        branch: Some("pnevma/recoverable".to_string()),
        worktree_id: Some(Uuid::new_v4().to_string()),
        handoff_summary: None,
        created_at: now,
        updated_at: now,
        auto_dispatch: true,
        agent_profile_override: None,
        execution_mode: Some("worktree".to_string()),
        timeout_minutes: None,
        max_retries: None,
        loop_iteration: 0,
        loop_context_json: None,
        forked_from_task_id: None,
        lineage_depth: 0,
        lineage_summary: None,
    };
    db.create_task(&recoverable_task)
        .await
        .expect("create recoverable task");

    let orphan_task = TaskRow {
        id: Uuid::new_v4().to_string(),
        project_id: project_id.clone(),
        title: "orphan".to_string(),
        goal: "should not be recoverable".to_string(),
        scope_json: "[]".to_string(),
        dependencies_json: "[]".to_string(),
        acceptance_json: "[]".to_string(),
        constraints_json: "[]".to_string(),
        priority: "P1".to_string(),
        status: "InProgress".to_string(),
        branch: Some("pnevma/orphan".to_string()),
        worktree_id: Some(Uuid::new_v4().to_string()),
        handoff_summary: None,
        created_at: now,
        updated_at: now,
        auto_dispatch: true,
        agent_profile_override: None,
        execution_mode: Some("worktree".to_string()),
        timeout_minutes: None,
        max_retries: None,
        loop_iteration: 0,
        loop_context_json: None,
        forked_from_task_id: None,
        lineage_depth: 0,
        lineage_summary: None,
    };
    db.create_task(&orphan_task)
        .await
        .expect("create orphan task");

    let worktree_path = format!("/tmp/{}", recoverable_task.id);
    db.upsert_worktree(&WorktreeRow {
        id: recoverable_task
            .worktree_id
            .clone()
            .expect("recoverable worktree id"),
        project_id: project_id.clone(),
        task_id: recoverable_task.id.clone(),
        path: worktree_path.clone(),
        branch: recoverable_task.branch.clone().expect("recoverable branch"),
        lease_status: "Active".to_string(),
        lease_started: now,
        last_active: now,
    })
    .await
    .expect("create worktree");

    db.upsert_session(&SessionRow {
        id: Uuid::new_v4().to_string(),
        project_id: project_id.clone(),
        name: "agent-recoverable".to_string(),
        r#type: Some("agent".to_string()),
        status: "running".to_string(),
        pid: None,
        cwd: worktree_path,
        command: "claude-code".to_string(),
        branch: recoverable_task.branch.clone(),
        worktree_id: recoverable_task.worktree_id.clone(),
        started_at: now,
        last_heartbeat: now,
        ended_at: None,
        exit_code: None,
        restore_status: None,
    })
    .await
    .expect("create agent session");

    db.upsert_session(&SessionRow {
        id: Uuid::new_v4().to_string(),
        project_id: project_id.clone(),
        name: "terminal".to_string(),
        r#type: Some("terminal".to_string()),
        status: "running".to_string(),
        pid: None,
        cwd: "/tmp".to_string(),
        command: "zsh".to_string(),
        branch: orphan_task.branch.clone(),
        worktree_id: orphan_task.worktree_id.clone(),
        started_at: now,
        last_heartbeat: now,
        restore_status: None,
        exit_code: None,
        ended_at: None,
    })
    .await
    .expect("create non-agent session");

    let recoverable = db
        .list_recoverable_in_progress_tasks(&project_id)
        .await
        .expect("list recoverable tasks");

    assert_eq!(recoverable.len(), 1);
    assert_eq!(recoverable[0].id, recoverable_task.id);
}

// ── G.1: claim_next_ready_task ──────────────────────────────────────────

#[tokio::test]
async fn claim_next_ready_task_picks_ready_skips_others() {
    let db = open_test_db().await;
    let project_id = Uuid::new_v4().to_string();
    seed_project(&db, &project_id).await;

    let now = Utc::now();
    let planned = TaskRow {
        id: Uuid::new_v4().to_string(),
        project_id: project_id.clone(),
        title: "Planned task".to_string(),
        goal: "goal".to_string(),
        scope_json: "[]".to_string(),
        dependencies_json: "[]".to_string(),
        acceptance_json: "[]".to_string(),
        constraints_json: "[]".to_string(),
        priority: "P2".to_string(),
        status: "Planned".to_string(),
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
    };
    db.create_task(&planned).await.expect("create planned");

    let ready = TaskRow {
        id: Uuid::new_v4().to_string(),
        project_id: project_id.clone(),
        title: "Ready task".to_string(),
        goal: "goal".to_string(),
        scope_json: "[]".to_string(),
        dependencies_json: "[]".to_string(),
        acceptance_json: "[]".to_string(),
        constraints_json: "[]".to_string(),
        priority: "P1".to_string(),
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
    };
    db.create_task(&ready).await.expect("create ready");

    let claimed = db.claim_next_ready_task(&project_id).await.expect("claim");
    assert_eq!(claimed, Some(ready.id.clone()));

    let loaded = db.get_task(&ready.id).await.expect("get").expect("exists");
    assert_eq!(loaded.status, "Dispatching");

    let second = db
        .claim_next_ready_task(&project_id)
        .await
        .expect("claim again");
    assert!(second.is_none());
}

// ── G.1: list_notifications ─────────────────────────────────────────────

#[tokio::test]
async fn list_notifications_returns_all_and_unread() {
    let db = open_test_db().await;
    let project_id = Uuid::new_v4().to_string();
    seed_project(&db, &project_id).await;

    for i in 0..3 {
        let n = NotificationRow {
            id: Uuid::new_v4().to_string(),
            project_id: project_id.clone(),
            task_id: None,
            session_id: None,
            title: format!("Notification {i}"),
            body: format!("Body {i}"),
            level: "info".to_string(),
            unread: i != 0, // first one is read
            created_at: Utc::now(),
        };
        db.create_notification(&n)
            .await
            .expect("create notification");
    }

    let unread = db
        .list_notifications(&project_id, true)
        .await
        .expect("list unread");
    assert_eq!(unread.len(), 2);

    let all = db
        .list_notifications(&project_id, false)
        .await
        .expect("list all");
    assert_eq!(all.len(), 3);
}

// ── G.1: error_signature upsert ─────────────────────────────────────────

#[tokio::test]
async fn error_signature_upsert_roundtrip() {
    let db = open_test_db().await;
    let project_id = Uuid::new_v4().to_string();
    seed_project(&db, &project_id).await;

    let now = Utc::now();
    let sig = ErrorSignatureRow {
        id: Uuid::new_v4().to_string(),
        project_id: project_id.clone(),
        signature_hash: "abc123".to_string(),
        canonical_message: "connection refused".to_string(),
        category: "network".to_string(),
        first_seen: now,
        last_seen: now,
        total_count: 1,
        sample_output: Some("error: connection refused".to_string()),
        remediation_hint: None,
    };

    db.upsert_error_signature(&sig).await.expect("upsert");
    // Second upsert should not error
    db.upsert_error_signature(&sig).await.expect("upsert again");
}

// ── G.1: cost append + aggregation ──────────────────────────────────────

#[tokio::test]
async fn cost_append_and_aggregation() {
    let db = open_test_db().await;
    let project_id = Uuid::new_v4().to_string();
    seed_project(&db, &project_id).await;

    let now = Utc::now();
    let task_id = Uuid::new_v4().to_string();
    let task = TaskRow {
        id: task_id.clone(),
        project_id: project_id.clone(),
        title: "cost task".to_string(),
        goal: "goal".to_string(),
        scope_json: "[]".to_string(),
        dependencies_json: "[]".to_string(),
        acceptance_json: "[]".to_string(),
        constraints_json: "[]".to_string(),
        priority: "P2".to_string(),
        status: "InProgress".to_string(),
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
    };
    db.create_task(&task).await.expect("create task");

    let session = SessionRow {
        id: Uuid::new_v4().to_string(),
        project_id: project_id.clone(),
        name: "test-session".to_string(),
        r#type: None,
        status: "running".to_string(),
        pid: None,
        cwd: "/tmp".to_string(),
        command: "bash".to_string(),
        branch: None,
        worktree_id: None,
        started_at: now,
        last_heartbeat: now,
        restore_status: None,
        exit_code: None,
        ended_at: None,
    };
    db.upsert_session(&session).await.expect("upsert session");

    let cost = CostRow {
        id: Uuid::new_v4().to_string(),
        agent_run_id: None,
        task_id: task_id.clone(),
        session_id: session.id.clone(),
        provider: "anthropic".to_string(),
        model: Some("claude-3-opus".to_string()),
        tokens_in: 1000,
        tokens_out: 500,
        estimated_usd: 0.05,
        tracked: true,
        timestamp: now,
    };
    db.append_cost(&cost).await.expect("append cost");

    let total = db.task_cost_total(&task_id).await.expect("task cost");
    assert!((total - 0.05).abs() < 0.001);

    let ptotal = db
        .project_cost_total(&project_id)
        .await
        .expect("project cost");
    assert!((ptotal - 0.05).abs() < 0.001);

    db.aggregate_costs_hourly(&project_id)
        .await
        .expect("hourly agg");
    db.aggregate_costs_daily(&project_id)
        .await
        .expect("daily agg");
}

// ── Helpers for new tests ───────────────────────────────────────────────

fn make_task(project_id: &str) -> TaskRow {
    let now = Utc::now();
    TaskRow {
        id: Uuid::new_v4().to_string(),
        project_id: project_id.to_string(),
        title: "test task".to_string(),
        goal: "goal".to_string(),
        scope_json: "[]".to_string(),
        dependencies_json: "[]".to_string(),
        acceptance_json: "[]".to_string(),
        constraints_json: "[]".to_string(),
        priority: "P2".to_string(),
        status: "Planned".to_string(),
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

fn make_automation_run(project_id: &str, task_id: &str, status: &str) -> AutomationRunRow {
    let now = Utc::now();
    AutomationRunRow {
        id: Uuid::new_v4().to_string(),
        project_id: project_id.to_string(),
        task_id: task_id.to_string(),
        run_id: Uuid::new_v4().to_string(),
        origin: "manual".to_string(),
        provider: "claude-code".to_string(),
        model: None,
        status: status.to_string(),
        attempt: 1,
        started_at: now,
        finished_at: None,
        duration_seconds: None,
        tokens_in: 0,
        tokens_out: 0,
        cost_usd: 0.0,
        summary: None,
        error_message: None,
        created_at: now,
    }
}

fn make_session(project_id: &str) -> SessionRow {
    let now = Utc::now();
    SessionRow {
        id: Uuid::new_v4().to_string(),
        project_id: project_id.to_string(),
        name: "test-session".to_string(),
        r#type: None,
        status: "running".to_string(),
        pid: None,
        cwd: "/tmp".to_string(),
        command: "bash".to_string(),
        branch: None,
        worktree_id: None,
        started_at: now,
        last_heartbeat: now,
        restore_status: None,
        exit_code: None,
        ended_at: None,
    }
}

// ── 1A: Automation run lifecycle ────────────────────────────────────────

#[tokio::test]
async fn automation_run_update_status_sets_finished_at() {
    let db = open_test_db().await;
    let pid = Uuid::new_v4().to_string();
    seed_project(&db, &pid).await;

    let task = make_task(&pid);
    db.create_task(&task).await.expect("create task");

    let run = make_automation_run(&pid, &task.id, "running");
    db.create_automation_run(&run).await.expect("create run");

    let finished = Utc::now();
    db.update_automation_run_status(&run.id, "completed", Some(finished), Some(12.5), None)
        .await
        .expect("update status");

    let loaded = db.get_automation_run(&run.id).await.expect("get").unwrap();
    assert_eq!(loaded.status, "completed");
    assert!(loaded.finished_at.is_some());
    assert!((loaded.duration_seconds.unwrap() - 12.5).abs() < 0.001);
    assert!(loaded.error_message.is_none());
}

#[tokio::test]
async fn automation_run_update_usage_persists_tokens() {
    let db = open_test_db().await;
    let pid = Uuid::new_v4().to_string();
    seed_project(&db, &pid).await;

    let task = make_task(&pid);
    db.create_task(&task).await.expect("create task");

    let run = make_automation_run(&pid, &task.id, "running");
    db.create_automation_run(&run).await.expect("create run");

    db.update_automation_run_usage(&run.id, 500, 200, 0.03, Some("done"))
        .await
        .expect("update usage");

    let loaded = db.get_automation_run(&run.id).await.expect("get").unwrap();
    assert_eq!(loaded.tokens_in, 500);
    assert_eq!(loaded.tokens_out, 200);
    assert!((loaded.cost_usd - 0.03).abs() < 0.001);
    assert_eq!(loaded.summary.as_deref(), Some("done"));
}

#[tokio::test]
async fn list_active_automation_runs_filters_running_only() {
    let db = open_test_db().await;
    let pid = Uuid::new_v4().to_string();
    seed_project(&db, &pid).await;

    let task = make_task(&pid);
    db.create_task(&task).await.expect("create task");

    let running = make_automation_run(&pid, &task.id, "running");
    db.create_automation_run(&running)
        .await
        .expect("create running");

    let mut completed = make_automation_run(&pid, &task.id, "completed");
    completed.finished_at = Some(Utc::now());
    db.create_automation_run(&completed)
        .await
        .expect("create completed");

    let mut failed = make_automation_run(&pid, &task.id, "failed");
    failed.finished_at = Some(Utc::now());
    failed.error_message = Some("boom".to_string());
    db.create_automation_run(&failed)
        .await
        .expect("create failed");

    let active = db
        .list_active_automation_runs(&pid)
        .await
        .expect("list active");
    assert_eq!(active.len(), 1);
    assert_eq!(active[0].id, running.id);
}

#[tokio::test]
async fn mark_stale_automation_runs_marks_only_running() {
    let db = open_test_db().await;
    let pid = Uuid::new_v4().to_string();
    seed_project(&db, &pid).await;

    let task = make_task(&pid);
    db.create_task(&task).await.expect("create task");

    let r1 = make_automation_run(&pid, &task.id, "running");
    db.create_automation_run(&r1).await.expect("r1");
    let r2 = make_automation_run(&pid, &task.id, "running");
    db.create_automation_run(&r2).await.expect("r2");

    let mut done = make_automation_run(&pid, &task.id, "completed");
    done.finished_at = Some(Utc::now());
    db.create_automation_run(&done).await.expect("done");

    let affected = db
        .mark_stale_automation_runs(&pid)
        .await
        .expect("mark stale");
    assert_eq!(affected, 2);

    // running ones are now failed
    let l1 = db.get_automation_run(&r1.id).await.expect("get").unwrap();
    assert_eq!(l1.status, "failed");
    assert!(l1.error_message.is_some());
    let l2 = db.get_automation_run(&r2.id).await.expect("get").unwrap();
    assert_eq!(l2.status, "failed");

    // completed one is unchanged
    let ld = db.get_automation_run(&done.id).await.expect("get").unwrap();
    assert_eq!(ld.status, "completed");
}

#[tokio::test]
async fn automation_retry_create_and_list_pending() {
    let db = open_test_db().await;
    let pid = Uuid::new_v4().to_string();
    seed_project(&db, &pid).await;

    let task = make_task(&pid);
    db.create_task(&task).await.expect("create task");

    let run = make_automation_run(&pid, &task.id, "failed");
    db.create_automation_run(&run).await.expect("create run");

    let now = Utc::now();
    let retry = AutomationRetryRow {
        id: Uuid::new_v4().to_string(),
        project_id: pid.clone(),
        run_id: run.id.clone(),
        task_id: task.id.clone(),
        attempt: 2,
        reason: "transient failure".to_string(),
        retry_after: now,
        retried_at: None,
        outcome: None,
        created_at: now,
    };
    db.create_automation_retry(&retry)
        .await
        .expect("create retry");

    let pending = db.list_pending_retries(&pid).await.expect("list pending");
    assert_eq!(pending.len(), 1);
    assert_eq!(pending[0].id, retry.id);

    db.update_automation_retry_outcome(&retry.id, "success", Some(Utc::now()))
        .await
        .expect("update outcome");

    let pending2 = db
        .list_pending_retries(&pid)
        .await
        .expect("list pending again");
    assert_eq!(pending2.len(), 0);
}

// ── 1B: Orphaned task detection ─────────────────────────────────────────

#[tokio::test]
async fn list_orphaned_in_progress_tasks_no_running_run() {
    let db = open_test_db().await;
    let pid = Uuid::new_v4().to_string();
    seed_project(&db, &pid).await;

    let mut task = make_task(&pid);
    task.status = "InProgress".to_string();
    db.create_task(&task).await.expect("create task");

    let orphaned = db
        .list_orphaned_in_progress_tasks(&pid)
        .await
        .expect("list");
    assert_eq!(orphaned.len(), 1);
    assert_eq!(orphaned[0].id, task.id);
}

#[tokio::test]
async fn list_orphaned_excludes_tasks_with_active_run() {
    let db = open_test_db().await;
    let pid = Uuid::new_v4().to_string();
    seed_project(&db, &pid).await;

    let mut task = make_task(&pid);
    task.status = "InProgress".to_string();
    db.create_task(&task).await.expect("create task");

    let run = make_automation_run(&pid, &task.id, "running");
    db.create_automation_run(&run).await.expect("create run");

    let orphaned = db
        .list_orphaned_in_progress_tasks(&pid)
        .await
        .expect("list");
    assert_eq!(orphaned.len(), 0);
}

// ── 1C: Cost aggregation queries ────────────────────────────────────────

#[tokio::test]
async fn aggregate_costs_daily_idempotent() {
    let db = open_test_db().await;
    let pid = Uuid::new_v4().to_string();
    seed_project(&db, &pid).await;

    let task = make_task(&pid);
    db.create_task(&task).await.expect("create task");
    let session = make_session(&pid);
    db.upsert_session(&session).await.expect("upsert session");

    let cost = CostRow {
        id: Uuid::new_v4().to_string(),
        agent_run_id: None,
        task_id: task.id.clone(),
        session_id: session.id.clone(),
        provider: "anthropic".to_string(),
        model: Some("opus".to_string()),
        tokens_in: 100,
        tokens_out: 50,
        estimated_usd: 0.01,
        tracked: true,
        timestamp: Utc::now(),
    };
    db.append_cost(&cost).await.expect("append cost");

    db.aggregate_costs_daily(&pid).await.expect("first agg");
    db.aggregate_costs_daily(&pid).await.expect("second agg");

    let by_model = db.get_usage_by_model(&pid).await.expect("by model");
    assert_eq!(by_model.len(), 1);
    assert_eq!(by_model[0].tokens_in, 100);
    assert!((by_model[0].estimated_usd - 0.01).abs() < 0.001);
}

#[tokio::test]
async fn get_usage_by_model_groups_correctly() {
    let db = open_test_db().await;
    let pid = Uuid::new_v4().to_string();
    seed_project(&db, &pid).await;

    let task = make_task(&pid);
    db.create_task(&task).await.expect("create task");
    let session = make_session(&pid);
    db.upsert_session(&session).await.expect("upsert session");

    let now = Utc::now();
    let c1 = CostRow {
        id: Uuid::new_v4().to_string(),
        agent_run_id: None,
        task_id: task.id.clone(),
        session_id: session.id.clone(),
        provider: "anthropic".to_string(),
        model: Some("opus".to_string()),
        tokens_in: 100,
        tokens_out: 50,
        estimated_usd: 0.10,
        tracked: true,
        timestamp: now,
    };
    let c2 = CostRow {
        id: Uuid::new_v4().to_string(),
        agent_run_id: None,
        task_id: task.id.clone(),
        session_id: session.id.clone(),
        provider: "anthropic".to_string(),
        model: Some("sonnet".to_string()),
        tokens_in: 200,
        tokens_out: 100,
        estimated_usd: 0.05,
        tracked: true,
        timestamp: now,
    };
    db.append_cost(&c1).await.expect("c1");
    db.append_cost(&c2).await.expect("c2");

    db.aggregate_costs_daily(&pid).await.expect("agg");

    let by_model = db.get_usage_by_model(&pid).await.expect("by model");
    assert_eq!(by_model.len(), 2);
    // Ordered by estimated_usd DESC
    assert_eq!(by_model[0].model, "opus");
    assert_eq!(by_model[0].tokens_in, 100);
    assert_eq!(by_model[1].model, "sonnet");
    assert_eq!(by_model[1].tokens_in, 200);
}

#[tokio::test]
async fn task_cost_total_zero_for_no_costs() {
    let db = open_test_db().await;
    let total = db
        .task_cost_total("nonexistent-task-id")
        .await
        .expect("task cost");
    assert!((total - 0.0).abs() < 0.001);
}

// ── 1D: Error signature daily tracking ──────────────────────────────────

#[tokio::test]
async fn increment_error_signature_daily_accumulates() {
    let db = open_test_db().await;
    let pid = Uuid::new_v4().to_string();
    seed_project(&db, &pid).await;

    let now = Utc::now();
    let sig = ErrorSignatureRow {
        id: Uuid::new_v4().to_string(),
        project_id: pid.clone(),
        signature_hash: Uuid::new_v4().to_string(),
        canonical_message: "timeout".to_string(),
        category: "network".to_string(),
        first_seen: now,
        last_seen: now,
        total_count: 1,
        sample_output: None,
        remediation_hint: None,
    };
    db.upsert_error_signature(&sig).await.expect("upsert sig");

    let date = "2026-03-16";
    for _ in 0..3 {
        db.increment_error_signature_daily(&sig.id, date)
            .await
            .expect("increment");
    }

    // Verify via get_error_trend which reads the daily table
    let trend = db.get_error_trend(&pid, 30).await.expect("trend");
    assert_eq!(trend.len(), 1);
    assert_eq!(trend[0].count, 3);
    assert_eq!(trend[0].date, date);
}

#[tokio::test]
async fn list_error_signatures_ordered_by_count() {
    let db = open_test_db().await;
    let pid = Uuid::new_v4().to_string();
    seed_project(&db, &pid).await;

    let now = Utc::now();
    let counts = [1i64, 5, 3];
    for count in counts {
        let sig = ErrorSignatureRow {
            id: Uuid::new_v4().to_string(),
            project_id: pid.clone(),
            signature_hash: Uuid::new_v4().to_string(),
            canonical_message: format!("error-{count}"),
            category: "test".to_string(),
            first_seen: now,
            last_seen: now,
            total_count: count,
            sample_output: None,
            remediation_hint: None,
        };
        db.upsert_error_signature(&sig).await.expect("upsert");
    }

    let sigs = db.list_error_signatures(&pid, 10).await.expect("list");
    assert_eq!(sigs.len(), 3);
    assert_eq!(sigs[0].total_count, 5);
    assert_eq!(sigs[1].total_count, 3);
    assert_eq!(sigs[2].total_count, 1);
}

// ── 1E: Worktree cascade + bulk ops ─────────────────────────────────────

#[tokio::test]
async fn update_task_status_bulk_transitions_multiple() {
    let db = open_test_db().await;
    let pid = Uuid::new_v4().to_string();
    seed_project(&db, &pid).await;

    let mut ids = Vec::new();
    for _ in 0..3 {
        let mut t = make_task(&pid);
        t.status = "Dispatching".to_string();
        db.create_task(&t).await.expect("create task");
        ids.push(t.id);
    }

    let affected = db
        .update_task_status_bulk(&pid, "Dispatching", "Ready")
        .await
        .expect("bulk update");
    assert_eq!(affected, 3);

    for id in &ids {
        let t = db.get_task(id).await.expect("get").unwrap();
        assert_eq!(t.status, "Ready");
    }
}

#[tokio::test]
async fn worktree_cascade_on_task_delete() {
    let db = open_test_db().await;
    let pid = Uuid::new_v4().to_string();
    seed_project(&db, &pid).await;

    let task = make_task(&pid);
    db.create_task(&task).await.expect("create task");

    let now = Utc::now();
    let wt = WorktreeRow {
        id: Uuid::new_v4().to_string(),
        project_id: pid.clone(),
        task_id: task.id.clone(),
        path: "/tmp/wt".to_string(),
        branch: "feat/test".to_string(),
        lease_status: "active".to_string(),
        lease_started: now,
        last_active: now,
    };
    db.upsert_worktree(&wt).await.expect("upsert worktree");

    // Verify worktree exists
    let found = db.find_worktree_by_task(&task.id).await.expect("find");
    assert!(found.is_some());

    // Delete task -- FK ON DELETE CASCADE should remove worktree
    db.delete_task(&task.id).await.expect("delete task");

    let gone = db
        .find_worktree_by_task(&task.id)
        .await
        .expect("find after");
    assert!(gone.is_none());
}

// ── 1F: Failure injection ───────────────────────────────────────────────

#[tokio::test]
async fn create_task_duplicate_id_returns_error() {
    let db = open_test_db().await;
    let pid = Uuid::new_v4().to_string();
    seed_project(&db, &pid).await;

    let task = make_task(&pid);
    db.create_task(&task).await.expect("first insert");

    let result = db.create_task(&task).await;
    assert!(result.is_err(), "duplicate task_id should return error");
}

// ── Batch 4: Directory & file permission tests ──────────────────────────

#[cfg(unix)]
#[tokio::test]
async fn open_creates_project_dir_with_0700() {
    use std::os::unix::fs::PermissionsExt;
    let project_root = std::env::temp_dir().join(format!("pnevma-dir-perm-{}", Uuid::new_v4()));
    tokio::fs::create_dir_all(&project_root)
        .await
        .expect("create temp root");

    let _db = Db::open(&project_root).await.expect("open db");
    let pnevma_dir = project_root.join(".pnevma");
    let meta = std::fs::metadata(&pnevma_dir).expect("stat .pnevma dir");
    let mode = meta.permissions().mode() & 0o777;
    assert_eq!(
        mode, 0o700,
        "expected .pnevma/ dir mode 0700, got {:o}",
        mode
    );

    let _ = tokio::fs::remove_dir_all(&project_root).await;
}

#[cfg(unix)]
#[tokio::test]
async fn open_corrects_overly_permissive_project_dir() {
    use std::os::unix::fs::PermissionsExt;
    let project_root = std::env::temp_dir().join(format!("pnevma-dir-fix-{}", Uuid::new_v4()));
    let pnevma_dir = project_root.join(".pnevma");
    tokio::fs::create_dir_all(&pnevma_dir)
        .await
        .expect("create .pnevma dir");
    std::fs::set_permissions(&pnevma_dir, std::fs::Permissions::from_mode(0o755))
        .expect("set permissive mode");

    let _db = Db::open(&project_root).await.expect("open db");
    let meta = std::fs::metadata(&pnevma_dir).expect("stat .pnevma dir");
    let mode = meta.permissions().mode() & 0o777;
    assert_eq!(mode, 0o700, "expected corrected mode 0700, got {:o}", mode);

    let _ = tokio::fs::remove_dir_all(&project_root).await;
}

#[cfg(unix)]
#[tokio::test]
async fn open_creates_db_file_with_0600() {
    use std::os::unix::fs::PermissionsExt;
    let project_root = std::env::temp_dir().join(format!("pnevma-file-perm-{}", Uuid::new_v4()));
    tokio::fs::create_dir_all(&project_root)
        .await
        .expect("create temp root");

    let db = Db::open(&project_root).await.expect("open db");
    let meta = std::fs::metadata(db.path()).expect("stat db file");
    let mode = meta.permissions().mode() & 0o777;
    assert_eq!(mode, 0o600, "expected db file mode 0600, got {:o}", mode);

    drop(db);
    let _ = tokio::fs::remove_dir_all(&project_root).await;
}

// ── Batch 5: merge_queue roundtrip ──────────────────────────────────────

#[tokio::test]
async fn merge_queue_roundtrip() {
    let db = open_test_db().await;
    let pid = Uuid::new_v4().to_string();
    seed_project(&db, &pid).await;

    let task = make_task(&pid);
    db.create_task(&task).await.expect("create task");

    let now = Utc::now();
    let item = crate::models::MergeQueueRow {
        id: Uuid::new_v4().to_string(),
        project_id: pid.clone(),
        task_id: task.id.clone(),
        status: "queued".to_string(),
        blocked_reason: None,
        approved_at: now,
        started_at: None,
        completed_at: None,
    };
    db.upsert_merge_queue_item(&item)
        .await
        .expect("upsert merge queue item");

    let queue = db.list_merge_queue(&pid).await.expect("list merge queue");
    assert_eq!(queue.len(), 1);
    assert_eq!(queue[0].task_id, task.id);
    assert_eq!(queue[0].status, "queued");

    // Get by task
    let found = db
        .get_merge_queue_item_by_task(&task.id)
        .await
        .expect("get by task")
        .expect("should exist");
    assert_eq!(found.id, item.id);
}

// ── Batch 4: Event payload redaction integration test ───────────────────

#[tokio::test]
async fn event_payload_is_redacted_before_storage() {
    // This test verifies the redaction-then-store pattern:
    // 1. Build a payload containing secret-shaped strings.
    // 2. Apply pnevma_redaction::redact_json_value (the same function used by
    //    append_automation_audit in pnevma-commands).
    // 3. Store the redacted payload via append_event.
    // 4. Read it back and verify the secrets are replaced with [REDACTED].
    let db = open_test_db().await;
    let pid = Uuid::new_v4().to_string();
    seed_project(&db, &pid).await;

    let secret_payload = serde_json::json!({
        "request_id": "req-1",
        "method": "session.new",
        "env": "GITHUB_TOKEN=ghp_ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefgh",
        "api_key": "sk-ant-api03-XXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXX",
    });

    // Redact using the same function the control plane uses.
    let redacted = pnevma_redaction::redact_json_value(secret_payload, &[]);

    db.append_event(crate::store::NewEvent {
        id: Uuid::new_v4().to_string(),
        project_id: pid.clone(),
        task_id: None,
        session_id: None,
        trace_id: Uuid::new_v4().to_string(),
        source: "test".to_string(),
        event_type: "TestRedaction".to_string(),
        payload: redacted,
    })
    .await
    .expect("append redacted event");

    let events = db.list_recent_events(&pid, 10).await.expect("list events");
    assert_eq!(events.len(), 1);
    let stored = &events[0].payload_json;
    assert!(
        !stored.contains("ghp_"),
        "GitHub token must be redacted in stored payload, got: {stored}"
    );
    assert!(
        !stored.contains("sk-ant-api03"),
        "Anthropic key must be redacted in stored payload, got: {stored}"
    );
    assert!(
        stored.contains("[REDACTED]"),
        "stored payload must contain [REDACTED] markers"
    );
}

// ── Batch 5: DB write failure graceful degradation ──────────────────────

#[tokio::test]
async fn closed_pool_append_event_returns_err() {
    let db = open_test_db().await;
    let pid = Uuid::new_v4().to_string();
    seed_project(&db, &pid).await;

    // Close the pool
    db.pool.close().await;

    let result = db
        .append_event(crate::store::NewEvent {
            id: Uuid::new_v4().to_string(),
            project_id: pid,
            task_id: None,
            session_id: None,
            trace_id: Uuid::new_v4().to_string(),
            source: "test".to_string(),
            event_type: "TestEvent".to_string(),
            payload: serde_json::json!({"key": "value"}),
        })
        .await;
    assert!(
        result.is_err(),
        "append_event on closed pool should return Err, not panic"
    );
}

// ── FK violation ────────────────────────────────────────────────────────

#[tokio::test]
async fn worktree_fk_violation_without_task() {
    let db = open_test_db().await;
    let pid = Uuid::new_v4().to_string();
    seed_project(&db, &pid).await;

    let now = Utc::now();
    let wt = WorktreeRow {
        id: Uuid::new_v4().to_string(),
        project_id: pid.clone(),
        task_id: "nonexistent-task".to_string(),
        path: "/tmp/wt".to_string(),
        branch: "feat/orphan".to_string(),
        lease_status: "active".to_string(),
        lease_started: now,
        last_active: now,
    };

    let result = db.upsert_worktree(&wt).await;
    assert!(result.is_err(), "FK violation should return error");
}
