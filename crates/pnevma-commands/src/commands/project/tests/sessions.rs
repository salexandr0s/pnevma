use super::*;

#[test]
fn resolve_session_command_prefers_global_default_shell_for_empty_commands() {
    assert_eq!(
        resolve_session_command("", Some("/bin/bash")),
        "/bin/bash".to_string()
    );
    assert_eq!(
        resolve_session_command("   ", Some("/bin/zsh")),
        "/bin/zsh".to_string()
    );
}

#[test]
fn resolve_session_command_preserves_explicit_commands() {
    assert_eq!(
        resolve_session_command("cargo test", Some("/bin/bash")),
        "cargo test".to_string()
    );
}

#[tokio::test]
async fn get_session_binding_reports_live_and_archived_modes() {
    let temp = tempfile::tempdir().expect("tempdir");
    let project_root = temp.path().join("project");
    std::fs::create_dir_all(project_root.join(".pnevma/data/scrollback")).unwrap();

    let db = open_test_db().await;
    let project_id = Uuid::new_v4();
    db.upsert_project(
        &project_id.to_string(),
        "binding-test",
        project_root.to_string_lossy().as_ref(),
        None,
        None,
    )
    .await
    .unwrap();

    let sessions = SessionSupervisor::new(project_root.join(".pnevma/data"));
    let live_session_id = Uuid::new_v4();
    let archived_session_id = Uuid::new_v4();
    sessions
        .register_restored(make_session_metadata(
            project_id,
            live_session_id,
            &project_root,
            SessionStatus::Waiting,
        ))
        .await
        .expect("register_restored");
    sessions
        .register_restored(make_session_metadata(
            project_id,
            archived_session_id,
            &project_root,
            SessionStatus::Complete,
        ))
        .await
        .expect("register_restored");

    let emitter: Arc<dyn EventEmitter> = Arc::new(NullEmitter);
    let state = AppState::new(emitter);
    let (shutdown_tx, _shutdown_rx) = tokio::sync::watch::channel(false);
    state
        .replace_current_project(
            "tests.get_session_binding.state",
            ProjectContext {
                project_id,
                project_path: project_root.clone(),
                config: make_project_config(),
                global_config: GlobalConfig::default(),
                db,
                sessions: sessions.clone(),
                redaction_secrets: Arc::new(RwLock::new(Vec::new())),
                git: Arc::new(GitService::new(&project_root)),
                adapters: AdapterRegistry::default(),
                pool: DispatchPool::new(1),
                tracker: None,
                workflow_store: Arc::new(crate::automation::workflow_store::WorkflowStore::new(
                    &project_root,
                )),
                coordinator: None,
                shutdown_tx,
            },
        )
        .await;

    let live = get_session_binding(live_session_id.to_string(), &state)
        .await
        .expect("live binding");
    assert_eq!(live.mode, "live_attach");
    assert_eq!(live.cwd, project_root.to_string_lossy());
    assert!(live
        .env
        .iter()
        .any(|env| env.key == "TMUX_TMPDIR" && !env.value.is_empty()));

    let archived = get_session_binding(archived_session_id.to_string(), &state)
        .await
        .expect("archived binding");
    assert_eq!(archived.mode, "archived");
    assert!(archived.env.is_empty());
    assert!(archived
        .recovery_options
        .iter()
        .any(|option| option.id == "restart" && option.enabled));
}

#[tokio::test]
async fn get_scrollback_defaults_to_tail_when_offset_is_omitted() {
    let temp = tempfile::tempdir().expect("tempdir");
    let project_root = temp.path().join("project");
    let scrollback_dir = project_root.join(".pnevma/data/scrollback");
    std::fs::create_dir_all(&scrollback_dir).unwrap();

    let db = open_test_db().await;
    let project_id = Uuid::new_v4();
    db.upsert_project(
        &project_id.to_string(),
        "scrollback-tail-test",
        project_root.to_string_lossy().as_ref(),
        None,
        None,
    )
    .await
    .unwrap();

    let sessions = SessionSupervisor::new(project_root.join(".pnevma/data"));
    let session_id = Uuid::new_v4();
    let scrollback_path = scrollback_dir.join(format!("{session_id}.log"));
    std::fs::write(&scrollback_path, "alpha\nbeta\ngamma\n").unwrap();
    sessions
        .register_restored(make_session_metadata(
            project_id,
            session_id,
            &project_root,
            SessionStatus::Complete,
        ))
        .await
        .expect("register_restored");

    let state = make_state_with_project(project_id, &project_root, db, sessions).await;
    let slice = get_scrollback(
        ScrollbackInput {
            session_id: session_id.to_string(),
            offset: None,
            limit: Some(6),
        },
        &state,
    )
    .await
    .expect("tail scrollback should load");

    assert_eq!(slice.data, "gamma\n");
    assert_eq!(slice.end_offset, slice.total_bytes);
}

#[tokio::test]
async fn get_session_timeline_uses_scrollback_tail_snapshot() {
    let temp = tempfile::tempdir().expect("tempdir");
    let project_root = temp.path().join("project");
    let scrollback_dir = project_root.join(".pnevma/data/scrollback");
    std::fs::create_dir_all(&scrollback_dir).unwrap();

    let db = open_test_db().await;
    let project_id = Uuid::new_v4();
    db.upsert_project(
        &project_id.to_string(),
        "timeline-tail-test",
        project_root.to_string_lossy().as_ref(),
        None,
        None,
    )
    .await
    .unwrap();

    let sessions = SessionSupervisor::new(project_root.join(".pnevma/data"));
    let session_id = Uuid::new_v4();
    let scrollback_path = scrollback_dir.join(format!("{session_id}.log"));
    let body = format!(
        "HEAD-MARKER\n{}TAIL-MARKER\n",
        "middle-line\n".repeat(14_000)
    );
    assert!(body.len() > 128 * 1024);
    std::fs::write(&scrollback_path, body).unwrap();
    sessions
        .register_restored(make_session_metadata(
            project_id,
            session_id,
            &project_root,
            SessionStatus::Complete,
        ))
        .await
        .expect("register_restored");

    let state = make_state_with_project(project_id, &project_root, db, sessions).await;
    let timeline = get_session_timeline(
        SessionTimelineInput {
            session_id: session_id.to_string(),
            limit: Some(10),
        },
        &state,
    )
    .await
    .expect("timeline should load");

    let snapshot = timeline
        .iter()
        .find(|entry| entry.kind == "ScrollbackSnapshot")
        .expect("timeline should include a scrollback snapshot");
    let data: &str = snapshot
        .payload
        .get("data")
        .and_then(Value::as_str)
        .expect("snapshot payload should contain data");

    assert!(data.contains("TAIL-MARKER"));
    assert!(!data.contains("HEAD-MARKER"));
}
