use super::*;

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
    config.bottom_tool_bar_auto_hide = input.bottom_tool_bar_auto_hide;
    config.focus_border_enabled = input.focus_border_enabled;
    config.focus_border_opacity = input.focus_border_opacity;
    config.focus_border_width = input.focus_border_width;
    config.focus_border_color = focus_border_color;
    config.telemetry_opt_in = input.telemetry_enabled;
    config.crash_reports_opt_in = input.crash_reports;

    // Persist keybinding overrides — only store entries that differ from defaults
    if let Some(overrides) = input.keybindings {
        let defaults = default_keybindings();
        config.keybindings.clear();
        for kb in overrides {
            let action = kb.action.trim().to_string();
            let shortcut = kb.shortcut.trim().to_string();
            if action.is_empty() || shortcut.is_empty() {
                continue;
            }
            if is_protected_action(&action) {
                continue;
            }
            if defaults
                .get(&action)
                .is_none_or(|d| normalize_shortcut(d) != normalize_shortcut(&shortcut))
            {
                config.keybindings.insert(action, shortcut);
            }
        }
    }

    save_global_config(&config).map_err(|e| e.to_string())?;

    let _ = state
        .with_project_mut("set_app_settings", |ctx| {
            ctx.global_config = config.clone();
        })
        .await;

    Ok(app_settings_view_from_config(&config))
}

pub(super) async fn install_project_runtime(
    state: &AppState,
    db: Db,
    sessions: SessionSupervisor,
    project_id: Uuid,
    redaction_secrets: Arc<RwLock<Vec<String>>>,
    workflow_store: Arc<crate::automation::workflow_store::WorkflowStore>,
    shutdown_rx: tokio::sync::watch::Receiver<bool>,
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

    let coordinator_task = if let Some(state_arc) = state.arc() {
        let coordinator = Arc::new(crate::automation::coordinator::AutomationCoordinator::new(
            state_arc,
            Arc::clone(&workflow_store),
            shutdown_rx,
        ));
        // Store coordinator in ProjectContext
        let _ = state
            .with_project_mut("install_project_runtime.coordinator", |ctx| {
                ctx.coordinator = Some(Arc::clone(&coordinator));
            })
            .await;
        let coordinator_clone = Arc::clone(&coordinator);
        Some(tokio::spawn(async move {
            coordinator_clone.run().await;
        }))
    } else {
        tracing::warn!("no Arc<AppState> registered; automation coordinator will not start");
        None
    };

    *state.current_runtime.lock().await = Some(crate::state::ProjectRuntime::new(
        session_bridge,
        health_refresh,
        coordinator_task,
    ));
}

pub(super) fn project_runtime_redaction_config(
    cfg: &ProjectConfig,
) -> pnevma_redaction::RedactionConfig {
    pnevma_redaction::RedactionConfig {
        extra_patterns: cfg.redaction.extra_patterns.clone(),
        enable_entropy_guard: cfg.redaction.enable_entropy_guard,
    }
}

pub(super) fn keybinding_views_from_config(config: &GlobalConfig) -> Vec<KeybindingView> {
    let defaults = default_keybindings();
    let mut merged = defaults.clone();
    for (action, shortcut) in &config.keybindings {
        let action = action.trim();
        let shortcut = shortcut.trim();
        if !action.is_empty() && !shortcut.is_empty() && is_supported_keybinding_action(action) {
            merged.insert(action.to_string(), shortcut.to_string());
        }
    }

    // Build normalized-shortcut -> actions index for conflict detection
    let mut shortcut_to_actions: HashMap<String, Vec<String>> = HashMap::new();
    for (action, shortcut) in &merged {
        let normalized = normalize_shortcut(shortcut);
        shortcut_to_actions
            .entry(normalized)
            .or_default()
            .push(action.clone());
    }

    let mut out: Vec<KeybindingView> = merged
        .into_iter()
        .map(|(action, shortcut)| {
            let is_default = defaults
                .get(&action)
                .is_some_and(|d| normalize_shortcut(d) == normalize_shortcut(&shortcut));
            let normalized = normalize_shortcut(&shortcut);
            let conflicts: Vec<String> = shortcut_to_actions
                .get(&normalized)
                .map(|actions| actions.iter().filter(|a| **a != action).cloned().collect())
                .unwrap_or_default();
            KeybindingView {
                is_protected: is_protected_action(&action),
                action,
                shortcut,
                is_default,
                conflicts_with: conflicts,
            }
        })
        .collect();
    out.sort_by(|a, b| a.action.cmp(&b.action));
    out
}

pub async fn get_environment_readiness(
    input: Option<EnvironmentReadinessInput>,
    state: &AppState,
) -> Result<EnvironmentReadinessView, String> {
    let current_project_path = state
        .with_project("get_environment_readiness", |ctx| ctx.project_path.clone())
        .await
        .ok();
    let requested_path = match input.and_then(|value| value.path) {
        Some(path) => Some(normalize_scaffold_path(&path)?),
        None => current_project_path,
    };
    let git_available = is_git_available();
    let detected_adapters = pnevma_agents::AdapterRegistry::detect().await.available();
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
        let _ = state
            .with_project_mut("initialize_global_config", |ctx| {
                ctx.global_config = latest_config;
            })
            .await;
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
        let _ = state
            .with_project_mut("initialize_project_scaffold", |ctx| {
                if ctx.project_path == root {
                    if let Ok(cfg) = load_project_config(&config_path) {
                        ctx.config = cfg;
                    }
                }
            })
            .await;
    }

    Ok(InitProjectScaffoldResultView {
        root_path: root.to_string_lossy().to_string(),
        already_initialized: created_paths.is_empty(),
        created_paths,
    })
}

pub async fn list_keybindings(state: &AppState) -> Result<Vec<KeybindingView>, String> {
    state
        .with_project("list_keybindings", |ctx| {
            keybinding_views_from_config(&ctx.global_config)
        })
        .await
}

pub async fn set_keybinding(
    input: SetKeybindingInput,
    state: &AppState,
) -> Result<Vec<KeybindingView>, String> {
    if input.action.trim().is_empty() || input.shortcut.trim().is_empty() {
        return Err("action and shortcut are required".to_string());
    }
    if !is_supported_keybinding_action(input.action.trim()) {
        return Err(format!(
            "unsupported keybinding action: {}",
            input.action.trim()
        ));
    }
    state
        .with_project_mut("set_keybinding", |ctx| {
            ctx.global_config.keybindings.insert(
                input.action.trim().to_string(),
                input.shortcut.trim().to_string(),
            );
            (
                ctx.global_config.clone(),
                keybinding_views_from_config(&ctx.global_config),
            )
        })
        .await
        .and_then(|(config, views)| {
            save_global_config(&config).map_err(|e| e.to_string())?;
            Ok(views)
        })
}

pub async fn reset_keybindings(state: &AppState) -> Result<Vec<KeybindingView>, String> {
    state
        .with_project_mut("reset_keybindings", |ctx| {
            ctx.global_config.keybindings.clear();
            (
                ctx.global_config.clone(),
                keybinding_views_from_config(&ctx.global_config),
            )
        })
        .await
        .and_then(|(config, views)| {
            save_global_config(&config).map_err(|e| e.to_string())?;
            Ok(views)
        })
}

pub async fn get_onboarding_state(state: &AppState) -> Result<OnboardingStateView, String> {
    let (db, project_id) = state
        .with_project("get_onboarding_state", |ctx| {
            (ctx.db.clone(), ctx.project_id)
        })
        .await?;
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
    let (db, project_id, global_config) = state
        .with_project("advance_onboarding_step", |ctx| {
            (ctx.db.clone(), ctx.project_id, ctx.global_config.clone())
        })
        .await?;
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
    let (db, project_id, global_config) = state
        .with_project("reset_onboarding", |ctx| {
            (ctx.db.clone(), ctx.project_id, ctx.global_config.clone())
        })
        .await?;
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
    let (db, project_id, global_config) = state
        .with_project("get_telemetry_status", |ctx| {
            (ctx.db.clone(), ctx.project_id, ctx.global_config.clone())
        })
        .await?;
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
    let (db, project_id, global_config) = state
        .with_project_mut("set_telemetry_opt_in", |ctx| {
            ctx.global_config.telemetry_opt_in = input.opted_in;
            (ctx.db.clone(), ctx.project_id, ctx.global_config.clone())
        })
        .await?;
    save_global_config(&global_config).map_err(|e| e.to_string())?;
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

    let maybe_project = state
        .with_project("audit_ghostty_settings", |ctx| {
            (ctx.db.clone(), ctx.project_id)
        })
        .await
        .ok();
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
    let (db, project_id, project_path, opted_in) = state
        .with_project("export_telemetry_bundle", |ctx| {
            (
                ctx.db.clone(),
                ctx.project_id,
                ctx.project_path.clone(),
                ctx.global_config.telemetry_opt_in,
            )
        })
        .await?;
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
    let (db, project_id) = state
        .with_project("clear_telemetry", |ctx| (ctx.db.clone(), ctx.project_id))
        .await?;
    db.clear_telemetry_events(&project_id.to_string())
        .await
        .map_err(|e| e.to_string())
}

pub async fn submit_feedback(
    input: FeedbackInput,
    state: &AppState,
) -> Result<FeedbackView, String> {
    let (db, project_id, project_path, global_config) = state
        .with_project("submit_feedback", |ctx| {
            (
                ctx.db.clone(),
                ctx.project_id,
                ctx.project_path.clone(),
                ctx.global_config.clone(),
            )
        })
        .await?;
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
    let (db, project_id) = state
        .with_project("partner_metrics_report", |ctx| {
            (ctx.db.clone(), ctx.project_id)
        })
        .await?;
    let onboarding_completed = db
        .get_onboarding_state(&project_id.to_string())
        .await
        .ok()
        .flatten()
        .map(|row| row.completed)
        .unwrap_or(false);
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
