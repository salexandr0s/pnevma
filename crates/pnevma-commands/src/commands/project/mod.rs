use super::tasks::{ensure_scope_rows_from_config, rule_row_to_view};
use super::*;
use pnevma_db::{AutomationRunRow, WorktreeRow};
use std::collections::{HashMap, HashSet};
use std::time::Instant;

mod overview;
mod sessions;
mod settings;
mod workspace;

pub use overview::*;
pub use sessions::*;
pub use settings::*;
pub use workspace::*;

const MAX_SESSION_NAME_BYTES: usize = 128;
const MAX_SESSION_COMMAND_BYTES: usize = 2048;
const MAX_SESSION_INPUT_BYTES: usize = 16 * 1024;
const MAX_PATH_INPUT_BYTES: usize = 4096;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ProjectCloseMode {
    WorkspaceClose,
    AppShutdown,
}

impl ProjectCloseMode {
    pub fn parse(value: &str) -> Result<Self, String> {
        match value {
            "workspace_close" => Ok(Self::WorkspaceClose),
            "app_shutdown" => Ok(Self::AppShutdown),
            other => Err(format!("unsupported project close mode: {other}")),
        }
    }

    pub fn as_str(self) -> &'static str {
        match self {
            Self::WorkspaceClose => "workspace_close",
            Self::AppShutdown => "app_shutdown",
        }
    }

    fn preserves_local_sessions(self) -> bool {
        matches!(self, Self::AppShutdown)
    }

    fn session_close_reason(self) -> &'static str {
        match self {
            Self::WorkspaceClose => "project_close",
            Self::AppShutdown => "app_shutdown",
        }
    }
}

fn ensure_bounded_text_field(value: &str, label: &str, max_bytes: usize) -> Result<(), String> {
    if value.trim().is_empty() {
        return Err(format!("{label} must not be empty"));
    }
    if value.len() > max_bytes {
        return Err(format!("{label} exceeds {max_bytes} byte limit"));
    }
    if value.chars().any(|c| c == '\0' || c.is_control()) {
        return Err(format!("{label} contains unsafe control characters"));
    }
    Ok(())
}

fn ensure_safe_path_input(value: &str, label: &str) -> Result<(), String> {
    if value.trim().is_empty() {
        return Err(format!("{label} must not be empty"));
    }
    if value.len() > MAX_PATH_INPUT_BYTES {
        return Err(format!("{label} exceeds {MAX_PATH_INPUT_BYTES} byte limit"));
    }
    if value.chars().any(|c| c == '\0' || c.is_control()) {
        return Err(format!("{label} contains unsafe control characters"));
    }
    Ok(())
}

fn ensure_safe_session_input(value: &str) -> Result<(), String> {
    if value.len() > MAX_SESSION_INPUT_BYTES {
        return Err(format!(
            "session input exceeds {MAX_SESSION_INPUT_BYTES} byte limit"
        ));
    }
    if value.contains('\0') {
        return Err("session input must not contain NUL bytes".to_string());
    }
    Ok(())
}

async fn abort_project_runtime(state: &AppState) {
    if let Some(runtime) = state.current_runtime.lock().await.take() {
        runtime.abort();
    }
}

use crate::platform::{process_alive, send_sigkill, send_sigterm, verify_pid_identity};

async fn terminate_helper_pid(pid: i64) {
    if pid <= 0 {
        return;
    }
    let pid = pid as libc::pid_t;
    if !verify_pid_identity(pid) {
        tracing::warn!(
            pid,
            "skipping signal: PID identity check failed (possible PID recycling)"
        );
        return;
    }
    send_sigterm(pid);
    for _ in 0..10 {
        if !process_alive(pid) {
            return;
        }
        tokio::time::sleep(std::time::Duration::from_millis(100)).await;
    }
    if verify_pid_identity(pid) {
        send_sigkill(pid);
    } else {
        tracing::warn!(
            pid,
            "skipping SIGKILL: PID identity check failed (possible PID recycling)"
        );
    }
}

async fn kill_tmux_session_for_row(project_path: &Path, session_id: &str) -> Result<(), String> {
    let name = tmux_name_from_session_id(session_id);
    let tmux_tmpdir = tmux_tmpdir_for_project(project_path);
    tokio::fs::create_dir_all(&tmux_tmpdir)
        .await
        .map_err(|e| e.to_string())?;
    let out = TokioCommand::new(pnevma_session::resolve_binary("tmux"))
        .env("TMUX_TMPDIR", &tmux_tmpdir)
        .args(["kill-session", "-t", &name])
        .output()
        .await
        .map_err(|e| e.to_string())?;
    if out.status.success() {
        return Ok(());
    }
    let stderr = String::from_utf8_lossy(&out.stderr);
    if stderr.contains("can't find session") {
        return Ok(());
    }
    Err(stderr.trim().to_string())
}

async fn terminate_project_owned_helpers(project_path: &Path) {
    let out = match TokioCommand::new("ps")
        .args(["axo", "pid=,command="])
        .output()
        .await
    {
        Ok(out) => out,
        Err(error) => {
            tracing::warn!(path = %project_path.display(), %error, "failed to inspect helper processes during project shutdown");
            return;
        }
    };
    if !out.status.success() {
        return;
    }

    let needle = project_path.to_string_lossy();
    for line in String::from_utf8_lossy(&out.stdout).lines() {
        let trimmed = line.trim();
        if trimmed.is_empty() || !trimmed.contains(needle.as_ref()) {
            continue;
        }
        if !trimmed.contains("tmux") && !trimmed.contains("script ") {
            continue;
        }
        let mut parts = trimmed.split_whitespace();
        let Some(pid_str) = parts.next() else {
            continue;
        };
        let Ok(pid) = pid_str.parse::<i64>() else {
            continue;
        };
        terminate_helper_pid(pid).await;
    }
}

async fn shutdown_project_sessions(
    db: &Db,
    sessions: &SessionSupervisor,
    project_id: Uuid,
    project_path: &Path,
    close_mode: ProjectCloseMode,
) {
    if !close_mode.preserves_local_sessions() {
        for meta in sessions.list().await {
            if !matches!(meta.status, SessionStatus::Running | SessionStatus::Waiting) {
                continue;
            }
            if let Some(pid) = meta.pid {
                terminate_helper_pid(i64::from(pid)).await;
            }
            match sessions.kill_session_backend(meta.id).await {
                Ok(_) => {
                    let _ = sessions.mark_exit(meta.id, None).await;
                }
                Err(error) => {
                    tracing::debug!(session_id = %meta.id, %error, "live session shutdown fell back to direct tmux cleanup");
                    let _ = kill_tmux_session_for_row(project_path, &meta.id.to_string()).await;
                }
            }
        }
    }

    let persisted_rows = match db.list_sessions(&project_id.to_string()).await {
        Ok(rows) => rows,
        Err(error) => {
            tracing::warn!(project_id = %project_id, %error, "failed to list persisted sessions during project shutdown");
            return;
        }
    };

    for mut row in persisted_rows {
        let is_live = matches!(row.status.as_str(), "running" | "waiting");
        if !is_live {
            continue;
        }

        if is_remote_ssh_durable_backend(&row.backend) {
            row.status = "waiting".to_string();
            row.lifecycle_state = SESSION_LIFECYCLE_DETACHED.to_string();
            row.detached_at = Some(Utc::now());
            row.last_heartbeat = Utc::now();
            row.last_error = None;
            row.restore_status = Some(SESSION_LIFECYCLE_DETACHED.to_string());
            if let Err(error) = db.upsert_session(&row).await {
                tracing::warn!(session_id = %row.id, %error, "failed to persist remote durable session row during project shutdown");
            } else if let Ok(session_id) = Uuid::parse_str(&row.id) {
                append_event(
                    db,
                    project_id,
                    None,
                    Some(session_id),
                    "session",
                    "SessionDetached",
                    json!({"backend": row.backend, "reason": close_mode.session_close_reason()}),
                )
                .await;
            }
            continue;
        }

        if close_mode.preserves_local_sessions() {
            if let Some(pid) = row.pid {
                terminate_helper_pid(pid).await;
            }
            row.status = "waiting".to_string();
            row.lifecycle_state = SESSION_LIFECYCLE_DETACHED.to_string();
            row.pid = None;
            row.last_heartbeat = Utc::now();
            row.detached_at = Some(Utc::now());
            row.ended_at = None;
            row.exit_code = None;
            row.last_error = None;
            row.restore_status = Some(SESSION_LIFECYCLE_DETACHED.to_string());
            if let Err(error) = db.upsert_session(&row).await {
                tracing::warn!(session_id = %row.id, %error, "failed to persist detached local session row during app shutdown");
            } else if let Ok(session_id) = Uuid::parse_str(&row.id) {
                append_event(
                    db,
                    project_id,
                    None,
                    Some(session_id),
                    "session",
                    "SessionDetached",
                    json!({"backend": row.backend, "reason": close_mode.session_close_reason()}),
                )
                .await;
            }
            continue;
        }

        if let Some(pid) = row.pid {
            terminate_helper_pid(pid).await;
        }

        if let Ok(session_id) = Uuid::parse_str(&row.id) {
            match sessions.kill_session_backend(session_id).await {
                Ok(_) => {
                    let _ = sessions.mark_exit(session_id, None).await;
                }
                Err(error) => {
                    tracing::debug!(session_id = %row.id, %error, "session supervisor backend cleanup fell back to direct tmux cleanup");
                    let _ = kill_tmux_session_for_row(project_path, &row.id).await;
                }
            }
        } else {
            let _ = kill_tmux_session_for_row(project_path, &row.id).await;
        }

        row.status = "complete".to_string();
        row.lifecycle_state = "exited".to_string();
        row.pid = None;
        row.last_heartbeat = Utc::now();
        row.ended_at = Some(Utc::now().to_rfc3339());
        row.last_error = None;
        if let Err(error) = db.upsert_session(&row).await {
            tracing::warn!(session_id = %row.id, %error, "failed to persist terminal session row during project shutdown");
        }
    }

    if !close_mode.preserves_local_sessions() {
        terminate_project_owned_helpers(project_path).await;

        if let Ok(rows) = db.list_sessions(&project_id.to_string()).await {
            for mut row in rows {
                if !matches!(row.status.as_str(), "running" | "waiting") {
                    continue;
                }
                if is_remote_ssh_durable_backend(&row.backend) {
                    continue;
                }
                row.status = "complete".to_string();
                row.lifecycle_state = "exited".to_string();
                row.pid = None;
                row.last_heartbeat = Utc::now();
                row.ended_at = Some(Utc::now().to_rfc3339());
                row.last_error = None;
                if let Err(error) = db.upsert_session(&row).await {
                    tracing::warn!(session_id = %row.id, %error, "failed to finalize lingering session row after helper sweep");
                }
            }
        }
    }
}

fn app_settings_view_from_config(config: &GlobalConfig) -> AppSettingsView {
    AppSettingsView {
        auto_save_workspace_on_quit: config.auto_save_workspace_on_quit,
        restore_windows_on_launch: config.restore_windows_on_launch,
        auto_update: config.auto_update,
        default_shell: config.default_shell.clone().unwrap_or_default(),
        terminal_font: config.terminal_font.clone(),
        terminal_font_size: config.terminal_font_size,
        scrollback_lines: config.scrollback_lines,
        sidebar_background_offset: config.sidebar_background_offset,
        bottom_tool_bar_auto_hide: config.bottom_tool_bar_auto_hide,
        focus_border_enabled: config.focus_border_enabled,
        focus_border_opacity: config.focus_border_opacity,
        focus_border_width: config.focus_border_width,
        focus_border_color: config
            .focus_border_color
            .clone()
            .filter(|value| !value.trim().is_empty())
            .unwrap_or_else(|| "accent".to_string()),
        telemetry_enabled: config.telemetry_opt_in,
        crash_reports: config.crash_reports_opt_in,
        keybindings: keybinding_views_from_config(config),
    }
}

async fn load_effective_global_config(state: &AppState) -> Result<GlobalConfig, String> {
    match state
        .with_project("load_effective_global_config", |ctx| {
            ctx.global_config.clone()
        })
        .await
    {
        Ok(config) => Ok(config),
        Err(_) => load_global_config().map_err(|e| e.to_string()),
    }
}

pub async fn open_project(
    path: String,
    checkout_path: Option<String>,
    client_activation_token: Option<String>,
    emitter: &Arc<dyn EventEmitter>,
    state: &AppState,
) -> Result<String, String> {
    let normalized_path = normalize_scaffold_path(&path)?;
    let path_buf = std::fs::canonicalize(&normalized_path)
        .map_err(|e| format!("failed to canonicalize project path: {e}"))?;
    if !project_is_initialized(&path_buf) {
        return Err("workspace_not_initialized".to_string());
    }
    let config_path = path_buf.join("pnevma.toml");
    let checkout_buf = if let Some(raw_checkout_path) = checkout_path.as_deref() {
        let normalized_checkout_path = normalize_scaffold_path(raw_checkout_path)?;
        if !normalized_checkout_path.exists() {
            return Err(format!(
                "checkout unavailable: {}",
                normalized_checkout_path.to_string_lossy()
            ));
        }
        let canonical_checkout = std::fs::canonicalize(&normalized_checkout_path)
            .map_err(|e| format!("checkout unavailable: {e}"))?;
        let checkout_root = TokioCommand::new("git")
            .args(["rev-parse", "--show-toplevel"])
            .current_dir(&canonical_checkout)
            .output()
            .await
            .map_err(|e| format!("failed to resolve checkout root: {e}"))?;
        if !checkout_root.status.success() {
            return Err(
                "checkout path must point to a git checkout for the selected project".to_string(),
            );
        }
        let checkout_root = PathBuf::from(String::from_utf8_lossy(&checkout_root.stdout).trim());
        let canonical_checkout_root = std::fs::canonicalize(&checkout_root)
            .map_err(|e| format!("failed to canonicalize checkout root: {e}"))?;
        if canonical_checkout_root != path_buf {
            return Err("checkout path must belong to the selected project root".to_string());
        }
        canonical_checkout
    } else {
        path_buf.clone()
    };

    // --- Workspace trust gate ---
    let config_content = std::fs::read_to_string(&config_path).map_err(|e| e.to_string())?;
    let current_fingerprint = sha256_hex(config_content.as_bytes());
    let path_str_for_trust = path_buf.to_string_lossy().to_string();
    let global_db = state.global_db().map_err(|e| e.to_string())?;
    let trust = global_db
        .is_path_trusted(&path_str_for_trust)
        .await
        .map_err(|e| e.to_string())?;
    match trust {
        Some(record) if record.fingerprint == current_fingerprint => {
            // Trusted and unchanged — proceed
        }
        Some(_) => {
            return Err("workspace_config_changed".to_string());
        }
        None => {
            return Err("workspace_not_trusted".to_string());
        }
    }

    let cfg = load_project_config(&config_path).map_err(|e| e.to_string())?;
    let global_cfg = load_global_config().map_err(|e| e.to_string())?;
    let runtime_redaction_config = project_runtime_redaction_config(&cfg);
    pnevma_redaction::validate_runtime_redaction_config(&runtime_redaction_config)
        .map_err(|e| format!("invalid redaction config: {e}"))?;

    let db = Db::open(&path_buf).await.map_err(|e| e.to_string())?;
    let path_str = path_buf.to_string_lossy().to_string();
    let existing = db
        .find_project_by_path(&path_str)
        .await
        .map_err(|e| e.to_string())?;
    let project_id = existing
        .as_ref()
        .and_then(|p| Uuid::parse_str(&p.id).ok())
        .unwrap_or_else(Uuid::new_v4);

    db.upsert_project(
        &project_id.to_string(),
        &cfg.project.name,
        &path_str,
        Some(&cfg.project.brief),
        Some(config_path.to_string_lossy().as_ref()),
    )
    .await
    .map_err(|e| e.to_string())?;

    let redaction_secrets = load_redaction_secrets(&db, project_id).await;
    let sessions = SessionSupervisor::new(path_buf.join(".pnevma/data"));
    sessions
        .set_redaction_secrets(redaction_secrets.clone())
        .await;
    let redaction_secrets = Arc::new(RwLock::new(redaction_secrets));
    let adapters = pnevma_agents::AdapterRegistry::detect().await;
    let pool = DispatchPool::new(cfg.agents.max_concurrent);
    let git = Arc::new(GitService::new(&path_buf));

    // Recover tasks stuck in Dispatching from a prior crash — revert them to Ready.
    let reverted = db
        .update_task_status_bulk(&project_id.to_string(), "Dispatching", "Ready")
        .await
        .unwrap_or(0);
    if reverted > 0 {
        tracing::info!(
            count = reverted,
            "reverted orphaned Dispatching tasks to Ready on startup"
        );
    }

    let session_rows =
        reconcile_persisted_sessions(&db, project_id, path_buf.as_path(), state).await?;
    let restore_root = path_buf.join(".pnevma/data");
    for row in session_rows {
        if row.status == "complete" || row.status == "error" {
            if is_remote_ssh_durable_backend(&row.backend) {
                record_remote_session_restore_outcome(&db, &row, "project_open").await;
            }
            continue;
        }
        if is_remote_ssh_durable_backend(&row.backend) {
            record_remote_session_restore_outcome(&db, &row, "project_open").await;
            continue;
        }
        if let Some(meta) = session_meta_from_row(&row, &restore_root) {
            let session_id = meta.id;
            append_event(
                &db,
                project_id,
                None,
                Some(session_id),
                "session",
                "SessionHealthChanged",
                json!({"status": row.status}),
            )
            .await;
            if let Err(e) = sessions.register_restored(meta).await {
                tracing::warn!(error = %e, %session_id, "failed to register restored session (limit reached)");
            }
            if row.status == "waiting" {
                match sessions.attach_existing(session_id).await {
                    Ok(()) => {
                        append_event(
                            &db,
                            project_id,
                            None,
                            Some(session_id),
                            "session",
                            "SessionReattached",
                            json!({}),
                        )
                        .await;
                    }
                    Err(err) => {
                        append_event(
                            &db,
                            project_id,
                            None,
                            Some(session_id),
                            "session",
                            "SessionReattachFailed",
                            json!({"error": err.to_string()}),
                        )
                        .await;
                    }
                }
            }
        }
    }

    ensure_default_panes(&db, project_id).await?;
    ensure_system_layout_templates(&db, project_id).await?;
    ensure_scope_rows_from_config(&db, project_id, &path_buf, &cfg, "rule").await?;
    ensure_scope_rows_from_config(&db, project_id, &path_buf, &cfg, "convention").await?;
    if cfg.retention.enabled {
        if let Err(err) = cleanup_project_data_retention_inner(
            &db,
            project_id,
            &path_buf,
            &cfg.retention,
            emitter,
            false,
        )
        .await
        {
            append_event(
                &db,
                project_id,
                None,
                None,
                "system",
                "DataRetentionCleanupFailed",
                json!({ "error": err }),
            )
            .await;
        }
    }

    let workflow_store = Arc::new(crate::automation::workflow_store::WorkflowStore::new(
        &path_buf,
    ));
    workflow_store.load().await;

    let (shutdown_tx, shutdown_rx) = tokio::sync::watch::channel(false);

    let ctx = ProjectContext {
        project_id,
        project_root_path: path_buf.clone(),
        project_path: path_buf.clone(),
        checkout_path: checkout_buf.clone(),
        config: cfg.clone(),
        global_config: global_cfg.clone(),
        db: db.clone(),
        sessions: sessions.clone(),
        redaction_secrets: Arc::clone(&redaction_secrets),
        git,
        adapters,
        pool,
        tracker: {
            if cfg.tracker.enabled {
                match initialize_tracker(&cfg.tracker, &db, project_id).await {
                    Some(tc) => Some(Arc::new(tc)),
                    None => {
                        tracing::warn!("tracker enabled but initialization failed (missing API key?), continuing without tracker");
                        None
                    }
                }
            } else {
                None
            }
        },
        workflow_store: Arc::clone(&workflow_store),
        coordinator: None,
        shutdown_tx,
    };

    restart_control_plane(state, path_buf.as_path(), &cfg, &global_cfg).await?;

    abort_project_runtime(state).await;
    if let Some(previous) = state
        .replace_current_project("open_project.replace_current", ctx)
        .await
    {
        clear_project_redaction_secrets(previous.project_id);
    }
    let current_redaction_secrets = redaction_secrets.read().await.clone();
    register_project_redaction_secrets(project_id, &current_redaction_secrets);
    pnevma_redaction::set_runtime_redaction_config(runtime_redaction_config)
        .map_err(|e| format!("invalid redaction config: {e}"))?;
    install_project_runtime(
        state,
        db.clone(),
        sessions.clone(),
        project_id,
        Arc::clone(&redaction_secrets),
        workflow_store,
        shutdown_rx,
    )
    .await;

    {
        let mut recents = state.recents.lock().await;
        recents.retain(|r| r.path != path_str);
        recents.insert(
            0,
            RecentProject {
                id: project_id.to_string(),
                name: cfg.project.name.clone(),
                path: path_str.clone(),
            },
        );
        recents.truncate(20);
    }

    if let Err(e) = global_db
        .add_recent_project(&path_str, &cfg.project.name, &project_id.to_string())
        .await
    {
        tracing::warn!("failed to persist recent project: {e}");
    }

    append_event(
        &db,
        project_id,
        None,
        None,
        "system",
        "ProjectOpened",
        json!({"path": path_str}),
    )
    .await;
    append_telemetry_event(
        &db,
        project_id,
        &global_cfg,
        "project.open",
        json!({"path": path_str}),
    )
    .await;
    emitter.emit(
        "project_opened",
        json!({
            "project_id": project_id.to_string(),
            "project_name": cfg.project.name,
            "project_path": path_str,
            "checkout_path": checkout_buf.to_string_lossy().to_string(),
            "client_activation_token": client_activation_token,
        }),
    );

    Ok(project_id.to_string())
}

pub async fn close_project(state: &AppState) -> Result<(), String> {
    close_project_with_mode(ProjectCloseMode::WorkspaceClose, state).await
}

pub async fn close_project_with_mode(
    close_mode: ProjectCloseMode,
    state: &AppState,
) -> Result<(), String> {
    let Some(ctx) = state
        .take_current_project("close_project.take_current")
        .await
    else {
        stop_control_plane(state).await;
        return Ok(());
    };
    let ProjectContext {
        project_id,
        project_root_path,
        db,
        sessions,
        coordinator,
        shutdown_tx,
        ..
    } = ctx;

    append_event(
        &db,
        project_id,
        None,
        None,
        "system",
        "ProjectClosed",
        json!({"mode": close_mode.as_str()}),
    )
    .await;

    // Signal the coordinator to shut down gracefully before aborting the runtime task.
    let _ = shutdown_tx.send(true);

    if let Some(coordinator) = coordinator {
        coordinator.shutdown_active_runs().await;
    }
    abort_project_runtime(state).await;
    shutdown_project_sessions(&db, &sessions, project_id, &project_root_path, close_mode).await;

    clear_project_redaction_secrets(project_id);
    pnevma_redaction::reset_runtime_redaction_config();
    stop_control_plane(state).await;
    Ok(())
}

fn resolve_retention_path(
    project_path: &Path,
    data_root: &Path,
    raw_path: &str,
) -> Option<PathBuf> {
    let candidate = if Path::new(raw_path).is_absolute() {
        PathBuf::from(raw_path)
    } else {
        project_path.join(raw_path)
    };
    let canonical_data = data_root
        .canonicalize()
        .unwrap_or_else(|_| data_root.to_path_buf());
    let canonical_candidate = if candidate.exists() {
        candidate.canonicalize().ok()?
    } else if let Some(parent) = candidate.parent() {
        let canonical_parent = parent.canonicalize().ok()?;
        canonical_parent.join(candidate.file_name().unwrap_or_default())
    } else {
        return None;
    };
    canonical_candidate
        .starts_with(&canonical_data)
        .then_some(canonical_candidate)
}

fn count_path_files(path: &Path) -> usize {
    if !path.exists() {
        return 0;
    }
    if path.is_file() {
        return 1;
    }
    std::fs::read_dir(path)
        .ok()
        .into_iter()
        .flat_map(|entries| entries.filter_map(Result::ok))
        .map(|entry| count_path_files(&entry.path()))
        .sum()
}

fn remove_retained_path(path: &Path, dry_run: bool) -> Result<usize, String> {
    let file_count = count_path_files(path);
    if file_count == 0 {
        return Ok(0);
    }
    if dry_run {
        return Ok(file_count);
    }
    if path.is_dir() {
        std::fs::remove_dir_all(path).map_err(|e| e.to_string())?;
    } else {
        std::fs::remove_file(path).map_err(|e| e.to_string())?;
    }
    Ok(file_count)
}

fn prune_stale_files_in_dir(
    dir: &Path,
    cutoff: DateTime<Utc>,
    dry_run: bool,
) -> Result<(usize, usize), String> {
    if !dir.exists() {
        return Ok((0, 0));
    }

    let mut entries_pruned = 0;
    let mut files_deleted = 0;

    for entry in std::fs::read_dir(dir).map_err(|e| e.to_string())? {
        let entry = entry.map_err(|e| e.to_string())?;
        let path = entry.path();
        let metadata = entry.metadata().map_err(|e| e.to_string())?;
        let modified = metadata.modified().map_err(|e| e.to_string())?;
        let modified_at: DateTime<Utc> = modified.into();
        if modified_at >= cutoff {
            continue;
        }
        let removed = remove_retained_path(&path, dry_run)?;
        if removed > 0 {
            entries_pruned += 1;
            files_deleted += removed;
        }
    }

    Ok((entries_pruned, files_deleted))
}

async fn cleanup_project_data_retention_inner(
    db: &Db,
    project_id: Uuid,
    project_path: &Path,
    retention: &pnevma_core::RetentionSection,
    emitter: &Arc<dyn EventEmitter>,
    dry_run: bool,
) -> Result<DataRetentionCleanupResponse, String> {
    let data_root = project_path.join(".pnevma").join("data");
    if !data_root.exists() {
        return Ok(DataRetentionCleanupResponse {
            dry_run,
            artifacts_pruned: 0,
            feedback_artifacts_cleared: 0,
            review_packs_pruned: 0,
            scrollback_sessions_pruned: 0,
            telemetry_exports_pruned: 0,
            files_deleted: 0,
        });
    }

    let artifact_cutoff = Utc::now() - chrono::Duration::days(retention.artifact_days);
    let review_cutoff = Utc::now() - chrono::Duration::days(retention.review_days);
    let scrollback_cutoff = Utc::now() - chrono::Duration::days(retention.scrollback_days);

    let mut response = DataRetentionCleanupResponse {
        dry_run,
        artifacts_pruned: 0,
        feedback_artifacts_cleared: 0,
        review_packs_pruned: 0,
        scrollback_sessions_pruned: 0,
        telemetry_exports_pruned: 0,
        files_deleted: 0,
    };

    for artifact in db
        .list_artifacts(&project_id.to_string())
        .await
        .map_err(|e| e.to_string())?
    {
        if artifact.created_at >= artifact_cutoff {
            continue;
        }
        if let Some(path) = resolve_retention_path(project_path, &data_root, &artifact.path) {
            response.files_deleted += remove_retained_path(&path, dry_run)?;
        }
        if !dry_run {
            db.delete_artifact(&artifact.id)
                .await
                .map_err(|e| e.to_string())?;
        }
        response.artifacts_pruned += 1;
    }

    for feedback in db
        .list_feedback(&project_id.to_string(), 10_000)
        .await
        .map_err(|e| e.to_string())?
    {
        if feedback.created_at >= artifact_cutoff {
            continue;
        }
        let Some(path_str) = feedback.artifact_path.as_deref() else {
            continue;
        };
        if let Some(path) = resolve_retention_path(project_path, &data_root, path_str) {
            response.files_deleted += remove_retained_path(&path, dry_run)?;
        }
        if !dry_run {
            db.clear_feedback_artifact_path(&feedback.id)
                .await
                .map_err(|e| e.to_string())?;
        }
        response.feedback_artifacts_cleared += 1;
    }

    for task in db
        .list_tasks(&project_id.to_string())
        .await
        .map_err(|e| e.to_string())?
    {
        if !matches!(task.status.as_str(), "Done" | "Failed") || task.updated_at >= review_cutoff {
            continue;
        }
        let Some(review) = db
            .get_review_by_task(&task.id)
            .await
            .map_err(|e| e.to_string())?
        else {
            continue;
        };

        let review_dir = resolve_retention_path(project_path, &data_root, &review.review_pack_path)
            .and_then(|path| path.parent().map(Path::to_path_buf))
            .unwrap_or_else(|| data_root.join("reviews").join(&task.id));

        response.files_deleted += remove_retained_path(&review_dir, dry_run)?;
        if !dry_run {
            db.delete_review_by_task(&task.id)
                .await
                .map_err(|e| e.to_string())?;
        }
        response.review_packs_pruned += 1;
    }

    for session in db
        .list_sessions(&project_id.to_string())
        .await
        .map_err(|e| e.to_string())?
    {
        if matches!(session.status.as_str(), "running" | "waiting")
            || session.last_heartbeat >= scrollback_cutoff
        {
            continue;
        }

        let log_path = data_root
            .join("scrollback")
            .join(format!("{}.log", session.id));
        let idx_path = data_root
            .join("scrollback")
            .join(format!("{}.idx", session.id));
        let mut deleted_any = false;

        for path in [&log_path, &idx_path] {
            let removed = remove_retained_path(path, dry_run)?;
            if removed > 0 {
                response.files_deleted += removed;
                deleted_any = true;
            }
        }

        if deleted_any {
            response.scrollback_sessions_pruned += 1;
        }
    }

    let (telemetry_entries, telemetry_files) =
        prune_stale_files_in_dir(&data_root.join("telemetry"), artifact_cutoff, dry_run)?;
    response.telemetry_exports_pruned = telemetry_entries;
    response.files_deleted += telemetry_files;

    append_event(
        db,
        project_id,
        None,
        None,
        "system",
        "DataRetentionCleanupCompleted",
        json!({
            "dry_run": response.dry_run,
            "artifacts_pruned": response.artifacts_pruned,
            "feedback_artifacts_cleared": response.feedback_artifacts_cleared,
            "review_packs_pruned": response.review_packs_pruned,
            "scrollback_sessions_pruned": response.scrollback_sessions_pruned,
            "telemetry_exports_pruned": response.telemetry_exports_pruned,
            "files_deleted": response.files_deleted,
        }),
    )
    .await;

    emitter.emit(
        "data_retention_cleaned",
        json!({
            "project_id": project_id.to_string(),
            "dry_run": response.dry_run,
            "artifacts_pruned": response.artifacts_pruned,
            "feedback_artifacts_cleared": response.feedback_artifacts_cleared,
            "review_packs_pruned": response.review_packs_pruned,
            "scrollback_sessions_pruned": response.scrollback_sessions_pruned,
            "telemetry_exports_pruned": response.telemetry_exports_pruned,
            "files_deleted": response.files_deleted,
        }),
    );

    Ok(response)
}

pub async fn cleanup_project_data(
    dry_run: bool,
    state: &AppState,
) -> Result<DataRetentionCleanupResponse, String> {
    let (db, project_id, project_path, retention) = state
        .with_project("cleanup_project_data", |ctx| {
            (
                ctx.db.clone(),
                ctx.project_id,
                ctx.project_path.clone(),
                ctx.config.retention.clone(),
            )
        })
        .await?;

    cleanup_project_data_retention_inner(
        &db,
        project_id,
        &project_path,
        &retention,
        &state.emitter,
        dry_run,
    )
    .await
}

pub async fn list_recent_projects(state: &AppState) -> Result<Vec<RecentProject>, String> {
    match state.global_db() {
        Ok(global_db) => match global_db.list_recent_projects(20).await {
            Ok(rows) => Ok(rows
                .into_iter()
                .map(|r| RecentProject {
                    id: r.project_id,
                    name: r.name,
                    path: r.path,
                })
                .collect()),
            Err(_) => Ok(state.recents.lock().await.clone()),
        },
        Err(_) => Ok(state.recents.lock().await.clone()),
    }
}

pub async fn trust_workspace(path: String, state: &AppState) -> Result<(), String> {
    let normalized_path = normalize_scaffold_path(&path)?;
    let path_buf = std::fs::canonicalize(&normalized_path)
        .map_err(|e| format!("failed to canonicalize path: {e}"))?;
    let config_path = path_buf.join("pnevma.toml");
    let content = std::fs::read_to_string(&config_path).map_err(|e| e.to_string())?;
    let fingerprint = sha256_hex(content.as_bytes());
    let canonical = path_buf.to_string_lossy().to_string();
    let global_db = state.global_db()?;
    global_db
        .trust_path(&canonical, &fingerprint)
        .await
        .map_err(|e| e.to_string())?;
    Ok(())
}

pub async fn revoke_workspace_trust(path: String, state: &AppState) -> Result<(), String> {
    let normalized_path = normalize_scaffold_path(&path)?;
    let canonical = std::fs::canonicalize(&normalized_path)
        .map_err(|e| format!("failed to canonicalize path: {e}"))?;
    let canonical_str = canonical.to_string_lossy().to_string();
    let global_db = state.global_db()?;
    global_db
        .revoke_trust(&canonical_str)
        .await
        .map_err(|e| e.to_string())?;
    Ok(())
}

pub async fn list_trusted_workspaces(state: &AppState) -> Result<Vec<TrustRecord>, String> {
    let global_db = state.global_db()?;
    global_db
        .list_trusted_paths()
        .await
        .map_err(|e| e.to_string())
}

/// Attempt to initialize a TrackerCoordinator from config settings.
/// Returns None if the API key is not available or setup fails.
async fn initialize_tracker(
    config: &pnevma_core::TrackerSection,
    db: &pnevma_db::Db,
    project_id: uuid::Uuid,
) -> Option<pnevma_tracker::poll::TrackerCoordinator> {
    let api_key_name = config.api_key_secret.as_deref()?;
    let api_key = super::secrets::resolve_secret_value_by_name(db, project_id, api_key_name)
        .await
        .ok()??;
    if api_key.is_empty() {
        return None;
    }

    let adapter: Arc<dyn pnevma_tracker::TrackerAdapter> = match config.kind {
        pnevma_core::TrackerKind::Linear => {
            Arc::new(pnevma_tracker::linear::LinearAdapter::new(api_key))
        }
    };

    let filter = pnevma_tracker::TrackerFilter {
        team_id: config.team_id.clone(),
        labels: config.labels.clone(),
        ..Default::default()
    };

    Some(pnevma_tracker::poll::TrackerCoordinator::new(
        adapter,
        filter,
        config.kind.to_string(),
    ))
}

#[cfg(test)]
mod tests;
