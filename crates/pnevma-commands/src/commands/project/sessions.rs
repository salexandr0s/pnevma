use super::*;

pub(super) fn resolve_session_command(
    input_command: &str,
    global_default_shell: Option<&str>,
) -> String {
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
    let started = Instant::now();
    let (db, project_id, project_path, default_shell, allowed_commands, sessions) = state
        .with_project("create_session", |ctx| {
            (
                ctx.db.clone(),
                ctx.project_id,
                ctx.project_path.clone(),
                ctx.global_config.default_shell.clone(),
                ctx.config.automation.allowed_commands.clone(),
                ctx.sessions.clone(),
            )
        })
        .await?;

    ensure_bounded_text_field(&input.name, "session name", MAX_SESSION_NAME_BYTES)?;
    ensure_safe_path_input(&input.cwd, "session cwd")?;

    let command = resolve_session_command(&input.command, default_shell.as_deref());
    ensure_bounded_text_field(&command, "session command", MAX_SESSION_COMMAND_BYTES)?;

    // H2: Validate command against the configured allowlist.
    let base_cmd = command.split_whitespace().next().unwrap_or("");
    let cmd_name = std::path::Path::new(base_cmd)
        .file_name()
        .and_then(|n| n.to_str())
        .unwrap_or(base_cmd);
    if !allowed_commands.iter().any(|c| c == cmd_name) {
        return Err(format!("command not allowed: {cmd_name}"));
    }

    let cwd = if Path::new(&input.cwd).is_relative() {
        project_path.join(&input.cwd).to_string_lossy().to_string()
    } else {
        input.cwd.clone()
    };

    // H2: Require cwd to resolve within the project directory.
    let resolved = std::fs::canonicalize(&cwd).map_err(|e| e.to_string())?;
    let project_canonical = std::fs::canonicalize(&project_path).map_err(|e| e.to_string())?;
    if !resolved.starts_with(&project_canonical) {
        return Err("session cwd must be within the project directory".to_string());
    }

    let session = sessions
        .spawn_shell(project_id, input.name.clone(), cwd.clone(), command.clone())
        .await
        .map_err(|e| e.to_string())?;

    let row = session_row_from_meta(&session);
    db.upsert_session(&row).await.map_err(|e| e.to_string())?;

    append_event(
        &db,
        project_id,
        None,
        Some(session.id),
        "session",
        "SessionSpawned",
        json!({"name": input.name, "cwd": cwd}),
    )
    .await;

    let elapsed = started.elapsed();
    if elapsed >= std::time::Duration::from_millis(250) {
        tracing::warn!(
            session_id = %session.id,
            elapsed_ms = elapsed.as_millis() as u64,
            "slow create_session command"
        );
    }

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

fn recovery_options_for_row(row: &SessionRow) -> Vec<RecoveryOptionView> {
    let can_interrupt = matches!(row.status.as_str(), "running" | "waiting");
    let can_restart = true;
    let can_reattach = row.status == "waiting";
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
    let (sessions, db, project_id) = state
        .with_project("get_session_binding", |ctx| {
            (ctx.sessions.clone(), ctx.db.clone(), ctx.project_id)
        })
        .await?;
    let session_uuid = Uuid::parse_str(&session_id).map_err(|e| e.to_string())?;
    let Some(meta) = sessions.get(session_uuid).await else {
        let row = db
            .get_session(&project_id.to_string(), &session_id)
            .await
            .map_err(|e| e.to_string())?
            .ok_or_else(|| format!("session not found: {session_id}"))?;
        let recovery_options = recovery_options_for_row(&row);

        return Ok(SessionBindingView {
            session_id,
            backend: row.backend,
            durability: row.durability,
            lifecycle_state: row.lifecycle_state,
            mode: "archived".to_string(),
            cwd: row.cwd,
            launch_command: None,
            env: Vec::new(),
            wait_after_command: false,
            recovery_options,
        });
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
            value: sessions.tmux_tmpdir().to_string_lossy().to_string(),
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
        backend: default_session_backend(),
        durability: default_session_durability(),
        lifecycle_state: session_lifecycle_state_for_status(&session_status_to_string(
            &meta.status,
        )),
        mode: if is_live {
            "live_attach".to_string()
        } else {
            "archived".to_string()
        },
        cwd,
        launch_command: is_live.then(tmux_attach_launch_command),
        env,
        wait_after_command: false,
        recovery_options,
    })
}

pub async fn list_sessions(state: &AppState) -> Result<Vec<SessionRow>, String> {
    let (db, project_id) = state
        .with_project("list_sessions", |ctx| (ctx.db.clone(), ctx.project_id))
        .await?;
    db.list_sessions(&project_id.to_string())
        .await
        .map_err(|e| e.to_string())
}

pub async fn restart_session(session_id: String, state: &AppState) -> Result<String, String> {
    let started = Instant::now();
    let (db, project_id, project_path, sessions) = state
        .with_project("restart_session", |ctx| {
            (
                ctx.db.clone(),
                ctx.project_id,
                ctx.project_path.clone(),
                ctx.sessions.clone(),
            )
        })
        .await?;

    let sessions_rows = db
        .list_sessions(&project_id.to_string())
        .await
        .map_err(|e| e.to_string())?;
    let mut prior = sessions_rows
        .into_iter()
        .find(|row| row.id == session_id)
        .ok_or_else(|| format!("session not found: {session_id}"))?;
    let prior_session_id = Uuid::parse_str(&prior.id).ok();

    let cwd = if Path::new(&prior.cwd).is_relative() {
        project_path.join(&prior.cwd).to_string_lossy().to_string()
    } else {
        prior.cwd.clone()
    };

    let new_meta = sessions
        .spawn_shell(
            project_id,
            prior.name.clone(),
            cwd.clone(),
            prior.command.clone(),
        )
        .await
        .map_err(|e| e.to_string())?;

    prior.status = "complete".to_string();
    prior.lifecycle_state = "exited".to_string();
    prior.pid = None;
    prior.last_heartbeat = Utc::now();
    prior.ended_at = Some(Utc::now().to_rfc3339());
    prior.last_error = None;
    db.upsert_session(&prior).await.map_err(|e| e.to_string())?;
    if let Some(old_id) = prior_session_id {
        match sessions.kill_session_backend(old_id).await {
            Ok(_) => {
                let _ = sessions.mark_exit(old_id, None).await;
            }
            Err(err) => {
                tracing::warn!(
                    "restart_session: failed to terminate prior session {old_id}: {err}"
                );
            }
        }
    }

    let row = session_row_from_meta(&new_meta);
    db.upsert_session(&row).await.map_err(|e| e.to_string())?;

    let panes = db
        .list_panes(&project_id.to_string())
        .await
        .map_err(|e| e.to_string())?;
    for mut pane in panes {
        if pane.session_id.as_deref() != Some(prior.id.as_str()) {
            continue;
        }
        pane.session_id = Some(row.id.clone());
        db.upsert_pane(&pane).await.map_err(|e| e.to_string())?;
    }

    append_event(
        &db,
        project_id,
        None,
        Some(new_meta.id),
        "session",
        "SessionSpawned",
        json!({"restart_of": prior.id, "cwd": cwd}),
    )
    .await;

    let elapsed = started.elapsed();
    if elapsed >= std::time::Duration::from_millis(250) {
        tracing::warn!(
            session_id = %new_meta.id,
            elapsed_ms = elapsed.as_millis() as u64,
            "slow restart_session command"
        );
    }

    Ok(row.id)
}

pub async fn send_session_input(
    session_id: String,
    input: String,
    state: &AppState,
) -> Result<(), String> {
    let sessions = state
        .with_project("send_session_input", |ctx| ctx.sessions.clone())
        .await?;
    ensure_safe_session_input(&input)?;
    let session_id = Uuid::parse_str(&session_id).map_err(|e| e.to_string())?;
    sessions
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
    let sessions = state
        .with_project("resize_session", |ctx| ctx.sessions.clone())
        .await?;
    let session_id = Uuid::parse_str(&session_id).map_err(|e| e.to_string())?;
    sessions
        .resize(session_id, cols, rows)
        .await
        .map_err(|e| e.to_string())
}

pub async fn get_scrollback(
    input: ScrollbackInput,
    state: &AppState,
) -> Result<ScrollbackSlice, String> {
    let started = Instant::now();
    let sessions = state
        .with_project("get_scrollback", |ctx| ctx.sessions.clone())
        .await?;
    let session_id = Uuid::parse_str(&input.session_id).map_err(|e| e.to_string())?;

    let limit = input.limit.unwrap_or(64 * 1024);
    let slice = match input.offset {
        Some(offset) => sessions
            .read_scrollback(session_id, offset, limit)
            .await
            .map_err(|e| e.to_string()),
        None => sessions
            .read_scrollback_tail(session_id, limit)
            .await
            .map_err(|e| e.to_string()),
    }?;
    let elapsed = started.elapsed();
    if elapsed >= std::time::Duration::from_millis(250) || slice.total_bytes > 512 * 1024 {
        tracing::warn!(
            session_id = %slice.session_id,
            requested_limit = limit,
            total_bytes = slice.total_bytes,
            returned_bytes = slice.data.len(),
            elapsed_ms = elapsed.as_millis() as u64,
            "slow or large scrollback fetch"
        );
    }
    Ok(slice)
}

pub async fn restore_sessions(state: &AppState) -> Result<Vec<SessionRow>, String> {
    let (db, project_id, project_path, sessions) = state
        .with_project("restore_sessions", |ctx| {
            (
                ctx.db.clone(),
                ctx.project_id,
                ctx.project_path.clone(),
                ctx.sessions.clone(),
            )
        })
        .await?;
    let rows = reconcile_persisted_sessions(&db, project_id, project_path.as_path()).await?;
    for row in &rows {
        if row.status != "waiting" {
            continue;
        }
        if let Ok(id) = Uuid::parse_str(&row.id) {
            let _ = sessions.attach_existing(id).await;
        }
    }
    Ok(rows)
}

pub async fn reattach_session(session_id: String, state: &AppState) -> Result<(), String> {
    let (db, project_id, sessions) = state
        .with_project("reattach_session", |ctx| {
            (ctx.db.clone(), ctx.project_id, ctx.sessions.clone())
        })
        .await?;
    let session_id = Uuid::parse_str(&session_id).map_err(|e| e.to_string())?;
    sessions
        .attach_existing(session_id)
        .await
        .map_err(|e| e.to_string())?;

    append_event(
        &db,
        project_id,
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
    let (db, project_id) = state
        .with_project("list_panes", |ctx| (ctx.db.clone(), ctx.project_id))
        .await?;
    db.list_panes(&project_id.to_string())
        .await
        .map_err(|e| e.to_string())
}

pub async fn upsert_pane(input: PaneInput, state: &AppState) -> Result<PaneRow, String> {
    let (db, project_id) = state
        .with_project("upsert_pane", |ctx| (ctx.db.clone(), ctx.project_id))
        .await?;

    let row = PaneRow {
        id: input.id.unwrap_or_else(|| Uuid::new_v4().to_string()),
        project_id: project_id.to_string(),
        session_id: input.session_id,
        r#type: input.r#type,
        position: input.position,
        label: input.label,
        metadata_json: input.metadata_json,
    };

    db.upsert_pane(&row).await.map_err(|e| e.to_string())?;
    Ok(row)
}

pub async fn remove_pane(pane_id: String, state: &AppState) -> Result<(), String> {
    let db = state
        .with_project("remove_pane", |ctx| ctx.db.clone())
        .await?;
    db.remove_pane(&pane_id).await.map_err(|e| e.to_string())
}

pub async fn list_pane_layout_templates(
    state: &AppState,
) -> Result<Vec<PaneLayoutTemplateView>, String> {
    let (db, project_id) = state
        .with_project("list_pane_layout_templates", |ctx| {
            (ctx.db.clone(), ctx.project_id)
        })
        .await?;
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

    let (db, project_id) = state
        .with_project("save_pane_layout_template", |ctx| {
            (ctx.db.clone(), ctx.project_id)
        })
        .await?;
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

    let (db, project_id) = state
        .with_project("apply_pane_layout_template", |ctx| {
            (ctx.db.clone(), ctx.project_id)
        })
        .await?;
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

pub(super) fn timeline_view_from_event(row: EventRow) -> TimelineEventView {
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
    let (db, project_id, sessions) = state
        .with_project("get_session_timeline", |ctx| {
            (ctx.db.clone(), ctx.project_id, ctx.sessions.clone())
        })
        .await?;
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
    let (sessions, db, project_id) = state
        .with_project("get_session_recovery_options", |ctx| {
            (ctx.sessions.clone(), ctx.db.clone(), ctx.project_id)
        })
        .await?;
    let session_uuid = Uuid::parse_str(&session_id).map_err(|e| e.to_string())?;
    if let Some(meta) = sessions.get(session_uuid).await {
        return Ok(recovery_options_for_meta(&meta));
    }
    let row = db
        .get_session(&project_id.to_string(), &session_id)
        .await
        .map_err(|e| e.to_string())?
        .ok_or_else(|| format!("session not found: {session_id}"))?;
    Ok(recovery_options_for_row(&row))
}

pub async fn recover_session(
    input: SessionRecoveryInput,
    emitter: &Arc<dyn EventEmitter>,
    state: &AppState,
) -> Result<serde_json::Value, String> {
    let (project_id, db, sessions, project_path) = state
        .with_project("recover_session", |ctx| {
            (
                ctx.project_id,
                ctx.db.clone(),
                ctx.sessions.clone(),
                ctx.project_path.clone(),
            )
        })
        .await?;
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
