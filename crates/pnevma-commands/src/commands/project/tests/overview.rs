use super::*;

#[tokio::test]
async fn command_center_snapshot_includes_live_queued_retry_review_and_failed_rows() {
    let temp = tempdir().expect("tempdir");
    let project_root = temp.path().join("project");
    std::fs::create_dir_all(project_root.join(".pnevma/data/scrollback")).unwrap();

    let db = open_test_db().await;
    let project_id = Uuid::new_v4();
    db.upsert_project(
        &project_id.to_string(),
        "command-center-test",
        project_root.to_string_lossy().as_ref(),
        None,
        None,
    )
    .await
    .unwrap();

    let now = Utc::now();
    let live_task_id = Uuid::new_v4();
    let queued_task_id = Uuid::new_v4();
    let retry_task_id = Uuid::new_v4();
    let review_task_id = Uuid::new_v4();
    let failed_task_id = Uuid::new_v4();

    let worktree_live = WorktreeRow {
        id: Uuid::new_v4().to_string(),
        project_id: project_id.to_string(),
        task_id: live_task_id.to_string(),
        path: project_root
            .join("worktrees/live")
            .to_string_lossy()
            .to_string(),
        branch: "pnevma/live".to_string(),
        lease_status: "Active".to_string(),
        lease_started: now,
        last_active: now,
    };
    let worktree_review = WorktreeRow {
        id: Uuid::new_v4().to_string(),
        project_id: project_id.to_string(),
        task_id: review_task_id.to_string(),
        path: project_root
            .join("worktrees/review")
            .to_string_lossy()
            .to_string(),
        branch: "pnevma/review".to_string(),
        lease_status: "Active".to_string(),
        lease_started: now,
        last_active: now,
    };
    let worktree_failed = WorktreeRow {
        id: Uuid::new_v4().to_string(),
        project_id: project_id.to_string(),
        task_id: failed_task_id.to_string(),
        path: project_root
            .join("worktrees/failed")
            .to_string_lossy()
            .to_string(),
        branch: "pnevma/failed".to_string(),
        lease_status: "Active".to_string(),
        lease_started: now,
        last_active: now,
    };
    let mut live_task = make_task(&project_id.to_string(), "Live task");
    live_task.id = live_task_id.to_string();
    live_task.scope_json = serde_json::to_string(&vec!["src/live.rs"]).unwrap();
    live_task.status = "InProgress".to_string();
    live_task.branch = Some(worktree_live.branch.clone());
    live_task.worktree_id = Some(worktree_live.id.clone());
    db.create_task(&live_task).await.unwrap();

    let mut queued_task = make_task(&project_id.to_string(), "Queued task");
    queued_task.id = queued_task_id.to_string();
    queued_task.scope_json = serde_json::to_string(&vec!["src/queued.rs"]).unwrap();
    queued_task.status = "Ready".to_string();
    queued_task.branch = Some("pnevma/queued".to_string());
    db.create_task(&queued_task).await.unwrap();

    let mut retry_task = make_task(&project_id.to_string(), "Retry task");
    retry_task.id = retry_task_id.to_string();
    retry_task.status = "Failed".to_string();
    retry_task.branch = Some("pnevma/retry".to_string());
    db.create_task(&retry_task).await.unwrap();

    let mut review_task = make_task(&project_id.to_string(), "Review task");
    review_task.id = review_task_id.to_string();
    review_task.scope_json = serde_json::to_string(&vec!["src/review.rs"]).unwrap();
    review_task.status = "Review".to_string();
    review_task.branch = Some(worktree_review.branch.clone());
    review_task.worktree_id = Some(worktree_review.id.clone());
    db.create_task(&review_task).await.unwrap();

    let mut failed_task = make_task(&project_id.to_string(), "Failed task");
    failed_task.id = failed_task_id.to_string();
    failed_task.status = "Failed".to_string();
    failed_task.branch = Some(worktree_failed.branch.clone());
    failed_task.worktree_id = Some(worktree_failed.id.clone());
    db.create_task(&failed_task).await.unwrap();

    db.upsert_worktree(&worktree_live).await.unwrap();
    db.upsert_worktree(&worktree_review).await.unwrap();
    db.upsert_worktree(&worktree_failed).await.unwrap();

    db.create_automation_run(&AutomationRunRow {
        id: Uuid::new_v4().to_string(),
        project_id: project_id.to_string(),
        task_id: live_task.id.clone(),
        run_id: Uuid::new_v4().to_string(),
        origin: "manual".to_string(),
        provider: "claude-code".to_string(),
        model: Some("sonnet".to_string()),
        status: "running".to_string(),
        attempt: 1,
        started_at: now,
        finished_at: None,
        duration_seconds: None,
        tokens_in: 11,
        tokens_out: 22,
        cost_usd: 1.25,
        summary: None,
        error_message: None,
        created_at: now,
    })
    .await
    .unwrap();
    let retry_run = AutomationRunRow {
        id: Uuid::new_v4().to_string(),
        project_id: project_id.to_string(),
        task_id: retry_task.id.clone(),
        run_id: Uuid::new_v4().to_string(),
        origin: "auto".to_string(),
        provider: "codex".to_string(),
        model: Some("gpt-5".to_string()),
        status: "failed".to_string(),
        attempt: 2,
        started_at: now,
        finished_at: Some(now),
        duration_seconds: Some(12.0),
        tokens_in: 33,
        tokens_out: 44,
        cost_usd: 2.5,
        summary: Some("failed".to_string()),
        error_message: Some("boom".to_string()),
        created_at: now,
    };
    db.create_automation_run(&retry_run).await.unwrap();
    db.create_automation_run(&AutomationRunRow {
        id: Uuid::new_v4().to_string(),
        project_id: project_id.to_string(),
        task_id: review_task.id.clone(),
        run_id: Uuid::new_v4().to_string(),
        origin: "auto".to_string(),
        provider: "claude-code".to_string(),
        model: Some("sonnet".to_string()),
        status: "completed".to_string(),
        attempt: 1,
        started_at: now,
        finished_at: Some(now),
        duration_seconds: Some(5.0),
        tokens_in: 55,
        tokens_out: 66,
        cost_usd: 3.0,
        summary: Some("done".to_string()),
        error_message: None,
        created_at: now,
    })
    .await
    .unwrap();
    db.create_automation_run(&AutomationRunRow {
        id: Uuid::new_v4().to_string(),
        project_id: project_id.to_string(),
        task_id: failed_task.id.clone(),
        run_id: Uuid::new_v4().to_string(),
        origin: "auto".to_string(),
        provider: "codex".to_string(),
        model: Some("gpt-5".to_string()),
        status: "failed".to_string(),
        attempt: 1,
        started_at: now,
        finished_at: Some(now),
        duration_seconds: Some(7.0),
        tokens_in: 77,
        tokens_out: 88,
        cost_usd: 4.0,
        summary: Some("failed".to_string()),
        error_message: Some("oops".to_string()),
        created_at: now,
    })
    .await
    .unwrap();

    db.create_automation_retry(&AutomationRetryRow {
        id: Uuid::new_v4().to_string(),
        project_id: project_id.to_string(),
        run_id: retry_run.id.clone(),
        task_id: retry_task.id.clone(),
        attempt: 2,
        reason: "transient".to_string(),
        retry_after: now + chrono::Duration::minutes(5),
        retried_at: None,
        outcome: None,
        created_at: now,
    })
    .await
    .unwrap();

    db.upsert_review(&ReviewRow {
        id: Uuid::new_v4().to_string(),
        task_id: review_task.id.clone(),
        status: "Ready".to_string(),
        review_pack_path: project_root
            .join("review-pack.json")
            .to_string_lossy()
            .to_string(),
        reviewer_notes: None,
        approved_at: None,
    })
    .await
    .unwrap();

    let sessions = SessionSupervisor::new(project_root.join(".pnevma/data"));
    let live_session_id = Uuid::new_v4();
    sessions
        .register_restored(SessionMetadata {
            id: live_session_id,
            project_id,
            name: "agent-live".to_string(),
            status: SessionStatus::Running,
            health: SessionHealth::Active,
            pid: Some(42),
            cwd: worktree_live.path.clone(),
            command: "claude-code".to_string(),
            branch: Some(worktree_live.branch.clone()),
            worktree_id: Some(Uuid::parse_str(&worktree_live.id).unwrap()),
            started_at: now,
            last_heartbeat: now,
            scrollback_path: project_root
                .join(".pnevma/data/scrollback/live.log")
                .to_string_lossy()
                .to_string(),
            exit_code: None,
            ended_at: None,
        })
        .await
        .expect("register_restored");

    let state = Arc::new(make_state_with_project(project_id, &project_root, db, sessions).await);
    let (_shutdown_tx, shutdown_rx) = tokio::sync::watch::channel(false);
    let coordinator = Arc::new(crate::automation::coordinator::AutomationCoordinator::new(
        Arc::clone(&state),
        Arc::new(crate::automation::workflow_store::WorkflowStore::new(
            &project_root,
        )),
        shutdown_rx,
    ));
    assert!(
        coordinator
            .try_claim(queued_task_id, crate::automation::DispatchOrigin::Manual)
            .await
    );
    state
        .with_project_mut("tests.command_center_snapshot.coordinator", |ctx| {
            ctx.coordinator = Some(coordinator);
        })
        .await
        .expect("set coordinator");

    let snapshot = command_center_snapshot(state.as_ref())
        .await
        .expect("command center snapshot");

    assert_eq!(snapshot.summary.active_count, 1);
    assert_eq!(snapshot.summary.queued_count, 1);
    assert_eq!(snapshot.summary.retrying_count, 1);
    assert_eq!(snapshot.summary.review_needed_count, 1);
    assert_eq!(snapshot.summary.failed_count, 1);

    let by_title: HashMap<String, CommandCenterRunView> = snapshot
        .runs
        .into_iter()
        .filter_map(|run| run.task_title.clone().map(|title| (title, run)))
        .collect();

    let live = by_title.get("Live task").expect("live row");
    assert_eq!(live.state, "running");
    assert_eq!(
        live.primary_file_path.as_deref(),
        Some("worktrees/live/src/live.rs")
    );
    assert!(live
        .available_actions
        .contains(&"open_terminal".to_string()));
    assert!(live.available_actions.contains(&"kill_session".to_string()));
    assert!(!live.available_actions.contains(&"open_review".to_string()));

    let queued = by_title.get("Queued task").expect("queued row");
    assert_eq!(queued.state, "queued");
    assert_eq!(queued.primary_file_path.as_deref(), Some("src/queued.rs"));
    assert!(queued.available_actions.contains(&"open_diff".to_string()));

    let retrying = by_title.get("Retry task").expect("retry row");
    assert_eq!(retrying.state, "retrying");
    assert_eq!(retrying.attention_reason.as_deref(), Some("retrying"));

    let review = by_title.get("Review task").expect("review row");
    assert_eq!(review.state, "review_needed");
    assert_eq!(
        review.primary_file_path.as_deref(),
        Some("worktrees/review/src/review.rs")
    );
    assert!(review
        .available_actions
        .contains(&"open_review".to_string()));

    let failed = by_title.get("Failed task").expect("failed row");
    assert_eq!(failed.state, "failed");
    assert_eq!(failed.attention_reason.as_deref(), Some("failed"));
}

#[tokio::test]
async fn command_center_snapshot_surfaces_unmatched_waiting_session_actions() {
    let temp = tempdir().expect("tempdir");
    let project_root = temp.path().join("project");
    std::fs::create_dir_all(project_root.join(".pnevma/data/scrollback")).unwrap();

    let db = open_test_db().await;
    let project_id = Uuid::new_v4();
    db.upsert_project(
        &project_id.to_string(),
        "command-center-session-test",
        project_root.to_string_lossy().as_ref(),
        None,
        None,
    )
    .await
    .unwrap();

    let sessions = SessionSupervisor::new(project_root.join(".pnevma/data"));
    let waiting_session_id = Uuid::new_v4();
    sessions
        .register_restored(SessionMetadata {
            id: waiting_session_id,
            project_id,
            name: "agent-waiting".to_string(),
            status: SessionStatus::Waiting,
            health: SessionHealth::Waiting,
            pid: Some(77),
            cwd: project_root.to_string_lossy().to_string(),
            command: "codex".to_string(),
            branch: None,
            worktree_id: None,
            started_at: Utc::now(),
            last_heartbeat: Utc::now(),
            scrollback_path: project_root
                .join(".pnevma/data/scrollback/waiting.log")
                .to_string_lossy()
                .to_string(),
            exit_code: None,
            ended_at: None,
        })
        .await
        .expect("register_restored");

    let state = make_state_with_project(project_id, &project_root, db, sessions).await;
    let snapshot = command_center_snapshot(&state)
        .await
        .expect("command center snapshot");

    assert_eq!(snapshot.summary.slot_limit, 1);
    assert_eq!(snapshot.runs.len(), 1);
    let row = &snapshot.runs[0];
    let waiting_session_id_str = waiting_session_id.to_string();
    assert_eq!(
        row.session_id.as_deref(),
        Some(waiting_session_id_str.as_str())
    );
    assert_eq!(row.state, "running");
    assert!(row
        .available_actions
        .contains(&"reattach_session".to_string()));
    assert!(row.available_actions.contains(&"open_terminal".to_string()));
}

#[tokio::test]
async fn command_center_snapshot_surfaces_attention_and_actions() {
    let project_root = tempdir().expect("temp project");
    let db = open_test_db().await;
    let project_id = Uuid::new_v4();
    db.upsert_project(
        &project_id.to_string(),
        "command-center-test",
        &project_root.path().to_string_lossy(),
        None,
        None,
    )
    .await
    .expect("upsert project");

    let sessions = SessionSupervisor::new(project_root.path().join(".pnevma/data"));
    let state = make_state_with_project(
        project_id,
        project_root.path(),
        db.clone(),
        sessions.clone(),
    )
    .await;

    let running_task = make_command_center_task(
        project_id,
        "Running task",
        "InProgress",
        Some("feature/running"),
        None,
    );
    let review_task = make_command_center_task(project_id, "Review task", "Review", None, None);
    let failed_task = make_command_center_task(project_id, "Failed task", "Failed", None, None);
    let retry_task = make_command_center_task(project_id, "Retry task", "InProgress", None, None);

    for task in [&running_task, &review_task, &failed_task, &retry_task] {
        db.create_task(task).await.expect("create task");
    }

    let session_id = Uuid::new_v4();
    let mut meta = make_session_metadata(
        project_id,
        session_id,
        project_root.path(),
        SessionStatus::Running,
    );
    meta.name = "Agent shell".to_string();
    meta.branch = Some("feature/running".to_string());
    meta.health = SessionHealth::Idle;
    sessions
        .register_restored(meta.clone())
        .await
        .expect("register_restored");
    db.upsert_session(&session_row_from_meta(&meta))
        .await
        .expect("persist session");

    let failed_run = pnevma_db::AutomationRunRow {
        id: Uuid::new_v4().to_string(),
        project_id: project_id.to_string(),
        task_id: failed_task.id.clone(),
        run_id: Uuid::new_v4().to_string(),
        origin: "manual".to_string(),
        provider: "claude-code".to_string(),
        model: Some("sonnet".to_string()),
        status: "failed".to_string(),
        attempt: 2,
        started_at: Utc::now() - chrono::Duration::minutes(8),
        finished_at: Some(Utc::now() - chrono::Duration::minutes(2)),
        duration_seconds: Some(360.0),
        tokens_in: 120,
        tokens_out: 240,
        cost_usd: 1.25,
        summary: Some("failed".to_string()),
        error_message: Some("boom".to_string()),
        created_at: Utc::now() - chrono::Duration::minutes(8),
    };
    db.create_automation_run(&failed_run)
        .await
        .expect("create failed run");

    let retry_run = pnevma_db::AutomationRunRow {
        id: Uuid::new_v4().to_string(),
        project_id: project_id.to_string(),
        task_id: retry_task.id.clone(),
        run_id: Uuid::new_v4().to_string(),
        origin: "manual".to_string(),
        provider: "codex".to_string(),
        model: Some("gpt-5".to_string()),
        status: "failed".to_string(),
        attempt: 1,
        started_at: Utc::now() - chrono::Duration::minutes(15),
        finished_at: Some(Utc::now() - chrono::Duration::minutes(14)),
        duration_seconds: Some(45.0),
        tokens_in: 64,
        tokens_out: 96,
        cost_usd: 0.42,
        summary: Some("retry me".to_string()),
        error_message: Some("transient".to_string()),
        created_at: Utc::now() - chrono::Duration::minutes(15),
    };
    db.create_automation_run(&retry_run)
        .await
        .expect("create retry run");

    db.create_automation_retry(&pnevma_db::AutomationRetryRow {
        id: Uuid::new_v4().to_string(),
        project_id: project_id.to_string(),
        run_id: retry_run.id.clone(),
        task_id: retry_task.id.clone(),
        attempt: 2,
        reason: "network".to_string(),
        retry_after: Utc::now() + chrono::Duration::minutes(5),
        retried_at: None,
        outcome: None,
        created_at: Utc::now(),
    })
    .await
    .expect("create retry");

    let snapshot = command_center_snapshot(&state)
        .await
        .expect("snapshot should load");

    assert_eq!(snapshot.project_name, "test-project");
    assert_eq!(snapshot.summary.idle_count, 1);
    assert_eq!(snapshot.summary.review_needed_count, 1);
    assert_eq!(snapshot.summary.failed_count, 1);
    assert_eq!(snapshot.summary.retrying_count, 1);

    let idle_run = snapshot
        .runs
        .iter()
        .find(|run| run.task_id.as_deref() == Some(running_task.id.as_str()))
        .expect("idle run");
    assert_eq!(idle_run.state, "idle");
    assert_eq!(idle_run.attention_reason.as_deref(), Some("idle"));
    assert_eq!(
        idle_run.session_id.as_deref(),
        Some(session_id.to_string().as_str())
    );
    assert!(idle_run
        .available_actions
        .iter()
        .any(|action| action == "open_terminal"));
    assert!(idle_run
        .available_actions
        .iter()
        .any(|action| action == "open_replay"));
    assert!(idle_run
        .available_actions
        .iter()
        .any(|action| action == "kill_session"));

    let review_run = snapshot
        .runs
        .iter()
        .find(|run| run.task_id.as_deref() == Some(review_task.id.as_str()))
        .expect("review run");
    assert_eq!(review_run.state, "review_needed");
    assert!(review_run
        .available_actions
        .iter()
        .any(|action| action == "open_review"));

    let retrying_run = snapshot
        .runs
        .iter()
        .find(|run| run.task_id.as_deref() == Some(retry_task.id.as_str()))
        .expect("retrying run");
    assert_eq!(retrying_run.state, "retrying");
    assert_eq!(retrying_run.retry_count, 2);
    assert!(retrying_run.retry_after.is_some());

    let failed = snapshot
        .runs
        .iter()
        .find(|run| run.task_id.as_deref() == Some(failed_task.id.as_str()))
        .expect("failed run");
    assert_eq!(failed.state, "failed");
    assert_eq!(failed.provider.as_deref(), Some("claude-code"));
    assert_eq!(failed.model.as_deref(), Some("sonnet"));
}

#[tokio::test]
async fn command_center_snapshot_includes_unmatched_live_sessions() {
    let project_root = tempdir().expect("temp project");
    let db = open_test_db().await;
    let project_id = Uuid::new_v4();
    db.upsert_project(
        &project_id.to_string(),
        "command-center-live-session",
        &project_root.path().to_string_lossy(),
        None,
        None,
    )
    .await
    .expect("upsert project");

    let sessions = SessionSupervisor::new(project_root.path().join(".pnevma/data"));
    let state =
        make_state_with_project(project_id, project_root.path(), db, sessions.clone()).await;

    let session_id = Uuid::new_v4();
    let mut meta = make_session_metadata(
        project_id,
        session_id,
        project_root.path(),
        SessionStatus::Running,
    );
    meta.name = "Detached agent".to_string();
    meta.health = SessionHealth::Stuck;
    let _ = sessions.register_restored(meta).await;

    let snapshot = command_center_snapshot(&state)
        .await
        .expect("snapshot should load");

    assert_eq!(snapshot.summary.stuck_count, 1);
    let run = snapshot
        .runs
        .iter()
        .find(|run| run.session_id.as_deref() == Some(session_id.to_string().as_str()))
        .expect("unmatched session should appear");
    assert!(run.task_id.is_none());
    assert_eq!(run.state, "stuck");
    assert_eq!(run.attention_reason.as_deref(), Some("stuck"));
    assert!(run
        .available_actions
        .iter()
        .any(|action| action == "open_terminal"));
    assert!(run
        .available_actions
        .iter()
        .any(|action| action == "restart_session"));
}

#[tokio::test]
async fn fleet_snapshot_includes_open_and_cataloged_recent_projects() {
    let home = tempdir().expect("temp home");
    let _home = HomeOverride::new(home.path()).await;
    let project_root = tempdir().expect("temp project");
    let db = open_test_db().await;
    let project_id = Uuid::new_v4();
    db.upsert_project(
        &project_id.to_string(),
        "open-project",
        &project_root.path().to_string_lossy(),
        None,
        None,
    )
    .await
    .expect("upsert project");

    let global_db = pnevma_db::GlobalDb::open().await.expect("open global db");
    global_db
        .add_recent_project("/tmp/cataloged-project", "cataloged-project", "cataloged-1")
        .await
        .expect("add recent project");

    let sessions = SessionSupervisor::new(project_root.path().join(".pnevma/data"));
    let state = make_state_with_project(project_id, project_root.path(), db, sessions).await;

    let snapshot = fleet_snapshot(&state).await.expect("fleet snapshot");
    let repeated = fleet_snapshot(&state)
        .await
        .expect("repeated fleet snapshot");

    assert_eq!(snapshot.machine_id, repeated.machine_id);
    assert!(!snapshot.machine_id.is_empty());
    assert_eq!(snapshot.summary.project_count, 2);
    assert_eq!(snapshot.summary.open_project_count, 1);

    let open = snapshot
        .projects
        .iter()
        .find(|project| project.state == "open")
        .expect("open project entry");
    assert_eq!(open.project_id, project_id.to_string());
    assert!(open.snapshot.is_some());

    let cataloged = snapshot
        .projects
        .iter()
        .find(|project| project.state == "cataloged")
        .expect("cataloged project entry");
    assert_eq!(cataloged.project_id, "cataloged-1");
    assert_eq!(cataloged.project_path, "/tmp/cataloged-project");
    assert!(cataloged.snapshot.is_none());
}

#[tokio::test]
async fn fleet_snapshot_without_open_project_returns_catalog_projects() {
    let home = tempdir().expect("temp home");
    let _home = HomeOverride::new(home.path()).await;
    let global_db = pnevma_db::GlobalDb::open().await.expect("open global db");
    global_db
        .add_recent_project("/tmp/closed-project", "closed-project", "closed-1")
        .await
        .expect("add recent project");

    let state = AppState::new(Arc::new(NullEmitter));
    let snapshot = fleet_snapshot(&state).await.expect("fleet snapshot");

    assert_eq!(snapshot.summary.project_count, 1);
    assert_eq!(snapshot.summary.open_project_count, 0);
    assert_eq!(snapshot.projects[0].state, "cataloged");
    assert_eq!(snapshot.projects[0].project_id, "closed-1");
}
