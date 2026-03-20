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

#[tokio::test]
async fn github_status_for_path_reports_not_git_repo_for_plain_folder() {
    let temp = tempdir().expect("tempdir");
    let status = github_status_for_path(WorkspaceOpenerPathInput {
        path: temp.path().to_string_lossy().to_string(),
    })
    .await
    .expect("github status");

    assert_eq!(status.state, "not_git_repo");
}

#[tokio::test]
async fn list_branches_for_path_uses_selected_repository_path() {
    let temp = tempdir().expect("tempdir");
    let project_root = temp.path().join("repo");
    std::fs::create_dir_all(&project_root).expect("create repo dir");

    let init = std::process::Command::new("git")
        .args(["init", "-b", "main"])
        .current_dir(&project_root)
        .output()
        .expect("git init");
    assert!(
        init.status.success(),
        "git init failed: {}",
        String::from_utf8_lossy(&init.stderr)
    );

    std::fs::write(project_root.join("README.md"), "hello\n").expect("write readme");
    let add = std::process::Command::new("git")
        .args(["add", "README.md"])
        .current_dir(&project_root)
        .output()
        .expect("git add");
    assert!(
        add.status.success(),
        "git add failed: {}",
        String::from_utf8_lossy(&add.stderr)
    );

    let commit = std::process::Command::new("git")
        .args([
            "-c",
            "user.name=Test User",
            "-c",
            "user.email=test@example.com",
            "commit",
            "-m",
            "initial",
        ])
        .current_dir(&project_root)
        .output()
        .expect("git commit");
    assert!(
        commit.status.success(),
        "git commit failed: {}",
        String::from_utf8_lossy(&commit.stderr)
    );

    let branch = std::process::Command::new("git")
        .args(["branch", "feature/workspace-opener"])
        .current_dir(&project_root)
        .output()
        .expect("git branch");
    assert!(
        branch.status.success(),
        "git branch failed: {}",
        String::from_utf8_lossy(&branch.stderr)
    );

    let branches = list_branches_for_path(WorkspaceOpenerPathInput {
        path: project_root.to_string_lossy().to_string(),
    })
    .await
    .expect("list branches");

    assert!(branches.iter().any(|branch| branch.name == "main"));
    assert!(branches
        .iter()
        .any(|branch| branch.name == "feature/workspace-opener"));
}

#[tokio::test]
async fn list_branches_for_path_marks_auxiliary_worktrees() {
    let temp = tempdir().expect("tempdir");
    let project_root = temp.path().join("repo");
    init_workspace_opener_repo(&project_root);
    run_git(&project_root, &["branch", "feature/worktree"]);

    let worktree_path = project_root.join(".pnevma/worktrees/feature-worktree");
    run_git(
        &project_root,
        &[
            "worktree",
            "add",
            worktree_path.to_string_lossy().as_ref(),
            "feature/worktree",
        ],
    );

    let branches = list_branches_for_path(WorkspaceOpenerPathInput {
        path: project_root.to_string_lossy().to_string(),
    })
    .await
    .expect("list branches");

    let feature_branch = branches
        .into_iter()
        .find(|branch| branch.name == "feature/worktree")
        .expect("feature branch");
    assert!(feature_branch.has_worktree);
    let expected_worktree_path = canonical_string(&worktree_path);
    assert_eq!(
        feature_branch.worktree_path.as_deref(),
        Some(expected_worktree_path.as_str())
    );
}

fn current_branch(project_root: &Path) -> String {
    let output = std::process::Command::new("git")
        .args(["branch", "--show-current"])
        .current_dir(project_root)
        .output()
        .expect("git branch --show-current");
    assert!(
        output.status.success(),
        "git branch --show-current failed: {}",
        String::from_utf8_lossy(&output.stderr)
    );
    String::from_utf8_lossy(&output.stdout).trim().to_string()
}

fn canonical_string(path: &Path) -> String {
    std::fs::canonicalize(path)
        .expect("canonicalize path")
        .to_string_lossy()
        .to_string()
}

#[tokio::test]
async fn create_workspace_from_branch_checks_out_existing_branch() {
    let temp = tempdir().expect("tempdir");
    let project_root = temp.path().join("repo");
    init_workspace_opener_repo(&project_root);
    run_git(&project_root, &["branch", "feature/existing"]);

    let result = create_workspace_from_branch(WorkspaceOpenerBranchLaunchInput {
        path: project_root.to_string_lossy().to_string(),
        branch_name: "feature/existing".to_string(),
        create_new: false,
    })
    .await
    .expect("create branch workspace");

    assert_eq!(result.project_path, canonical_string(&project_root));
    assert_eq!(result.workspace_name, "feature/existing");
    assert_eq!(result.branch.as_deref(), Some("feature/existing"));
    assert!(result.working_directory.is_none());
    assert_eq!(current_branch(&project_root), "feature/existing");
}

#[tokio::test]
async fn create_workspace_from_branch_creates_and_checks_out_new_branch() {
    let temp = tempdir().expect("tempdir");
    let project_root = temp.path().join("repo");
    init_workspace_opener_repo(&project_root);

    let result = create_workspace_from_branch(WorkspaceOpenerBranchLaunchInput {
        path: project_root.to_string_lossy().to_string(),
        branch_name: "feature/new-workspace".to_string(),
        create_new: true,
    })
    .await
    .expect("create new branch workspace");

    assert_eq!(result.branch.as_deref(), Some("feature/new-workspace"));
    assert!(result.working_directory.is_none());
    assert_eq!(current_branch(&project_root), "feature/new-workspace");
}

#[tokio::test]
async fn create_workspace_from_branch_reuses_existing_worktree_without_checkout() {
    let temp = tempdir().expect("tempdir");
    let project_root = temp.path().join("repo");
    init_workspace_opener_repo(&project_root);
    run_git(&project_root, &["branch", "feature/worktree"]);

    let worktree_path = project_root.join(".pnevma/worktrees/feature-worktree");
    run_git(
        &project_root,
        &[
            "worktree",
            "add",
            worktree_path.to_string_lossy().as_ref(),
            "feature/worktree",
        ],
    );

    let result = create_workspace_from_branch(WorkspaceOpenerBranchLaunchInput {
        path: project_root.to_string_lossy().to_string(),
        branch_name: "feature/worktree".to_string(),
        create_new: false,
    })
    .await
    .expect("reuse branch worktree");

    assert_eq!(result.branch.as_deref(), Some("feature/worktree"));
    let expected_worktree_path = canonical_string(&worktree_path);
    assert_eq!(
        result.working_directory.as_deref(),
        Some(expected_worktree_path.as_str())
    );
    assert_eq!(current_branch(&project_root), "main");
}

fn init_workspace_opener_repo(project_root: &Path) {
    std::fs::create_dir_all(project_root).expect("create repo dir");
    run_git(project_root, &["init", "-b", "main"]);
    std::fs::write(project_root.join("README.md"), "hello\n").expect("write readme");
    run_git(project_root, &["add", "README.md"]);
    run_git(
        project_root,
        &[
            "-c",
            "user.name=Test User",
            "-c",
            "user.email=test@example.com",
            "commit",
            "-m",
            "initial",
        ],
    );
    run_git(
        project_root,
        &["remote", "add", "origin", "git@github.com:acme/widgets.git"],
    );
}

fn fake_gh_script(log_path: &Path, pr_head_repo: Option<&Path>) -> String {
    let head_repo_case = pr_head_repo.map(|path| {
        format!(
            r#"    echo '{{"number":88,"title":"Review fork changes","headRefName":"feature/from-fork","baseRefName":"main","state":"OPEN","url":"https://github.com/acme/widgets/pull/88","headRepository":{{"url":"{}"}}}}'
    exit 0
"#,
            path.to_string_lossy()
        )
    });
    let head_repo_case = head_repo_case.unwrap_or_else(|| {
        r#"    echo '{"number":88,"title":"Review fork changes","headRefName":"feature/from-fork","baseRefName":"main","state":"OPEN","url":"https://github.com/acme/widgets/pull/88","headRepository":{"url":"https://github.com/acme/widgets"}}'
    exit 0
"#
        .to_string()
    });

    format!(
        r#"#!/bin/sh
printf '%s\n' "$*" >> "{}"
if [ "$1" = "--version" ]; then
    echo "gh version 2.99.0"
    exit 0
fi
if [ "$1" = "auth" ] && [ "$2" = "status" ]; then
    exit 0
fi
if [ "$1" = "repo" ] && [ "$2" = "view" ]; then
    if [ "$3" != "acme/widgets" ]; then
        echo "expected explicit repo target" >&2
        exit 1
    fi
    echo '{{"nameWithOwner":"acme/widgets","defaultBranchRef":{{"name":"main"}}}}'
    exit 0
fi
if [ "$1" = "issue" ] && [ "$2" = "list" ]; then
    if [ "$3" != "-R" ] || [ "$4" != "acme/widgets" ]; then
        echo "expected issue list -R acme/widgets" >&2
        exit 1
    fi
    echo '[{{"number":123,"title":"Fix opener","state":"OPEN","labels":[],"author":{{"login":"octocat"}}}}]'
    exit 0
fi
if [ "$1" = "pr" ] && [ "$2" = "list" ]; then
    if [ "$3" = "-R" ] && [ "$4" = "acme/widgets" ]; then
        echo '[{{"number":88,"title":"Review fork changes","headRefName":"feature/from-fork","baseRefName":"main","state":"OPEN"}}]'
        exit 0
    fi
    echo '[]'
    exit 0
fi
if [ "$1" = "issue" ] && [ "$2" = "view" ]; then
    echo '{{"number":123,"title":"Fix opener","state":"OPEN","url":"https://github.com/acme/widgets/issues/123"}}'
    exit 0
fi
if [ "$1" = "pr" ] && [ "$2" = "view" ]; then
{head_repo_case}fi
echo "unexpected gh args: $*" >&2
exit 1
"#,
        log_path.to_string_lossy()
    )
}

#[tokio::test]
async fn github_status_for_path_uses_detected_gh_and_explicit_repo_target() {
    let temp = tempdir().expect("tempdir");
    let project_root = temp.path().join("repo");
    init_workspace_opener_repo(&project_root);

    let gh_dir = temp.path().join("gh-bin");
    std::fs::create_dir_all(&gh_dir).expect("create gh dir");
    let log_path = temp.path().join("gh.log");
    let gh_path = gh_dir.join("gh");
    write_fake_executable(&gh_path, &fake_gh_script(&log_path, None));
    let _gh = crate::github_cli::TestGithubCliBinaryOverride::new(gh_path);

    let status = github_status_for_path(WorkspaceOpenerPathInput {
        path: project_root.to_string_lossy().to_string(),
    })
    .await
    .expect("github status");

    assert_eq!(status.state, "ready");
    assert_eq!(status.resolved_repo.as_deref(), Some("acme/widgets"));

    let log = std::fs::read_to_string(&log_path).expect("read gh log");
    assert!(
        log.lines()
            .any(|line| line
                .contains("repo view acme/widgets --json nameWithOwner,defaultBranchRef")),
        "expected explicit repo view call in log: {log}"
    );
}

#[tokio::test]
async fn list_github_issues_for_path_passes_explicit_repo_flag() {
    let temp = tempdir().expect("tempdir");
    let project_root = temp.path().join("repo");
    init_workspace_opener_repo(&project_root);

    let gh_dir = temp.path().join("gh-bin");
    std::fs::create_dir_all(&gh_dir).expect("create gh dir");
    let log_path = temp.path().join("gh.log");
    let gh_path = gh_dir.join("gh");
    write_fake_executable(&gh_path, &fake_gh_script(&log_path, None));
    let _gh = crate::github_cli::TestGithubCliBinaryOverride::new(gh_path);

    let issues = list_github_issues_for_path(WorkspaceOpenerPathInput {
        path: project_root.to_string_lossy().to_string(),
    })
    .await
    .expect("list issues");

    assert_eq!(issues.len(), 1);
    assert_eq!(issues[0].number, 123);
    assert_eq!(issues[0].title, "Fix opener");

    let log = std::fs::read_to_string(&log_path).expect("read gh log");
    assert!(
        log.lines().any(|line| line.contains(
            "issue list -R acme/widgets --json number,title,state,labels,author --limit 50"
        )),
        "expected explicit issue list call in log: {log}"
    );
}

#[tokio::test]
async fn create_workspace_from_issue_without_linked_task_returns_repo_launch_result() {
    let temp = tempdir().expect("tempdir");
    let project_root = temp.path().join("repo");
    init_workspace_opener_repo(&project_root);

    let gh_dir = temp.path().join("gh-bin");
    std::fs::create_dir_all(&gh_dir).expect("create gh dir");
    let log_path = temp.path().join("gh.log");
    let gh_path = gh_dir.join("gh");
    write_fake_executable(&gh_path, &fake_gh_script(&log_path, None));
    let _gh = crate::github_cli::TestGithubCliBinaryOverride::new(gh_path);

    let state = AppState::new(Arc::new(NullEmitter));
    let result = create_workspace_from_issue(
        WorkspaceOpenerIssueLaunchInput {
            path: project_root.to_string_lossy().to_string(),
            issue_number: 123,
            create_linked_task_worktree: false,
        },
        &state,
    )
    .await
    .expect("create from issue");

    let expected_project_path = std::fs::canonicalize(&project_root)
        .expect("canonical project root")
        .to_string_lossy()
        .to_string();
    assert_eq!(result.project_path, expected_project_path);
    assert_eq!(result.workspace_name, "Issue #123 — Fix opener");
    assert_eq!(result.launch_source.kind, "issue");
    assert_eq!(result.launch_source.number, 123);
    assert_eq!(
        result.launch_source.url,
        "https://github.com/acme/widgets/issues/123"
    );
    assert!(result.working_directory.is_none());
    assert!(result.task_id.is_none());
    assert!(result.branch.is_none());
}

#[tokio::test]
async fn create_workspace_from_issue_with_linked_task_creates_task_and_worktree() {
    let home = tempdir().expect("temp home");
    let _home = HomeOverride::new(home.path()).await;

    let project_root = home.path().join("repo");
    init_workspace_opener_repo(&project_root);
    std::fs::create_dir_all(project_root.join(".pnevma/data")).expect("create scaffold");
    write_test_project_config(&project_root, &[]);

    let global_db = GlobalDb::open().await.expect("open global db");
    let state = AppState::new_with_global_db(Arc::new(NullEmitter), global_db);
    trust_workspace(project_root.to_string_lossy().to_string(), &state)
        .await
        .expect("trust workspace");

    let gh_dir = home.path().join("gh-bin");
    std::fs::create_dir_all(&gh_dir).expect("create gh dir");
    let log_path = home.path().join("gh.log");
    let gh_path = gh_dir.join("gh");
    write_fake_executable(&gh_path, &fake_gh_script(&log_path, None));
    let _gh = crate::github_cli::TestGithubCliBinaryOverride::new(gh_path);

    let result = create_workspace_from_issue(
        WorkspaceOpenerIssueLaunchInput {
            path: project_root.to_string_lossy().to_string(),
            issue_number: 123,
            create_linked_task_worktree: true,
        },
        &state,
    )
    .await
    .expect("create linked issue workspace");

    let task_id = result.task_id.clone().expect("task id");
    let working_directory = result.working_directory.clone().expect("working dir");
    let branch = result.branch.clone().expect("branch");

    assert!(Path::new(&working_directory).exists());
    assert!(branch.starts_with("pnevma/"));

    let db = Db::open(&project_root).await.expect("open db");
    let task = db
        .get_task(&task_id)
        .await
        .expect("get task")
        .expect("task exists");
    assert_eq!(task.title, "Issue #123: Fix opener");
    assert_eq!(task.branch.as_deref(), Some(branch.as_str()));
    assert!(task.worktree_id.is_some());

    let source = db
        .get_task_external_source(&task.project_id, "github_issue", "123")
        .await
        .expect("get external source")
        .expect("external source exists");
    assert_eq!(source.task_id, task_id);

    let worktrees = db
        .list_worktrees(&task.project_id)
        .await
        .expect("list worktrees");
    assert_eq!(worktrees.len(), 1);
    assert_eq!(worktrees[0].path, working_directory);
}

#[tokio::test]
async fn create_workspace_from_pull_request_with_linked_task_fetches_fork_head() {
    let home = tempdir().expect("temp home");
    let _home = HomeOverride::new(home.path()).await;

    let project_root = home.path().join("repo");
    init_workspace_opener_repo(&project_root);
    std::fs::create_dir_all(project_root.join(".pnevma/data")).expect("create scaffold");
    write_test_project_config(&project_root, &[]);

    let fork_root = home.path().join("fork");
    init_workspace_opener_repo(&fork_root);
    run_git(&fork_root, &["checkout", "-b", "feature/from-fork"]);
    std::fs::write(fork_root.join("fork.txt"), "from fork\n").expect("write fork change");
    run_git(&fork_root, &["add", "fork.txt"]);
    run_git(
        &fork_root,
        &[
            "-c",
            "user.name=Test User",
            "-c",
            "user.email=test@example.com",
            "commit",
            "-m",
            "fork change",
        ],
    );

    let global_db = GlobalDb::open().await.expect("open global db");
    let state = AppState::new_with_global_db(Arc::new(NullEmitter), global_db);
    trust_workspace(project_root.to_string_lossy().to_string(), &state)
        .await
        .expect("trust workspace");

    let gh_dir = home.path().join("gh-bin");
    std::fs::create_dir_all(&gh_dir).expect("create gh dir");
    let log_path = home.path().join("gh.log");
    let gh_path = gh_dir.join("gh");
    write_fake_executable(&gh_path, &fake_gh_script(&log_path, Some(&fork_root)));
    let _gh = crate::github_cli::TestGithubCliBinaryOverride::new(gh_path);

    let result = create_workspace_from_pull_request(
        WorkspaceOpenerPullRequestLaunchInput {
            path: project_root.to_string_lossy().to_string(),
            pr_number: 88,
            create_linked_task_worktree: true,
        },
        &state,
    )
    .await
    .expect("create linked pr workspace");

    let task_id = result.task_id.expect("task id");
    let working_directory = result.working_directory.expect("working directory");
    assert!(Path::new(&working_directory).exists());

    let fetched_head = Command::new("git")
        .args(["rev-parse", "HEAD"])
        .current_dir(&working_directory)
        .output()
        .expect("rev-parse worktree head");
    assert!(
        fetched_head.status.success(),
        "{}",
        String::from_utf8_lossy(&fetched_head.stderr)
    );
    let fetched_head = String::from_utf8_lossy(&fetched_head.stdout)
        .trim()
        .to_string();

    let fork_head = Command::new("git")
        .args(["rev-parse", "feature/from-fork"])
        .current_dir(&fork_root)
        .output()
        .expect("rev-parse fork head");
    assert!(
        fork_head.status.success(),
        "{}",
        String::from_utf8_lossy(&fork_head.stderr)
    );
    let fork_head = String::from_utf8_lossy(&fork_head.stdout)
        .trim()
        .to_string();

    assert_eq!(fetched_head, fork_head);

    let db = Db::open(&project_root).await.expect("open db");
    let task = db
        .get_task(&task_id)
        .await
        .expect("get task")
        .expect("task exists");
    assert_eq!(task.title, "PR #88: Review fork changes");

    let source = db
        .get_task_external_source(&task.project_id, "github_pull_request", "88")
        .await
        .expect("get external source")
        .expect("external source exists");
    assert_eq!(source.task_id, task_id);
}
