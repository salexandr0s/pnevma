use super::tasks::{ensure_scope_rows_from_config, rule_row_to_view};
use super::*;

const MAX_SESSION_NAME_BYTES: usize = 128;
const MAX_SESSION_COMMAND_BYTES: usize = 2048;
const MAX_SESSION_INPUT_BYTES: usize = 16 * 1024;
const MAX_PATH_INPUT_BYTES: usize = 4096;

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
    let current = state.current.lock().await;
    if let Some(ctx) = current.as_ref() {
        Ok(ctx.global_config.clone())
    } else {
        load_global_config().map_err(|e| e.to_string())
    }
}

pub async fn get_app_settings(state: &AppState) -> Result<AppSettingsView, String> {
    let config = load_effective_global_config(state).await?;
    Ok(app_settings_view_from_config(&config))
}

pub async fn set_app_settings(
    input: SetAppSettingsInput,
    state: &AppState,
) -> Result<AppSettingsView, String> {
    let mut config = load_effective_global_config(state).await?;

    let default_shell = match input.default_shell.trim() {
        "" => None,
        value => Some(value.to_string()),
    };
    let terminal_font = input.terminal_font.trim();
    if terminal_font.is_empty() {
        return Err("terminal_font must not be empty".to_string());
    }

    let focus_border_color = match input.focus_border_color.trim() {
        "" | "accent" => None,
        value => Some(value.to_string()),
    };

    config.auto_save_workspace_on_quit = input.auto_save_workspace_on_quit;
    config.restore_windows_on_launch = input.restore_windows_on_launch;
    config.auto_update = input.auto_update;
    config.default_shell = default_shell;
    config.terminal_font = terminal_font.to_string();
    config.terminal_font_size = input.terminal_font_size;
    config.scrollback_lines = input.scrollback_lines;
    config.sidebar_background_offset = input.sidebar_background_offset;
    config.focus_border_enabled = input.focus_border_enabled;
    config.focus_border_opacity = input.focus_border_opacity;
    config.focus_border_width = input.focus_border_width;
    config.focus_border_color = focus_border_color;
    config.telemetry_opt_in = input.telemetry_enabled;
    config.crash_reports_opt_in = input.crash_reports;

    save_global_config(&config).map_err(|e| e.to_string())?;

    let mut current = state.current.lock().await;
    if let Some(ctx) = current.as_mut() {
        ctx.global_config = config.clone();
    }

    Ok(app_settings_view_from_config(&config))
}

async fn install_project_runtime(
    state: &AppState,
    db: Db,
    sessions: SessionSupervisor,
    project_id: Uuid,
    redaction_secrets: Arc<RwLock<Vec<String>>>,
) {
    let session_bridge = spawn_session_bridge(
        Arc::clone(&state.emitter),
        db,
        sessions.clone(),
        project_id,
        redaction_secrets,
    );
    let health_refresh = tokio::spawn(async move {
        let mut ticker = tokio::time::interval(std::time::Duration::from_secs(30));
        loop {
            ticker.tick().await;
            sessions.refresh_health().await;
        }
    });

    *state.current_runtime.lock().await = Some(crate::state::ProjectRuntime::new(
        session_bridge,
        health_refresh,
    ));
}

pub async fn open_project(
    path: String,
    emitter: &Arc<dyn EventEmitter>,
    state: &AppState,
) -> Result<String, String> {
    let path_buf = std::fs::canonicalize(PathBuf::from(path.clone()))
        .map_err(|e| format!("failed to canonicalize project path: {e}"))?;
    let config_path = path_buf.join("pnevma.toml");

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
    let adapters = pnevma_agents::AdapterRegistry::detect();
    let pool = DispatchPool::new(cfg.agents.max_concurrent);
    let git = Arc::new(GitService::new(&path_buf));

    let session_rows = reconcile_persisted_sessions(&db, project_id, path_buf.as_path()).await?;
    let restore_root = path_buf.join(".pnevma/data");
    for row in session_rows {
        if row.status == "complete" || row.status == "error" {
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
            sessions.register_restored(meta).await;
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

    let ctx = ProjectContext {
        project_id,
        project_path: path_buf.clone(),
        config: cfg.clone(),
        global_config: global_cfg.clone(),
        db: db.clone(),
        sessions: sessions.clone(),
        redaction_secrets: Arc::clone(&redaction_secrets),
        git,
        adapters,
        pool,
    };

    restart_control_plane(state, path_buf.as_path(), &cfg, &global_cfg).await?;

    abort_project_runtime(state).await;
    let previous_project_id = {
        let current = state.current.lock().await;
        current.as_ref().map(|ctx| ctx.project_id)
    };
    if let Some(previous_project_id) = previous_project_id {
        clear_project_redaction_secrets(previous_project_id);
    }
    let current_redaction_secrets = redaction_secrets.read().await.clone();
    register_project_redaction_secrets(project_id, &current_redaction_secrets);
    {
        let mut current = state.current.lock().await;
        *current = Some(ctx);
    }
    install_project_runtime(
        state,
        db.clone(),
        sessions.clone(),
        project_id,
        Arc::clone(&redaction_secrets),
    )
    .await;

    {
        let mut recents = state.recents.lock().await;
        recents.retain(|r| r.path != path);
        recents.insert(
            0,
            RecentProject {
                id: project_id.to_string(),
                name: cfg.project.name.clone(),
                path: path.clone(),
            },
        );
        recents.truncate(20);
    }

    if let Err(e) = global_db
        .add_recent_project(&path, &cfg.project.name, &project_id.to_string())
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
        }),
    );

    Ok(project_id.to_string())
}

pub async fn close_project(state: &AppState) -> Result<(), String> {
    let (db, project_id) = {
        let current = state.current.lock().await;
        let Some(ctx) = current.as_ref() else {
            return {
                drop(current);
                stop_control_plane(state).await;
                Ok(())
            };
        };
        (ctx.db.clone(), ctx.project_id)
    };

    append_event(
        &db,
        project_id,
        None,
        None,
        "system",
        "ProjectClosed",
        json!({}),
    )
    .await;

    {
        let mut current = state.current.lock().await;
        *current = None;
    }
    clear_project_redaction_secrets(project_id);
    abort_project_runtime(state).await;
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
    let (db, project_id, project_path, retention) = {
        let current = state.current.lock().await;
        let ctx = current
            .as_ref()
            .ok_or_else(|| "no open project".to_string())?;
        (
            ctx.db.clone(),
            ctx.project_id,
            ctx.project_path.clone(),
            ctx.config.retention.clone(),
        )
    };

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
    let path_buf = std::fs::canonicalize(PathBuf::from(&path))
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
    let canonical = std::fs::canonicalize(PathBuf::from(&path))
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

fn resolve_session_command(input_command: &str, global_default_shell: Option<&str>) -> String {
    if !input_command.trim().is_empty() {
        return input_command.to_string();
    }

    global_default_shell
        .map(str::trim)
        .filter(|shell| !shell.is_empty())
        .map(str::to_string)
        .or_else(|| {
            std::env::var("SHELL").ok().and_then(|shell| {
                std::path::Path::new(&shell)
                    .file_name()
                    .and_then(|name| name.to_str())
                    .map(|name| name.to_string())
            })
        })
        .unwrap_or_else(|| "zsh".to_string())
}

pub async fn create_session(input: SessionInput, state: &AppState) -> Result<String, String> {
    let current = state.current.lock().await;
    let ctx = current
        .as_ref()
        .ok_or_else(|| "no open project".to_string())?;

    ensure_bounded_text_field(&input.name, "session name", MAX_SESSION_NAME_BYTES)?;
    ensure_safe_path_input(&input.cwd, "session cwd")?;

    let command =
        resolve_session_command(&input.command, ctx.global_config.default_shell.as_deref());
    ensure_bounded_text_field(&command, "session command", MAX_SESSION_COMMAND_BYTES)?;

    // H2: Validate command against the configured allowlist.
    let base_cmd = command.split_whitespace().next().unwrap_or("");
    let cmd_name = std::path::Path::new(base_cmd)
        .file_name()
        .and_then(|n| n.to_str())
        .unwrap_or(base_cmd);
    if !ctx
        .config
        .automation
        .allowed_commands
        .iter()
        .any(|c| c == cmd_name)
    {
        return Err(format!("command not allowed: {cmd_name}"));
    }

    let cwd = if Path::new(&input.cwd).is_relative() {
        ctx.project_path
            .join(&input.cwd)
            .to_string_lossy()
            .to_string()
    } else {
        input.cwd.clone()
    };

    // H2: Require cwd to resolve within the project directory.
    let resolved = std::fs::canonicalize(&cwd).map_err(|e| e.to_string())?;
    let project_canonical = std::fs::canonicalize(&ctx.project_path).map_err(|e| e.to_string())?;
    if !resolved.starts_with(&project_canonical) {
        return Err("session cwd must be within the project directory".to_string());
    }

    let session = ctx
        .sessions
        .spawn_shell(
            ctx.project_id,
            input.name.clone(),
            cwd.clone(),
            command.clone(),
        )
        .await
        .map_err(|e| e.to_string())?;

    let row = session_row_from_meta(&session);
    ctx.db
        .upsert_session(&row)
        .await
        .map_err(|e| e.to_string())?;

    append_event(
        &ctx.db,
        ctx.project_id,
        None,
        Some(session.id),
        "session",
        "SessionSpawned",
        json!({"name": input.name, "cwd": cwd}),
    )
    .await;

    Ok(row.id)
}

fn recovery_options_for_meta(meta: &SessionMetadata) -> Vec<RecoveryOptionView> {
    let can_interrupt = matches!(meta.status, SessionStatus::Running | SessionStatus::Waiting);
    let can_restart = true;
    let can_reattach = meta.status == SessionStatus::Waiting;
    vec![
        RecoveryOptionView {
            id: "interrupt".to_string(),
            label: "Interrupt".to_string(),
            description: "Send Ctrl+C to the session process.".to_string(),
            enabled: can_interrupt,
        },
        RecoveryOptionView {
            id: "restart".to_string(),
            label: "Restart Session".to_string(),
            description: "Restart backend process and rebind panes.".to_string(),
            enabled: can_restart,
        },
        RecoveryOptionView {
            id: "reattach".to_string(),
            label: "Reattach Backend".to_string(),
            description: "Attach to an existing waiting backend.".to_string(),
            enabled: can_reattach,
        },
    ]
}

pub async fn get_session_binding(
    session_id: String,
    state: &AppState,
) -> Result<SessionBindingView, String> {
    let current = state.current.lock().await;
    let ctx = current
        .as_ref()
        .ok_or_else(|| "no open project".to_string())?;
    let session_uuid = Uuid::parse_str(&session_id).map_err(|e| e.to_string())?;
    let Some(meta) = ctx.sessions.get(session_uuid).await else {
        return Err(format!("session not found: {session_id}"));
    };

    let is_live = matches!(meta.status, SessionStatus::Running | SessionStatus::Waiting);
    let mut env = Vec::new();
    if is_live {
        env.push(SessionEnvVarView {
            key: "PNEVMA_TMUX_TARGET".to_string(),
            value: tmux_name_from_session_id(&session_id),
        });
        env.push(SessionEnvVarView {
            key: "TMUX_TMPDIR".to_string(),
            value: ctx.sessions.tmux_tmpdir().to_string_lossy().to_string(),
        });
        env.push(SessionEnvVarView {
            key: "PNEVMA_SESSION_ID".to_string(),
            value: session_id.clone(),
        });
    }

    let recovery_options = recovery_options_for_meta(&meta);
    let cwd = meta.cwd.clone();

    Ok(SessionBindingView {
        session_id,
        mode: if is_live {
            "live_attach".to_string()
        } else {
            "archived".to_string()
        },
        cwd,
        env,
        wait_after_command: false,
        recovery_options,
    })
}

pub async fn list_sessions(state: &AppState) -> Result<Vec<SessionRow>, String> {
    let current = state.current.lock().await;
    let ctx = current
        .as_ref()
        .ok_or_else(|| "no open project".to_string())?;
    ctx.db
        .list_sessions(&ctx.project_id.to_string())
        .await
        .map_err(|e| e.to_string())
}

pub async fn restart_session(session_id: String, state: &AppState) -> Result<String, String> {
    let current = state.current.lock().await;
    let ctx = current
        .as_ref()
        .ok_or_else(|| "no open project".to_string())?;

    let sessions = ctx
        .db
        .list_sessions(&ctx.project_id.to_string())
        .await
        .map_err(|e| e.to_string())?;
    let mut prior = sessions
        .into_iter()
        .find(|row| row.id == session_id)
        .ok_or_else(|| format!("session not found: {session_id}"))?;
    let prior_session_id = Uuid::parse_str(&prior.id).ok();

    let cwd = if Path::new(&prior.cwd).is_relative() {
        ctx.project_path
            .join(&prior.cwd)
            .to_string_lossy()
            .to_string()
    } else {
        prior.cwd.clone()
    };

    let new_meta = ctx
        .sessions
        .spawn_shell(
            ctx.project_id,
            prior.name.clone(),
            cwd.clone(),
            prior.command.clone(),
        )
        .await
        .map_err(|e| e.to_string())?;

    prior.status = "complete".to_string();
    prior.pid = None;
    prior.last_heartbeat = Utc::now();
    ctx.db
        .upsert_session(&prior)
        .await
        .map_err(|e| e.to_string())?;
    if let Some(old_id) = prior_session_id {
        match ctx.sessions.kill_session_backend(old_id).await {
            Ok(_) => {
                let _ = ctx.sessions.mark_exit(old_id, None).await;
            }
            Err(err) => {
                tracing::warn!(
                    "restart_session: failed to terminate prior session {old_id}: {err}"
                );
            }
        }
    }

    let row = session_row_from_meta(&new_meta);
    ctx.db
        .upsert_session(&row)
        .await
        .map_err(|e| e.to_string())?;

    let panes = ctx
        .db
        .list_panes(&ctx.project_id.to_string())
        .await
        .map_err(|e| e.to_string())?;
    for mut pane in panes {
        if pane.session_id.as_deref() != Some(prior.id.as_str()) {
            continue;
        }
        pane.session_id = Some(row.id.clone());
        ctx.db.upsert_pane(&pane).await.map_err(|e| e.to_string())?;
    }

    append_event(
        &ctx.db,
        ctx.project_id,
        None,
        Some(new_meta.id),
        "session",
        "SessionSpawned",
        json!({"restart_of": prior.id, "cwd": cwd}),
    )
    .await;

    Ok(row.id)
}

pub async fn send_session_input(
    session_id: String,
    input: String,
    state: &AppState,
) -> Result<(), String> {
    let current = state.current.lock().await;
    let ctx = current
        .as_ref()
        .ok_or_else(|| "no open project".to_string())?;
    ensure_safe_session_input(&input)?;
    let session_id = Uuid::parse_str(&session_id).map_err(|e| e.to_string())?;
    ctx.sessions
        .send_input(session_id, &input)
        .await
        .map_err(|e| e.to_string())
}

pub async fn resize_session(
    session_id: String,
    cols: u16,
    rows: u16,
    state: &AppState,
) -> Result<(), String> {
    let current = state.current.lock().await;
    let ctx = current
        .as_ref()
        .ok_or_else(|| "no open project".to_string())?;
    let session_id = Uuid::parse_str(&session_id).map_err(|e| e.to_string())?;
    ctx.sessions
        .resize(session_id, cols, rows)
        .await
        .map_err(|e| e.to_string())
}

pub async fn get_scrollback(
    input: ScrollbackInput,
    state: &AppState,
) -> Result<ScrollbackSlice, String> {
    let current = state.current.lock().await;
    let ctx = current
        .as_ref()
        .ok_or_else(|| "no open project".to_string())?;
    let session_id = Uuid::parse_str(&input.session_id).map_err(|e| e.to_string())?;

    let limit = input.limit.unwrap_or(64 * 1024);
    match input.offset {
        Some(offset) => ctx
            .sessions
            .read_scrollback(session_id, offset, limit)
            .await
            .map_err(|e| e.to_string()),
        None => ctx
            .sessions
            .read_scrollback_tail(session_id, limit)
            .await
            .map_err(|e| e.to_string()),
    }
}

pub async fn restore_sessions(state: &AppState) -> Result<Vec<SessionRow>, String> {
    let current = state.current.lock().await;
    let ctx = current
        .as_ref()
        .ok_or_else(|| "no open project".to_string())?;
    let rows =
        reconcile_persisted_sessions(&ctx.db, ctx.project_id, ctx.project_path.as_path()).await?;
    for row in &rows {
        if row.status != "waiting" {
            continue;
        }
        if let Ok(id) = Uuid::parse_str(&row.id) {
            let _ = ctx.sessions.attach_existing(id).await;
        }
    }
    Ok(rows)
}

pub async fn reattach_session(session_id: String, state: &AppState) -> Result<(), String> {
    let current = state.current.lock().await;
    let ctx = current
        .as_ref()
        .ok_or_else(|| "no open project".to_string())?;
    let session_id = Uuid::parse_str(&session_id).map_err(|e| e.to_string())?;
    ctx.sessions
        .attach_existing(session_id)
        .await
        .map_err(|e| e.to_string())?;

    append_event(
        &ctx.db,
        ctx.project_id,
        None,
        Some(session_id),
        "session",
        "SessionReattached",
        json!({"manual": true}),
    )
    .await;

    Ok(())
}

pub async fn list_panes(state: &AppState) -> Result<Vec<PaneRow>, String> {
    let current = state.current.lock().await;
    let ctx = current
        .as_ref()
        .ok_or_else(|| "no open project".to_string())?;
    ctx.db
        .list_panes(&ctx.project_id.to_string())
        .await
        .map_err(|e| e.to_string())
}

pub async fn upsert_pane(input: PaneInput, state: &AppState) -> Result<PaneRow, String> {
    let current = state.current.lock().await;
    let ctx = current
        .as_ref()
        .ok_or_else(|| "no open project".to_string())?;

    let row = PaneRow {
        id: input.id.unwrap_or_else(|| Uuid::new_v4().to_string()),
        project_id: ctx.project_id.to_string(),
        session_id: input.session_id,
        r#type: input.r#type,
        position: input.position,
        label: input.label,
        metadata_json: input.metadata_json,
    };

    ctx.db.upsert_pane(&row).await.map_err(|e| e.to_string())?;
    Ok(row)
}

pub async fn remove_pane(pane_id: String, state: &AppState) -> Result<(), String> {
    let current = state.current.lock().await;
    let ctx = current
        .as_ref()
        .ok_or_else(|| "no open project".to_string())?;
    ctx.db
        .remove_pane(&pane_id)
        .await
        .map_err(|e| e.to_string())
}

pub async fn list_pane_layout_templates(
    state: &AppState,
) -> Result<Vec<PaneLayoutTemplateView>, String> {
    let (db, project_id) = {
        let current = state.current.lock().await;
        let ctx = current
            .as_ref()
            .ok_or_else(|| "no open project".to_string())?;
        (ctx.db.clone(), ctx.project_id)
    };
    ensure_system_layout_templates(&db, project_id).await?;
    let rows = db
        .list_pane_layout_templates(&project_id.to_string())
        .await
        .map_err(|e| e.to_string())?;
    rows.into_iter()
        .map(pane_layout_template_view_from_row)
        .collect()
}

pub async fn save_pane_layout_template(
    input: SavePaneLayoutTemplateInput,
    emitter: &Arc<dyn EventEmitter>,
    state: &AppState,
) -> Result<PaneLayoutTemplateView, String> {
    let name = normalize_layout_template_name(&input.name);
    if name.is_empty() {
        return Err("template name cannot be empty".to_string());
    }
    let system_names = system_layout_templates()
        .into_iter()
        .map(|(id, _, _)| id)
        .collect::<HashSet<_>>();
    if system_names.contains(&name) {
        return Err(format!("template name is reserved: {name}"));
    }

    let display_name = input
        .display_name
        .as_deref()
        .map(str::trim)
        .filter(|v| !v.is_empty())
        .map(ToString::to_string)
        .unwrap_or_else(|| default_layout_template_display_name(&name));

    let (db, project_id) = {
        let current = state.current.lock().await;
        let ctx = current
            .as_ref()
            .ok_or_else(|| "no open project".to_string())?;
        (ctx.db.clone(), ctx.project_id)
    };
    ensure_system_layout_templates(&db, project_id).await?;

    let panes = db
        .list_panes(&project_id.to_string())
        .await
        .map_err(|e| e.to_string())?;
    if panes.is_empty() {
        return Err("cannot save an empty pane layout".to_string());
    }
    let template_panes = panes
        .into_iter()
        .map(|pane| PaneLayoutTemplatePane {
            id: pane.id,
            session_id: pane.session_id,
            r#type: pane.r#type,
            position: pane.position,
            label: pane.label,
            metadata_json: pane.metadata_json,
        })
        .collect::<Vec<_>>();

    let existing = db
        .get_pane_layout_template(&project_id.to_string(), &name)
        .await
        .map_err(|e| e.to_string())?;
    if existing.as_ref().is_some_and(|row| row.is_system) {
        return Err(format!("cannot overwrite system template: {name}"));
    }
    let now = Utc::now();
    let (id, created_at) = existing
        .map(|row| (row.id, row.created_at))
        .unwrap_or_else(|| (Uuid::new_v4().to_string(), now));

    let row = PaneLayoutTemplateRow {
        id,
        project_id: project_id.to_string(),
        name: name.clone(),
        display_name: display_name.clone(),
        pane_graph_json: panes_to_template_json(&template_panes)?,
        is_system: false,
        created_at,
        updated_at: now,
    };
    db.upsert_pane_layout_template(&row)
        .await
        .map_err(|e| e.to_string())?;

    append_event(
        &db,
        project_id,
        None,
        None,
        "ui",
        "PaneLayoutTemplateSaved",
        json!({"name": name, "display_name": display_name, "pane_count": template_panes.len()}),
    )
    .await;
    emitter.emit(
        "project_refreshed",
        json!({"reason": "layout_template_saved", "template_name": row.name}),
    );

    pane_layout_template_view_from_row(row)
}

pub async fn apply_pane_layout_template(
    input: ApplyPaneLayoutTemplateInput,
    emitter: &Arc<dyn EventEmitter>,
    state: &AppState,
) -> Result<ApplyPaneLayoutTemplateResult, String> {
    let template_name = normalize_layout_template_name(&input.name);
    if template_name.is_empty() {
        return Err("template name cannot be empty".to_string());
    }

    let (db, project_id) = {
        let current = state.current.lock().await;
        let ctx = current
            .as_ref()
            .ok_or_else(|| "no open project".to_string())?;
        (ctx.db.clone(), ctx.project_id)
    };
    ensure_system_layout_templates(&db, project_id).await?;

    let template = db
        .get_pane_layout_template(&project_id.to_string(), &template_name)
        .await
        .map_err(|e| e.to_string())?
        .ok_or_else(|| format!("template not found: {template_name}"))?;
    let template_panes = parse_template_panes(&template.pane_graph_json)?;
    if template_panes.is_empty() {
        return Err("template contains no panes".to_string());
    }
    let mut template_ids = HashSet::new();
    for pane in &template_panes {
        if pane.id.trim().is_empty() {
            return Err(format!(
                "template {template_name} has a pane with an empty id"
            ));
        }
        if !template_ids.insert(pane.id.clone()) {
            return Err(format!(
                "template {template_name} contains duplicate pane id: {}",
                pane.id
            ));
        }
    }

    let current_panes = db
        .list_panes(&project_id.to_string())
        .await
        .map_err(|e| e.to_string())?;
    let session_rows = db
        .list_sessions(&project_id.to_string())
        .await
        .map_err(|e| e.to_string())?;
    let sessions_by_id = session_rows
        .into_iter()
        .map(|row| (row.id.clone(), row))
        .collect::<HashMap<_, _>>();
    let desired_by_id = template_panes
        .iter()
        .map(|pane| (pane.id.clone(), pane))
        .collect::<HashMap<_, _>>();

    let mut replaced_panes = Vec::new();
    let mut unsaved_replacements = Vec::new();
    for pane in &current_panes {
        let changed = desired_by_id
            .get(&pane.id)
            .map(|target| {
                pane.session_id != target.session_id
                    || pane.r#type != target.r#type
                    || pane.position != target.position
                    || pane.label != target.label
                    || pane.metadata_json != target.metadata_json
            })
            .unwrap_or(true);
        if !changed {
            continue;
        }
        replaced_panes.push(pane.id.clone());

        if pane_contains_unsaved_metadata(pane.metadata_json.as_deref()) {
            unsaved_replacements.push(UnsavedPaneReplacementView {
                pane_id: pane.id.clone(),
                pane_label: pane.label.clone(),
                pane_type: pane.r#type.clone(),
                reason: "pane metadata is marked unsaved/dirty".to_string(),
            });
            continue;
        }
        if pane.r#type != "terminal" {
            continue;
        }
        let Some(session_id) = pane.session_id.as_deref() else {
            continue;
        };
        let Some(session) = sessions_by_id.get(session_id) else {
            continue;
        };
        if session_state_may_be_unsaved(&session.status) {
            unsaved_replacements.push(UnsavedPaneReplacementView {
                pane_id: pane.id.clone(),
                pane_label: pane.label.clone(),
                pane_type: pane.r#type.clone(),
                reason: format!(
                    "bound session \"{}\" is still {}",
                    session.name, session.status
                ),
            });
        }
    }

    if !input.force && !unsaved_replacements.is_empty() {
        return Ok(ApplyPaneLayoutTemplateResult {
            applied: false,
            template_name,
            replaced_panes,
            unsaved_replacements,
        });
    }

    let existing_sessions = sessions_by_id.keys().cloned().collect::<HashSet<_>>();
    for pane in &current_panes {
        db.remove_pane(&pane.id).await.map_err(|e| e.to_string())?;
        emitter.emit(
            "pane_updated",
            json!({
                "action": "removed",
                "pane_id": pane.id,
                "template_name": template.name,
            }),
        );
    }
    for pane in &template_panes {
        let mut session_id = pane.session_id.clone();
        if session_id
            .as_ref()
            .is_some_and(|id| !existing_sessions.contains(id))
        {
            session_id = None;
        }
        let row = PaneRow {
            id: pane.id.clone(),
            project_id: project_id.to_string(),
            session_id,
            r#type: pane.r#type.clone(),
            position: pane.position.clone(),
            label: pane.label.clone(),
            metadata_json: pane.metadata_json.clone(),
        };
        db.upsert_pane(&row).await.map_err(|e| e.to_string())?;
        emitter.emit(
            "pane_updated",
            json!({
                "action": "upserted",
                "pane_id": row.id,
                "pane_type": row.r#type,
                "template_name": template.name,
            }),
        );
    }

    append_event(
        &db,
        project_id,
        None,
        None,
        "ui",
        "PaneLayoutTemplateApplied",
        json!({
            "name": template.name,
            "force": input.force,
            "pane_count": template_panes.len(),
            "replaced_panes": replaced_panes.clone(),
            "unsaved_replacements": unsaved_replacements.clone(),
        }),
    )
    .await;
    emitter.emit(
        "project_refreshed",
        json!({"reason": "layout_template_applied", "template_name": template.name}),
    );

    Ok(ApplyPaneLayoutTemplateResult {
        applied: true,
        template_name,
        replaced_panes,
        unsaved_replacements,
    })
}

pub async fn query_events(
    input: QueryEventsInput,
    state: &AppState,
) -> Result<Vec<EventRow>, String> {
    let current = state.current.lock().await;
    let ctx = current
        .as_ref()
        .ok_or_else(|| "no open project".to_string())?;

    ctx.db
        .query_events(EventQueryFilter {
            project_id: ctx.project_id.to_string(),
            task_id: input.task_id,
            session_id: input.session_id,
            event_type: input.event_type,
            from: parse_dt(input.from),
            to: parse_dt(input.to),
            limit: input.limit,
        })
        .await
        .map_err(|e| e.to_string())
}

/// Testable core of search_project — searches tasks, events, and artifacts in the DB.
/// Does not search git commits or session scrollback (those require filesystem/process access).
pub(crate) async fn search_db(
    query: &str,
    limit: usize,
    db: &Db,
    project_id: &str,
) -> Result<Vec<SearchResultView>, String> {
    let mut hits = Vec::new();

    // Use FTS5 for task search when available, falling back to in-memory scan.
    // Wrap query in double-quotes for FTS5 phrase matching; inner quotes are
    // escaped by doubling them per the FTS5 tokenizer grammar.
    let fts_query = format!("\"{}\"", query.replace('"', "\"\""));
    let fts_result: Result<Vec<TaskRow>, _> = sqlx::query_as(
        r#"SELECT t.id, t.project_id, t.title, t.goal, t.scope_json, t.dependencies_json,
                  t.acceptance_json, t.constraints_json, t.priority, t.status, t.branch,
                  t.worktree_id, t.handoff_summary, t.created_at, t.updated_at,
                  t.auto_dispatch, t.agent_profile_override, t.execution_mode,
                  t.timeout_minutes, t.max_retries, t.loop_iteration, t.loop_context_json
           FROM tasks_fts f
           JOIN tasks t ON t.rowid = f.rowid
           WHERE tasks_fts MATCH ?1 AND t.project_id = ?3
           ORDER BY rank
           LIMIT ?2"#,
    )
    .bind(&fts_query)
    .bind(limit as i64)
    .bind(project_id)
    .fetch_all(db.pool())
    .await;
    let fts_available = fts_result.is_ok();
    let fts_task_results: Vec<TaskRow> = fts_result.unwrap_or_default();

    if fts_available {
        for task in fts_task_results {
            let body = format!("{}\n{}", task.title, task.goal);
            hits.push(SearchResultView {
                id: format!("task:{}", task.id),
                source: "task".to_string(),
                title: task.title.clone(),
                snippet: summarize_match(&body, query),
                path: None,
                task_id: Some(task.id),
                session_id: None,
                timestamp: Some(task.updated_at),
            });
            if hits.len() >= limit {
                return Ok(hits);
            }
        }
    } else {
        // Fallback: in-memory scan if FTS table doesn't exist yet.
        let tasks = db.list_tasks(project_id).await.map_err(|e| e.to_string())?;
        for task in tasks {
            let body = format!(
                "{}\n{}\n{}\n{}\n{}",
                task.title, task.goal, task.scope_json, task.constraints_json, task.acceptance_json
            );
            if contains_case_insensitive(&body, query) {
                hits.push(SearchResultView {
                    id: format!("task:{}", task.id),
                    source: "task".to_string(),
                    title: task.title.clone(),
                    snippet: summarize_match(&body, query),
                    path: None,
                    task_id: Some(task.id),
                    session_id: None,
                    timestamp: Some(task.updated_at),
                });
            }
            if hits.len() >= limit {
                return Ok(hits);
            }
        }
    }

    // Use FTS5 for event search when available, falling back to in-memory scan.
    let fts_event_result: Result<Vec<EventRow>, _> = sqlx::query_as(
        r#"SELECT e.id, e.project_id, e.task_id, e.session_id, e.trace_id,
                  e.source, e.event_type, e.payload_json, e.timestamp
           FROM events_fts f
           JOIN events e ON e.rowid = f.rowid
           WHERE events_fts MATCH ?1 AND e.project_id = ?3
           ORDER BY rank
           LIMIT ?2"#,
    )
    .bind(&fts_query)
    .bind(limit as i64)
    .bind(project_id)
    .fetch_all(db.pool())
    .await;
    let fts_events_available = fts_event_result.is_ok();
    let fts_event_results: Vec<EventRow> = fts_event_result.unwrap_or_default();

    if fts_events_available {
        for event in fts_event_results {
            let body = format!(
                "{}\n{}\n{}",
                event.event_type, event.source, event.payload_json
            );
            hits.push(SearchResultView {
                id: format!("event:{}", event.id),
                source: "event".to_string(),
                title: event.event_type.clone(),
                snippet: summarize_match(&body, query),
                path: None,
                task_id: event.task_id.clone(),
                session_id: event.session_id.clone(),
                timestamp: Some(event.timestamp),
            });
            if hits.len() >= limit {
                return Ok(hits);
            }
        }
    } else {
        // Fallback: in-memory scan.
        let events = db
            .list_recent_events(project_id, 4_000)
            .await
            .map_err(|e| e.to_string())?;
        for event in events {
            let body = format!(
                "{}\n{}\n{}",
                event.event_type, event.source, event.payload_json
            );
            if contains_case_insensitive(&body, query) {
                hits.push(SearchResultView {
                    id: format!("event:{}", event.id),
                    source: "event".to_string(),
                    title: event.event_type.clone(),
                    snippet: summarize_match(&body, query),
                    path: None,
                    task_id: event.task_id.clone(),
                    session_id: event.session_id.clone(),
                    timestamp: Some(event.timestamp),
                });
            }
            if hits.len() >= limit {
                return Ok(hits);
            }
        }
    }

    let artifacts = db
        .list_artifacts(project_id)
        .await
        .map_err(|e| e.to_string())?;
    for artifact in artifacts {
        let body = format!(
            "{}\n{}\n{}",
            artifact.r#type,
            artifact.path,
            artifact.description.clone().unwrap_or_default()
        );
        if contains_case_insensitive(&body, query) {
            hits.push(SearchResultView {
                id: format!("artifact:{}", artifact.id),
                source: "artifact".to_string(),
                title: format!("{} · {}", artifact.r#type, artifact.path),
                snippet: summarize_match(&body, query),
                path: Some(artifact.path.clone()),
                task_id: artifact.task_id.clone(),
                session_id: None,
                timestamp: Some(artifact.created_at),
            });
        }
        if hits.len() >= limit {
            return Ok(hits);
        }
    }

    Ok(hits)
}

pub async fn search_project(
    input: SearchProjectInput,
    state: &AppState,
) -> Result<Vec<SearchResultView>, String> {
    let query = input.query.trim().to_string();
    if query.is_empty() {
        return Ok(Vec::new());
    }

    let (db, project_id, project_path, sessions) = {
        let current = state.current.lock().await;
        let ctx = current
            .as_ref()
            .ok_or_else(|| "no open project".to_string())?;
        (
            ctx.db.clone(),
            ctx.project_id,
            ctx.project_path.clone(),
            ctx.sessions.clone(),
        )
    };

    let limit = input.limit.unwrap_or(120).clamp(1, 500);

    // Search tasks, events, and artifacts in the DB.
    let mut hits = search_db(&query, limit, &db, &project_id.to_string()).await?;
    if hits.len() >= limit {
        return Ok(hits);
    }

    let commit_log = git_output(
        &project_path,
        &["log", "--pretty=format:%H%x1f%ct%x1f%s", "-n", "300"],
    )
    .await
    .unwrap_or_default();
    for line in commit_log.lines() {
        let mut parts = line.split('\x1f');
        let hash = parts.next().unwrap_or_default();
        let ts = parts
            .next()
            .and_then(|v| v.parse::<i64>().ok())
            .and_then(|secs| DateTime::<Utc>::from_timestamp(secs, 0));
        let subject = parts.next().unwrap_or_default();
        if hash.is_empty() || subject.is_empty() {
            continue;
        }
        if contains_case_insensitive(subject, &query) {
            hits.push(SearchResultView {
                id: format!("commit:{hash}"),
                source: "commit".to_string(),
                title: format!("commit {}", hash.chars().take(8).collect::<String>()),
                snippet: subject.to_string(),
                path: None,
                task_id: None,
                session_id: None,
                timestamp: ts,
            });
        }
        if hits.len() >= limit {
            return Ok(hits);
        }
    }

    let metas = sessions.list().await;
    for meta in metas {
        let slice = sessions
            .read_scrollback(meta.id, 0, 128 * 1024)
            .await
            .unwrap_or(ScrollbackSlice {
                session_id: meta.id,
                start_offset: 0,
                end_offset: 0,
                total_bytes: 0,
                data: String::new(),
            });
        if slice.data.is_empty() || !contains_case_insensitive(&slice.data, &query) {
            continue;
        }
        hits.push(SearchResultView {
            id: format!("scrollback:{}", meta.id),
            source: "scrollback".to_string(),
            title: format!("session {}", meta.name),
            snippet: summarize_match(&slice.data, &query),
            path: Some(meta.scrollback_path.clone()),
            task_id: None,
            session_id: Some(meta.id.to_string()),
            timestamp: Some(meta.last_heartbeat),
        });
        if hits.len() >= limit {
            return Ok(hits);
        }
    }

    Ok(hits)
}

fn normalize_relative_path(path: &Path) -> String {
    path.to_string_lossy().replace('\\', "/")
}

fn sort_file_tree_nodes(nodes: &mut [FileTreeNodeView]) {
    nodes.sort_by(|a, b| match (a.is_directory, b.is_directory) {
        (true, false) => std::cmp::Ordering::Less,
        (false, true) => std::cmp::Ordering::Greater,
        _ => a
            .name
            .to_ascii_lowercase()
            .cmp(&b.name.to_ascii_lowercase())
            .then_with(|| a.name.cmp(&b.name)),
    });
}

fn resolve_project_tree_directory(
    project_path: &Path,
    requested_path: Option<&str>,
) -> Result<(PathBuf, PathBuf), String> {
    let root_dir = std::fs::canonicalize(project_path)
        .map_err(|e| format!("failed to canonicalize project path: {e}"))?;

    let current_dir = match requested_path
        .map(str::trim)
        .filter(|value| !value.is_empty())
    {
        Some(path) => {
            let relative_path = path.trim_start_matches('/');
            ensure_safe_path_input(relative_path, "file tree path")?;
            if relative_path.is_empty() {
                return Err("invalid path".to_string());
            }

            let directory = root_dir.join(relative_path);
            if !directory.exists() {
                return Err(format!("directory not found: {path}"));
            }

            let canonical = directory.canonicalize().map_err(|e| e.to_string())?;
            if !canonical.starts_with(&root_dir) {
                return Err("path escapes project directory".to_string());
            }
            if !canonical.is_dir() {
                return Err("path is not a directory".to_string());
            }

            directory
        }
        None => root_dir.clone(),
    };

    Ok((root_dir, current_dir))
}

fn list_project_directory_entries(
    current_dir: &Path,
    root_dir: &Path,
) -> Result<Vec<FileTreeNodeView>, String> {
    let entries = std::fs::read_dir(current_dir)
        .map_err(|e| format!("failed to read {}: {e}", current_dir.display()))?;
    let mut nodes = Vec::new();

    for entry in entries {
        let Ok(entry) = entry else {
            continue;
        };
        let entry_path = entry.path();
        let Ok(relative_path) = entry_path.strip_prefix(root_dir) else {
            continue;
        };
        if relative_path.as_os_str().is_empty() {
            continue;
        }

        let name = entry.file_name().to_string_lossy().to_string();
        let path = normalize_relative_path(relative_path);
        let metadata = match std::fs::symlink_metadata(&entry_path) {
            Ok(metadata) => metadata,
            Err(_) => continue,
        };
        let file_type = metadata.file_type();

        if file_type.is_symlink() {
            let Ok(canonical_target) = entry_path.canonicalize() else {
                continue;
            };
            if !canonical_target.starts_with(root_dir) {
                continue;
            }
            let Ok(target_metadata) = std::fs::metadata(&canonical_target) else {
                continue;
            };
            if target_metadata.is_dir() {
                nodes.push(FileTreeNodeView {
                    id: path.clone(),
                    name,
                    path,
                    is_directory: true,
                    children: None,
                    size: None,
                });
            } else if target_metadata.is_file() {
                nodes.push(FileTreeNodeView {
                    id: path.clone(),
                    name,
                    path,
                    is_directory: false,
                    children: None,
                    size: i64::try_from(target_metadata.len()).ok(),
                });
            }
            continue;
        }

        if metadata.is_dir() {
            let Ok(canonical_dir) = entry_path.canonicalize() else {
                continue;
            };
            if !canonical_dir.starts_with(root_dir) {
                continue;
            }
            nodes.push(FileTreeNodeView {
                id: path.clone(),
                name,
                path,
                is_directory: true,
                children: None,
                size: None,
            });
            continue;
        }

        if metadata.is_file() {
            nodes.push(FileTreeNodeView {
                id: path.clone(),
                name,
                path,
                is_directory: false,
                children: None,
                size: i64::try_from(metadata.len()).ok(),
            });
        }
    }

    sort_file_tree_nodes(&mut nodes);
    Ok(nodes)
}

fn filter_project_file_tree(
    mut nodes: Vec<FileTreeNodeView>,
    query: &str,
) -> Vec<FileTreeNodeView> {
    if query.is_empty() {
        return nodes;
    }

    nodes.retain(|node| {
        node.name.to_ascii_lowercase().contains(query)
            || node.path.to_ascii_lowercase().contains(query)
    });
    nodes
}

pub async fn list_project_files(
    input: Option<ListProjectFilesInput>,
    state: &AppState,
) -> Result<Vec<ProjectFileView>, String> {
    let (project_path, query) = {
        let current = state.current.lock().await;
        let ctx = current
            .as_ref()
            .ok_or_else(|| "no open project".to_string())?;
        (
            ctx.project_path.clone(),
            input
                .as_ref()
                .and_then(|v| v.query.clone())
                .unwrap_or_default(),
        )
    };

    let limit = input.and_then(|v| v.limit).unwrap_or(1_000).clamp(1, 5_000);
    let mut all_paths = HashSet::new();
    let tracked = git_output(&project_path, &["ls-files"])
        .await
        .unwrap_or_default();
    for line in tracked.lines().map(str::trim).filter(|v| !v.is_empty()) {
        all_paths.insert(line.to_string());
    }
    let untracked = git_output(
        &project_path,
        &["ls-files", "--others", "--exclude-standard"],
    )
    .await
    .unwrap_or_default();
    for line in untracked.lines().map(str::trim).filter(|v| !v.is_empty()) {
        all_paths.insert(line.to_string());
    }

    let mut statuses = HashMap::<String, String>::new();
    let porcelain = git_output(&project_path, &["status", "--porcelain"])
        .await
        .unwrap_or_default();
    for line in porcelain.lines() {
        if let Some((path, status)) = parse_porcelain_status_line(line) {
            statuses.insert(path, status);
        }
    }

    let query = query.trim().to_ascii_lowercase();
    let mut files = all_paths
        .into_iter()
        .filter(|path| query.is_empty() || path.to_ascii_lowercase().contains(&query))
        .map(|path| {
            let status = statuses
                .get(&path)
                .cloned()
                .unwrap_or_else(|| "  ".to_string());
            let staged = status.chars().next().is_some_and(|c| c != ' ' && c != '?');
            let modified = status.chars().nth(1).is_some_and(|c| c != ' ' && c != '?');
            let conflicted = status.contains('U');
            let untracked = status.starts_with("??");
            ProjectFileView {
                path,
                status,
                modified,
                staged,
                conflicted,
                untracked,
            }
        })
        .collect::<Vec<_>>();
    files.sort_by(|a, b| a.path.cmp(&b.path));
    if files.len() > limit {
        files.truncate(limit);
    }
    Ok(files)
}

pub async fn list_project_file_tree(
    input: Option<ListProjectFilesInput>,
    state: &AppState,
) -> Result<Vec<FileTreeNodeView>, String> {
    let (project_path, query, limit, requested_path) = {
        let current = state.current.lock().await;
        let ctx = current
            .as_ref()
            .ok_or_else(|| "no open project".to_string())?;
        (
            ctx.project_path.clone(),
            input
                .as_ref()
                .and_then(|value| value.query.clone())
                .unwrap_or_default()
                .trim()
                .to_ascii_lowercase(),
            input.as_ref().and_then(|value| value.limit),
            input.as_ref().and_then(|value| value.path.clone()),
        )
    };

    tokio::task::spawn_blocking(move || {
        let (root_dir, current_dir) =
            resolve_project_tree_directory(&project_path, requested_path.as_deref())?;
        let mut nodes = list_project_directory_entries(&current_dir, &root_dir)?;
        nodes = filter_project_file_tree(nodes, &query);
        if let Some(limit) = limit {
            nodes.truncate(limit.clamp(1, 10_000));
        }
        Ok(nodes)
    })
    .await
    .map_err(|e| format!("failed to list file tree entries: {e}"))?
}

pub async fn open_file_target(
    input: OpenFileTargetInput,
    state: &AppState,
) -> Result<FileOpenResultView, String> {
    let project_path = {
        let current = state.current.lock().await;
        let ctx = current
            .as_ref()
            .ok_or_else(|| "no open project".to_string())?;
        ctx.project_path.clone()
    };
    let rel = input.path.trim().trim_start_matches('/');
    ensure_safe_path_input(rel, "file path")?;
    if rel.is_empty() {
        return Err("invalid path".to_string());
    }
    let abs = project_path.join(rel);
    if !abs.exists() {
        return Err(format!("file not found: {}", input.path));
    }
    let canonical = abs.canonicalize().map_err(|e| e.to_string())?;
    let canonical_project = project_path.canonicalize().map_err(|e| e.to_string())?;
    if !canonical.starts_with(&canonical_project) {
        return Err("path escapes project directory".to_string());
    }
    if !canonical.is_file() {
        return Err("path is not a file".to_string());
    }

    let editor_mode = input.mode.as_deref().unwrap_or("preview") == "editor";
    let launched_editor = if editor_mode {
        if let Ok(editor) = std::env::var("EDITOR") {
            if !editor.trim().is_empty() {
                TokioCommand::new(editor)
                    .arg(&abs)
                    .current_dir(&project_path)
                    .spawn()
                    .is_ok()
            } else {
                false
            }
        } else {
            false
        }
    } else {
        false
    };

    let raw = tokio::fs::read(&abs).await.map_err(|e| e.to_string())?;
    let raw = match String::from_utf8(raw) {
        Ok(text) => text,
        Err(_) => {
            return Ok(FileOpenResultView {
                path: rel.to_string(),
                content: "[Binary file preview unavailable]".to_string(),
                truncated: false,
                launched_editor,
            });
        }
    };
    let max_chars = 20_000usize;
    let truncated = raw.chars().count() > max_chars;
    let content = if truncated {
        raw.chars().take(max_chars).collect::<String>()
    } else {
        raw
    };

    Ok(FileOpenResultView {
        path: rel.to_string(),
        content,
        truncated,
        launched_editor,
    })
}

pub async fn list_rules(state: &AppState) -> Result<Vec<RuleView>, String> {
    let (db, project_id, project_path, config) = {
        let current = state.current.lock().await;
        let ctx = current
            .as_ref()
            .ok_or_else(|| "no open project".to_string())?;
        (
            ctx.db.clone(),
            ctx.project_id,
            ctx.project_path.clone(),
            ctx.config.clone(),
        )
    };
    ensure_scope_rows_from_config(&db, project_id, &project_path, &config, "rule").await?;
    let rows = db
        .list_rules(&project_id.to_string(), Some("rule"))
        .await
        .map_err(|e| e.to_string())?;
    let mut out = Vec::with_capacity(rows.len());
    for row in rows {
        out.push(rule_row_to_view(row, &project_path).await);
    }
    Ok(out)
}

pub async fn list_conventions(state: &AppState) -> Result<Vec<RuleView>, String> {
    let (db, project_id, project_path, config) = {
        let current = state.current.lock().await;
        let ctx = current
            .as_ref()
            .ok_or_else(|| "no open project".to_string())?;
        (
            ctx.db.clone(),
            ctx.project_id,
            ctx.project_path.clone(),
            ctx.config.clone(),
        )
    };
    ensure_scope_rows_from_config(&db, project_id, &project_path, &config, "convention").await?;
    let rows = db
        .list_rules(&project_id.to_string(), Some("convention"))
        .await
        .map_err(|e| e.to_string())?;
    let mut out = Vec::with_capacity(rows.len());
    for row in rows {
        out.push(rule_row_to_view(row, &project_path).await);
    }
    Ok(out)
}

async fn upsert_scope_item(
    input: RuleUpsertInput,
    scope: &str,
    emitter: &Arc<dyn EventEmitter>,
    state: &&AppState,
) -> Result<RuleView, String> {
    let (db, project_id, project_path) = {
        let current = state.current.lock().await;
        let ctx = current
            .as_ref()
            .ok_or_else(|| "no open project".to_string())?;
        (ctx.db.clone(), ctx.project_id, ctx.project_path.clone())
    };
    let scope = normalize_rule_scope(scope);
    let mut row = if let Some(id) = input.id.clone() {
        db.get_rule(&id)
            .await
            .map_err(|e| e.to_string())?
            .unwrap_or(RuleRow {
                id,
                project_id: project_id.to_string(),
                name: input.name.clone(),
                path: String::new(),
                scope: Some(scope.to_string()),
                active: input.active.unwrap_or(true),
            })
    } else {
        RuleRow {
            id: Uuid::new_v4().to_string(),
            project_id: project_id.to_string(),
            name: input.name.clone(),
            path: String::new(),
            scope: Some(scope.to_string()),
            active: input.active.unwrap_or(true),
        }
    };

    row.name = input.name.trim().to_string();
    row.scope = Some(scope.to_string());
    row.active = input.active.unwrap_or(row.active);

    if row.path.trim().is_empty() {
        let dir = project_path.join(scope_default_dir(scope));
        tokio::fs::create_dir_all(&dir)
            .await
            .map_err(|e| e.to_string())?;
        let mut candidate = dir.join(format!("{}.md", slugify_with_fallback(&row.name, "entry")));
        if candidate.exists() {
            candidate = dir.join(format!(
                "{}-{}.md",
                slugify_with_fallback(&row.name, "entry"),
                &row.id.chars().take(8).collect::<String>()
            ));
        }
        row.path = candidate
            .strip_prefix(&project_path)
            .unwrap_or(&candidate)
            .to_string_lossy()
            .to_string();
    }

    let absolute = project_path.join(&row.path);
    // M2: Validate that the resolved path stays within the project directory.
    if let Some(parent) = absolute.parent() {
        if parent.exists() {
            let canonical_parent = parent.canonicalize().map_err(|e| e.to_string())?;
            let project_canonical = project_path.canonicalize().map_err(|e| e.to_string())?;
            if !canonical_parent.starts_with(&project_canonical) {
                return Err("rule path escapes project directory".to_string());
            }
        }
    }
    if let Some(parent) = absolute.parent() {
        tokio::fs::create_dir_all(parent)
            .await
            .map_err(|e| e.to_string())?;
    }
    tokio::fs::write(&absolute, input.content.as_bytes())
        .await
        .map_err(|e| e.to_string())?;
    db.upsert_rule(&row).await.map_err(|e| e.to_string())?;
    append_event(
        &db,
        project_id,
        None,
        None,
        "rules",
        "RuleUpdated",
        json!({"rule_id": row.id, "scope": scope, "active": row.active}),
    )
    .await;
    emitter.emit("project_refreshed", json!({"reason": "rules_updated"}));
    Ok(rule_row_to_view(row, &project_path).await)
}

pub async fn upsert_rule(
    input: RuleUpsertInput,
    emitter: &Arc<dyn EventEmitter>,
    state: &AppState,
) -> Result<RuleView, String> {
    upsert_scope_item(input, "rule", emitter, &state).await
}

pub async fn upsert_convention(
    input: RuleUpsertInput,
    emitter: &Arc<dyn EventEmitter>,
    state: &AppState,
) -> Result<RuleView, String> {
    upsert_scope_item(input, "convention", emitter, &state).await
}

async fn toggle_scope_item(
    input: RuleToggleInput,
    expected_scope: &str,
    emitter: &Arc<dyn EventEmitter>,
    state: &&AppState,
) -> Result<RuleView, String> {
    let (db, project_id, project_path) = {
        let current = state.current.lock().await;
        let ctx = current
            .as_ref()
            .ok_or_else(|| "no open project".to_string())?;
        (ctx.db.clone(), ctx.project_id, ctx.project_path.clone())
    };
    let mut row = db
        .get_rule(&input.id)
        .await
        .map_err(|e| e.to_string())?
        .ok_or_else(|| format!("rule not found: {}", input.id))?;
    let scope = row.scope.clone().unwrap_or_else(|| "rule".to_string());
    if normalize_rule_scope(&scope) != normalize_rule_scope(expected_scope) {
        return Err(format!("entry scope mismatch: expected {expected_scope}"));
    }
    row.active = input.active;
    db.upsert_rule(&row).await.map_err(|e| e.to_string())?;
    append_event(
        &db,
        project_id,
        None,
        None,
        "rules",
        "RuleToggled",
        json!({"rule_id": row.id, "active": row.active}),
    )
    .await;
    emitter.emit("project_refreshed", json!({"reason": "rules_updated"}));
    Ok(rule_row_to_view(row, &project_path).await)
}

pub async fn toggle_rule(
    input: RuleToggleInput,
    emitter: &Arc<dyn EventEmitter>,
    state: &AppState,
) -> Result<RuleView, String> {
    toggle_scope_item(input, "rule", emitter, &state).await
}

pub async fn toggle_convention(
    input: RuleToggleInput,
    emitter: &Arc<dyn EventEmitter>,
    state: &AppState,
) -> Result<RuleView, String> {
    toggle_scope_item(input, "convention", emitter, &state).await
}

async fn delete_scope_item(
    id: String,
    expected_scope: &str,
    emitter: &Arc<dyn EventEmitter>,
    state: &&AppState,
) -> Result<(), String> {
    let (db, project_id, project_path) = {
        let current = state.current.lock().await;
        let ctx = current
            .as_ref()
            .ok_or_else(|| "no open project".to_string())?;
        (ctx.db.clone(), ctx.project_id, ctx.project_path.clone())
    };
    let row = db
        .get_rule(&id)
        .await
        .map_err(|e| e.to_string())?
        .ok_or_else(|| format!("rule not found: {id}"))?;
    let scope = row.scope.clone().unwrap_or_else(|| "rule".to_string());
    if normalize_rule_scope(&scope) != normalize_rule_scope(expected_scope) {
        return Err(format!("entry scope mismatch: expected {expected_scope}"));
    }
    let path = project_path.join(&row.path);
    // M1: Containment check — prevent deleting files outside the project.
    if let Ok(canonical) = tokio::fs::canonicalize(&path).await {
        let project_canonical = project_path.canonicalize().map_err(|e| e.to_string())?;
        if !canonical.starts_with(&project_canonical) {
            return Err("rule path escapes project directory".to_string());
        }
        let _ = tokio::fs::remove_file(canonical).await;
    }
    // If canonicalize fails, the file doesn't exist — skip silently.
    db.delete_rule(&id).await.map_err(|e| e.to_string())?;
    append_event(
        &db,
        project_id,
        None,
        None,
        "rules",
        "RuleDeleted",
        json!({"rule_id": id}),
    )
    .await;
    emitter.emit("project_refreshed", json!({"reason": "rules_updated"}));
    Ok(())
}

pub async fn delete_rule(
    id: String,
    emitter: &Arc<dyn EventEmitter>,
    state: &AppState,
) -> Result<(), String> {
    delete_scope_item(id, "rule", emitter, &state).await
}

pub async fn delete_convention(
    id: String,
    emitter: &Arc<dyn EventEmitter>,
    state: &AppState,
) -> Result<(), String> {
    delete_scope_item(id, "convention", emitter, &state).await
}

pub async fn list_rule_usage(
    input: RuleUsageInput,
    state: &AppState,
) -> Result<Vec<RuleUsageView>, String> {
    let (db, project_id) = {
        let current = state.current.lock().await;
        let ctx = current
            .as_ref()
            .ok_or_else(|| "no open project".to_string())?;
        (ctx.db.clone(), ctx.project_id)
    };
    let rows = db
        .list_context_rule_usage(
            &project_id.to_string(),
            &input.rule_id,
            input.limit.unwrap_or(100).max(1),
        )
        .await
        .map_err(|e| e.to_string())?;
    Ok(rows
        .into_iter()
        .map(|row| RuleUsageView {
            run_id: row.run_id,
            included: row.included,
            reason: row.reason,
            created_at: row.created_at,
        })
        .collect())
}

pub async fn capture_knowledge(
    input: KnowledgeCaptureInput,
    emitter: &Arc<dyn EventEmitter>,
    state: &AppState,
) -> Result<ArtifactView, String> {
    let (db, project_id, project_path, global_config) = {
        let current = state.current.lock().await;
        let ctx = current
            .as_ref()
            .ok_or_else(|| "no open project".to_string())?;
        (
            ctx.db.clone(),
            ctx.project_id,
            ctx.project_path.clone(),
            ctx.global_config.clone(),
        )
    };
    let kind = input.kind.trim().to_ascii_lowercase();
    if kind != "adr" && kind != "changelog" && kind != "convention-update" {
        return Err("kind must be one of: adr, changelog, convention-update".to_string());
    }
    // M4: Validate task_id to prevent directory traversal.
    if let Some(ref tid) = input.task_id {
        validate_path_component(tid, "task_id")?;
    }
    let artifact_id = Uuid::new_v4().to_string();
    let now = Utc::now();
    let task_folder = input
        .task_id
        .clone()
        .unwrap_or_else(|| "general".to_string());
    let dir = project_path
        .join(".pnevma")
        .join("data")
        .join("artifacts")
        .join(task_folder);
    tokio::fs::create_dir_all(&dir)
        .await
        .map_err(|e| e.to_string())?;
    let filename = format!(
        "{}-{}.md",
        slugify_with_fallback(&kind, "entry"),
        now.format("%Y%m%d-%H%M%S")
    );
    let file_path = dir.join(filename);
    let title = input
        .title
        .clone()
        .unwrap_or_else(|| format!("{} capture", kind));
    let body = format!(
        "# {title}\n\nkind: {kind}\ncreated_at: {}\n\n{}\n",
        now.to_rfc3339(),
        input.content
    );
    tokio::fs::write(&file_path, body.as_bytes())
        .await
        .map_err(|e| e.to_string())?;
    let rel = file_path
        .strip_prefix(&project_path)
        .unwrap_or(&file_path)
        .to_string_lossy()
        .to_string();
    let row = ArtifactRow {
        id: artifact_id,
        project_id: project_id.to_string(),
        task_id: input.task_id.clone(),
        r#type: kind.clone(),
        path: rel.clone(),
        description: Some(title.clone()),
        created_at: now,
    };
    db.create_artifact(&row).await.map_err(|e| e.to_string())?;
    append_event(
        &db,
        project_id,
        input
            .task_id
            .as_deref()
            .and_then(|raw| Uuid::parse_str(raw).ok()),
        None,
        "knowledge",
        "KnowledgeCaptured",
        json!({"artifact_id": row.id, "type": kind, "path": rel}),
    )
    .await;
    append_telemetry_event(
        &db,
        project_id,
        &global_config,
        "knowledge.capture",
        json!({"artifact_id": row.id, "kind": row.r#type}),
    )
    .await;
    emitter.emit(
        "knowledge_captured",
        json!({"artifact_id": row.id, "path": row.path, "type": row.r#type}),
    );
    Ok(ArtifactView {
        id: row.id,
        task_id: row.task_id,
        r#type: row.r#type,
        path: row.path,
        description: row.description,
        created_at: row.created_at,
    })
}

pub async fn list_artifacts(state: &AppState) -> Result<Vec<ArtifactView>, String> {
    let (db, project_id) = {
        let current = state.current.lock().await;
        let ctx = current
            .as_ref()
            .ok_or_else(|| "no open project".to_string())?;
        (ctx.db.clone(), ctx.project_id)
    };
    let rows = db
        .list_artifacts(&project_id.to_string())
        .await
        .map_err(|e| e.to_string())?;
    Ok(rows
        .into_iter()
        .map(|row| ArtifactView {
            id: row.id,
            task_id: row.task_id,
            r#type: row.r#type,
            path: row.path,
            description: row.description,
            created_at: row.created_at,
        })
        .collect())
}

fn keybinding_views_from_config(config: &GlobalConfig) -> Vec<KeybindingView> {
    let mut merged = default_keybindings();
    for (action, shortcut) in &config.keybindings {
        let action = action.trim();
        let shortcut = shortcut.trim();
        if !action.is_empty() && !shortcut.is_empty() && is_supported_keybinding_action(action) {
            merged.insert(action.to_string(), shortcut.to_string());
        }
    }
    let mut out = merged
        .into_iter()
        .map(|(action, shortcut)| KeybindingView { action, shortcut })
        .collect::<Vec<_>>();
    out.sort_by(|a, b| a.action.cmp(&b.action));
    out
}

pub async fn get_environment_readiness(
    input: Option<EnvironmentReadinessInput>,
    state: &AppState,
) -> Result<EnvironmentReadinessView, String> {
    let current_project_path = {
        let current = state.current.lock().await;
        current.as_ref().map(|ctx| ctx.project_path.clone())
    };
    let requested_path = match input.and_then(|value| value.path) {
        Some(path) => Some(normalize_scaffold_path(&path)?),
        None => current_project_path,
    };
    let git_available = is_git_available();
    let detected_adapters = pnevma_agents::AdapterRegistry::detect().available();
    let global_path = global_config_path();
    let global_config_exists = global_path.exists();
    let project_initialized = requested_path
        .as_deref()
        .map(project_is_initialized)
        .unwrap_or(false);

    let mut missing_steps = Vec::new();
    if !git_available {
        missing_steps.push("install_git".to_string());
    }
    if detected_adapters.is_empty() {
        missing_steps.push("install_agent_cli".to_string());
    }
    if !global_config_exists {
        missing_steps.push("initialize_global_config".to_string());
    }
    if requested_path.is_none() {
        missing_steps.push("select_project_path".to_string());
    } else if !project_initialized {
        missing_steps.push("initialize_project_scaffold".to_string());
    }

    Ok(EnvironmentReadinessView {
        git_available,
        detected_adapters,
        global_config_path: global_path.to_string_lossy().to_string(),
        global_config_exists,
        project_path: requested_path.map(|path| path.to_string_lossy().to_string()),
        project_initialized,
        missing_steps,
    })
}

pub async fn initialize_global_config(
    input: Option<InitializeGlobalConfigInput>,
    state: &AppState,
) -> Result<InitGlobalConfigResultView, String> {
    let path = global_config_path();
    let mut created = false;
    if !path.exists() {
        let mut config = GlobalConfig::default();
        if let Some(provider) = input
            .as_ref()
            .and_then(|value| value.default_provider.as_deref())
            .map(str::trim)
            .filter(|value| !value.is_empty())
        {
            config.default_provider = Some(provider.to_string());
        }
        save_global_config(&config).map_err(|e| e.to_string())?;
        created = true;
    }

    if let Ok(latest_config) = load_global_config() {
        let mut current = state.current.lock().await;
        if let Some(ctx) = current.as_mut() {
            ctx.global_config = latest_config;
        }
    }

    Ok(InitGlobalConfigResultView {
        created,
        path: path.to_string_lossy().to_string(),
    })
}

pub async fn initialize_project_scaffold(
    input: InitializeProjectScaffoldInput,
    state: &AppState,
) -> Result<InitProjectScaffoldResultView, String> {
    let root = normalize_scaffold_path(&input.path)?;
    let metadata = tokio::fs::metadata(&root)
        .await
        .map_err(|e| format!("project path is not accessible: {e}"))?;
    if !metadata.is_dir() {
        return Err("project path must be a directory".to_string());
    }

    let mut created_paths = Vec::new();
    for rel in [
        ".pnevma",
        ".pnevma/data",
        ".pnevma/rules",
        ".pnevma/conventions",
    ] {
        let path = root.join(rel);
        if !path.exists() {
            tokio::fs::create_dir_all(&path)
                .await
                .map_err(|e| e.to_string())?;
            created_paths.push(path.to_string_lossy().to_string());
        }
    }

    let global = load_global_config().unwrap_or_default();
    let default_provider = normalize_default_provider(
        input
            .default_provider
            .as_deref()
            .or(global.default_provider.as_deref()),
    );

    let config_path = root.join("pnevma.toml");
    if !config_path.exists() {
        let content = build_default_project_toml(
            &root,
            input.project_name.as_deref(),
            input.project_brief.as_deref(),
            &default_provider,
        );
        tokio::fs::write(&config_path, content.as_bytes())
            .await
            .map_err(|e| e.to_string())?;
        created_paths.push(config_path.to_string_lossy().to_string());
    }

    let rule_seed = root.join(".pnevma/rules/project-rules.md");
    if !rule_seed.exists() {
        let content = "\
# Project Rules

- Keep work scoped to the active task contract.
- Prefer deterministic checks before requesting review.
";
        tokio::fs::write(&rule_seed, content.as_bytes())
            .await
            .map_err(|e| e.to_string())?;
        created_paths.push(rule_seed.to_string_lossy().to_string());
    }

    let convention_seed = root.join(".pnevma/conventions/conventions.md");
    if !convention_seed.exists() {
        let content = "\
# Conventions

- Write concise commit messages in imperative mood.
- Capture reusable decisions in ADR knowledge artifacts.
";
        tokio::fs::write(&convention_seed, content.as_bytes())
            .await
            .map_err(|e| e.to_string())?;
        created_paths.push(convention_seed.to_string_lossy().to_string());
    }

    {
        let mut current = state.current.lock().await;
        if let Some(ctx) = current.as_mut() {
            if ctx.project_path == root {
                if let Ok(cfg) = load_project_config(&config_path) {
                    ctx.config = cfg;
                }
            }
        }
    }

    Ok(InitProjectScaffoldResultView {
        root_path: root.to_string_lossy().to_string(),
        already_initialized: created_paths.is_empty(),
        created_paths,
    })
}

pub async fn list_keybindings(state: &AppState) -> Result<Vec<KeybindingView>, String> {
    let current = state.current.lock().await;
    let ctx = current
        .as_ref()
        .ok_or_else(|| "no open project".to_string())?;
    Ok(keybinding_views_from_config(&ctx.global_config))
}

pub async fn set_keybinding(
    input: SetKeybindingInput,
    state: &AppState,
) -> Result<Vec<KeybindingView>, String> {
    let mut current = state.current.lock().await;
    let ctx = current
        .as_mut()
        .ok_or_else(|| "no open project".to_string())?;
    if input.action.trim().is_empty() || input.shortcut.trim().is_empty() {
        return Err("action and shortcut are required".to_string());
    }
    if !is_supported_keybinding_action(input.action.trim()) {
        return Err(format!(
            "unsupported keybinding action: {}",
            input.action.trim()
        ));
    }
    ctx.global_config.keybindings.insert(
        input.action.trim().to_string(),
        input.shortcut.trim().to_string(),
    );
    save_global_config(&ctx.global_config).map_err(|e| e.to_string())?;
    Ok(keybinding_views_from_config(&ctx.global_config))
}

pub async fn reset_keybindings(state: &AppState) -> Result<Vec<KeybindingView>, String> {
    let mut current = state.current.lock().await;
    let ctx = current
        .as_mut()
        .ok_or_else(|| "no open project".to_string())?;
    ctx.global_config.keybindings.clear();
    save_global_config(&ctx.global_config).map_err(|e| e.to_string())?;
    Ok(keybinding_views_from_config(&ctx.global_config))
}

pub async fn get_onboarding_state(state: &AppState) -> Result<OnboardingStateView, String> {
    let (db, project_id) = {
        let current = state.current.lock().await;
        let ctx = current
            .as_ref()
            .ok_or_else(|| "no open project".to_string())?;
        (ctx.db.clone(), ctx.project_id)
    };
    let row = db
        .get_onboarding_state(&project_id.to_string())
        .await
        .map_err(|e| e.to_string())?
        .unwrap_or(OnboardingStateRow {
            project_id: project_id.to_string(),
            step: "open_project".to_string(),
            completed: false,
            dismissed: false,
            updated_at: Utc::now(),
        });
    Ok(OnboardingStateView {
        step: row.step,
        completed: row.completed,
        dismissed: row.dismissed,
        updated_at: row.updated_at,
    })
}

pub async fn advance_onboarding_step(
    input: AdvanceOnboardingInput,
    state: &AppState,
) -> Result<OnboardingStateView, String> {
    let (db, project_id, global_config) = {
        let current = state.current.lock().await;
        let ctx = current
            .as_ref()
            .ok_or_else(|| "no open project".to_string())?;
        (ctx.db.clone(), ctx.project_id, ctx.global_config.clone())
    };
    let row = OnboardingStateRow {
        project_id: project_id.to_string(),
        step: input.step,
        completed: input.completed.unwrap_or(false),
        dismissed: input.dismissed.unwrap_or(false),
        updated_at: Utc::now(),
    };
    db.upsert_onboarding_state(&row)
        .await
        .map_err(|e| e.to_string())?;
    append_event(
        &db,
        project_id,
        None,
        None,
        "onboarding",
        "OnboardingStepAdvanced",
        json!({
            "step": row.step,
            "completed": row.completed,
            "dismissed": row.dismissed
        }),
    )
    .await;
    append_telemetry_event(
        &db,
        project_id,
        &global_config,
        "onboarding.advance",
        json!({
            "step": row.step,
            "completed": row.completed,
            "dismissed": row.dismissed
        }),
    )
    .await;
    Ok(OnboardingStateView {
        step: row.step,
        completed: row.completed,
        dismissed: row.dismissed,
        updated_at: row.updated_at,
    })
}

pub async fn reset_onboarding(state: &AppState) -> Result<OnboardingStateView, String> {
    let (db, project_id, global_config) = {
        let current = state.current.lock().await;
        let ctx = current
            .as_ref()
            .ok_or_else(|| "no open project".to_string())?;
        (ctx.db.clone(), ctx.project_id, ctx.global_config.clone())
    };
    let row = OnboardingStateRow {
        project_id: project_id.to_string(),
        step: "open_project".to_string(),
        completed: false,
        dismissed: false,
        updated_at: Utc::now(),
    };
    db.upsert_onboarding_state(&row)
        .await
        .map_err(|e| e.to_string())?;
    append_event(
        &db,
        project_id,
        None,
        None,
        "onboarding",
        "OnboardingReset",
        json!({}),
    )
    .await;
    append_telemetry_event(
        &db,
        project_id,
        &global_config,
        "onboarding.reset",
        json!({}),
    )
    .await;
    Ok(OnboardingStateView {
        step: row.step,
        completed: row.completed,
        dismissed: row.dismissed,
        updated_at: row.updated_at,
    })
}

pub async fn get_telemetry_status(state: &AppState) -> Result<TelemetryStatusView, String> {
    let (db, project_id, global_config) = {
        let current = state.current.lock().await;
        let ctx = current
            .as_ref()
            .ok_or_else(|| "no open project".to_string())?;
        (ctx.db.clone(), ctx.project_id, ctx.global_config.clone())
    };
    let queued_events = db
        .count_telemetry_events(&project_id.to_string())
        .await
        .map_err(|e| e.to_string())?;
    Ok(TelemetryStatusView {
        opted_in: global_config.telemetry_opt_in,
        queued_events,
    })
}

pub async fn set_telemetry_opt_in(
    input: SetTelemetryInput,
    state: &AppState,
) -> Result<TelemetryStatusView, String> {
    let (db, project_id, global_config) = {
        let mut current = state.current.lock().await;
        let ctx = current
            .as_mut()
            .ok_or_else(|| "no open project".to_string())?;
        ctx.global_config.telemetry_opt_in = input.opted_in;
        save_global_config(&ctx.global_config).map_err(|e| e.to_string())?;
        (ctx.db.clone(), ctx.project_id, ctx.global_config.clone())
    };
    let queued_events = db
        .count_telemetry_events(&project_id.to_string())
        .await
        .map_err(|e| e.to_string())?;
    Ok(TelemetryStatusView {
        opted_in: global_config.telemetry_opt_in,
        queued_events,
    })
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct GhosttyAuditInput {
    pub action: String,
    #[serde(default)]
    pub changed_keys: Vec<String>,
    #[serde(default)]
    pub diagnostics: Vec<String>,
    pub applied: bool,
    pub managed_path: String,
}

pub async fn audit_ghostty_settings(
    input: GhosttyAuditInput,
    state: &AppState,
) -> Result<bool, String> {
    ensure_bounded_text_field(&input.action, "action", 128)?;
    ensure_safe_path_input(&input.managed_path, "managed_path")?;

    let payload = json!({
        "action": input.action,
        "changed_keys": input.changed_keys,
        "diagnostics": input.diagnostics,
        "applied": input.applied,
        "managed_path": input.managed_path,
    });

    let maybe_project = {
        let current = state.current.lock().await;
        current.as_ref().map(|ctx| (ctx.db.clone(), ctx.project_id))
    };
    let recorded = maybe_project.is_some();

    if let Some((db, project_id)) = maybe_project {
        append_event(
            &db,
            project_id,
            None,
            None,
            "settings",
            "GhosttySettingsAudit",
            payload.clone(),
        )
        .await;
    }

    state.emitter.emit("ghostty_settings_audited", payload);

    Ok(recorded)
}

pub async fn export_telemetry_bundle(
    input: Option<ExportTelemetryInput>,
    state: &AppState,
) -> Result<String, String> {
    let (db, project_id, project_path, opted_in) = {
        let current = state.current.lock().await;
        let ctx = current
            .as_ref()
            .ok_or_else(|| "no open project".to_string())?;
        (
            ctx.db.clone(),
            ctx.project_id,
            ctx.project_path.clone(),
            ctx.global_config.telemetry_opt_in,
        )
    };
    if !opted_in {
        return Err("telemetry is disabled; opt in first".to_string());
    }
    let limit = input
        .as_ref()
        .and_then(|v| v.limit)
        .unwrap_or(10_000)
        .max(1);
    let rows = db
        .list_telemetry_events(&project_id.to_string(), limit)
        .await
        .map_err(|e| e.to_string())?;
    let payload = rows
        .into_iter()
        .map(|row| {
            json!({
                "id": row.id,
                "event_type": row.event_type,
                "payload": serde_json::from_str::<serde_json::Value>(&row.payload_json).unwrap_or_else(|_| json!({})),
                "created_at": row.created_at,
            })
        })
        .collect::<Vec<_>>();

    let data_dir = project_path.join(".pnevma").join("data");
    let target = if let Some(path) = input.and_then(|v| v.path) {
        ensure_safe_path_input(&path, "export path")?;
        let requested = PathBuf::from(&path);
        let canonical_data = data_dir.canonicalize().unwrap_or_else(|_| data_dir.clone());
        let canonical_target = if requested.exists() {
            requested.canonicalize().map_err(|e| e.to_string())?
        } else if let Some(parent) = requested.parent() {
            let canon_parent = parent.canonicalize().map_err(|e| e.to_string())?;
            canon_parent.join(requested.file_name().unwrap_or_default())
        } else {
            return Err("invalid export path".to_string());
        };
        if !canonical_target.starts_with(&canonical_data) {
            return Err("export path must be within .pnevma/data/".to_string());
        }
        canonical_target
    } else {
        data_dir.join("telemetry").join(format!(
            "telemetry-export-{}.json",
            Utc::now().format("%Y%m%d-%H%M%S")
        ))
    };
    if let Some(parent) = target.parent() {
        tokio::fs::create_dir_all(parent)
            .await
            .map_err(|e| e.to_string())?;
    }
    tokio::fs::write(
        &target,
        serde_json::to_string_pretty(&payload).map_err(|e| e.to_string())?,
    )
    .await
    .map_err(|e| e.to_string())?;
    Ok(target.to_string_lossy().to_string())
}

pub async fn clear_telemetry(state: &AppState) -> Result<(), String> {
    let (db, project_id) = {
        let current = state.current.lock().await;
        let ctx = current
            .as_ref()
            .ok_or_else(|| "no open project".to_string())?;
        (ctx.db.clone(), ctx.project_id)
    };
    db.clear_telemetry_events(&project_id.to_string())
        .await
        .map_err(|e| e.to_string())
}

pub async fn submit_feedback(
    input: FeedbackInput,
    state: &AppState,
) -> Result<FeedbackView, String> {
    let (db, project_id, project_path, global_config) = {
        let current = state.current.lock().await;
        let ctx = current
            .as_ref()
            .ok_or_else(|| "no open project".to_string())?;
        (
            ctx.db.clone(),
            ctx.project_id,
            ctx.project_path.clone(),
            ctx.global_config.clone(),
        )
    };
    if input.category.trim().is_empty() || input.body.trim().is_empty() {
        return Err("category and body are required".to_string());
    }
    let now = Utc::now();
    let id = Uuid::new_v4().to_string();
    let dir = project_path.join(".pnevma").join("data").join("feedback");
    tokio::fs::create_dir_all(&dir)
        .await
        .map_err(|e| e.to_string())?;
    let artifact_path = dir.join(format!(
        "{}-{}.md",
        slugify_with_fallback(&input.category, "entry"),
        now.format("%Y%m%d-%H%M%S")
    ));
    let artifact_content = format!(
        "# Feedback\n\ncategory: {}\ncreated_at: {}\ncontact: {}\n\n{}\n",
        input.category.trim(),
        now.to_rfc3339(),
        input.contact.clone().unwrap_or_default(),
        input.body.trim()
    );
    tokio::fs::write(&artifact_path, artifact_content)
        .await
        .map_err(|e| e.to_string())?;
    let rel = artifact_path
        .strip_prefix(&project_path)
        .unwrap_or(&artifact_path)
        .to_string_lossy()
        .to_string();
    let row = FeedbackRow {
        id: id.clone(),
        project_id: project_id.to_string(),
        category: input.category.trim().to_string(),
        body: input.body.trim().to_string(),
        contact: input.contact.clone(),
        artifact_path: Some(rel.clone()),
        created_at: now,
    };
    db.create_feedback(&row).await.map_err(|e| e.to_string())?;
    append_event(
        &db,
        project_id,
        None,
        None,
        "feedback",
        "FeedbackSubmitted",
        json!({"feedback_id": row.id, "category": row.category}),
    )
    .await;
    append_telemetry_event(
        &db,
        project_id,
        &global_config,
        "feedback.submit",
        json!({"category": row.category}),
    )
    .await;
    Ok(FeedbackView {
        id,
        category: row.category,
        body: row.body,
        contact: row.contact,
        artifact_path: row.artifact_path,
        created_at: row.created_at,
    })
}

pub async fn partner_metrics_report(
    input: Option<PartnerMetricsInput>,
    state: &AppState,
) -> Result<PartnerMetricsReportView, String> {
    let (db, project_id, onboarding_completed) = {
        let current = state.current.lock().await;
        let ctx = current
            .as_ref()
            .ok_or_else(|| "no open project".to_string())?;
        let db = ctx.db.clone();
        let onboarding_completed = db
            .get_onboarding_state(&ctx.project_id.to_string())
            .await
            .ok()
            .flatten()
            .map(|row| row.completed)
            .unwrap_or(false);
        (db, ctx.project_id, onboarding_completed)
    };
    let window_days = input.and_then(|v| v.days).unwrap_or(14).max(1);
    let from = Utc::now() - chrono::Duration::days(window_days);
    let events = db
        .query_events(EventQueryFilter {
            project_id: project_id.to_string(),
            from: Some(from),
            ..EventQueryFilter::default()
        })
        .await
        .map_err(|e| e.to_string())?;
    let sessions_started = events
        .iter()
        .filter(|e| e.event_type == "SessionSpawned")
        .count() as i64;
    let merges_completed = events
        .iter()
        .filter(|e| e.event_type == "MergeCompleted")
        .count() as i64;
    let knowledge_captures = events
        .iter()
        .filter(|e| e.event_type == "KnowledgeCaptured")
        .count() as i64;
    let tasks = db
        .list_tasks(&project_id.to_string())
        .await
        .map_err(|e| e.to_string())?;
    let tasks_created = tasks.iter().filter(|t| t.created_at >= from).count() as i64;
    let tasks_done = tasks
        .iter()
        .filter(|t| t.status == "Done" && t.updated_at >= from)
        .count() as i64;
    let feedback_rows = db
        .list_feedback(&project_id.to_string(), 10_000)
        .await
        .map_err(|e| e.to_string())?;
    let feedback_count = feedback_rows
        .iter()
        .filter(|f| f.created_at >= from)
        .count() as i64;
    let feedback_with_contact = feedback_rows
        .iter()
        .filter(|f| f.created_at >= from)
        .filter(|f| {
            f.contact
                .as_deref()
                .map(|v| !v.trim().is_empty())
                .unwrap_or(false)
        })
        .count() as i64;
    let cycle_hours = tasks
        .iter()
        .filter(|t| t.status == "Done" && t.updated_at >= from)
        .map(|t| (t.updated_at - t.created_at).num_seconds() as f64 / 3600.0)
        .collect::<Vec<_>>();
    let avg_task_cycle_hours = if cycle_hours.is_empty() {
        None
    } else {
        Some(cycle_hours.iter().sum::<f64>() / cycle_hours.len() as f64)
    };
    let telemetry_events = db
        .count_telemetry_events(&project_id.to_string())
        .await
        .unwrap_or(0);
    Ok(PartnerMetricsReportView {
        generated_at: Utc::now(),
        window_days,
        sessions_started,
        tasks_created,
        tasks_done,
        merges_completed,
        knowledge_captures,
        feedback_count,
        feedback_with_contact,
        telemetry_events,
        onboarding_completed,
        avg_task_cycle_hours,
    })
}

fn timeline_view_from_event(row: EventRow) -> TimelineEventView {
    let payload =
        serde_json::from_str::<serde_json::Value>(&row.payload_json).unwrap_or_else(|_| {
            json!({
                "raw": row.payload_json
            })
        });
    let summary = payload
        .get("summary")
        .and_then(|v| v.as_str())
        .or_else(|| payload.get("message").and_then(|v| v.as_str()))
        .or_else(|| payload.get("chunk").and_then(|v| v.as_str()))
        .map(|v| v.chars().take(160).collect::<String>())
        .unwrap_or_else(|| row.event_type.clone());
    TimelineEventView {
        timestamp: row.timestamp,
        kind: row.event_type,
        summary,
        payload,
    }
}

pub async fn get_session_timeline(
    input: SessionTimelineInput,
    state: &AppState,
) -> Result<Vec<TimelineEventView>, String> {
    let (db, project_id, sessions) = {
        let current = state.current.lock().await;
        let ctx = current
            .as_ref()
            .ok_or_else(|| "no open project".to_string())?;
        (ctx.db.clone(), ctx.project_id, ctx.sessions.clone())
    };
    let session_uuid = Uuid::parse_str(&input.session_id).map_err(|e| e.to_string())?;
    let events = db
        .query_events(EventQueryFilter {
            project_id: project_id.to_string(),
            task_id: None,
            session_id: Some(input.session_id.clone()),
            event_type: None,
            from: None,
            to: None,
            limit: input.limit.or(Some(500)),
        })
        .await
        .map_err(|e| e.to_string())?;
    let mut timeline = events
        .into_iter()
        .map(timeline_view_from_event)
        .collect::<Vec<_>>();

    if let Ok(slice) = sessions
        .read_scrollback_tail(session_uuid, 128 * 1024)
        .await
    {
        if !slice.data.trim().is_empty() {
            timeline.push(TimelineEventView {
                timestamp: Utc::now(),
                kind: "ScrollbackSnapshot".to_string(),
                summary: "latest scrollback snapshot".to_string(),
                payload: json!({
                    "session_id": input.session_id,
                    "start_offset": slice.start_offset,
                    "end_offset": slice.end_offset,
                    "total_bytes": slice.total_bytes,
                    "data": slice.data
                }),
            });
        }
    }

    Ok(timeline)
}

pub async fn get_session_recovery_options(
    session_id: String,
    state: &AppState,
) -> Result<Vec<RecoveryOptionView>, String> {
    let current = state.current.lock().await;
    let ctx = current
        .as_ref()
        .ok_or_else(|| "no open project".to_string())?;
    let session_uuid = Uuid::parse_str(&session_id).map_err(|e| e.to_string())?;
    let Some(meta) = ctx.sessions.get(session_uuid).await else {
        return Err(format!("session not found: {session_id}"));
    };
    Ok(recovery_options_for_meta(&meta))
}

pub async fn recover_session(
    input: SessionRecoveryInput,
    emitter: &Arc<dyn EventEmitter>,
    state: &AppState,
) -> Result<serde_json::Value, String> {
    let (project_id, db, sessions, project_path) = {
        let current = state.current.lock().await;
        let ctx = current
            .as_ref()
            .ok_or_else(|| "no open project".to_string())?;
        (
            ctx.project_id,
            ctx.db.clone(),
            ctx.sessions.clone(),
            ctx.project_path.clone(),
        )
    };
    let action = input.action.trim().to_ascii_lowercase();
    let session_uuid = Uuid::parse_str(&input.session_id).map_err(|e| e.to_string())?;
    match action.as_str() {
        "interrupt" => {
            sessions
                .send_input(session_uuid, "\u{3}")
                .await
                .map_err(|e| e.to_string())?;
            append_event(
                &db,
                project_id,
                None,
                Some(session_uuid),
                "session",
                "SessionRecoveryAction",
                json!({"action": "interrupt"}),
            )
            .await;
            Ok(json!({"ok": true, "action": "interrupt"}))
        }
        "restart" => {
            let new_id = restart_session(input.session_id.clone(), state).await?;
            append_event(
                &db,
                project_id,
                None,
                Some(session_uuid),
                "session",
                "SessionRecoveryAction",
                json!({"action": "restart", "new_session_id": new_id}),
            )
            .await;
            Ok(json!({"ok": true, "action": "restart", "new_session_id": new_id}))
        }
        "reattach" => {
            sessions
                .attach_existing(session_uuid)
                .await
                .map_err(|e| e.to_string())?;
            append_event(
                &db,
                project_id,
                None,
                Some(session_uuid),
                "session",
                "SessionRecoveryAction",
                json!({"action": "reattach"}),
            )
            .await;
            Ok(json!({"ok": true, "action": "reattach"}))
        }
        "checkpoint_restore" => {
            // Guard: reject restore if any sessions are running
            let all_sessions = db
                .list_sessions(&project_id.to_string())
                .await
                .map_err(|e| e.to_string())?;
            if all_sessions.iter().any(|s| s.status == "running") {
                return Err("cannot restore checkpoint while sessions are running — stop all sessions first".to_string());
            }

            let checkpoints = db
                .list_checkpoints(&project_id.to_string())
                .await
                .map_err(|e| e.to_string())?;
            let Some(last) = checkpoints.last() else {
                return Err("no checkpoints available".to_string());
            };
            let _ = git_output(&project_path, &["reset", "--hard", &last.git_ref]).await?;
            append_event(
                &db,
                project_id,
                None,
                Some(session_uuid),
                "session",
                "SessionRecoveryAction",
                json!({"action": "checkpoint_restore", "checkpoint_id": last.id, "git_ref": last.git_ref}),
            )
            .await;
            emitter.emit("project_refreshed", json!({"reason": "checkpoint_restore"}));
            Ok(
                json!({"ok": true, "action": "checkpoint_restore", "checkpoint_id": last.id, "git_ref": last.git_ref}),
            )
        }
        _ => Err(
            "unsupported action; expected interrupt|restart|reattach|checkpoint_restore"
                .to_string(),
        ),
    }
}

pub async fn project_status(state: &AppState) -> Result<ProjectStatusView, String> {
    let current = state.current.lock().await;
    let ctx = current
        .as_ref()
        .ok_or_else(|| "no open project".to_string())?;
    let sessions = ctx
        .db
        .list_sessions(&ctx.project_id.to_string())
        .await
        .map_err(|e| e.to_string())?;
    let tasks = ctx
        .db
        .list_tasks(&ctx.project_id.to_string())
        .await
        .map_err(|e| e.to_string())?;
    let worktrees = ctx
        .db
        .list_worktrees(&ctx.project_id.to_string())
        .await
        .map_err(|e| e.to_string())?;
    Ok(ProjectStatusView {
        project_id: ctx.project_id.to_string(),
        project_name: ctx.config.project.name.clone(),
        project_path: ctx.project_path.to_string_lossy().to_string(),
        sessions: sessions.len(),
        tasks: tasks.len(),
        worktrees: worktrees.len(),
    })
}

pub async fn project_summary(state: &AppState) -> Result<ProjectSummaryView, String> {
    let (db, project_id, project_path) = {
        let current = state.current.lock().await;
        let ctx = current
            .as_ref()
            .ok_or_else(|| "no open project".to_string())?;
        (ctx.db.clone(), ctx.project_id, ctx.project_path.clone())
    };

    let sessions = db
        .list_sessions(&project_id.to_string())
        .await
        .map_err(|e| e.to_string())?;
    let tasks = db
        .list_tasks(&project_id.to_string())
        .await
        .map_err(|e| e.to_string())?;
    let unread_notifications = db
        .list_notifications(&project_id.to_string(), true)
        .await
        .map_err(|e| e.to_string())?
        .len();

    db.aggregate_costs_daily(&project_id.to_string())
        .await
        .map_err(|e| e.to_string())?;
    let today = Utc::now().format("%Y-%m-%d").to_string();
    let cost_today = db
        .get_usage_daily_trend(&project_id.to_string(), 1)
        .await
        .map_err(|e| e.to_string())?
        .into_iter()
        .find(|row| row.period_date == today)
        .map(|row| row.estimated_usd)
        .unwrap_or(0.0);

    let git_branch = TokioCommand::new("git")
        .arg("rev-parse")
        .arg("--abbrev-ref")
        .arg("HEAD")
        .current_dir(&project_path)
        .output()
        .await
        .ok()
        .filter(|out| out.status.success())
        .and_then(|out| String::from_utf8(out.stdout).ok())
        .map(|branch| branch.trim().to_string())
        .filter(|branch| !branch.is_empty());

    Ok(ProjectSummaryView {
        project_id: project_id.to_string(),
        git_branch,
        active_tasks: tasks
            .iter()
            .filter(|task| !matches!(task.status.as_str(), "Done" | "Failed"))
            .count(),
        active_agents: sessions
            .iter()
            .filter(|session| {
                session.r#type.as_deref() == Some("agent") && session.status == "running"
            })
            .count(),
        cost_today,
        unread_notifications,
    })
}

pub async fn get_daily_brief(state: &AppState) -> Result<DailyBriefView, String> {
    let (db, project_id) = {
        let current = state.current.lock().await;
        let ctx = current
            .as_ref()
            .ok_or_else(|| "no open project".to_string())?;
        (ctx.db.clone(), ctx.project_id)
    };
    let tasks = db
        .list_tasks(&project_id.to_string())
        .await
        .map_err(|e| e.to_string())?;
    let recent = db
        .list_recent_events(&project_id.to_string(), 20)
        .await
        .map_err(|e| e.to_string())?;
    let ready_tasks = tasks.iter().filter(|task| task.status == "Ready").count();
    let review_tasks = tasks.iter().filter(|task| task.status == "Review").count();
    let blocked_tasks = tasks.iter().filter(|task| task.status == "Blocked").count();
    let failed_tasks = tasks.iter().filter(|task| task.status == "Failed").count();
    let mut actions = Vec::new();
    if review_tasks > 0 {
        actions.push(format!(
            "{review_tasks} task(s) waiting for review decisions"
        ));
    }
    if ready_tasks > 0 {
        actions.push(format!("{ready_tasks} task(s) ready for dispatch"));
    }
    if blocked_tasks > 0 {
        actions.push(format!("{blocked_tasks} task(s) blocked by dependencies"));
    }
    if failed_tasks > 0 {
        actions.push(format!(
            "{failed_tasks} task(s) failed and need handoff/recovery"
        ));
    }
    if actions.is_empty() {
        actions.push("No urgent actions. Continue highest-priority in-progress work.".to_string());
    }

    let recent_events = recent
        .into_iter()
        .map(timeline_view_from_event)
        .collect::<Vec<_>>();

    // Extended intelligence: active sessions
    let sessions = db
        .list_sessions(&project_id.to_string())
        .await
        .map_err(|e| e.to_string())?;
    let active_sessions = sessions.iter().filter(|s| s.status == "running").count();

    // Cost in last 24h
    let cost_last_24h_usd: f64 = sqlx::query_scalar(
        "SELECT COALESCE(SUM(c.estimated_usd), 0.0) FROM costs c JOIN tasks t ON c.task_id = t.id WHERE t.project_id = ?1 AND c.timestamp > datetime('now', '-24 hours')",
    )
    .bind(project_id.to_string())
    .fetch_one(db.pool())
    .await
    .unwrap_or(0.0);

    // Tasks completed/failed in last 24h (from events)
    let tasks_completed_last_24h: i64 = sqlx::query_scalar(
        "SELECT COUNT(*) FROM events WHERE project_id = ?1 AND event_type = 'TaskStatusChanged' AND json_extract(payload_json, '$.to') = 'Done' AND timestamp > datetime('now', '-24 hours')",
    )
    .bind(project_id.to_string())
    .fetch_one(db.pool())
    .await
    .unwrap_or(0);

    let tasks_failed_last_24h: i64 = sqlx::query_scalar(
        "SELECT COUNT(*) FROM events WHERE project_id = ?1 AND event_type = 'TaskStatusChanged' AND json_extract(payload_json, '$.to') = 'Failed' AND timestamp > datetime('now', '-24 hours')",
    )
    .bind(project_id.to_string())
    .fetch_one(db.pool())
    .await
    .unwrap_or(0);

    // Stale ready: Ready for >24h without dispatch
    let twenty_four_hours_ago = Utc::now() - chrono::Duration::hours(24);
    let stale_ready_count = tasks
        .iter()
        .filter(|t| t.status == "Ready" && t.updated_at < twenty_four_hours_ago)
        .count();

    // Longest running task (InProgress, oldest created_at)
    let longest_running_task = tasks
        .iter()
        .filter(|t| t.status == "InProgress")
        .min_by_key(|t| t.created_at)
        .map(|t| t.title.clone());

    // Top 3 tasks by cost
    #[derive(sqlx::FromRow)]
    struct TaskCostRow {
        task_id: String,
        total_cost: f64,
    }
    let top_cost_rows: Vec<TaskCostRow> = sqlx::query_as(
        "SELECT c.task_id, SUM(c.estimated_usd) as total_cost FROM costs c JOIN tasks t ON c.task_id = t.id WHERE t.project_id = ?1 AND c.task_id != '' GROUP BY c.task_id ORDER BY total_cost DESC LIMIT 3",
    )
    .bind(project_id.to_string())
    .fetch_all(db.pool())
    .await
    .unwrap_or_default();

    let mut top_cost_tasks = Vec::new();
    for cr in top_cost_rows {
        let title = tasks
            .iter()
            .find(|t| t.id == cr.task_id)
            .map(|t| t.title.clone())
            .unwrap_or_else(|| cr.task_id.clone());
        top_cost_tasks.push(TaskCostEntry {
            task_id: cr.task_id,
            title,
            cost_usd: cr.total_cost,
        });
    }

    if stale_ready_count > 0 {
        actions.push(format!(
            "{stale_ready_count} task(s) have been Ready for >24h — consider dispatching"
        ));
    }
    if let Some(ref lt) = longest_running_task {
        actions.push(format!("Longest running task: \"{lt}\" — check for stalls"));
    }

    let brief = DailyBriefView {
        generated_at: Utc::now(),
        total_tasks: tasks.len(),
        ready_tasks,
        review_tasks,
        blocked_tasks,
        failed_tasks,
        total_cost_usd: db
            .project_cost_total(&project_id.to_string())
            .await
            .unwrap_or(0.0),
        recent_events,
        recommended_actions: actions,
        active_sessions,
        cost_last_24h_usd,
        tasks_completed_last_24h: tasks_completed_last_24h as usize,
        tasks_failed_last_24h: tasks_failed_last_24h as usize,
        stale_ready_count,
        longest_running_task,
        top_cost_tasks,
    };
    append_event(
        &db,
        project_id,
        None,
        None,
        "system",
        "DailyBriefGenerated",
        json!({
            "total_tasks": brief.total_tasks,
            "ready_tasks": brief.ready_tasks,
            "review_tasks": brief.review_tasks,
            "blocked_tasks": brief.blocked_tasks,
            "failed_tasks": brief.failed_tasks
        }),
    )
    .await;
    Ok(brief)
}

fn infer_scope_paths(input: &str) -> Vec<String> {
    let mut paths = Vec::new();
    for token in input.split_whitespace() {
        let trimmed = token.trim_matches(|c: char| {
            matches!(
                c,
                ',' | '.' | ':' | ';' | '"' | '\'' | '(' | ')' | '[' | ']' | '{' | '}'
            )
        });
        let looks_like_path = trimmed.contains('/')
            || trimmed.ends_with(".rs")
            || trimmed.ends_with(".ts")
            || trimmed.ends_with(".tsx")
            || trimmed.ends_with(".js")
            || trimmed.ends_with(".json")
            || trimmed.ends_with(".toml")
            || trimmed.ends_with(".md");
        if looks_like_path && !trimmed.is_empty() && !paths.iter().any(|p| p == trimmed) {
            paths.push(trimmed.to_string());
        }
    }
    paths
}

fn normalize_priority(input: Option<&str>) -> String {
    match input.unwrap_or("P1").trim().to_ascii_uppercase().as_str() {
        "P0" => "P0".to_string(),
        "P1" => "P1".to_string(),
        "P2" => "P2".to_string(),
        _ => "P3".to_string(),
    }
}

pub(crate) fn fallback_draft(text: &str, warning: Option<String>) -> DraftTaskView {
    let title = text
        .split(['.', '\n'])
        .next()
        .map(str::trim)
        .filter(|line| !line.is_empty())
        .map(|line| {
            if line.chars().count() > 72 {
                line.chars().take(72).collect::<String>()
            } else {
                line.to_string()
            }
        })
        .unwrap_or_else(|| "Draft Task".to_string());
    let mut warnings = Vec::new();
    if let Some(message) = warning {
        warnings.push(message);
    }
    DraftTaskView {
        title,
        goal: text.to_string(),
        scope: infer_scope_paths(text),
        acceptance_criteria: vec![
            "Relevant tests pass".to_string(),
            "Manual review confirms expected behavior".to_string(),
        ],
        constraints: vec!["Keep changes scoped to requested behavior".to_string()],
        dependencies: Vec::new(),
        priority: "P1".to_string(),
        source: "fallback".to_string(),
        warnings,
    }
}

fn extract_first_json_object(raw: &str) -> Option<serde_json::Value> {
    let starts = raw
        .match_indices('{')
        .map(|(idx, _)| idx)
        .collect::<Vec<_>>();
    for start in starts {
        let mut ends = raw[start..]
            .match_indices('}')
            .map(|(idx, _)| start + idx + 1)
            .collect::<Vec<_>>();
        ends.reverse();
        for end in ends {
            if let Ok(parsed) = serde_json::from_str::<serde_json::Value>(&raw[start..end]) {
                if parsed.is_object() {
                    return Some(parsed);
                }
            }
        }
    }
    None
}

fn strings_from_array(value: Option<&serde_json::Value>) -> Vec<String> {
    value
        .and_then(|item| item.as_array())
        .map(|items| {
            items
                .iter()
                .filter_map(|item| item.as_str())
                .map(ToString::to_string)
                .filter(|item| !item.trim().is_empty())
                .collect::<Vec<_>>()
        })
        .unwrap_or_default()
}

fn parse_provider_draft(
    value: serde_json::Value,
    user_text: &str,
) -> Result<DraftTaskView, String> {
    let obj = value
        .as_object()
        .ok_or_else(|| "provider draft response must be a JSON object".to_string())?;
    let title = obj
        .get("title")
        .and_then(|v| v.as_str())
        .map(str::trim)
        .filter(|v| !v.is_empty())
        .ok_or_else(|| "provider draft missing title".to_string())?
        .to_string();
    let goal = obj
        .get("goal")
        .and_then(|v| v.as_str())
        .map(str::trim)
        .filter(|v| !v.is_empty())
        .map(ToString::to_string)
        .unwrap_or_else(|| user_text.to_string());
    let mut acceptance = strings_from_array(obj.get("acceptance_criteria"));
    if acceptance.is_empty() {
        acceptance.push("Relevant tests pass".to_string());
    }

    Ok(DraftTaskView {
        title,
        goal,
        scope: strings_from_array(obj.get("scope")),
        acceptance_criteria: acceptance,
        constraints: strings_from_array(obj.get("constraints")),
        dependencies: strings_from_array(obj.get("dependencies")),
        priority: normalize_priority(obj.get("priority").and_then(|v| v.as_str())),
        source: "provider".to_string(),
        warnings: Vec::new(),
    })
}

#[allow(clippy::too_many_arguments)]
pub(crate) async fn try_provider_task_draft(
    adapter: Arc<dyn pnevma_agents::AgentAdapter>,
    provider: &str,
    model: Option<String>,
    timeout_minutes: u64,
    env: Vec<(String, String)>,
    project_path: &Path,
    text: &str,
) -> Result<DraftTaskView, String> {
    let handle = adapter
        .spawn(AgentConfig {
            provider: provider.to_string(),
            model,
            env,
            working_dir: project_path.to_string_lossy().to_string(),
            timeout_minutes,
            auto_approve: false,
            output_format: "stream-json".to_string(),
            context_file: None,
        })
        .await
        .map_err(|e| e.to_string())?;
    let mut rx = adapter.events(&handle);
    let objective = format!(
        "Draft a software task contract from this request.\n\
Return JSON only (no markdown, no prose) with keys:\n\
title, goal, scope[], acceptance_criteria[], constraints[], dependencies[], priority.\n\
Priority must be one of P0/P1/P2/P3.\n\
User request:\n{}",
        text
    );
    adapter
        .send(
            &handle,
            TaskPayload {
                task_id: Uuid::new_v4(),
                objective,
                constraints: vec!["Return strict JSON object only".to_string()],
                project_rules: Vec::new(),
                worktree_path: project_path.to_string_lossy().to_string(),
                branch_name: "draft-only".to_string(),
                acceptance_checks: Vec::new(),
                relevant_file_paths: Vec::new(),
                prior_context_summary: None,
            },
        )
        .await
        .map_err(|e| e.to_string())?;

    let mut combined_output = String::new();
    let timeout_window = Duration::from_secs((timeout_minutes.max(1) * 60).min(45));
    loop {
        let event = timeout(timeout_window, rx.recv())
            .await
            .map_err(|_| "provider draft timed out".to_string())?
            .map_err(|e| e.to_string())?;
        match event {
            AgentEvent::OutputChunk(chunk) => {
                combined_output.push_str(&chunk);
                if combined_output.len() > 128_000 {
                    let keep_from = combined_output.len().saturating_sub(96_000);
                    combined_output = combined_output[keep_from..].to_string();
                }
            }
            AgentEvent::Complete { summary } => {
                combined_output.push('\n');
                combined_output.push_str(&summary);
                break;
            }
            AgentEvent::Error(err) => {
                return Err(format!("provider draft failed: {err}"));
            }
            AgentEvent::ToolUse { .. }
            | AgentEvent::StatusChange(_)
            | AgentEvent::UsageUpdate { .. } => {}
        }
    }

    let parsed = extract_first_json_object(&combined_output)
        .ok_or_else(|| "provider output did not contain parseable JSON object".to_string())?;
    parse_provider_draft(parsed, text)
}

pub async fn create_notification(
    input: NotificationInput,
    emitter: &Arc<dyn EventEmitter>,
    state: &AppState,
) -> Result<NotificationView, String> {
    let (db, project_id) = {
        let current = state.current.lock().await;
        let ctx = current
            .as_ref()
            .ok_or_else(|| "no open project".to_string())?;
        (ctx.db.clone(), ctx.project_id)
    };
    let secret_values = load_redaction_secrets(&db, project_id).await;
    create_notification_row(
        &db,
        emitter,
        project_id,
        input
            .task_id
            .as_deref()
            .and_then(|v| Uuid::parse_str(v).ok()),
        input
            .session_id
            .as_deref()
            .and_then(|v| Uuid::parse_str(v).ok()),
        &input.title,
        &input.body,
        input.level.as_deref(),
        "manual",
        &secret_values,
    )
    .await
}

pub async fn list_notifications(
    input: Option<NotificationListInput>,
    state: &AppState,
) -> Result<Vec<NotificationView>, String> {
    let (db, project_id) = {
        let current = state.current.lock().await;
        let ctx = current
            .as_ref()
            .ok_or_else(|| "no open project".to_string())?;
        (ctx.db.clone(), ctx.project_id)
    };
    let unread_only = input.map(|v| v.unread_only).unwrap_or(false);
    let rows = db
        .list_notifications(&project_id.to_string(), unread_only)
        .await
        .map_err(|e| e.to_string())?;
    Ok(rows
        .into_iter()
        .map(|row| NotificationView {
            id: row.id,
            task_id: row.task_id,
            session_id: row.session_id,
            title: row.title,
            body: row.body,
            level: row.level,
            unread: row.unread,
            created_at: row.created_at,
        })
        .collect())
}

pub async fn mark_notification_read(
    notification_id: String,
    emitter: &Arc<dyn EventEmitter>,
    state: &AppState,
) -> Result<(), String> {
    let (db, project_id) = {
        let current = state.current.lock().await;
        let ctx = current
            .as_ref()
            .ok_or_else(|| "no open project".to_string())?;
        (ctx.db.clone(), ctx.project_id)
    };
    db.mark_notification_read(&notification_id)
        .await
        .map_err(|e| e.to_string())?;
    append_event(
        &db,
        project_id,
        None,
        None,
        "system",
        "NotificationMarkedRead",
        json!({"notification_id": notification_id}),
    )
    .await;
    emitter.emit(
        "notification_updated",
        json!({"id": notification_id, "unread": false}),
    );
    Ok(())
}

pub async fn clear_notifications(
    emitter: &Arc<dyn EventEmitter>,
    state: &AppState,
) -> Result<(), String> {
    let (db, project_id) = {
        let current = state.current.lock().await;
        let ctx = current
            .as_ref()
            .ok_or_else(|| "no open project".to_string())?;
        (ctx.db.clone(), ctx.project_id)
    };
    db.clear_notifications(&project_id.to_string())
        .await
        .map_err(|e| e.to_string())?;
    append_event(
        &db,
        project_id,
        None,
        None,
        "system",
        "NotificationsCleared",
        json!({}),
    )
    .await;
    emitter.emit(
        "notification_cleared",
        json!({"project_id": project_id.to_string()}),
    );
    Ok(())
}

pub async fn list_registered_commands() -> Result<Vec<RegisteredCommand>, String> {
    Ok(default_registry().list())
}

pub async fn execute_registered_command(
    input: ExecuteRegisteredCommandInput,
    _emitter: &Arc<dyn EventEmitter>,
    state: &AppState,
) -> Result<serde_json::Value, String> {
    if !default_registry().contains(&input.id) {
        return Err(format!("unknown command id: {}", input.id));
    }

    let command_id = input.id.clone();
    let mut params = serde_json::Map::new();
    for (key, value) in &input.args {
        params.insert(key.clone(), json_value_from_arg(value));
    }

    if input.id == "task.new" {
        params
            .entry("scope".to_string())
            .or_insert_with(|| json!([]));
        params
            .entry("acceptance_criteria".to_string())
            .or_insert_with(|| json!(["manual review"]));
        params
            .entry("constraints".to_string())
            .or_insert_with(|| json!([]));
        params
            .entry("dependencies".to_string())
            .or_insert_with(|| json!([]));
    }

    let result = match input.id.as_str() {
        "session.reattach_active" => {
            let session_id = required_arg(&input.args, "active_session_id")?;
            reattach_session(session_id.clone(), state).await?;
            Ok(json!({ "session_id": session_id }))
        }
        "session.restart_active" => {
            let session_id = required_arg(&input.args, "active_session_id")?;
            let active_pane_id = required_arg(&input.args, "active_pane_id")?;
            let new_session_id = restart_session(session_id.clone(), state).await?;
            if let Some(active) = list_panes(state)
                .await?
                .into_iter()
                .find(|pane| pane.id == active_pane_id)
            {
                let _ = upsert_pane(
                    PaneInput {
                        id: Some(active.id.clone()),
                        session_id: Some(new_session_id.clone()),
                        r#type: active.r#type,
                        position: active.position,
                        label: active.label,
                        metadata_json: active.metadata_json,
                    },
                    state,
                )
                .await?;
            }
            Ok(json!({
                "old_session_id": session_id,
                "new_session_id": new_session_id
            }))
        }
        "pane.split_horizontal" | "pane.split_vertical" => {
            let suffix = if input.id.ends_with("horizontal") {
                ":h"
            } else {
                ":v"
            };
            let active_pane_id = optional_arg(&input.args, "active_pane_id");
            let panes = list_panes(state).await?;
            let active = active_pane_id
                .as_ref()
                .and_then(|id| panes.iter().find(|pane| &pane.id == id))
                .cloned()
                .or_else(|| panes.first().cloned())
                .ok_or_else(|| "no panes found".to_string())?;
            let new_pane = upsert_pane(
                PaneInput {
                    id: None,
                    session_id: active.session_id,
                    r#type: active.r#type,
                    position: format!("{}{}", active.id, suffix),
                    label: format!("{} Copy", active.label),
                    metadata_json: active.metadata_json,
                },
                state,
            )
            .await?;
            Ok(json!({ "pane_id": new_pane.id }))
        }
        "pane.close" => {
            let active_pane_id = required_arg(&input.args, "active_pane_id")?;
            let panes = list_panes(state).await?;
            let active = panes
                .into_iter()
                .find(|pane| pane.id == active_pane_id)
                .ok_or_else(|| format!("pane not found: {active_pane_id}"))?;
            remove_pane(active.id.clone(), state).await?;
            Ok(json!({ "closed": true, "pane_id": active.id }))
        }
        "pane.open_review"
        | "pane.open_notifications"
        | "pane.open_merge_queue"
        | "pane.open_replay"
        | "pane.open_daily_brief"
        | "pane.open_search"
        | "pane.open_diff"
        | "pane.open_file_browser"
        | "pane.open_rules_manager"
        | "pane.open_settings" => {
            let active_pane_id = optional_arg(&input.args, "active_pane_id");
            let position = active_pane_id
                .map(|id| format!("after:{id}"))
                .unwrap_or_else(|| "after:root".to_string());
            let (pane_type, label) = match input.id.as_str() {
                "pane.open_review" => ("review", "Review"),
                "pane.open_notifications" => ("notifications", "Notifications"),
                "pane.open_merge_queue" => ("merge_queue", "Merge Queue"),
                "pane.open_replay" => ("replay", "Replay"),
                "pane.open_daily_brief" => ("daily_brief", "Daily Brief"),
                "pane.open_search" => ("search", "Search"),
                "pane.open_diff" => ("diff", "Diff"),
                "pane.open_file_browser" => ("file_browser", "Files"),
                "pane.open_rules_manager" => ("rules", "Rules"),
                "pane.open_settings" => ("settings", "Settings"),
                _ => unreachable!(),
            };
            let pane = upsert_pane(
                PaneInput {
                    id: None,
                    session_id: None,
                    r#type: pane_type.to_string(),
                    position,
                    label: label.to_string(),
                    metadata_json: None,
                },
                state,
            )
            .await?;
            Ok(json!({ "pane_id": pane.id }))
        }
        "task.delete_ready" => {
            let ready = list_tasks(state)
                .await?
                .into_iter()
                .find(|task| task.status == "Ready");
            let Some(ready) = ready else {
                return Ok(json!({ "deleted": false }));
            };
            delete_task(ready.id.clone(), &state.emitter, state).await?;
            Ok(json!({ "deleted": true, "task_id": ready.id }))
        }
        "review.approve_task" => crate::control::route_method(
            state,
            "review.approve",
            &serde_json::Value::Object(params),
        )
        .await
        .map_err(|(_code, msg)| msg),
        "review.reject_task" => {
            crate::control::route_method(state, "review.reject", &serde_json::Value::Object(params))
                .await
                .map_err(|(_code, msg)| msg)
        }
        "merge.execute_task" => crate::control::route_method(
            state,
            "merge.queue.execute",
            &serde_json::Value::Object(params),
        )
        .await
        .map_err(|(_code, msg)| msg),
        _ => crate::control::route_method(state, &input.id, &serde_json::Value::Object(params))
            .await
            .map_err(|(_code, msg)| msg),
    };

    if result.is_ok() {
        let current = state.current.lock().await;
        if let Some(ctx) = current.as_ref() {
            append_telemetry_event(
                &ctx.db,
                ctx.project_id,
                &ctx.global_config,
                "command.execute",
                json!({"id": command_id}),
            )
            .await;
        }
    }
    result
}

pub async fn pool_state(state: &AppState) -> Result<(usize, usize, usize, usize), String> {
    let current = state.current.lock().await;
    let ctx = current
        .as_ref()
        .ok_or_else(|| "no open project".to_string())?;
    Ok(ctx.pool.state().await)
}

pub async fn check_action_risk(
    action_kind: pnevma_core::ActionKind,
) -> Result<pnevma_core::ActionRiskInfo, String> {
    Ok(action_kind.risk_info())
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::event_emitter::NullEmitter;
    use pnevma_agents::AdapterRegistry;
    use pnevma_core::config::{
        AgentsSection, AutomationSection, BranchesSection, PathSection, ProjectSection,
        RetentionSection,
    };
    use pnevma_core::RemoteSection;
    use serde_json::Value;
    use sqlx::sqlite::SqlitePoolOptions;
    use std::ffi::OsString;
    use std::sync::{Mutex, MutexGuard, OnceLock};

    fn home_env_lock() -> &'static Mutex<()> {
        static LOCK: OnceLock<Mutex<()>> = OnceLock::new();
        LOCK.get_or_init(|| Mutex::new(()))
    }

    struct HomeOverride {
        previous_home: Option<OsString>,
        _guard: MutexGuard<'static, ()>,
    }

    impl HomeOverride {
        fn new(path: &Path) -> Self {
            let guard = home_env_lock().lock().expect("home env lock");
            let previous_home = std::env::var_os("HOME");
            std::env::set_var("HOME", path);
            Self {
                previous_home,
                _guard: guard,
            }
        }
    }

    impl Drop for HomeOverride {
        fn drop(&mut self) {
            if let Some(previous_home) = self.previous_home.as_ref() {
                std::env::set_var("HOME", previous_home);
            } else {
                std::env::remove_var("HOME");
            }
        }
    }

    async fn open_test_db() -> Db {
        let pool = SqlitePoolOptions::new()
            .max_connections(1)
            .connect("sqlite::memory:")
            .await
            .expect("memory sqlite");
        let db = Db::from_pool_and_path(pool, std::path::PathBuf::from(":memory:"));
        db.migrate().await.expect("migrate");
        db
    }

    fn make_task(pid: &str, title: &str) -> TaskRow {
        let now = chrono::Utc::now();
        TaskRow {
            id: Uuid::new_v4().to_string(),
            project_id: pid.to_string(),
            title: title.to_string(),
            goal: String::new(),
            scope_json: "[]".to_string(),
            dependencies_json: "[]".to_string(),
            acceptance_json: "[]".to_string(),
            constraints_json: "[]".to_string(),
            priority: "medium".to_string(),
            status: "ready".to_string(),
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
        }
    }

    fn make_project_config() -> ProjectConfig {
        ProjectConfig {
            project: ProjectSection {
                name: "test-project".to_string(),
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
                naming: "task/{slug}".to_string(),
            },
            rules: PathSection::default(),
            conventions: PathSection::default(),
            remote: RemoteSection::default(),
        }
    }

    fn make_session_metadata(
        project_id: Uuid,
        session_id: Uuid,
        cwd: &Path,
        status: SessionStatus,
    ) -> SessionMetadata {
        SessionMetadata {
            id: session_id,
            project_id,
            name: "shell".to_string(),
            status: status.clone(),
            health: match status {
                SessionStatus::Running => SessionHealth::Active,
                SessionStatus::Waiting => SessionHealth::Waiting,
                SessionStatus::Error => SessionHealth::Error,
                SessionStatus::Complete => SessionHealth::Complete,
            },
            pid: Some(42),
            cwd: cwd.to_string_lossy().to_string(),
            command: "/bin/zsh".to_string(),
            branch: None,
            worktree_id: None,
            started_at: Utc::now(),
            last_heartbeat: Utc::now(),
            scrollback_path: cwd
                .join(".pnevma/data/scrollback")
                .join(format!("{session_id}.log"))
                .to_string_lossy()
                .to_string(),
            exit_code: (status == SessionStatus::Complete).then_some(0),
            ended_at: (status == SessionStatus::Complete).then_some(Utc::now()),
        }
    }

    async fn make_state_with_project(
        project_id: Uuid,
        project_root: &Path,
        db: Db,
        sessions: SessionSupervisor,
    ) -> AppState {
        let emitter: Arc<dyn EventEmitter> = Arc::new(NullEmitter);
        let state = AppState::new(emitter);
        *state.current.lock().await = Some(ProjectContext {
            project_id,
            project_path: project_root.to_path_buf(),
            config: make_project_config(),
            global_config: GlobalConfig::default(),
            db,
            sessions,
            redaction_secrets: Arc::new(RwLock::new(Vec::new())),
            git: Arc::new(GitService::new(project_root)),
            adapters: AdapterRegistry::default(),
            pool: DispatchPool::new(1),
        });
        state
    }

    #[tokio::test]
    async fn search_tasks_by_title() {
        let db = open_test_db().await;
        let pid = Uuid::new_v4().to_string();
        db.upsert_project(&pid, "test", "/tmp/test", None, None)
            .await
            .unwrap();

        db.create_task(&make_task(&pid, "Fix the widget renderer"))
            .await
            .unwrap();

        let hits = search_db("widget", 10, &db, &pid).await.unwrap();
        assert!(!hits.is_empty());
        assert_eq!(hits[0].source, "task");
        assert!(hits[0].title.contains("widget"));
    }

    #[tokio::test]
    async fn search_no_results() {
        let db = open_test_db().await;
        let pid = Uuid::new_v4().to_string();
        db.upsert_project(&pid, "test", "/tmp/test", None, None)
            .await
            .unwrap();

        let hits = search_db("xyznonexistent", 10, &db, &pid).await.unwrap();
        assert!(hits.is_empty());
    }

    #[tokio::test]
    async fn search_respects_limit() {
        let db = open_test_db().await;
        let pid = Uuid::new_v4().to_string();
        db.upsert_project(&pid, "test", "/tmp/test", None, None)
            .await
            .unwrap();

        for i in 0..5 {
            db.create_task(&make_task(&pid, &format!("Widget task {i}")))
                .await
                .unwrap();
        }

        let hits = search_db("widget", 2, &db, &pid).await.unwrap();
        assert_eq!(hits.len(), 2);
    }

    #[tokio::test]
    async fn search_events_by_type() {
        let db = open_test_db().await;
        let pid = Uuid::new_v4().to_string();
        db.upsert_project(&pid, "test", "/tmp/test", None, None)
            .await
            .unwrap();

        let event = NewEvent {
            id: Uuid::new_v4().to_string(),
            project_id: pid.clone(),
            task_id: None,
            session_id: None,
            trace_id: Uuid::new_v4().to_string(),
            source: "system".to_string(),
            // Use space-separated words so FTS5 tokenizer can match individual terms.
            // CamelCase like "DeploymentStarted" is a single FTS token and won't
            // match a search for "deployment".
            event_type: "deployment started".to_string(),
            payload: serde_json::json!({"env": "staging"}),
        };
        db.append_event(event).await.unwrap();

        let hits = search_db("deployment", 10, &db, &pid).await.unwrap();
        assert!(!hits.is_empty());
        assert_eq!(hits[0].source, "event");
        assert!(hits[0].title.contains("deployment"));
    }

    #[tokio::test]
    async fn fts_fallback_exercised() {
        let db = open_test_db().await;
        let pid = Uuid::new_v4().to_string();
        db.upsert_project(&pid, "test", "/tmp/test", None, None)
            .await
            .unwrap();

        // Insert data while FTS tables and triggers still exist.
        db.create_task(&make_task(&pid, "Fallback search target"))
            .await
            .unwrap();

        // Drop FTS triggers and tables to force the in-memory scan fallback path.
        // Triggers must go first — they reference the FTS tables and would fire
        // errors on any subsequent task/event mutations.
        for stmt in [
            "DROP TRIGGER IF EXISTS tasks_fts_insert",
            "DROP TRIGGER IF EXISTS tasks_fts_update",
            "DROP TRIGGER IF EXISTS tasks_fts_delete",
            "DROP TRIGGER IF EXISTS events_fts_insert",
            "DROP TABLE IF EXISTS tasks_fts",
            "DROP TABLE IF EXISTS events_fts",
        ] {
            sqlx::query(stmt).execute(db.pool()).await.unwrap();
        }

        let hits = search_db("Fallback", 10, &db, &pid).await.unwrap();
        assert!(!hits.is_empty());
        assert_eq!(hits[0].source, "task");
        assert!(hits[0].title.contains("Fallback"));
    }

    #[tokio::test]
    async fn search_artifacts_by_path() {
        let db = open_test_db().await;
        let pid = Uuid::new_v4().to_string();
        db.upsert_project(&pid, "test", "/tmp/test", None, None)
            .await
            .unwrap();

        let artifact = ArtifactRow {
            id: Uuid::new_v4().to_string(),
            project_id: pid.clone(),
            task_id: None,
            r#type: "document".to_string(),
            path: "docs/architecture.md".to_string(),
            description: Some("System architecture overview".to_string()),
            created_at: chrono::Utc::now(),
        };
        db.create_artifact(&artifact).await.unwrap();

        let hits = search_db("architecture", 10, &db, &pid).await.unwrap();
        assert!(!hits.is_empty());
        assert_eq!(hits[0].source, "artifact");
    }

    #[tokio::test]
    async fn search_does_not_leak_across_projects() {
        let db = open_test_db().await;
        let pid_a = Uuid::new_v4().to_string();
        let pid_b = Uuid::new_v4().to_string();
        db.upsert_project(&pid_a, "alpha", "/tmp/a", None, None)
            .await
            .unwrap();
        db.upsert_project(&pid_b, "beta", "/tmp/b", None, None)
            .await
            .unwrap();

        // Insert task in project A only
        db.create_task(&make_task(&pid_a, "Unique crosscheck"))
            .await
            .unwrap();

        // Search in project B via FTS path → should find nothing
        let hits = search_db("crosscheck", 10, &db, &pid_b).await.unwrap();
        assert!(hits.is_empty(), "FTS path must not leak across projects");

        // Drop FTS to verify fallback path also isolates by project
        sqlx::query("DROP TRIGGER IF EXISTS tasks_fts_insert")
            .execute(db.pool())
            .await
            .unwrap();
        sqlx::query("DROP TRIGGER IF EXISTS tasks_fts_update")
            .execute(db.pool())
            .await
            .unwrap();
        sqlx::query("DROP TRIGGER IF EXISTS tasks_fts_delete")
            .execute(db.pool())
            .await
            .unwrap();
        sqlx::query("DROP TABLE IF EXISTS tasks_fts")
            .execute(db.pool())
            .await
            .unwrap();
        let hits = search_db("crosscheck", 10, &db, &pid_b).await.unwrap();
        assert!(
            hits.is_empty(),
            "fallback path must not leak across projects"
        );
    }

    #[test]
    fn validate_path_component_rejects_traversal() {
        assert!(validate_path_component("../etc", "test").is_err());
        assert!(validate_path_component("foo/bar", "test").is_err());
        assert!(validate_path_component("foo\\bar", "test").is_err());
        assert!(validate_path_component("", "test").is_err());
        assert!(validate_path_component("foo\0bar", "test").is_err());
        assert!(validate_path_component("valid-name", "test").is_ok());
        assert!(validate_path_component("task-123", "test").is_ok());
    }

    #[test]
    fn session_and_path_inputs_are_bounded() {
        assert!(ensure_bounded_text_field("shell", "session name", MAX_SESSION_NAME_BYTES).is_ok());
        assert!(
            ensure_bounded_text_field("bad\nname", "session name", MAX_SESSION_NAME_BYTES).is_err()
        );
        assert!(ensure_safe_path_input("src/main.rs", "file path").is_ok());
        assert!(ensure_safe_path_input("src/\0main.rs", "file path").is_err());
        assert!(ensure_safe_session_input("pwd\n").is_ok());
        assert!(ensure_safe_session_input(&"x".repeat(MAX_SESSION_INPUT_BYTES + 1)).is_err());
    }

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
            status: "complete".to_string(),
            pid: None,
            cwd: project_root.to_string_lossy().to_string(),
            command: "zsh".to_string(),
            branch: None,
            worktree_id: None,
            started_at: old,
            last_heartbeat: old,
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
            .await;
        sessions
            .register_restored(make_session_metadata(
                project_id,
                archived_session_id,
                &project_root,
                SessionStatus::Complete,
            ))
            .await;

        let emitter: Arc<dyn EventEmitter> = Arc::new(NullEmitter);
        let state = AppState::new(emitter);
        *state.current.lock().await = Some(ProjectContext {
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
        });

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

    #[test]
    fn app_settings_view_uses_defaults_for_empty_optional_fields() {
        let view = app_settings_view_from_config(&GlobalConfig::default());
        assert_eq!(view.default_shell, "");
        assert_eq!(view.focus_border_color, "accent");
        assert!(!view.keybindings.is_empty());
    }

    #[tokio::test]
    async fn set_app_settings_round_trips_and_preserves_other_global_fields() {
        let temp = tempfile::tempdir().expect("tempdir");
        let _home = HomeOverride::new(temp.path());

        let mut initial = GlobalConfig {
            default_provider: Some("claude-code".to_string()),
            theme: Some("solarized".to_string()),
            socket_auth_mode: Some("same-user".to_string()),
            ..GlobalConfig::default()
        };
        initial
            .keybindings
            .insert("Open Settings".to_string(), "Cmd+,".to_string());
        save_global_config(&initial).expect("save initial config");

        let emitter: Arc<dyn EventEmitter> = Arc::new(NullEmitter);
        let state = AppState::new(emitter);
        let updated = set_app_settings(
            SetAppSettingsInput {
                auto_save_workspace_on_quit: false,
                restore_windows_on_launch: false,
                auto_update: false,
                default_shell: "/bin/bash".to_string(),
                terminal_font: "JetBrains Mono".to_string(),
                terminal_font_size: 14,
                scrollback_lines: 20_000,
                sidebar_background_offset: 0.1,
                focus_border_enabled: false,
                focus_border_opacity: 0.5,
                focus_border_width: 3.0,
                focus_border_color: "#336699".to_string(),
                telemetry_enabled: true,
                crash_reports: true,
            },
            &state,
        )
        .await
        .expect("set app settings");

        assert_eq!(updated.default_shell, "/bin/bash");
        assert_eq!(updated.terminal_font, "JetBrains Mono");
        assert_eq!(updated.focus_border_color, "#336699");
        assert!(updated.telemetry_enabled);
        assert!(updated.crash_reports);

        let reloaded = load_global_config().expect("reload config");
        assert_eq!(reloaded.default_provider.as_deref(), Some("claude-code"));
        assert_eq!(reloaded.theme.as_deref(), Some("solarized"));
        assert_eq!(reloaded.socket_auth_mode.as_deref(), Some("same-user"));
        assert_eq!(
            reloaded
                .keybindings
                .get("Open Settings")
                .map(String::as_str),
            Some("Cmd+,")
        );
        assert_eq!(reloaded.default_shell.as_deref(), Some("/bin/bash"));
        assert_eq!(reloaded.terminal_font, "JetBrains Mono");
        assert_eq!(reloaded.terminal_font_size, 14);
        assert_eq!(reloaded.scrollback_lines, 20_000);
        assert_eq!(reloaded.sidebar_background_offset, 0.1);
        assert!(!reloaded.focus_border_enabled);
        assert_eq!(reloaded.focus_border_opacity, 0.5);
        assert_eq!(reloaded.focus_border_width, 3.0);
        assert_eq!(reloaded.focus_border_color.as_deref(), Some("#336699"));
        assert!(reloaded.telemetry_opt_in);
        assert!(reloaded.crash_reports_opt_in);
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
            .await;

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
            .await;

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
    async fn list_project_file_tree_lists_directory_entries_including_hidden_entries() {
        let temp = tempfile::tempdir().expect("tempdir");
        let project_root = temp.path().join("project");
        std::fs::create_dir_all(project_root.join("src")).unwrap();
        std::fs::create_dir_all(project_root.join(".git")).unwrap();
        std::fs::create_dir_all(project_root.join(".pnevma/data")).unwrap();
        std::fs::write(project_root.join("src/lib.rs"), "pub fn tree() {}\n").unwrap();
        std::fs::write(project_root.join(".env"), "TOKEN=secret\n").unwrap();
        std::fs::write(project_root.join(".git/config"), "[core]\n").unwrap();
        std::fs::write(project_root.join(".pnevma/data/runtime.log"), "runtime\n").unwrap();

        let db = open_test_db().await;
        let project_id = Uuid::new_v4();
        db.upsert_project(
            &project_id.to_string(),
            "tree-test",
            project_root.to_string_lossy().as_ref(),
            None,
            None,
        )
        .await
        .unwrap();

        let sessions = SessionSupervisor::new(project_root.join(".pnevma/data"));
        let state = make_state_with_project(project_id, &project_root, db, sessions).await;
        let nodes = list_project_file_tree(None, &state)
            .await
            .expect("file tree should load");

        let src = nodes
            .iter()
            .find(|node| node.path == "src" && node.is_directory)
            .expect("src directory should be present");
        assert!(src.children.is_none(), "src should load lazily");
        assert!(nodes.iter().any(|node| node.path == ".env"));
        assert!(nodes.iter().any(|node| node.path == ".git"));
        assert!(nodes.iter().any(|node| node.path == ".pnevma"));
    }

    #[tokio::test]
    async fn list_project_file_tree_loads_subdirectory_entries() {
        let temp = tempfile::tempdir().expect("tempdir");
        let project_root = temp.path().join("project");
        std::fs::create_dir_all(project_root.join("src")).unwrap();
        std::fs::write(project_root.join("src/lib.rs"), "pub fn preview() {}\n").unwrap();

        let db = open_test_db().await;
        let project_id = Uuid::new_v4();
        db.upsert_project(
            &project_id.to_string(),
            "tree-preview-test",
            project_root.to_string_lossy().as_ref(),
            None,
            None,
        )
        .await
        .unwrap();

        let sessions = SessionSupervisor::new(project_root.join(".pnevma/data"));
        let state = make_state_with_project(project_id, &project_root, db, sessions).await;
        let nodes = list_project_file_tree(
            Some(ListProjectFilesInput {
                query: None,
                limit: None,
                path: Some("src".to_string()),
            }),
            &state,
        )
        .await
        .expect("file tree should load");

        let lib_rs = nodes
            .iter()
            .find(|node| node.path == "src/lib.rs" && !node.is_directory)
            .expect("lib.rs should be present");

        assert_eq!(lib_rs.id, "src/lib.rs");
        assert_eq!(lib_rs.name, "lib.rs");
        assert!(lib_rs.size.unwrap_or_default() > 0);
        assert!(nodes.iter().all(|node| !node.path.starts_with(".git")));
    }

    #[tokio::test]
    async fn open_file_target_accepts_path_from_file_tree() {
        let temp = tempfile::tempdir().expect("tempdir");
        let project_root = temp.path().join("project");
        std::fs::create_dir_all(project_root.join("src")).unwrap();
        std::fs::write(project_root.join("src/lib.rs"), "pub fn preview() {}\n").unwrap();

        let db = open_test_db().await;
        let project_id = Uuid::new_v4();
        db.upsert_project(
            &project_id.to_string(),
            "tree-preview-test",
            project_root.to_string_lossy().as_ref(),
            None,
            None,
        )
        .await
        .unwrap();

        let sessions = SessionSupervisor::new(project_root.join(".pnevma/data"));
        let state = make_state_with_project(project_id, &project_root, db, sessions).await;
        let nodes = list_project_file_tree(
            Some(ListProjectFilesInput {
                query: None,
                limit: None,
                path: Some("src".to_string()),
            }),
            &state,
        )
        .await
        .expect("file tree should load");
        let lib_rs_path = nodes
            .iter()
            .find(|node| node.path == "src/lib.rs" && !node.is_directory)
            .map(|node| node.path.clone())
            .expect("lib.rs path should be available");

        let opened = open_file_target(
            OpenFileTargetInput {
                path: lib_rs_path,
                mode: Some("preview".to_string()),
            },
            &state,
        )
        .await
        .expect("preview should load");

        assert_eq!(opened.path, "src/lib.rs");
        assert!(opened.content.contains("preview"));
    }

    #[tokio::test]
    async fn open_file_target_reports_binary_preview_unavailable() {
        let temp = tempfile::tempdir().expect("tempdir");
        let project_root = temp.path().join("project");
        std::fs::create_dir_all(project_root.join("assets")).unwrap();
        std::fs::write(project_root.join("assets/icon.bin"), [0_u8, 159, 146, 150]).unwrap();

        let db = open_test_db().await;
        let project_id = Uuid::new_v4();
        db.upsert_project(
            &project_id.to_string(),
            "tree-binary-preview-test",
            project_root.to_string_lossy().as_ref(),
            None,
            None,
        )
        .await
        .unwrap();

        let sessions = SessionSupervisor::new(project_root.join(".pnevma/data"));
        let state = make_state_with_project(project_id, &project_root, db, sessions).await;

        let opened = open_file_target(
            OpenFileTargetInput {
                path: "assets/icon.bin".to_string(),
                mode: Some("preview".to_string()),
            },
            &state,
        )
        .await
        .expect("binary preview should return a placeholder");

        assert_eq!(opened.path, "assets/icon.bin");
        assert_eq!(opened.content, "[Binary file preview unavailable]");
        assert!(!opened.truncated);
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
}
