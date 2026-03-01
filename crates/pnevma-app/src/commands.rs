use crate::command_registry::{default_registry, RegisteredCommand};
use crate::control::{resolve_control_plane_settings, start_control_plane};
use crate::state::{AppState, ProjectContext, RecentProject};
use chrono::{DateTime, Utc};
use pnevma_agents::{AgentConfig, AgentEvent, DispatchPool, QueuedDispatch, TaskPayload};
use pnevma_context::{
    ContextCompileInput, ContextCompileMode, ContextCompiler, ContextCompilerConfig,
};
use pnevma_core::{
    load_global_config, load_project_config, Check, CheckType, GlobalConfig, Priority,
    ProjectConfig, TaskContract, TaskStatus,
};
use pnevma_db::{
    CostRow, Db, EventQueryFilter, EventRow, NewEvent, PaneRow, SessionRow, TaskRow, WorktreeRow,
};
use pnevma_git::GitService;
use pnevma_session::{
    ScrollbackSlice, SessionEvent, SessionHealth, SessionMetadata, SessionStatus, SessionSupervisor,
};
use serde::{Deserialize, Serialize};
use serde_json::json;
use std::collections::{HashMap, HashSet};
use std::path::{Path, PathBuf};
use std::sync::Arc;
use tauri::{AppHandle, Emitter, Manager, State};
use tokio::process::Command as TokioCommand;
use uuid::Uuid;

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct SessionInput {
    pub name: String,
    pub cwd: String,
    pub command: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct PaneInput {
    pub id: Option<String>,
    pub session_id: Option<String>,
    pub r#type: String,
    pub position: String,
    pub label: String,
    pub metadata_json: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct QueryEventsInput {
    pub event_type: Option<String>,
    pub session_id: Option<String>,
    pub task_id: Option<String>,
    pub from: Option<String>,
    pub to: Option<String>,
    pub limit: Option<i64>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ScrollbackInput {
    pub session_id: String,
    pub offset: Option<u64>,
    pub limit: Option<usize>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct CreateTaskInput {
    pub title: String,
    pub goal: String,
    pub scope: Vec<String>,
    pub acceptance_criteria: Vec<String>,
    #[serde(default)]
    pub constraints: Vec<String>,
    #[serde(default)]
    pub dependencies: Vec<String>,
    pub priority: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct UpdateTaskInput {
    pub id: String,
    pub title: Option<String>,
    pub goal: Option<String>,
    pub scope: Option<Vec<String>>,
    pub acceptance_criteria: Option<Vec<String>>,
    pub constraints: Option<Vec<String>>,
    pub dependencies: Option<Vec<String>>,
    pub priority: Option<String>,
    pub status: Option<String>,
    pub handoff_summary: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct TaskView {
    pub id: String,
    pub project_id: String,
    pub title: String,
    pub goal: String,
    pub scope: Vec<String>,
    pub dependencies: Vec<String>,
    pub acceptance_criteria: Vec<Check>,
    pub constraints: Vec<String>,
    pub priority: String,
    pub status: String,
    pub branch: Option<String>,
    pub worktree_id: Option<String>,
    pub handoff_summary: Option<String>,
    pub created_at: DateTime<Utc>,
    pub updated_at: DateTime<Utc>,
    pub queued_position: Option<usize>,
    pub cost_usd: Option<f64>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct WorktreeView {
    pub id: String,
    pub task_id: String,
    pub path: String,
    pub branch: String,
    pub lease_status: String,
    pub lease_started: DateTime<Utc>,
    pub last_active: DateTime<Utc>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ProjectStatusView {
    pub project_id: String,
    pub project_name: String,
    pub project_path: String,
    pub sessions: usize,
    pub tasks: usize,
    pub worktrees: usize,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct NotificationInput {
    pub title: String,
    pub body: String,
    pub level: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct NotificationView {
    pub id: String,
    pub title: String,
    pub body: String,
    pub level: String,
    pub created_at: DateTime<Utc>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ExecuteRegisteredCommandInput {
    pub id: String,
    #[serde(default)]
    pub args: HashMap<String, String>,
}

fn map_priority(priority: &str) -> Priority {
    match priority {
        "P0" => Priority::P0,
        "P1" => Priority::P1,
        "P2" => Priority::P2,
        _ => Priority::P3,
    }
}

fn parse_status(status: &str) -> TaskStatus {
    match status {
        "Ready" => TaskStatus::Ready,
        "InProgress" => TaskStatus::InProgress,
        "Review" => TaskStatus::Review,
        "Done" => TaskStatus::Done,
        "Failed" => TaskStatus::Failed,
        "Blocked" => TaskStatus::Blocked,
        _ => TaskStatus::Planned,
    }
}

fn status_to_str(status: &TaskStatus) -> &'static str {
    match status {
        TaskStatus::Planned => "Planned",
        TaskStatus::Ready => "Ready",
        TaskStatus::InProgress => "InProgress",
        TaskStatus::Review => "Review",
        TaskStatus::Done => "Done",
        TaskStatus::Failed => "Failed",
        TaskStatus::Blocked => "Blocked",
    }
}

fn map_priority_str(priority: &Priority) -> &'static str {
    match priority {
        Priority::P0 => "P0",
        Priority::P1 => "P1",
        Priority::P2 => "P2",
        Priority::P3 => "P3",
    }
}

fn parse_dt(input: Option<String>) -> Option<DateTime<Utc>> {
    input
        .and_then(|v| DateTime::parse_from_rfc3339(&v).ok())
        .map(|v| v.with_timezone(&Utc))
}

fn tmux_name_from_session_id(session_id: &str) -> String {
    format!("pnevma_{}", session_id.replace('-', ""))
}

fn tmux_tmpdir_for_project(project_path: &Path) -> PathBuf {
    project_path.join(".pnevma").join("data").join("tmux")
}

async fn session_backend_alive(project_path: &Path, session_id: &str) -> bool {
    let name = tmux_name_from_session_id(session_id);
    let tmux_tmpdir = tmux_tmpdir_for_project(project_path);
    let _ = tokio::fs::create_dir_all(&tmux_tmpdir).await;
    TokioCommand::new("tmux")
        .env("TMUX_TMPDIR", &tmux_tmpdir)
        .args(["has-session", "-t", &name])
        .status()
        .await
        .map(|status| status.success())
        .unwrap_or(false)
}

async fn reconcile_persisted_sessions(
    db: &Db,
    project_id: Uuid,
    project_path: &Path,
) -> Result<Vec<SessionRow>, String> {
    let rows = db
        .list_sessions(&project_id.to_string())
        .await
        .map_err(|e| e.to_string())?;

    let mut out = Vec::with_capacity(rows.len());
    for mut row in rows {
        if row.status == "running" || row.status == "waiting" {
            let alive = session_backend_alive(project_path, &row.id).await;
            row.status = if alive {
                "waiting".to_string()
            } else {
                "complete".to_string()
            };
            row.pid = None;
            row.last_heartbeat = Utc::now();
            db.upsert_session(&row).await.map_err(|e| e.to_string())?;
        }
        out.push(row);
    }
    Ok(out)
}

fn session_status_to_string(status: &SessionStatus) -> String {
    match status {
        SessionStatus::Running => "running".to_string(),
        SessionStatus::Waiting => "waiting".to_string(),
        SessionStatus::Error => "error".to_string(),
        SessionStatus::Complete => "complete".to_string(),
    }
}

fn parse_session_status(status: &str) -> SessionStatus {
    match status {
        "running" => SessionStatus::Running,
        "waiting" => SessionStatus::Waiting,
        "error" => SessionStatus::Error,
        _ => SessionStatus::Complete,
    }
}

fn parse_session_health(status: &str) -> SessionHealth {
    match status {
        "running" => SessionHealth::Waiting,
        "waiting" => SessionHealth::Waiting,
        "error" => SessionHealth::Error,
        _ => SessionHealth::Complete,
    }
}

fn session_row_from_meta(meta: &SessionMetadata) -> SessionRow {
    SessionRow {
        id: meta.id.to_string(),
        project_id: meta.project_id.to_string(),
        name: meta.name.clone(),
        r#type: Some("terminal".to_string()),
        status: session_status_to_string(&meta.status),
        pid: meta.pid.map(i64::from),
        cwd: meta.cwd.clone(),
        command: meta.command.clone(),
        branch: meta.branch.clone(),
        worktree_id: meta.worktree_id.map(|v| v.to_string()),
        started_at: meta.started_at,
        last_heartbeat: meta.last_heartbeat,
    }
}

fn session_meta_from_row(row: &SessionRow, data_root: &Path) -> Option<SessionMetadata> {
    let session_id = Uuid::parse_str(&row.id).ok()?;
    let project_id = Uuid::parse_str(&row.project_id).ok()?;

    let mut status = parse_session_status(&row.status);
    let mut health = parse_session_health(&row.status);
    if status == SessionStatus::Running {
        status = SessionStatus::Waiting;
        health = SessionHealth::Waiting;
    }

    Some(SessionMetadata {
        id: session_id,
        project_id,
        name: row.name.clone(),
        status,
        health,
        pid: row.pid.map(|v| v as u32),
        cwd: row.cwd.clone(),
        command: row.command.clone(),
        branch: row.branch.clone(),
        worktree_id: row
            .worktree_id
            .as_ref()
            .and_then(|v| Uuid::parse_str(v).ok()),
        started_at: row.started_at,
        last_heartbeat: row.last_heartbeat,
        scrollback_path: data_root
            .join("scrollback")
            .join(format!("{}.log", row.id))
            .to_string_lossy()
            .to_string(),
        exit_code: None,
        ended_at: None,
    })
}

fn slugify(input: &str) -> String {
    let mut out = String::with_capacity(input.len());
    let mut prev_dash = false;
    for ch in input.chars() {
        let c = ch.to_ascii_lowercase();
        if c.is_ascii_alphanumeric() {
            out.push(c);
            prev_dash = false;
            continue;
        }
        if !prev_dash {
            out.push('-');
            prev_dash = true;
        }
    }
    let trimmed = out.trim_matches('-');
    if trimmed.is_empty() {
        "task".to_string()
    } else {
        trimmed.to_string()
    }
}

fn task_row_to_contract(row: &TaskRow) -> Result<TaskContract, String> {
    let scope: Vec<String> = serde_json::from_str(&row.scope_json).map_err(|e| e.to_string())?;
    let dependencies: Vec<String> =
        serde_json::from_str(&row.dependencies_json).map_err(|e| e.to_string())?;
    let acceptance_criteria: Vec<Check> =
        serde_json::from_str(&row.acceptance_json).map_err(|e| e.to_string())?;
    let constraints: Vec<String> =
        serde_json::from_str(&row.constraints_json).map_err(|e| e.to_string())?;
    let id = Uuid::parse_str(&row.id).map_err(|e| e.to_string())?;

    Ok(TaskContract {
        id,
        title: row.title.clone(),
        goal: row.goal.clone(),
        scope,
        out_of_scope: Vec::new(),
        dependencies: dependencies
            .iter()
            .filter_map(|dep| Uuid::parse_str(dep).ok())
            .collect(),
        acceptance_criteria,
        constraints,
        priority: map_priority(&row.priority),
        status: parse_status(&row.status),
        assigned_session: None,
        branch: row.branch.clone(),
        worktree: row.worktree_id.clone(),
        prompt_pack: None,
        handoff_summary: row.handoff_summary.clone(),
        created_at: row.created_at,
        updated_at: row.updated_at,
    })
}

fn task_contract_to_row(task: &TaskContract, project_id: &str) -> Result<TaskRow, String> {
    Ok(TaskRow {
        id: task.id.to_string(),
        project_id: project_id.to_string(),
        title: task.title.clone(),
        goal: task.goal.clone(),
        scope_json: serde_json::to_string(&task.scope).map_err(|e| e.to_string())?,
        dependencies_json: serde_json::to_string(
            &task
                .dependencies
                .iter()
                .map(ToString::to_string)
                .collect::<Vec<_>>(),
        )
        .map_err(|e| e.to_string())?,
        acceptance_json: serde_json::to_string(&task.acceptance_criteria)
            .map_err(|e| e.to_string())?,
        constraints_json: serde_json::to_string(&task.constraints).map_err(|e| e.to_string())?,
        priority: map_priority_str(&task.priority).to_string(),
        status: status_to_str(&task.status).to_string(),
        branch: task.branch.clone(),
        worktree_id: task.worktree.clone(),
        handoff_summary: task.handoff_summary.clone(),
        created_at: task.created_at,
        updated_at: task.updated_at,
    })
}

fn task_row_to_view(row: TaskRow, cost_usd: Option<f64>) -> Result<TaskView, String> {
    let scope: Vec<String> = serde_json::from_str(&row.scope_json).map_err(|e| e.to_string())?;
    let dependencies: Vec<String> =
        serde_json::from_str(&row.dependencies_json).map_err(|e| e.to_string())?;
    let acceptance_criteria: Vec<Check> =
        serde_json::from_str(&row.acceptance_json).map_err(|e| e.to_string())?;
    let constraints: Vec<String> =
        serde_json::from_str(&row.constraints_json).map_err(|e| e.to_string())?;

    Ok(TaskView {
        id: row.id,
        project_id: row.project_id,
        title: row.title,
        goal: row.goal,
        scope,
        dependencies,
        acceptance_criteria,
        constraints,
        priority: row.priority,
        status: row.status,
        branch: row.branch,
        worktree_id: row.worktree_id,
        handoff_summary: row.handoff_summary,
        created_at: row.created_at,
        updated_at: row.updated_at,
        queued_position: None,
        cost_usd,
    })
}

async fn load_texts(paths: &[String], project_path: &Path) -> Vec<String> {
    let mut out = Vec::new();
    for path in paths {
        let candidate = if Path::new(path).is_absolute() {
            PathBuf::from(path)
        } else {
            project_path.join(path)
        };
        if let Ok(text) = tokio::fs::read_to_string(&candidate).await {
            out.push(text);
        }
    }
    out
}

async fn load_rule_texts(config: &ProjectConfig, project_path: &Path) -> Vec<String> {
    load_texts(&config.rules.paths, project_path).await
}

async fn load_convention_texts(config: &ProjectConfig, project_path: &Path) -> Vec<String> {
    load_texts(&config.conventions.paths, project_path).await
}

async fn emit_task_updated(db: &Db, project_id: Uuid, task_id: Uuid) {
    append_event(
        db,
        project_id,
        Some(task_id),
        None,
        "core",
        "TaskUpdated",
        json!({"task_id": task_id}),
    )
    .await;
}

async fn refresh_dependency_states(
    db: &Db,
    project_id: Uuid,
    app: Option<&AppHandle>,
) -> Result<(), String> {
    let rows = db
        .list_tasks(&project_id.to_string())
        .await
        .map_err(|e| e.to_string())?;
    let completed = rows
        .iter()
        .filter(|row| row.status == "Done")
        .filter_map(|row| Uuid::parse_str(&row.id).ok())
        .collect::<HashSet<_>>();

    for row in rows {
        if row.status != "Planned" && row.status != "Ready" && row.status != "Blocked" {
            continue;
        }
        let mut task = task_row_to_contract(&row)?;
        let prev = task.status.clone();
        task.refresh_blocked_status(&completed);
        if task.status == prev {
            continue;
        }

        let next = task_contract_to_row(&task, &project_id.to_string())?;
        db.update_task(&next).await.map_err(|e| e.to_string())?;
        emit_task_updated(db, project_id, task.id).await;
        if let Some(app) = app {
            let _ = app.emit("task_updated", json!({"task_id": task.id.to_string()}));
        }
    }
    Ok(())
}

fn required_arg(args: &HashMap<String, String>, key: &str) -> Result<String, String> {
    args.get(key)
        .cloned()
        .filter(|v| !v.trim().is_empty())
        .ok_or_else(|| format!("missing required command arg: {key}"))
}

fn optional_arg(args: &HashMap<String, String>, key: &str) -> Option<String> {
    args.get(key).cloned().filter(|v| !v.trim().is_empty())
}

fn is_terminal_task_status(status: &TaskStatus) -> bool {
    matches!(status, TaskStatus::Done | TaskStatus::Failed)
}

async fn stop_control_plane(state: &AppState) {
    let prior = {
        let mut slot = state.control_plane.lock().await;
        slot.take()
    };
    if let Some(handle) = prior {
        handle.shutdown().await;
    }
}

async fn restart_control_plane(
    app: &AppHandle,
    state: &AppState,
    project_path: &Path,
    project_config: &ProjectConfig,
    global_config: &GlobalConfig,
) -> Result<(), String> {
    stop_control_plane(state).await;
    let settings = resolve_control_plane_settings(project_path, project_config, global_config)?;
    let next = start_control_plane(app.clone(), settings).await?;
    let mut slot = state.control_plane.lock().await;
    *slot = next;
    Ok(())
}

async fn cleanup_task_worktree(
    db: &Db,
    git: &Arc<GitService>,
    project_id: Uuid,
    task_id: Uuid,
    app: Option<&AppHandle>,
) -> Result<(), String> {
    let task_id_str = task_id.to_string();
    if let Some(worktree) = db
        .find_worktree_by_task(&task_id_str)
        .await
        .map_err(|e| e.to_string())?
    {
        if let Err(err) = git
            .cleanup_persisted_worktree(task_id, &worktree.path, Some(&worktree.branch), false)
            .await
        {
            append_event(
                db,
                project_id,
                Some(task_id),
                None,
                "git",
                "WorktreeCleanupFailed",
                json!({"task_id": task_id_str, "error": err.to_string(), "path": worktree.path}),
            )
            .await;
        } else {
            append_event(
                db,
                project_id,
                Some(task_id),
                None,
                "git",
                "WorktreeRemoved",
                json!({"task_id": task_id_str, "path": worktree.path}),
            )
            .await;
        }
        db.remove_worktree_by_task(&task_id_str)
            .await
            .map_err(|e| e.to_string())?;
    }

    if let Some(mut row) = db.get_task(&task_id_str).await.map_err(|e| e.to_string())? {
        let mut changed = false;
        if row.branch.is_some() {
            row.branch = None;
            changed = true;
        }
        if row.worktree_id.is_some() {
            row.worktree_id = None;
            changed = true;
        }
        if changed {
            row.updated_at = Utc::now();
            db.update_task(&row).await.map_err(|e| e.to_string())?;
            emit_task_updated(db, project_id, task_id).await;
            if let Some(app) = app {
                let _ = app.emit("task_updated", json!({"task_id": task_id_str}));
            }
        }
    }
    Ok(())
}

pub(crate) async fn append_event(
    db: &Db,
    project_id: Uuid,
    task_id: Option<Uuid>,
    session_id: Option<Uuid>,
    source: &str,
    event_type: &str,
    payload: serde_json::Value,
) {
    let _ = db
        .append_event(NewEvent {
            id: Uuid::new_v4().to_string(),
            project_id: project_id.to_string(),
            task_id: task_id.map(|v| v.to_string()),
            session_id: session_id.map(|v| v.to_string()),
            trace_id: Uuid::new_v4().to_string(),
            source: source.to_string(),
            event_type: event_type.to_string(),
            payload,
        })
        .await;
}

async fn ensure_default_panes(db: &Db, project_id: Uuid) -> Result<(), String> {
    let existing = db
        .list_panes(&project_id.to_string())
        .await
        .map_err(|e| e.to_string())?;
    if !existing.is_empty() {
        return Ok(());
    }

    db.upsert_pane(&PaneRow {
        id: "pane-board".to_string(),
        project_id: project_id.to_string(),
        session_id: None,
        r#type: "task-board".to_string(),
        position: "root".to_string(),
        label: "Task Board".to_string(),
        metadata_json: None,
    })
    .await
    .map_err(|e| e.to_string())?;

    Ok(())
}

fn spawn_session_bridge(app: AppHandle, db: Db, sessions: SessionSupervisor, project_id: Uuid) {
    let mut rx = sessions.subscribe();
    tauri::async_runtime::spawn(async move {
        while let Ok(event) = rx.recv().await {
            match event {
                SessionEvent::Spawned(meta) => {
                    let row = session_row_from_meta(&meta);
                    let _ = db.upsert_session(&row).await;
                    let _ = app.emit(
                        "session_spawned",
                        json!({"session_id": meta.id, "name": meta.name}),
                    );
                    append_event(
                        &db,
                        project_id,
                        None,
                        Some(meta.id),
                        "session",
                        "SessionSpawned",
                        json!({"name": meta.name, "cwd": meta.cwd}),
                    )
                    .await;
                }
                SessionEvent::Output { session_id, chunk } => {
                    let _ = app.emit(
                        "session_output",
                        json!({"session_id": session_id, "chunk": chunk}),
                    );
                }
                SessionEvent::Heartbeat { session_id, health } => {
                    if let Some(meta) = sessions.get(session_id).await {
                        let _ = db.upsert_session(&session_row_from_meta(&meta)).await;
                    }
                    let _ = app.emit(
                        "session_heartbeat",
                        json!({"session_id": session_id, "health": format!("{:?}", health)}),
                    );
                }
                SessionEvent::Exited { session_id, code } => {
                    if let Some(meta) = sessions.get(session_id).await {
                        let _ = db.upsert_session(&session_row_from_meta(&meta)).await;
                    }
                    let _ = app.emit(
                        "session_exited",
                        json!({"session_id": session_id, "code": code}),
                    );
                    append_event(
                        &db,
                        project_id,
                        None,
                        Some(session_id),
                        "session",
                        "SessionExited",
                        json!({"exit_code": code}),
                    )
                    .await;
                }
            }
        }
    });
}

#[tauri::command]
pub async fn open_project(
    path: String,
    app: AppHandle,
    state: State<'_, AppState>,
) -> Result<String, String> {
    let path_buf = PathBuf::from(path.clone());
    let config_path = path_buf.join("pnevma.toml");
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

    let sessions = SessionSupervisor::new(path_buf.join(".pnevma/data"));
    let adapters = pnevma_agents::AdapterRegistry::detect();
    let pool = DispatchPool::new(cfg.agents.max_concurrent);
    let git = Arc::new(GitService::new(&path_buf));
    spawn_session_bridge(app.clone(), db.clone(), sessions.clone(), project_id);
    {
        let sessions = sessions.clone();
        tokio::spawn(async move {
            let mut ticker = tokio::time::interval(std::time::Duration::from_secs(30));
            loop {
                ticker.tick().await;
                sessions.refresh_health().await;
            }
        });
    }

    let session_rows = reconcile_persisted_sessions(&db, project_id, path_buf.as_path()).await?;
    let restore_root = path_buf.join(".pnevma/data");
    for row in session_rows {
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

    let ctx = ProjectContext {
        project_id,
        project_path: path_buf.clone(),
        config: cfg.clone(),
        global_config: global_cfg.clone(),
        db: db.clone(),
        sessions: sessions.clone(),
        git,
        adapters,
        pool,
    };

    {
        let mut current = state.current.lock().await;
        *current = Some(ctx);
    }

    if let Err(err) =
        restart_control_plane(&app, state.inner(), path_buf.as_path(), &cfg, &global_cfg).await
    {
        let mut current = state.current.lock().await;
        *current = None;
        return Err(err);
    }

    {
        let mut recents = state.recents.lock().await;
        recents.retain(|r| r.path != path);
        recents.insert(
            0,
            RecentProject {
                id: project_id.to_string(),
                name: cfg.project.name.clone(),
                path,
            },
        );
        recents.truncate(20);
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

    Ok(project_id.to_string())
}

#[tauri::command]
pub async fn close_project(state: State<'_, AppState>) -> Result<(), String> {
    let (db, project_id) = {
        let current = state.current.lock().await;
        let Some(ctx) = current.as_ref() else {
            return {
                drop(current);
                stop_control_plane(state.inner()).await;
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
    stop_control_plane(state.inner()).await;
    Ok(())
}

#[tauri::command]
pub async fn list_recent_projects(
    state: State<'_, AppState>,
) -> Result<Vec<RecentProject>, String> {
    Ok(state.recents.lock().await.clone())
}

#[tauri::command]
pub async fn create_session(
    input: SessionInput,
    state: State<'_, AppState>,
) -> Result<String, String> {
    let current = state.current.lock().await;
    let ctx = current
        .as_ref()
        .ok_or_else(|| "no open project".to_string())?;
    let cwd = if Path::new(&input.cwd).is_relative() {
        ctx.project_path
            .join(&input.cwd)
            .to_string_lossy()
            .to_string()
    } else {
        input.cwd.clone()
    };

    let session = ctx
        .sessions
        .spawn_shell(
            ctx.project_id,
            input.name.clone(),
            cwd.clone(),
            input.command.clone(),
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

#[tauri::command]
pub async fn list_sessions(state: State<'_, AppState>) -> Result<Vec<SessionRow>, String> {
    let current = state.current.lock().await;
    let ctx = current
        .as_ref()
        .ok_or_else(|| "no open project".to_string())?;
    ctx.db
        .list_sessions(&ctx.project_id.to_string())
        .await
        .map_err(|e| e.to_string())
}

#[tauri::command]
pub async fn restart_session(
    session_id: String,
    state: State<'_, AppState>,
) -> Result<String, String> {
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
        let _ = ctx.sessions.kill_session_backend(old_id).await;
        let _ = ctx.sessions.mark_exit(old_id, None).await;
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

#[tauri::command]
pub async fn send_session_input(
    session_id: String,
    input: String,
    state: State<'_, AppState>,
) -> Result<(), String> {
    let current = state.current.lock().await;
    let ctx = current
        .as_ref()
        .ok_or_else(|| "no open project".to_string())?;
    let session_id = Uuid::parse_str(&session_id).map_err(|e| e.to_string())?;
    ctx.sessions
        .send_input(session_id, &input)
        .await
        .map_err(|e| e.to_string())
}

#[tauri::command]
pub async fn get_scrollback(
    input: ScrollbackInput,
    state: State<'_, AppState>,
) -> Result<ScrollbackSlice, String> {
    let current = state.current.lock().await;
    let ctx = current
        .as_ref()
        .ok_or_else(|| "no open project".to_string())?;
    let session_id = Uuid::parse_str(&input.session_id).map_err(|e| e.to_string())?;

    ctx.sessions
        .read_scrollback(
            session_id,
            input.offset.unwrap_or(0),
            input.limit.unwrap_or(64 * 1024),
        )
        .await
        .map_err(|e| e.to_string())
}

#[tauri::command]
pub async fn restore_sessions(state: State<'_, AppState>) -> Result<Vec<SessionRow>, String> {
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

#[tauri::command]
pub async fn reattach_session(
    session_id: String,
    state: State<'_, AppState>,
) -> Result<(), String> {
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

#[tauri::command]
pub async fn list_panes(state: State<'_, AppState>) -> Result<Vec<PaneRow>, String> {
    let current = state.current.lock().await;
    let ctx = current
        .as_ref()
        .ok_or_else(|| "no open project".to_string())?;
    ctx.db
        .list_panes(&ctx.project_id.to_string())
        .await
        .map_err(|e| e.to_string())
}

#[tauri::command]
pub async fn upsert_pane(input: PaneInput, state: State<'_, AppState>) -> Result<PaneRow, String> {
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

#[tauri::command]
pub async fn remove_pane(pane_id: String, state: State<'_, AppState>) -> Result<(), String> {
    let current = state.current.lock().await;
    let ctx = current
        .as_ref()
        .ok_or_else(|| "no open project".to_string())?;
    ctx.db
        .remove_pane(&pane_id)
        .await
        .map_err(|e| e.to_string())
}

#[tauri::command]
pub async fn query_events(
    input: QueryEventsInput,
    state: State<'_, AppState>,
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

#[tauri::command]
pub async fn project_status(state: State<'_, AppState>) -> Result<ProjectStatusView, String> {
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

#[tauri::command]
pub async fn create_notification(
    input: NotificationInput,
    app: AppHandle,
    state: State<'_, AppState>,
) -> Result<NotificationView, String> {
    let (db, project_id) = {
        let current = state.current.lock().await;
        let ctx = current
            .as_ref()
            .ok_or_else(|| "no open project".to_string())?;
        (ctx.db.clone(), ctx.project_id)
    };
    let level = input.level.unwrap_or_else(|| "info".to_string());
    let out = NotificationView {
        id: Uuid::new_v4().to_string(),
        title: input.title,
        body: input.body,
        level: level.clone(),
        created_at: Utc::now(),
    };
    append_event(
        &db,
        project_id,
        None,
        None,
        "system",
        "NotificationCreated",
        json!({"id": out.id, "title": out.title, "body": out.body, "level": level}),
    )
    .await;
    let _ = app.emit("notification_created", json!(out.clone()));
    Ok(out)
}

#[tauri::command]
pub async fn list_registered_commands() -> Result<Vec<RegisteredCommand>, String> {
    Ok(default_registry().list())
}

#[tauri::command]
pub async fn execute_registered_command(
    input: ExecuteRegisteredCommandInput,
    app: AppHandle,
    _state: State<'_, AppState>,
) -> Result<serde_json::Value, String> {
    if !default_registry().contains(&input.id) {
        return Err(format!("unknown command id: {}", input.id));
    }

    match input.id.as_str() {
        "project.open" => {
            let path = required_arg(&input.args, "path")?;
            let project_id = open_project(path, app.clone(), app.state::<AppState>()).await?;
            let status = project_status(app.state::<AppState>()).await?;
            Ok(json!({"project_id": project_id, "status": status}))
        }
        "session.new" => {
            let name = optional_arg(&input.args, "name").unwrap_or_else(|| "session".to_string());
            let cwd = optional_arg(&input.args, "cwd").unwrap_or_else(|| ".".to_string());
            let command = optional_arg(&input.args, "command").unwrap_or_else(|| "zsh".to_string());
            let active_pane_id = optional_arg(&input.args, "active_pane_id");
            let session_id = create_session(
                SessionInput {
                    name: name.clone(),
                    cwd,
                    command,
                },
                app.state::<AppState>(),
            )
            .await?;
            let position = active_pane_id
                .map(|id| format!("after:{id}"))
                .unwrap_or_else(|| "after:root".to_string());
            let pane = upsert_pane(
                PaneInput {
                    id: None,
                    session_id: Some(session_id.clone()),
                    r#type: "terminal".to_string(),
                    position,
                    label: name,
                    metadata_json: None,
                },
                app.state::<AppState>(),
            )
            .await?;
            Ok(json!({"session_id": session_id, "pane_id": pane.id}))
        }
        "session.reattach_active" => {
            let active_session_id = required_arg(&input.args, "active_session_id")?;
            reattach_session(active_session_id.clone(), app.state::<AppState>()).await?;
            Ok(json!({"session_id": active_session_id}))
        }
        "session.restart_active" => {
            let active_session_id = required_arg(&input.args, "active_session_id")?;
            let active_pane_id = required_arg(&input.args, "active_pane_id")?;
            let new_session_id =
                restart_session(active_session_id.clone(), app.state::<AppState>()).await?;
            if let Some(active) = list_panes(app.state::<AppState>())
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
                    app.state::<AppState>(),
                )
                .await?;
            }
            Ok(json!({"old_session_id": active_session_id, "new_session_id": new_session_id}))
        }
        "pane.split_horizontal" | "pane.split_vertical" => {
            let suffix = if input.id.ends_with("horizontal") {
                ":h"
            } else {
                ":v"
            };
            let active_pane_id = optional_arg(&input.args, "active_pane_id");
            let panes = list_panes(app.state::<AppState>()).await?;
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
                app.state::<AppState>(),
            )
            .await?;
            Ok(json!({"pane_id": new_pane.id}))
        }
        "pane.close" => {
            let active_pane_id = required_arg(&input.args, "active_pane_id")?;
            let panes = list_panes(app.state::<AppState>()).await?;
            let active = panes
                .into_iter()
                .find(|pane| pane.id == active_pane_id)
                .ok_or_else(|| format!("pane not found: {active_pane_id}"))?;
            if active.r#type == "task-board" {
                return Ok(json!({"closed": false, "reason": "task-board"}));
            }
            remove_pane(active.id.clone(), app.state::<AppState>()).await?;
            Ok(json!({"closed": true, "pane_id": active.id}))
        }
        "pane.open_review" => {
            let active_pane_id = optional_arg(&input.args, "active_pane_id");
            let position = active_pane_id
                .map(|id| format!("after:{id}"))
                .unwrap_or_else(|| "after:root".to_string());
            let pane = upsert_pane(
                PaneInput {
                    id: None,
                    session_id: None,
                    r#type: "review".to_string(),
                    position,
                    label: "Review".to_string(),
                    metadata_json: None,
                },
                app.state::<AppState>(),
            )
            .await?;
            Ok(json!({"pane_id": pane.id}))
        }
        "task.new" => {
            let title = optional_arg(&input.args, "title").unwrap_or_else(|| "Task".to_string());
            let goal =
                optional_arg(&input.args, "goal").unwrap_or_else(|| "Ship value".to_string());
            let priority =
                optional_arg(&input.args, "priority").unwrap_or_else(|| "P1".to_string());
            let id = create_task(
                CreateTaskInput {
                    title,
                    goal,
                    scope: Vec::new(),
                    acceptance_criteria: vec!["manual review".to_string()],
                    constraints: Vec::new(),
                    dependencies: Vec::new(),
                    priority,
                },
                app.clone(),
                app.state::<AppState>(),
            )
            .await?;
            Ok(json!({"task_id": id}))
        }
        "task.delete_ready" => {
            let ready = list_tasks(app.state::<AppState>())
                .await?
                .into_iter()
                .find(|task| task.status == "Ready");
            let Some(ready) = ready else {
                return Ok(json!({"deleted": false}));
            };
            delete_task(ready.id.clone(), app.clone(), app.state::<AppState>()).await?;
            Ok(json!({"deleted": true, "task_id": ready.id}))
        }
        _ => Err(format!("command not implemented: {}", input.id)),
    }
}

#[tauri::command]
pub async fn create_task(
    input: CreateTaskInput,
    app: AppHandle,
    state: State<'_, AppState>,
) -> Result<String, String> {
    let (project_id, db, project_path) = {
        let current = state.current.lock().await;
        let ctx = current
            .as_ref()
            .ok_or_else(|| "no open project".to_string())?;
        (ctx.project_id, ctx.db.clone(), ctx.project_path.clone())
    };

    let id = Uuid::new_v4();
    let now = Utc::now();
    let deps = input
        .dependencies
        .iter()
        .filter_map(|dep| Uuid::parse_str(dep).ok())
        .collect::<Vec<_>>();

    let mut task = TaskContract {
        id,
        title: input.title.clone(),
        goal: input.goal.clone(),
        scope: input.scope.clone(),
        out_of_scope: Vec::new(),
        dependencies: deps,
        acceptance_criteria: input
            .acceptance_criteria
            .iter()
            .map(|description| Check {
                description: description.clone(),
                check_type: CheckType::ManualApproval,
                command: None,
            })
            .collect(),
        constraints: input.constraints.clone(),
        priority: map_priority(&input.priority),
        status: TaskStatus::Planned,
        assigned_session: None,
        branch: None,
        worktree: None,
        prompt_pack: None,
        handoff_summary: None,
        created_at: now,
        updated_at: now,
    };

    task.validate_new().map_err(|e| e.to_string())?;
    let existing = db
        .list_tasks(&project_id.to_string())
        .await
        .map_err(|e| e.to_string())?;
    let completed = existing
        .iter()
        .filter(|row| row.status == "Done")
        .filter_map(|row| Uuid::parse_str(&row.id).ok())
        .collect::<HashSet<_>>();
    task.refresh_blocked_status(&completed);

    if task.status == TaskStatus::Ready {
        if task.acceptance_criteria.is_empty() {
            return Err("task must include at least one acceptance criterion".to_string());
        }
        for rel in &task.scope {
            if !project_path.join(rel).exists() {
                return Err(format!("scope file does not exist: {rel}"));
            }
        }
    }

    let row = task_contract_to_row(&task, &project_id.to_string())?;
    db.create_task(&row).await.map_err(|e| e.to_string())?;
    db.replace_task_dependencies(
        &row.id,
        &task
            .dependencies
            .iter()
            .map(ToString::to_string)
            .collect::<Vec<_>>(),
    )
    .await
    .map_err(|e| e.to_string())?;
    append_event(
        &db,
        project_id,
        Some(id),
        None,
        "core",
        "TaskCreated",
        json!({"title": row.title}),
    )
    .await;
    refresh_dependency_states(&db, project_id, Some(&app)).await?;
    let _ = app.emit("task_updated", json!({"task_id": id.to_string()}));

    Ok(id.to_string())
}

#[tauri::command]
pub async fn list_tasks(state: State<'_, AppState>) -> Result<Vec<TaskView>, String> {
    let (project_id, db) = {
        let current = state.current.lock().await;
        let ctx = current
            .as_ref()
            .ok_or_else(|| "no open project".to_string())?;
        (ctx.project_id, ctx.db.clone())
    };

    let rows = db
        .list_tasks(&project_id.to_string())
        .await
        .map_err(|e| e.to_string())?;
    let mut out = Vec::with_capacity(rows.len());
    for row in rows {
        let cost = db.task_cost_total(&row.id).await.ok();
        out.push(task_row_to_view(row, cost)?);
    }
    Ok(out)
}

#[tauri::command]
pub async fn get_task(task_id: String, state: State<'_, AppState>) -> Result<TaskView, String> {
    let db = {
        let current = state.current.lock().await;
        let ctx = current
            .as_ref()
            .ok_or_else(|| "no open project".to_string())?;
        ctx.db.clone()
    };
    let row = db
        .get_task(&task_id)
        .await
        .map_err(|e| e.to_string())?
        .ok_or_else(|| format!("task not found: {task_id}"))?;
    let cost = db.task_cost_total(&task_id).await.ok();
    task_row_to_view(row, cost)
}

#[tauri::command]
pub async fn update_task(
    input: UpdateTaskInput,
    app: AppHandle,
    state: State<'_, AppState>,
) -> Result<TaskView, String> {
    let (project_id, db, project_path, git) = {
        let current = state.current.lock().await;
        let ctx = current
            .as_ref()
            .ok_or_else(|| "no open project".to_string())?;
        (
            ctx.project_id,
            ctx.db.clone(),
            ctx.project_path.clone(),
            ctx.git.clone(),
        )
    };

    let existing = db
        .get_task(&input.id)
        .await
        .map_err(|e| e.to_string())?
        .ok_or_else(|| format!("task not found: {}", input.id))?;
    let mut task = task_row_to_contract(&existing)?;
    let previous_status = task.status.clone();

    if let Some(title) = input.title {
        task.title = title;
    }
    if let Some(goal) = input.goal {
        task.goal = goal;
    }
    if let Some(scope) = input.scope {
        task.scope = scope;
    }
    if let Some(criteria) = input.acceptance_criteria {
        task.acceptance_criteria = criteria
            .into_iter()
            .map(|description| Check {
                description,
                check_type: CheckType::ManualApproval,
                command: None,
            })
            .collect();
    }
    if let Some(constraints) = input.constraints {
        task.constraints = constraints;
    }
    if let Some(priority) = input.priority {
        task.priority = map_priority(&priority);
    }
    if let Some(handoff) = input.handoff_summary {
        task.handoff_summary = Some(handoff);
    }
    if let Some(dependencies) = input.dependencies {
        task.dependencies = dependencies
            .into_iter()
            .filter_map(|dep| Uuid::parse_str(&dep).ok())
            .collect();
    }
    if let Some(status) = input.status {
        let target = parse_status(&status);
        if target != task.status {
            task.transition(target).map_err(|e| e.to_string())?;
        }
    }

    if task.status == TaskStatus::Ready {
        if task.acceptance_criteria.is_empty() {
            return Err("acceptance_criteria is required before Ready".to_string());
        }
        for rel in &task.scope {
            if !project_path.join(rel).exists() {
                return Err(format!("scope file does not exist: {rel}"));
            }
        }
    }

    let all = db
        .list_tasks(&project_id.to_string())
        .await
        .map_err(|e| e.to_string())?;
    let completed = all
        .iter()
        .filter(|row| row.status == "Done")
        .filter_map(|row| Uuid::parse_str(&row.id).ok())
        .collect::<HashSet<_>>();
    task.refresh_blocked_status(&completed);
    task.validate_new().map_err(|e| e.to_string())?;
    task.updated_at = Utc::now();

    let row = task_contract_to_row(&task, &project_id.to_string())?;
    db.update_task(&row).await.map_err(|e| e.to_string())?;
    db.replace_task_dependencies(
        &row.id,
        &task
            .dependencies
            .iter()
            .map(ToString::to_string)
            .collect::<Vec<_>>(),
    )
    .await
    .map_err(|e| e.to_string())?;
    refresh_dependency_states(&db, project_id, Some(&app)).await?;
    emit_task_updated(&db, project_id, task.id).await;
    let _ = app.emit("task_updated", json!({"task_id": row.id}));
    if previous_status != task.status && is_terminal_task_status(&task.status) {
        cleanup_task_worktree(&db, &git, project_id, task.id, Some(&app)).await?;
    }
    task_row_to_view(row.clone(), db.task_cost_total(&row.id).await.ok())
}

#[tauri::command]
pub async fn delete_task(
    task_id: String,
    app: AppHandle,
    state: State<'_, AppState>,
) -> Result<(), String> {
    let (project_id, db, git) = {
        let current = state.current.lock().await;
        let ctx = current
            .as_ref()
            .ok_or_else(|| "no open project".to_string())?;
        (ctx.project_id, ctx.db.clone(), ctx.git.clone())
    };

    if let Ok(task_uuid) = Uuid::parse_str(&task_id) {
        let _ = cleanup_task_worktree(&db, &git, project_id, task_uuid, Some(&app)).await;
    }
    db.delete_task(&task_id).await.map_err(|e| e.to_string())?;
    append_event(
        &db,
        project_id,
        Uuid::parse_str(&task_id).ok(),
        None,
        "core",
        "TaskDeleted",
        json!({"task_id": task_id}),
    )
    .await;
    refresh_dependency_states(&db, project_id, Some(&app)).await?;
    let _ = app.emit("task_updated", json!({"task_id": task_id, "deleted": true}));
    Ok(())
}

#[tauri::command]
pub async fn dispatch_task(
    task_id: String,
    app: AppHandle,
    state: State<'_, AppState>,
) -> Result<String, String> {
    let (project_id, db, project_path, config, global_config, pool, adapters, git) = {
        let current = state.current.lock().await;
        let ctx = current
            .as_ref()
            .ok_or_else(|| "no open project".to_string())?;
        (
            ctx.project_id,
            ctx.db.clone(),
            ctx.project_path.clone(),
            ctx.config.clone(),
            ctx.global_config.clone(),
            ctx.pool.clone(),
            ctx.adapters.clone(),
            ctx.git.clone(),
        )
    };

    let task_id_uuid = Uuid::parse_str(&task_id).map_err(|e| e.to_string())?;
    let row = db
        .get_task(&task_id)
        .await
        .map_err(|e| e.to_string())?
        .ok_or_else(|| format!("task not found: {task_id}"))?;
    let mut task = task_row_to_contract(&row)?;
    if task.status != TaskStatus::Ready {
        return Err(format!(
            "task must be Ready before dispatch (current: {})",
            status_to_str(&task.status)
        ));
    }

    let queued = QueuedDispatch {
        task_id: task_id_uuid,
        priority: task.priority.clone(),
    };

    let permit = match pool.try_acquire(queued).await {
        Ok(permit) => permit,
        Err(position) => {
            let _ = app.emit(
                "task_queue_updated",
                json!({"task_id": task_id, "queued_position": position}),
            );
            return Ok(format!("queued:{position}"));
        }
    };

    let preferred_provider = global_config
        .default_provider
        .clone()
        .unwrap_or_else(|| config.agents.default_provider.clone());
    let provider = if adapters.get(&preferred_provider).is_some() {
        preferred_provider
    } else if adapters.get("claude-code").is_some() {
        "claude-code".to_string()
    } else {
        "codex".to_string()
    };

    let adapter = adapters
        .get(&provider)
        .ok_or_else(|| "no available agent adapters found".to_string())?;

    let slug = slugify(&task.title);
    let lease = git
        .create_worktree(task_id_uuid, &config.branches.target, &slug)
        .await
        .map_err(|e| e.to_string())?;
    let worktree_row = WorktreeRow {
        id: lease.id.to_string(),
        project_id: project_id.to_string(),
        task_id: task_id.clone(),
        path: lease.path.clone(),
        branch: lease.branch.clone(),
        lease_status: "Active".to_string(),
        lease_started: lease.started_at,
        last_active: lease.last_active,
    };
    db.upsert_worktree(&worktree_row)
        .await
        .map_err(|e| e.to_string())?;

    task.transition(TaskStatus::InProgress)
        .map_err(|e| e.to_string())?;
    task.branch = Some(lease.branch.clone());
    task.worktree = Some(worktree_row.id.clone());
    let task_row = task_contract_to_row(&task, &project_id.to_string())?;
    db.update_task(&task_row).await.map_err(|e| e.to_string())?;
    emit_task_updated(&db, project_id, task.id).await;
    let _ = app.emit("task_updated", json!({"task_id": task.id}));

    let rules = load_rule_texts(&config, &project_path).await;
    let conventions = load_convention_texts(&config, &project_path).await;
    let token_budget = match provider.as_str() {
        "codex" => config
            .agents
            .codex
            .as_ref()
            .map(|c| c.token_budget)
            .unwrap_or(60_000),
        _ => config
            .agents
            .claude_code
            .as_ref()
            .map(|c| c.token_budget)
            .unwrap_or(80_000),
    };
    let compiler = ContextCompiler::new(ContextCompilerConfig {
        mode: ContextCompileMode::V1,
        token_budget,
    });
    let ctx_result = compiler
        .compile(ContextCompileInput {
            task: task.clone(),
            project_brief: config.project.brief.clone(),
            architecture_notes: String::new(),
            conventions,
            rules: rules.clone(),
            relevant_file_contents: Vec::new(),
            prior_task_summaries: Vec::new(),
        })
        .map_err(|e| e.to_string())?;
    let context_path = PathBuf::from(&lease.path)
        .join(".pnevma")
        .join("task-context.md");
    compiler
        .write_markdown(&ctx_result.markdown, &context_path)
        .map_err(|e| e.to_string())?;

    let timeout_minutes = match provider.as_str() {
        "codex" => config
            .agents
            .codex
            .as_ref()
            .map(|c| c.timeout_minutes)
            .unwrap_or(20),
        _ => config
            .agents
            .claude_code
            .as_ref()
            .map(|c| c.timeout_minutes)
            .unwrap_or(30),
    };
    let model = match provider.as_str() {
        "codex" => config.agents.codex.as_ref().and_then(|c| c.model.clone()),
        _ => config
            .agents
            .claude_code
            .as_ref()
            .and_then(|c| c.model.clone()),
    };

    let handle = adapter
        .spawn(AgentConfig {
            provider: provider.clone(),
            model,
            env: Vec::new(),
            working_dir: lease.path.clone(),
            timeout_minutes,
        })
        .await
        .map_err(|e| e.to_string())?;

    let agent_session_row = SessionRow {
        id: handle.id.to_string(),
        project_id: project_id.to_string(),
        name: format!("agent-{}", task.title),
        r#type: Some("agent".to_string()),
        status: "running".to_string(),
        pid: None,
        cwd: lease.path.clone(),
        command: provider.clone(),
        branch: Some(lease.branch.clone()),
        worktree_id: Some(worktree_row.id.clone()),
        started_at: Utc::now(),
        last_heartbeat: Utc::now(),
    };
    db.upsert_session(&agent_session_row)
        .await
        .map_err(|e| e.to_string())?;
    let pane = PaneRow {
        id: Uuid::new_v4().to_string(),
        project_id: project_id.to_string(),
        session_id: Some(handle.id.to_string()),
        r#type: "terminal".to_string(),
        position: "after:pane-board".to_string(),
        label: format!("Agent {}", task.title),
        metadata_json: Some("{\"read_only\":true}".to_string()),
    };
    db.upsert_pane(&pane).await.map_err(|e| e.to_string())?;
    let _ = app.emit(
        "session_spawned",
        json!({"session_id": handle.id.to_string(), "name": agent_session_row.name}),
    );

    adapter
        .send(
            &handle,
            TaskPayload {
                task_id: task_id_uuid,
                objective: task.goal.clone(),
                constraints: task.constraints.clone(),
                project_rules: rules.clone(),
                worktree_path: lease.path.clone(),
                branch_name: lease.branch.clone(),
                acceptance_checks: task
                    .acceptance_criteria
                    .iter()
                    .map(|check| check.description.clone())
                    .collect(),
                relevant_file_paths: task.scope.clone(),
                prior_context_summary: None,
            },
        )
        .await
        .map_err(|e| e.to_string())?;

    let mut rx = adapter.events(&handle);
    let db_for_task = db.clone();
    let app_for_task = app.clone();
    let git_for_task = git.clone();
    let lease_task_id = task_id_uuid;
    let provider_for_task = provider.clone();
    let session_id = handle.id.to_string();

    tauri::async_runtime::spawn(async move {
        let mut last_summary: Option<String> = None;
        let mut failed = false;

        while let Ok(event) = rx.recv().await {
            match event {
                AgentEvent::OutputChunk(chunk) => {
                    let _ = app_for_task.emit(
                        "session_output",
                        json!({"session_id": session_id, "chunk": chunk}),
                    );
                }
                AgentEvent::ToolUse {
                    name,
                    input,
                    output,
                } => {
                    append_event(
                        &db_for_task,
                        project_id,
                        Some(lease_task_id),
                        None,
                        "agent",
                        "AgentToolUse",
                        json!({"name": name, "input": input, "output": output}),
                    )
                    .await;
                }
                AgentEvent::UsageUpdate {
                    tokens_in,
                    tokens_out,
                    cost_usd,
                } => {
                    let _ = db_for_task
                        .append_cost(&CostRow {
                            id: Uuid::new_v4().to_string(),
                            agent_run_id: None,
                            task_id: lease_task_id.to_string(),
                            session_id: session_id.clone(),
                            provider: provider_for_task.clone(),
                            model: None,
                            tokens_in: tokens_in as i64,
                            tokens_out: tokens_out as i64,
                            estimated_usd: cost_usd,
                            tracked: true,
                            timestamp: Utc::now(),
                        })
                        .await;
                    let _ = app_for_task.emit(
                        "cost_updated",
                        json!({"task_id": lease_task_id.to_string(), "cost_usd": cost_usd}),
                    );
                }
                AgentEvent::Error(message) => {
                    failed = true;
                    last_summary = Some(message);
                    break;
                }
                AgentEvent::Complete { summary } => {
                    last_summary = Some(summary);
                    break;
                }
                AgentEvent::StatusChange(_) => {}
            }
        }
        drop(permit);
        if let Ok(Some(mut row)) = db_for_task.get_task(&lease_task_id.to_string()).await {
            row.handoff_summary = last_summary.clone();
            row.status = if failed {
                "Failed".to_string()
            } else {
                "InProgress".to_string()
            };
            row.updated_at = Utc::now();
            let _ = db_for_task.update_task(&row).await;
            let _ = app_for_task.emit("task_updated", json!({"task_id": row.id}));
        }
        if failed {
            let _ = cleanup_task_worktree(
                &db_for_task,
                &git_for_task,
                project_id,
                lease_task_id,
                Some(&app_for_task),
            )
            .await;
        }
        let _ = app_for_task.emit(
            "pool_updated",
            json!({"state": db_for_task.path().to_string_lossy()}),
        );
        append_event(
            &db_for_task,
            project_id,
            Some(lease_task_id),
            None,
            "agent",
            "AgentComplete",
            json!({"task_id": lease_task_id, "failed": failed}),
        )
        .await;
    });

    Ok("started".to_string())
}

#[tauri::command]
pub async fn list_worktrees(state: State<'_, AppState>) -> Result<Vec<WorktreeView>, String> {
    let (project_id, db) = {
        let current = state.current.lock().await;
        let ctx = current
            .as_ref()
            .ok_or_else(|| "no open project".to_string())?;
        (ctx.project_id, ctx.db.clone())
    };

    let rows = db
        .list_worktrees(&project_id.to_string())
        .await
        .map_err(|e| e.to_string())?;
    Ok(rows
        .into_iter()
        .map(|row| WorktreeView {
            id: row.id,
            task_id: row.task_id,
            path: row.path,
            branch: row.branch,
            lease_status: row.lease_status,
            lease_started: row.lease_started,
            last_active: row.last_active,
        })
        .collect())
}

#[tauri::command]
pub async fn cleanup_worktree(
    task_id: String,
    app: AppHandle,
    state: State<'_, AppState>,
) -> Result<(), String> {
    let (project_id, db, git) = {
        let current = state.current.lock().await;
        let ctx = current
            .as_ref()
            .ok_or_else(|| "no open project".to_string())?;
        (ctx.project_id, ctx.db.clone(), ctx.git.clone())
    };

    let task_uuid = Uuid::parse_str(&task_id).map_err(|e| e.to_string())?;
    cleanup_task_worktree(&db, &git, project_id, task_uuid, Some(&app)).await
}

#[tauri::command]
pub async fn get_task_cost(task_id: String, state: State<'_, AppState>) -> Result<f64, String> {
    let current = state.current.lock().await;
    let ctx = current
        .as_ref()
        .ok_or_else(|| "no open project".to_string())?;
    ctx.db
        .task_cost_total(&task_id)
        .await
        .map_err(|e| e.to_string())
}

#[tauri::command]
pub async fn get_project_cost(
    project_id: String,
    state: State<'_, AppState>,
) -> Result<f64, String> {
    let current = state.current.lock().await;
    let ctx = current
        .as_ref()
        .ok_or_else(|| "no open project".to_string())?;

    let id = if project_id.is_empty() {
        ctx.project_id.to_string()
    } else {
        project_id
    };

    ctx.db
        .project_cost_total(&id)
        .await
        .map_err(|e| e.to_string())
}

#[tauri::command]
pub async fn pool_state(state: State<'_, AppState>) -> Result<(usize, usize, usize), String> {
    let current = state.current.lock().await;
    let ctx = current
        .as_ref()
        .ok_or_else(|| "no open project".to_string())?;
    Ok(ctx.pool.state().await)
}
