use super::*;
use pnevma_db::{EventQueryFilter, SshProfileRow};
use serde_json::{json, Value};
use sha2::Digest;
use std::ffi::OsString;
use std::path::Path;

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
async fn upsert_ssh_profile_returns_stable_id_for_duplicate_global_name() {
    let home = tempdir().expect("temp home");
    let _home = HomeOverride::new(home.path()).await;
    let global_db = GlobalDb::open().await.expect("open global db");
    let state = AppState::new_with_global_db(Arc::new(NullEmitter), global_db);

    let first_id = upsert_ssh_profile(
        SshProfileInput {
            id: Some("profile-original".to_string()),
            name: "Mac Studio".to_string(),
            host: "savorgserver".to_string(),
            port: 22,
            user: Some("savorgserver".to_string()),
            identity_file: Some("/tmp/id_ed25519".to_string()),
            proxy_jump: None,
            tags: Vec::new(),
            source: Some("manual".to_string()),
        },
        &state,
    )
    .await
    .expect("insert ssh profile");

    let second_id = upsert_ssh_profile(
        SshProfileInput {
            id: Some("profile-updated".to_string()),
            name: "Mac Studio".to_string(),
            host: "savorgserver.tailnet".to_string(),
            port: 2222,
            user: Some("builder".to_string()),
            identity_file: Some("/tmp/id_ed25519_new".to_string()),
            proxy_jump: Some("jump.internal".to_string()),
            tags: Vec::new(),
            source: Some("manual".to_string()),
        },
        &state,
    )
    .await
    .expect("update ssh profile");

    assert_eq!(second_id, first_id);

    let profiles = list_ssh_profiles(&state).await.expect("list ssh profiles");
    assert_eq!(profiles.len(), 1);
    assert_eq!(profiles[0].id, first_id);
    assert_eq!(profiles[0].name, "Mac Studio");
    assert_eq!(profiles[0].host, "savorgserver.tailnet");
    assert_eq!(profiles[0].port, 2222);
    assert_eq!(profiles[0].user.as_deref(), Some("builder"));
    assert_eq!(profiles[0].proxy_jump.as_deref(), Some("jump.internal"));
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
                project_root_path: project_root.clone(),
                project_path: project_root.clone(),
                checkout_path: project_root.clone(),
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
    let expected_tmux = pnevma_ssh::shell_escape_arg(
        pnevma_session::resolve_binary("tmux")
            .to_string_lossy()
            .as_ref(),
    );
    assert_eq!(
        live.launch_command.as_deref(),
        Some(tmux_attach_launch_command().as_str())
    );
    assert!(live
        .launch_command
        .as_deref()
        .unwrap_or_default()
        .contains(&expected_tmux));
    assert!(live
        .env
        .iter()
        .any(|env| env.key == "TMUX_TMPDIR" && !env.value.is_empty()));

    let archived = get_session_binding(archived_session_id.to_string(), &state)
        .await
        .expect("archived binding");
    assert_eq!(archived.mode, "archived");
    assert_eq!(archived.launch_command, None);
    assert!(archived.env.is_empty());
    assert!(archived
        .recovery_options
        .iter()
        .any(|option| option.id == "restart" && option.enabled));
}

#[tokio::test]
async fn get_session_binding_falls_back_to_archived_persisted_rows() {
    let temp = tempfile::tempdir().expect("tempdir");
    let project_root = temp.path().join("project");
    std::fs::create_dir_all(project_root.join(".pnevma/data/scrollback")).unwrap();

    let db = open_test_db().await;
    let project_id = Uuid::new_v4();
    db.upsert_project(
        &project_id.to_string(),
        "binding-fallback-test",
        project_root.to_string_lossy().as_ref(),
        None,
        None,
    )
    .await
    .unwrap();

    let session_id = Uuid::new_v4();
    let now = Utc::now();
    db.upsert_session(&SessionRow {
        id: session_id.to_string(),
        project_id: project_id.to_string(),
        name: "shell".to_string(),
        r#type: Some("terminal".to_string()),
        backend: "tmux_compat".to_string(),
        durability: "durable".to_string(),
        lifecycle_state: "exited".to_string(),
        status: "complete".to_string(),
        pid: None,
        cwd: project_root.to_string_lossy().to_string(),
        command: "/bin/zsh".to_string(),
        branch: None,
        worktree_id: None,
        connection_id: None,
        remote_session_id: None,
        controller_id: None,
        started_at: now,
        last_heartbeat: now,
        last_output_at: Some(now),
        detached_at: Some(now),
        last_error: None,
        restore_status: None,
        exit_code: Some(0),
        ended_at: Some(now.to_rfc3339()),
    })
    .await
    .expect("persist archived session row");

    let sessions = SessionSupervisor::new(project_root.join(".pnevma/data"));
    let state = make_state_with_project(project_id, &project_root, db, sessions).await;

    let archived = get_session_binding(session_id.to_string(), &state)
        .await
        .expect("archived fallback binding");
    assert_eq!(archived.mode, "archived");
    assert_eq!(archived.lifecycle_state, "exited");
    assert_eq!(archived.launch_command, None);
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
async fn get_scrollback_falls_back_to_archived_persisted_local_rows() {
    let temp = tempfile::tempdir().expect("tempdir");
    let project_root = temp.path().join("project");
    let scrollback_dir = project_root.join(".pnevma/data/scrollback");
    std::fs::create_dir_all(&scrollback_dir).unwrap();

    let db = open_test_db().await;
    let project_id = Uuid::new_v4();
    db.upsert_project(
        &project_id.to_string(),
        "scrollback-archived-fallback-test",
        project_root.to_string_lossy().as_ref(),
        None,
        None,
    )
    .await
    .unwrap();

    let session_id = Uuid::new_v4();
    let now = Utc::now();
    std::fs::write(
        scrollback_dir.join(format!("{session_id}.log")),
        "alpha\nbeta\ngamma\n",
    )
    .unwrap();
    db.upsert_session(&SessionRow {
        id: session_id.to_string(),
        project_id: project_id.to_string(),
        name: "shell".to_string(),
        r#type: Some("terminal".to_string()),
        backend: "tmux_compat".to_string(),
        durability: "durable".to_string(),
        lifecycle_state: "exited".to_string(),
        status: "complete".to_string(),
        pid: None,
        cwd: project_root.to_string_lossy().to_string(),
        command: "/bin/zsh".to_string(),
        branch: None,
        worktree_id: None,
        connection_id: None,
        remote_session_id: None,
        controller_id: None,
        started_at: now,
        last_heartbeat: now,
        last_output_at: Some(now),
        detached_at: Some(now),
        last_error: None,
        restore_status: None,
        exit_code: Some(0),
        ended_at: Some(now.to_rfc3339()),
    })
    .await
    .expect("persist archived session row");

    let sessions = SessionSupervisor::new(project_root.join(".pnevma/data"));
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
    .expect("archived scrollback should load");

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

#[tokio::test]
async fn get_session_timeline_uses_archived_persisted_local_scrollback_snapshot() {
    let temp = tempfile::tempdir().expect("tempdir");
    let project_root = temp.path().join("project");
    let scrollback_dir = project_root.join(".pnevma/data/scrollback");
    std::fs::create_dir_all(&scrollback_dir).unwrap();

    let db = open_test_db().await;
    let project_id = Uuid::new_v4();
    db.upsert_project(
        &project_id.to_string(),
        "timeline-archived-fallback-test",
        project_root.to_string_lossy().as_ref(),
        None,
        None,
    )
    .await
    .unwrap();

    let session_id = Uuid::new_v4();
    let now = Utc::now();
    std::fs::write(
        scrollback_dir.join(format!("{session_id}.log")),
        "archived tail\n",
    )
    .unwrap();
    db.upsert_session(&SessionRow {
        id: session_id.to_string(),
        project_id: project_id.to_string(),
        name: "shell".to_string(),
        r#type: Some("terminal".to_string()),
        backend: "tmux_compat".to_string(),
        durability: "durable".to_string(),
        lifecycle_state: "exited".to_string(),
        status: "complete".to_string(),
        pid: None,
        cwd: project_root.to_string_lossy().to_string(),
        command: "/bin/zsh".to_string(),
        branch: None,
        worktree_id: None,
        connection_id: None,
        remote_session_id: None,
        controller_id: None,
        started_at: now,
        last_heartbeat: now,
        last_output_at: Some(now),
        detached_at: Some(now),
        last_error: None,
        restore_status: None,
        exit_code: Some(0),
        ended_at: Some(now.to_rfc3339()),
    })
    .await
    .expect("persist archived session row");

    let sessions = SessionSupervisor::new(project_root.join(".pnevma/data"));
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
    let data = snapshot
        .payload
        .get("data")
        .and_then(Value::as_str)
        .expect("snapshot payload should contain data");

    assert_eq!(data, "archived tail\n");
}

pub(super) struct RemoteSshTestEnv {
    previous_home: Option<OsString>,
    previous_ssh_bin: Option<OsString>,
    previous_artifact_dir: Option<OsString>,
    _guard: tokio::sync::MutexGuard<'static, ()>,
}

impl RemoteSshTestEnv {
    pub(super) async fn new(root: &Path) -> Self {
        Self::new_with_target(root, "Linux x86_64", "x86_64-unknown-linux-musl").await
    }

    pub(super) async fn new_with_target(
        root: &Path,
        platform_output: &str,
        target_triple: &str,
    ) -> Self {
        let guard = home_env_lock().lock().await;
        let previous_home = std::env::var_os("HOME");
        let previous_ssh_bin = std::env::var_os("PNEVMA_SSH_BIN");
        let previous_artifact_dir = std::env::var_os("PNEVMA_REMOTE_HELPER_ARTIFACT_DIR");
        let fake_home = root.join("home");
        std::fs::create_dir_all(&fake_home).expect("create fake home");
        let fake_bin = root.join("fake-bin");
        std::fs::create_dir_all(&fake_bin).expect("create fake bin");
        write_fake_executable(
            &fake_bin.join("sh"),
            "#!/bin/sh\nset -eu\nif [ \"$#\" -ge 2 ] && [ \"$1\" = \"-lc\" ]; then\n  shift\n  exec /bin/sh -c \"$1\"\nfi\nexec /bin/sh \"$@\"\n",
        );
        write_fake_executable(
            &fake_bin.join("uname"),
            &format!(
                "#!/bin/sh\nset -eu\nif [ \"$#\" -eq 1 ] && [ \"$1\" = \"-sm\" ]; then\n  printf '{}\\n'\nelse\n  /usr/bin/uname \"$@\"\nfi\n",
                platform_output
            ),
        );
        let fake_ssh = root.join("fake-ssh.sh");
        write_fake_executable(
            &fake_ssh,
            &format!(
                "#!/bin/sh\nset -eu\nexport HOME={}\nexport PATH={}:$PATH\nremote_cmd=\"\"\nfor arg in \"$@\"; do remote_cmd=\"$arg\"; done\nexec sh -lc \"$remote_cmd\"\n",
                pnevma_ssh::shell_escape_arg(fake_home.to_string_lossy().as_ref()),
                pnevma_ssh::shell_escape_arg(fake_bin.to_string_lossy().as_ref())
            ),
        );
        let artifact_dir = write_test_remote_helper_artifacts(root, target_triple);
        std::env::set_var("HOME", &fake_home);
        std::env::set_var("PNEVMA_SSH_BIN", &fake_ssh);
        std::env::set_var("PNEVMA_REMOTE_HELPER_ARTIFACT_DIR", &artifact_dir);
        Self {
            previous_home,
            previous_ssh_bin,
            previous_artifact_dir,
            _guard: guard,
        }
    }
}

impl Drop for RemoteSshTestEnv {
    fn drop(&mut self) {
        if let Some(previous_home) = self.previous_home.as_ref() {
            std::env::set_var("HOME", previous_home);
        } else {
            std::env::remove_var("HOME");
        }
        if let Some(previous_ssh_bin) = self.previous_ssh_bin.as_ref() {
            std::env::set_var("PNEVMA_SSH_BIN", previous_ssh_bin);
        } else {
            std::env::remove_var("PNEVMA_SSH_BIN");
        }
        if let Some(previous_artifact_dir) = self.previous_artifact_dir.as_ref() {
            std::env::set_var("PNEVMA_REMOTE_HELPER_ARTIFACT_DIR", previous_artifact_dir);
        } else {
            std::env::remove_var("PNEVMA_REMOTE_HELPER_ARTIFACT_DIR");
        }
    }
}

fn write_test_remote_helper_artifacts(root: &Path, target_triple: &str) -> std::path::PathBuf {
    let artifact_dir = root.join("remote-helper");
    let target_dir = artifact_dir.join(target_triple);
    std::fs::create_dir_all(&target_dir).expect("create artifact target dir");

    let artifact_path = target_dir.join("pnevma-remote-helper");
    write_fake_executable(
        &artifact_path,
        &format!(
            r#"#!/bin/sh
set -eu

metadata_value() {{
  if [ -f "$0.metadata" ]; then
    sed -n "s/^$1=//p" "$0.metadata" | head -n 1
  fi
}}

state_root="$HOME/.local/state/pnevma/remote"
sessions_dir="$state_root/test-sessions"
mkdir -p "$sessions_dir"

print_health() {{
  printf 'version=pnevma-remote-helper/{}\n'
  printf 'protocol_version=1\n'
  printf 'helper_kind=binary\n'
  printf 'helper_path=%s\n' "$0"
  printf 'state_root=%s\n' "$state_root"
  printf 'controller_id=controller-binary\n'
  printf 'target_triple=%s\n' "$(metadata_value target_triple)"
  printf 'artifact_source=%s\n' "$(metadata_value artifact_source)"
  printf 'artifact_sha256=%s\n' "$(metadata_value artifact_sha256)"
  printf 'missing_dependencies=\n'
  printf 'healthy=true\n'
}}

session_file() {{
  printf '%s/%s.env' "$sessions_dir" "$1"
}}

read_field() {{
  file="$1"
  key="$2"
  if [ -f "$file" ]; then
    sed -n "s/^$key=//p" "$file" | head -n 1
  fi
}}

write_session() {{
  file="$1"
  session_id="$2"
  state="$3"
  pid="$4"
  printf 'session_id=%s\nstate=%s\npid=%s\n' "$session_id" "$state" "$pid" > "$file"
}}

handle_session_create() {{
  session_id=""
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --session-id)
        session_id="$2"
        shift 2
        ;;
      --cwd|--command)
        shift 2
        ;;
      --json)
        shift
        ;;
      *)
        shift
        ;;
    esac
  done
  if [ -z "$session_id" ]; then
    printf 'missing session id\n' >&2
    exit 64
  fi
  write_session "$(session_file "$session_id")" "$session_id" "detached" "4242"
  printf 'session_id=%s\n' "$session_id"
  printf 'controller_id=controller-binary\n'
  printf 'state=detached\n'
  printf 'pid=4242\n'
  printf 'log_path=%s/%s.log\n' "$state_root" "$session_id"
}}

handle_session_status() {{
  session_id=""
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --session-id)
        session_id="$2"
        shift 2
        ;;
      --json)
        shift
        ;;
      *)
        shift
        ;;
    esac
  done
  if [ -z "$session_id" ]; then
    printf 'missing session id\n' >&2
    exit 64
  fi
  file="$(session_file "$session_id")"
  if [ -f "$file" ]; then
    state="$(read_field "$file" state)"
    pid="$(read_field "$file" pid)"
    transient_lost_once="$(read_field "$file" transient_lost_once)"
    if [ "$transient_lost_once" = "1" ] && [ ! -f "$file.transient-lost-once" ]; then
      : > "$file.transient-lost-once"
      state="lost"
      pid=""
    fi
  else
    state="lost"
    pid=""
  fi
  printf 'session_id=%s\n' "$session_id"
  printf 'controller_id=controller-binary\n'
  printf 'state=%s\n' "$state"
  if [ -n "$pid" ]; then
    printf 'pid=%s\n' "$pid"
  fi
  printf 'total_bytes=0\n'
}}

handle_session_signal() {{
  printf 'ok=true\n'
}}

handle_session_terminate() {{
  session_id=""
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --session-id)
        session_id="$2"
        shift 2
        ;;
      --json)
        shift
        ;;
      *)
        shift
        ;;
    esac
  done
  if [ -n "$session_id" ]; then
    write_session "$(session_file "$session_id")" "$session_id" "exited" ""
  fi
  printf 'ok=true\n'
}}

cmd="${{1:-}}"
case "$cmd" in
  health)
    print_health
    ;;
  session)
    subcmd="${{2:-}}"
    shift
    shift || true
    case "$subcmd" in
      create)
        handle_session_create "$@"
        ;;
      status)
        handle_session_status "$@"
        ;;
      signal)
        handle_session_signal "$@"
        ;;
      terminate)
        handle_session_terminate "$@"
        ;;
      attach)
        exit 0
        ;;
      *)
        printf 'unsupported session subcommand: %s\n' "$subcmd" >&2
        exit 64
        ;;
    esac
    ;;
  *)
    print_health
    ;;
esac
"#,
            env!("CARGO_PKG_VERSION"),
        ),
    );
    let final_bytes = std::fs::read(&artifact_path).expect("final artifact bytes");
    let final_sha = format!("{:x}", sha2::Sha256::digest(&final_bytes));
    let manifest = json!({
        "schema_version": 1,
        "package_version": env!("CARGO_PKG_VERSION"),
        "protocol_version": "1",
        "artifacts": [
            {
                "target_triple": target_triple,
                "relative_path": format!("{target_triple}/pnevma-remote-helper"),
                "sha256": final_sha,
                "size": final_bytes.len()
            }
        ]
    });
    std::fs::write(
        artifact_dir.join("manifest.json"),
        serde_json::to_vec_pretty(&manifest).expect("manifest json"),
    )
    .expect("write manifest");

    artifact_dir
}

pub(super) async fn upsert_test_project_ssh_profile(
    db: &Db,
    project_id: Uuid,
    profile_id: &str,
    name: &str,
) {
    let now = Utc::now();
    db.upsert_ssh_profile(&SshProfileRow {
        id: profile_id.to_string(),
        project_id: project_id.to_string(),
        name: name.to_string(),
        host: "example.internal".to_string(),
        port: 22,
        user: Some("builder".to_string()),
        identity_file: Some("/tmp/id_ed25519".to_string()),
        proxy_jump: Some("jump.internal".to_string()),
        tags_json: "[]".to_string(),
        source: "manual".to_string(),
        created_at: now,
        updated_at: now,
    })
    .await
    .expect("upsert ssh profile");
}

pub(super) fn test_remote_profile(profile_id: &str, name: &str) -> pnevma_ssh::SshProfile {
    let now = Utc::now();
    pnevma_ssh::SshProfile {
        id: profile_id.to_string(),
        name: name.to_string(),
        host: "example.internal".to_string(),
        port: 22,
        user: Some("builder".to_string()),
        identity_file: Some("/tmp/id_ed25519".to_string()),
        proxy_jump: Some("jump.internal".to_string()),
        tags: Vec::new(),
        source: "manual".to_string(),
        created_at: now,
        updated_at: now,
    }
}

#[tokio::test]
async fn get_session_binding_returns_live_attach_for_remote_durable_rows() {
    let temp = tempfile::tempdir().expect("tempdir");
    let _env = RemoteSshTestEnv::new(temp.path()).await;
    let project_root = temp.path().join("project");
    std::fs::create_dir_all(project_root.join(".pnevma/data/scrollback")).unwrap();

    let db = open_test_db().await;
    let project_id = Uuid::new_v4();
    db.upsert_project(
        &project_id.to_string(),
        "remote-binding-test",
        project_root.to_string_lossy().as_ref(),
        None,
        None,
    )
    .await
    .unwrap();
    upsert_test_project_ssh_profile(&db, project_id, "ssh-profile-1", "Builder").await;

    let sessions = SessionSupervisor::new(project_root.join(".pnevma/data"));
    let state = make_state_with_project(project_id, &project_root, db.clone(), sessions).await;
    let row = create_remote_managed_session(CreateRemoteManagedSessionInput {
        db: &db,
        project_id,
        name: "Remote Terminal".to_string(),
        session_type: Some("terminal".to_string()),
        profile: &test_remote_profile("ssh-profile-1", "Builder"),
        connection_id: "ssh-profile-1".to_string(),
        cwd: "/srv/project".to_string(),
        command: Some("sleep 30".to_string()),
    })
    .await
    .expect("create remote managed session");

    let binding = get_session_binding(row.id.clone(), &state)
        .await
        .expect("remote binding");
    assert_eq!(binding.backend, "remote_ssh_durable");
    assert_eq!(binding.mode, "live_attach");
    assert_eq!(binding.lifecycle_state, "detached");
    assert!(binding.env.is_empty());
    assert!(binding
        .launch_command
        .as_deref()
        .unwrap_or_default()
        .contains("pnevma-remote-helper session attach"));
}

#[tokio::test]
async fn get_session_binding_retries_transient_remote_lost_for_fresh_durable_rows() {
    let temp = tempfile::tempdir().expect("tempdir");
    let _env = RemoteSshTestEnv::new(temp.path()).await;
    let project_root = temp.path().join("project");
    std::fs::create_dir_all(project_root.join(".pnevma/data/scrollback")).unwrap();

    let db = open_test_db().await;
    let project_id = Uuid::new_v4();
    db.upsert_project(
        &project_id.to_string(),
        "remote-binding-retry-test",
        project_root.to_string_lossy().as_ref(),
        None,
        None,
    )
    .await
    .unwrap();
    upsert_test_project_ssh_profile(&db, project_id, "ssh-profile-1", "Builder").await;

    let sessions = SessionSupervisor::new(project_root.join(".pnevma/data"));
    let state =
        make_state_with_project(project_id, &project_root, db.clone(), sessions.clone()).await;

    let session_id = connect_ssh("ssh-profile-1".to_string(), &state)
        .await
        .expect("connect ssh");
    let session_file = temp
        .path()
        .join("home/.local/state/pnevma/remote/test-sessions")
        .join(format!("{session_id}.env"));
    std::fs::write(
        &session_file,
        format!(
            "{}\ntransient_lost_once=1\n",
            std::fs::read_to_string(&session_file).expect("read session file")
        ),
    )
    .expect("mark transient lost");

    let binding = get_session_binding(session_id.clone(), &state)
        .await
        .expect("remote binding");
    assert_eq!(binding.backend, "remote_ssh_durable");
    assert_eq!(binding.mode, "live_attach");
    assert_eq!(binding.lifecycle_state, "detached");

    let row = db
        .get_session(&project_id.to_string(), &session_id)
        .await
        .expect("load session row")
        .expect("session row");
    assert_eq!(row.status, "waiting");
    assert_eq!(row.lifecycle_state, "detached");
    assert_eq!(row.restore_status.as_deref(), Some("detached"));
    assert_eq!(row.last_error, None);
}

#[tokio::test]
async fn connect_ssh_creates_remote_durable_backend_session() {
    let temp = tempfile::tempdir().expect("tempdir");
    let _env = RemoteSshTestEnv::new(temp.path()).await;
    let project_root = temp.path().join("project");
    std::fs::create_dir_all(project_root.join(".pnevma/data/scrollback")).unwrap();

    let db = open_test_db().await;
    let project_id = Uuid::new_v4();
    db.upsert_project(
        &project_id.to_string(),
        "connect-ssh-test",
        project_root.to_string_lossy().as_ref(),
        None,
        None,
    )
    .await
    .unwrap();
    upsert_test_project_ssh_profile(&db, project_id, "ssh-profile-1", "Builder").await;

    let sessions = SessionSupervisor::new(project_root.join(".pnevma/data"));
    let state =
        make_state_with_project(project_id, &project_root, db.clone(), sessions.clone()).await;

    let session_id = connect_ssh("ssh-profile-1".to_string(), &state)
        .await
        .expect("connect ssh");

    let row = db
        .get_session(&project_id.to_string(), &session_id)
        .await
        .expect("load session row")
        .expect("session row should exist");
    assert_eq!(row.backend, "remote_ssh_durable");
    assert_eq!(row.r#type.as_deref(), Some("ssh"));
    assert_eq!(row.connection_id.as_deref(), Some("ssh-profile-1"));
    assert!(row.remote_session_id.is_some());
    assert!(sessions.list().await.is_empty());
}

#[tokio::test]
async fn connect_ssh_reuses_existing_live_remote_durable_session_for_same_profile() {
    let temp = tempfile::tempdir().expect("tempdir");
    let _env = RemoteSshTestEnv::new(temp.path()).await;
    let project_root = temp.path().join("project");
    std::fs::create_dir_all(project_root.join(".pnevma/data/scrollback")).unwrap();

    let db = open_test_db().await;
    let project_id = Uuid::new_v4();
    db.upsert_project(
        &project_id.to_string(),
        "connect-ssh-reuse-test",
        project_root.to_string_lossy().as_ref(),
        None,
        None,
    )
    .await
    .unwrap();
    upsert_test_project_ssh_profile(&db, project_id, "ssh-profile-1", "Builder").await;

    let sessions = SessionSupervisor::new(project_root.join(".pnevma/data"));
    let state =
        make_state_with_project(project_id, &project_root, db.clone(), sessions.clone()).await;

    let first_session_id = connect_ssh("ssh-profile-1".to_string(), &state)
        .await
        .expect("first connect ssh");
    let second_session_id = connect_ssh("ssh-profile-1".to_string(), &state)
        .await
        .expect("second connect ssh");

    assert_eq!(second_session_id, first_session_id);

    let live_rows = db
        .list_sessions(&project_id.to_string())
        .await
        .expect("list sessions")
        .into_iter()
        .filter(|row| {
            row.backend == "remote_ssh_durable"
                && row.r#type.as_deref() == Some("ssh")
                && row.connection_id.as_deref() == Some("ssh-profile-1")
                && matches!(row.status.as_str(), "running" | "waiting")
        })
        .collect::<Vec<_>>();
    assert_eq!(live_rows.len(), 1);
    assert_eq!(live_rows[0].id, first_session_id);

    let panes = db
        .list_panes(&project_id.to_string())
        .await
        .expect("list panes")
        .into_iter()
        .filter(|pane| pane.session_id.as_deref() == Some(first_session_id.as_str()))
        .collect::<Vec<_>>();
    assert_eq!(panes.len(), 1);

    let events = db
        .query_events(EventQueryFilter {
            project_id: project_id.to_string(),
            task_id: None,
            session_id: Some(first_session_id.clone()),
            event_type: Some("SessionReattached".to_string()),
            from: None,
            to: None,
            limit: Some(20),
        })
        .await
        .expect("query reattach events");
    assert!(events.iter().any(|event| {
        event
            .payload_json
            .contains("\"action\":\"ssh_connect_reuse\"")
            || event
                .payload_json
                .contains("\"action\": \"ssh_connect_reuse\"")
    }));
}

#[tokio::test]
async fn disconnect_ssh_marks_remote_durable_row_exited() {
    let temp = tempfile::tempdir().expect("tempdir");
    let _env = RemoteSshTestEnv::new(temp.path()).await;
    let project_root = temp.path().join("project");
    std::fs::create_dir_all(project_root.join(".pnevma/data/scrollback")).unwrap();

    let db = open_test_db().await;
    let project_id = Uuid::new_v4();
    db.upsert_project(
        &project_id.to_string(),
        "disconnect-ssh-test",
        project_root.to_string_lossy().as_ref(),
        None,
        None,
    )
    .await
    .unwrap();
    upsert_test_project_ssh_profile(&db, project_id, "ssh-profile-1", "Builder").await;

    let sessions = SessionSupervisor::new(project_root.join(".pnevma/data"));
    let state =
        make_state_with_project(project_id, &project_root, db.clone(), sessions.clone()).await;

    let session_id = connect_ssh("ssh-profile-1".to_string(), &state)
        .await
        .expect("connect ssh");
    disconnect_ssh("ssh-profile-1".to_string(), &state)
        .await
        .expect("disconnect ssh");

    let row = db
        .get_session(&project_id.to_string(), &session_id)
        .await
        .expect("load session row")
        .expect("session row should exist");
    assert_eq!(row.status, "complete");
    assert_eq!(row.lifecycle_state, "exited");
    assert_eq!(row.restore_status.as_deref(), Some("exited"));
    assert!(row.ended_at.is_some());
}

#[tokio::test]
async fn restore_sessions_marks_missing_remote_durable_rows_lost_with_reason() {
    let temp = tempfile::tempdir().expect("tempdir");
    let _env = RemoteSshTestEnv::new(temp.path()).await;
    let project_root = temp.path().join("project");
    std::fs::create_dir_all(project_root.join(".pnevma/data/scrollback")).unwrap();

    let db = open_test_db().await;
    let project_id = Uuid::new_v4();
    db.upsert_project(
        &project_id.to_string(),
        "restore-remote-lost-test",
        project_root.to_string_lossy().as_ref(),
        None,
        None,
    )
    .await
    .unwrap();
    upsert_test_project_ssh_profile(&db, project_id, "ssh-profile-1", "Builder").await;

    let sessions = SessionSupervisor::new(project_root.join(".pnevma/data"));
    let state =
        make_state_with_project(project_id, &project_root, db.clone(), sessions.clone()).await;

    let session_id = connect_ssh("ssh-profile-1".to_string(), &state)
        .await
        .expect("connect ssh");

    let session_file = temp
        .path()
        .join("home/.local/state/pnevma/remote/test-sessions")
        .join(format!("{session_id}.env"));
    std::fs::remove_file(&session_file).expect("remove fake remote session file");

    let rows = restore_sessions(&state).await.expect("restore sessions");
    let row = rows
        .into_iter()
        .find(|row| row.id == session_id)
        .expect("restored row");
    assert_eq!(row.status, "complete");
    assert_eq!(row.lifecycle_state, "lost");
    assert_eq!(row.restore_status.as_deref(), Some("lost"));
    assert!(row
        .last_error
        .as_deref()
        .is_some_and(|error| error.contains("missing on remote host")));

    let restore_log = db
        .list_session_restore_log(&row.id)
        .await
        .expect("list session restore log");
    assert!(restore_log.iter().any(|entry| {
        entry.action == "restore_sessions"
            && entry.outcome == "lost"
            && entry
                .error_message
                .as_deref()
                .is_some_and(|error| error.contains("missing on remote host"))
    }));
}

#[tokio::test]
async fn ensure_ssh_runtime_helper_returns_packaged_metadata() {
    let temp = tempfile::tempdir().expect("tempdir");
    let _env = RemoteSshTestEnv::new(temp.path()).await;
    let project_root = temp.path().join("project");
    std::fs::create_dir_all(project_root.join(".pnevma/data/scrollback")).unwrap();

    let db = open_test_db().await;
    let project_id = Uuid::new_v4();
    db.upsert_project(
        &project_id.to_string(),
        "ensure-helper-test",
        project_root.to_string_lossy().as_ref(),
        None,
        None,
    )
    .await
    .unwrap();
    upsert_test_project_ssh_profile(&db, project_id, "ssh-profile-1", "Builder").await;

    let sessions = SessionSupervisor::new(project_root.join(".pnevma/data"));
    let state =
        make_state_with_project(project_id, &project_root, db.clone(), sessions.clone()).await;

    let health = ensure_ssh_runtime_helper("ssh-profile-1".to_string(), &state)
        .await
        .expect("ensure helper");
    assert_eq!(health.helper_kind, "binary");
    assert_eq!(
        health.target_triple.as_deref(),
        Some("x86_64-unknown-linux-musl")
    );
    assert_eq!(health.artifact_source.as_deref(), Some("artifact_dir"));
    assert!(health.artifact_sha256.is_some());
    assert!(health.protocol_compatible);
    assert!(health.missing_dependencies.is_empty());
    assert_eq!(health.install_kind.as_deref(), Some("binary_artifact"));
}

#[tokio::test]
async fn ensure_ssh_runtime_helper_returns_packaged_darwin_metadata() {
    let temp = tempfile::tempdir().expect("tempdir");
    let _env =
        RemoteSshTestEnv::new_with_target(temp.path(), "Darwin arm64", "aarch64-apple-darwin")
            .await;
    let project_root = temp.path().join("project");
    std::fs::create_dir_all(project_root.join(".pnevma/data/scrollback")).unwrap();

    let db = open_test_db().await;
    let project_id = Uuid::new_v4();
    db.upsert_project(
        &project_id.to_string(),
        "ensure-darwin-helper-test",
        project_root.to_string_lossy().as_ref(),
        None,
        None,
    )
    .await
    .unwrap();
    upsert_test_project_ssh_profile(&db, project_id, "ssh-profile-1", "Builder").await;

    let sessions = SessionSupervisor::new(project_root.join(".pnevma/data"));
    let state =
        make_state_with_project(project_id, &project_root, db.clone(), sessions.clone()).await;

    let health = ensure_ssh_runtime_helper("ssh-profile-1".to_string(), &state)
        .await
        .expect("ensure helper");
    assert_eq!(health.helper_kind, "binary");
    assert_eq!(
        health.target_triple.as_deref(),
        Some("aarch64-apple-darwin")
    );
    assert_eq!(health.artifact_source.as_deref(), Some("artifact_dir"));
    assert!(health.artifact_sha256.is_some());
    assert!(health.protocol_compatible);
    assert!(health.missing_dependencies.is_empty());
    assert_eq!(health.install_kind.as_deref(), Some("binary_artifact"));
}

#[tokio::test]
async fn connect_ssh_emits_packaged_helper_metadata_events() {
    let temp = tempfile::tempdir().expect("tempdir");
    let _env = RemoteSshTestEnv::new(temp.path()).await;
    let project_root = temp.path().join("project");
    std::fs::create_dir_all(project_root.join(".pnevma/data/scrollback")).unwrap();

    let db = open_test_db().await;
    let project_id = Uuid::new_v4();
    db.upsert_project(
        &project_id.to_string(),
        "helper-event-test",
        project_root.to_string_lossy().as_ref(),
        None,
        None,
    )
    .await
    .unwrap();
    upsert_test_project_ssh_profile(&db, project_id, "ssh-profile-1", "Builder").await;

    let sessions = SessionSupervisor::new(project_root.join(".pnevma/data"));
    let state =
        make_state_with_project(project_id, &project_root, db.clone(), sessions.clone()).await;

    let _session_id = connect_ssh("ssh-profile-1".to_string(), &state)
        .await
        .expect("connect ssh");

    let events = db
        .query_events(EventQueryFilter {
            project_id: project_id.to_string(),
            limit: Some(20),
            ..EventQueryFilter::default()
        })
        .await
        .expect("query helper events");
    let health_payload = events
        .into_iter()
        .find(|event| event.event_type == "SessionHelperHealthChecked")
        .map(|event| serde_json::from_str::<Value>(&event.payload_json).expect("payload json"))
        .expect("helper health payload");
    assert_eq!(
        health_payload.get("target_triple").and_then(Value::as_str),
        Some("x86_64-unknown-linux-musl")
    );
    assert_eq!(
        health_payload
            .get("artifact_source")
            .and_then(Value::as_str),
        Some("artifact_dir")
    );
    assert_eq!(
        health_payload
            .get("protocol_compatible")
            .and_then(Value::as_bool),
        Some(true)
    );
    assert!(health_payload
        .get("artifact_sha256")
        .and_then(Value::as_str)
        .is_some());

    let installed_payload = db
        .query_events(EventQueryFilter {
            project_id: project_id.to_string(),
            event_type: Some("SessionHelperInstalled".to_string()),
            limit: Some(20),
            ..EventQueryFilter::default()
        })
        .await
        .expect("query helper installed events")
        .into_iter()
        .find(|event| event.event_type == "SessionHelperInstalled")
        .map(|event| serde_json::from_str::<Value>(&event.payload_json).expect("payload json"))
        .expect("helper installed payload");
    assert_eq!(
        installed_payload
            .get("install_kind")
            .and_then(Value::as_str),
        Some("binary_artifact")
    );
}
