use super::*;

#[tokio::test]
async fn open_project_returns_workspace_not_initialized_for_existing_repo_without_scaffold() {
    let project_root = tempdir().expect("temp project");
    let global_db = GlobalDb::open().await.expect("open global db");
    let state = AppState::new_with_global_db(Arc::new(NullEmitter), global_db);
    let emitter: Arc<dyn EventEmitter> = Arc::new(NullEmitter);

    let err = open_project(
        project_root.path().to_string_lossy().to_string(),
        None,
        &emitter,
        &state,
    )
    .await
    .expect_err("missing scaffold should fail open");

    assert_eq!(err, "workspace_not_initialized");
}

#[tokio::test]
async fn open_project_returns_workspace_not_initialized_when_support_dir_is_missing() {
    let home = tempdir().expect("temp home");
    let _home = HomeOverride::new(home.path()).await;
    let project_root = tempdir().expect("temp project");
    write_test_project_config(project_root.path(), &[]);
    let global_db = GlobalDb::open().await.expect("open global db");
    let state = AppState::new_with_global_db(Arc::new(NullEmitter), global_db);
    let emitter: Arc<dyn EventEmitter> = Arc::new(NullEmitter);

    let err = open_project(
        project_root.path().to_string_lossy().to_string(),
        None,
        &emitter,
        &state,
    )
    .await
    .expect_err("missing support dir should fail open");

    assert_eq!(err, "workspace_not_initialized");
}

#[tokio::test]
async fn trust_and_open_project_expand_home_relative_paths() {
    let _guard = redaction_config_lock().lock().await;
    let home = tempdir().expect("temp home");
    let _home = HomeOverride::new(home.path()).await;
    let project_root = home.path().join("dev/claude-code/cc-skills");
    std::fs::create_dir_all(project_root.join(".pnevma/data")).expect("create scaffold dirs");
    write_test_project_config(&project_root, &[]);

    let global_db = GlobalDb::open().await.expect("open global db");
    let state = AppState::new_with_global_db(Arc::new(NullEmitter), global_db);
    let emitter: Arc<dyn EventEmitter> = Arc::new(NullEmitter);
    let input_path = "~/dev/claude-code/cc-skills".to_string();

    trust_workspace(input_path.clone(), &state)
        .await
        .expect("trust workspace");
    let project_id = open_project(input_path.clone(), None, &emitter, &state)
        .await
        .expect("open project");

    let global_db = state.global_db().expect("global db");
    let recents = global_db
        .list_recent_projects(10)
        .await
        .expect("list recent projects");
    let recent = recents
        .into_iter()
        .find(|row| row.project_id == project_id)
        .expect("recent project row");

    let expected_path = std::fs::canonicalize(&project_root)
        .expect("canonical project path")
        .to_string_lossy()
        .to_string();
    assert_eq!(
        recent.path, expected_path,
        "recent project path should be canonicalized"
    );
}

#[tokio::test]
async fn open_project_invalid_redaction_does_not_replace_live_runtime_config() {
    let _guard = redaction_config_lock().lock().await;
    let home = tempdir().expect("temp home");
    let _home = HomeOverride::new(home.path()).await;
    let project_root = tempdir().expect("temp project");
    std::fs::create_dir_all(project_root.path().join(".pnevma/data"))
        .expect("create scaffold dirs");
    write_test_project_config(project_root.path(), &["("]);

    let global_db = GlobalDb::open().await.expect("open global db");
    let state = AppState::new_with_global_db(Arc::new(NullEmitter), global_db);

    let original = pnevma_redaction::RedactionConfig {
        extra_patterns: vec![r"existing-secret-[0-9]+".to_string()],
        enable_entropy_guard: true,
    };
    pnevma_redaction::set_runtime_redaction_config(original.clone())
        .expect("set original runtime redaction config");

    trust_workspace(project_root.path().to_string_lossy().to_string(), &state)
        .await
        .expect("trust workspace");

    let emitter: Arc<dyn EventEmitter> = Arc::new(NullEmitter);
    let err = open_project(
        project_root.path().to_string_lossy().to_string(),
        None,
        &emitter,
        &state,
    )
    .await
    .expect_err("invalid regex should fail project open");
    assert!(
        err.contains("redaction.extra_patterns"),
        "unexpected error: {err}"
    );
    assert_eq!(
        pnevma_redaction::current_runtime_redaction_settings(),
        original,
        "failed open must preserve the live runtime redaction config"
    );

    pnevma_redaction::reset_runtime_redaction_config();
}

#[tokio::test]
async fn close_project_resets_runtime_redaction_config_after_shutdown() {
    let _guard = redaction_config_lock().lock().await;
    let project_root = tempdir().expect("temp project");
    let db = open_test_db().await;
    let project_id = Uuid::new_v4();
    db.upsert_project(
        &project_id.to_string(),
        "test-project",
        &project_root.path().to_string_lossy(),
        None,
        None,
    )
    .await
    .expect("upsert project");
    let sessions = SessionSupervisor::new(project_root.path().join(".pnevma/data"));
    let state = make_state_with_project(project_id, project_root.path(), db, sessions).await;
    *state.current_runtime.lock().await = Some(crate::state::ProjectRuntime::new(
        tokio::spawn(async {
            tokio::time::sleep(Duration::from_secs(30)).await;
        }),
        tokio::spawn(async {
            tokio::time::sleep(Duration::from_secs(30)).await;
        }),
        None,
    ));
    let active = pnevma_redaction::RedactionConfig {
        extra_patterns: vec![r"close-secret-[A-Z]+".to_string()],
        enable_entropy_guard: false,
    };
    pnevma_redaction::set_runtime_redaction_config(active).expect("set runtime redaction");

    close_project(&state).await.expect("close project");

    assert_eq!(
        pnevma_redaction::current_runtime_redaction_settings(),
        pnevma_redaction::RedactionConfig::default(),
        "close_project should clear the runtime redaction config after shutdown"
    );
    assert!(
        !state.has_open_project("tests.close_project.is_none").await,
        "close_project should clear the current project context"
    );
    assert!(
        state.current_runtime.lock().await.is_none(),
        "close_project should clear the current runtime handle"
    );
}

#[tokio::test]
async fn close_project_marks_live_session_rows_complete() {
    let project_root = tempdir().expect("temp project");
    let db = open_test_db().await;
    let project_id = Uuid::new_v4();
    db.upsert_project(
        &project_id.to_string(),
        "test-project",
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

    let session_id = Uuid::new_v4();
    let mut meta = make_session_metadata(
        project_id,
        session_id,
        project_root.path(),
        SessionStatus::Running,
    );
    meta.pid = None;
    sessions
        .register_restored(meta.clone())
        .await
        .expect("register_restored");
    db.upsert_session(&session_row_from_meta(&meta))
        .await
        .expect("persist session row");

    close_project(&state).await.expect("close project");

    let row = db
        .list_sessions(&project_id.to_string())
        .await
        .expect("list sessions")
        .into_iter()
        .find(|row| row.id == session_id.to_string())
        .expect("session row exists");
    assert_eq!(row.status, "complete");
    assert!(row.pid.is_none());
}

#[tokio::test]
async fn close_project_terminates_running_session_helpers_and_persists_complete_rows() {
    let project_root = tempdir().expect("temp project");
    let db = open_test_db().await;
    let project_id = Uuid::new_v4();
    db.upsert_project(
        &project_id.to_string(),
        "shutdown-test",
        &project_root.path().to_string_lossy(),
        None,
        None,
    )
    .await
    .expect("upsert project");

    let sessions = SessionSupervisor::new(project_root.path().join(".pnevma/data"));
    let session_id = Uuid::new_v4();
    let mut child = TokioCommand::new("sleep")
        .arg("30")
        .spawn()
        .expect("spawn helper");
    let helper_pid = child.id().expect("helper pid") as i64;
    let mut meta = make_session_metadata(
        project_id,
        session_id,
        project_root.path(),
        SessionStatus::Running,
    );
    meta.pid = Some(helper_pid as u32);
    sessions
        .register_restored(meta.clone())
        .await
        .expect("register_restored");
    db.upsert_session(&session_row_from_meta(&meta))
        .await
        .expect("persist session");

    let state =
        make_state_with_project(project_id, project_root.path(), db.clone(), sessions).await;
    close_project(&state).await.expect("close project");

    let waited = tokio::time::timeout(Duration::from_secs(2), child.wait())
        .await
        .expect("helper should exit promptly")
        .expect("wait on helper");
    assert!(
        !process_alive(helper_pid as libc::pid_t),
        "helper pid should not survive project shutdown: {helper_pid}"
    );
    assert!(
        !waited.success(),
        "sleep helper should be terminated rather than exit cleanly"
    );

    let persisted = db
        .list_sessions(&project_id.to_string())
        .await
        .expect("list sessions");
    let row = persisted
        .into_iter()
        .find(|row| row.id == session_id.to_string())
        .expect("session row");
    assert_eq!(row.status, "complete");
    assert_eq!(row.pid, None);
}

#[tokio::test]
async fn cleanup_project_data_prunes_old_files_and_updates_rows() {
    let temp = tempfile::tempdir().expect("tempdir");
    let project_root = temp.path();
    let data_root = project_root.join(".pnevma").join("data");
    let db = open_test_db().await;
    let project_id = Uuid::new_v4().to_string();
    db.upsert_project(
        &project_id,
        "retention-test",
        project_root.to_string_lossy().as_ref(),
        None,
        None,
    )
    .await
    .unwrap();

    let old = Utc::now() - chrono::Duration::days(45);

    let artifact_rel = ".pnevma/data/artifacts/knowledge.md";
    let artifact_path = project_root.join(artifact_rel);
    std::fs::create_dir_all(artifact_path.parent().expect("artifact parent")).unwrap();
    std::fs::write(&artifact_path, "knowledge").unwrap();
    db.create_artifact(&ArtifactRow {
        id: Uuid::new_v4().to_string(),
        project_id: project_id.clone(),
        task_id: None,
        r#type: "knowledge".to_string(),
        path: artifact_rel.to_string(),
        description: Some("old knowledge".to_string()),
        created_at: old,
    })
    .await
    .unwrap();

    let feedback_rel = ".pnevma/data/feedback/ux.md";
    let feedback_path = project_root.join(feedback_rel);
    std::fs::create_dir_all(feedback_path.parent().expect("feedback parent")).unwrap();
    std::fs::write(&feedback_path, "feedback").unwrap();
    db.create_feedback(&FeedbackRow {
        id: Uuid::new_v4().to_string(),
        project_id: project_id.clone(),
        category: "ux".to_string(),
        body: "old feedback".to_string(),
        contact: None,
        artifact_path: Some(feedback_rel.to_string()),
        created_at: old,
    })
    .await
    .unwrap();

    let mut done_task = make_task(&project_id, "completed task");
    done_task.status = "Done".to_string();
    done_task.created_at = old;
    done_task.updated_at = old;
    db.create_task(&done_task).await.unwrap();

    let review_dir = data_root.join("reviews").join(&done_task.id);
    std::fs::create_dir_all(&review_dir).unwrap();
    let review_pack_path = review_dir.join("review-pack.json");
    std::fs::write(&review_pack_path, "{}").unwrap();
    std::fs::write(review_dir.join("diff.patch"), "diff").unwrap();
    sqlx::query(
        r#"
        INSERT INTO reviews (id, task_id, status, review_pack_path, reviewer_notes, approved_at)
        VALUES (?1, ?2, ?3, ?4, ?5, ?6)
        "#,
    )
    .bind(Uuid::new_v4().to_string())
    .bind(&done_task.id)
    .bind("Ready")
    .bind(review_pack_path.to_string_lossy().to_string())
    .bind(Option::<String>::None)
    .bind(Option::<DateTime<Utc>>::None)
    .execute(db.pool())
    .await
    .unwrap();

    let session_id = Uuid::new_v4().to_string();
    let scrollback_dir = data_root.join("scrollback");
    std::fs::create_dir_all(&scrollback_dir).unwrap();
    std::fs::write(
        scrollback_dir.join(format!("{session_id}.log")),
        "scrollback",
    )
    .unwrap();
    std::fs::write(scrollback_dir.join(format!("{session_id}.idx")), "0").unwrap();
    db.upsert_session(&SessionRow {
        id: session_id.clone(),
        project_id: project_id.clone(),
        name: "shell".to_string(),
        r#type: Some("terminal".to_string()),
        backend: "tmux_compat".to_string(),
        durability: "durable".to_string(),
        lifecycle_state: "exited".to_string(),
        status: "complete".to_string(),
        pid: None,
        cwd: project_root.to_string_lossy().to_string(),
        command: "zsh".to_string(),
        branch: None,
        worktree_id: None,
        connection_id: None,
        remote_session_id: None,
        controller_id: None,
        started_at: old,
        last_heartbeat: old,
        last_output_at: Some(old),
        detached_at: Some(old),
        last_error: None,
        restore_status: None,
        exit_code: None,
        ended_at: None,
    })
    .await
    .unwrap();

    let retention = pnevma_core::RetentionSection {
        enabled: true,
        artifact_days: 30,
        review_days: 30,
        scrollback_days: 14,
    };
    let emitter: Arc<dyn EventEmitter> = Arc::new(NullEmitter);
    let response = cleanup_project_data_retention_inner(
        &db,
        Uuid::parse_str(&project_id).unwrap(),
        project_root,
        &retention,
        &emitter,
        false,
    )
    .await
    .expect("cleanup succeeds");

    assert_eq!(response.artifacts_pruned, 1);
    assert_eq!(response.feedback_artifacts_cleared, 1);
    assert_eq!(response.review_packs_pruned, 1);
    assert_eq!(response.scrollback_sessions_pruned, 1);
    assert_eq!(response.telemetry_exports_pruned, 0);
    assert_eq!(response.files_deleted, 6);

    assert!(db.list_artifacts(&project_id).await.unwrap().is_empty());
    assert_eq!(
        db.list_feedback(&project_id, 100).await.unwrap()[0].artifact_path,
        None
    );
    assert!(db
        .get_review_by_task(&done_task.id)
        .await
        .unwrap()
        .is_none());
    assert!(!artifact_path.exists());
    assert!(!feedback_path.exists());
    assert!(!review_dir.exists());
    assert!(!scrollback_dir.join(format!("{session_id}.log")).exists());
    assert!(!scrollback_dir.join(format!("{session_id}.idx")).exists());
}

#[tokio::test]
async fn cleanup_project_data_dry_run_does_not_delete_files() {
    let temp = tempfile::tempdir().expect("tempdir");
    let project_root = temp.path();
    let data_root = project_root.join(".pnevma").join("data");
    let db = open_test_db().await;
    let project_id = Uuid::new_v4().to_string();
    db.upsert_project(
        &project_id,
        "retention-test",
        project_root.to_string_lossy().as_ref(),
        None,
        None,
    )
    .await
    .unwrap();

    let old = Utc::now() - chrono::Duration::days(45);
    let artifact_rel = ".pnevma/data/artifacts/knowledge.md";
    let artifact_path = project_root.join(artifact_rel);
    std::fs::create_dir_all(artifact_path.parent().expect("artifact parent")).unwrap();
    std::fs::write(&artifact_path, "knowledge").unwrap();
    db.create_artifact(&ArtifactRow {
        id: Uuid::new_v4().to_string(),
        project_id: project_id.clone(),
        task_id: None,
        r#type: "knowledge".to_string(),
        path: artifact_rel.to_string(),
        description: Some("old knowledge".to_string()),
        created_at: old,
    })
    .await
    .unwrap();

    let retention = pnevma_core::RetentionSection {
        enabled: true,
        artifact_days: 30,
        review_days: 30,
        scrollback_days: 14,
    };
    let emitter: Arc<dyn EventEmitter> = Arc::new(NullEmitter);
    let response = cleanup_project_data_retention_inner(
        &db,
        Uuid::parse_str(&project_id).unwrap(),
        project_root,
        &retention,
        &emitter,
        true,
    )
    .await
    .expect("cleanup succeeds");

    assert_eq!(response.artifacts_pruned, 1);
    assert_eq!(response.files_deleted, 1);
    assert!(artifact_path.exists());
    assert_eq!(db.list_artifacts(&project_id).await.unwrap().len(), 1);
    assert!(data_root.exists());
}
