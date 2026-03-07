use crate::auth_secret::load_socket_password;
use crate::commands;
use crate::state::AppState;
use pnevma_context::redact_secrets;
use pnevma_core::{GlobalConfig, ProjectConfig};
use pnevma_db::NewEvent;
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use std::path::{Path, PathBuf};
use std::sync::Arc;
use uuid::Uuid;

const MAX_CONTROL_REQUEST_ID_BYTES: usize = 128;
const MAX_CONTROL_METHOD_BYTES: usize = 128;

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ControlRequest {
    pub id: String,
    pub method: String,
    #[serde(default)]
    pub params: Value,
    #[serde(default)]
    pub auth: Option<ControlAuthEnvelope>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ControlAuthEnvelope {
    #[serde(default)]
    pub password: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ControlError {
    pub code: String,
    pub message: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ControlResponse {
    pub id: String,
    pub ok: bool,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub result: Option<Value>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub error: Option<ControlError>,
}

impl ControlResponse {
    fn ok(id: String, result: Value) -> Self {
        Self {
            id,
            ok: true,
            result: Some(result),
            error: None,
        }
    }

    fn err(id: String, code: &str, message: impl Into<String>) -> Self {
        Self {
            id,
            ok: false,
            result: None,
            error: Some(ControlError {
                code: code.to_string(),
                message: message.into(),
            }),
        }
    }
}

#[derive(Debug, Clone)]
pub enum ControlAuthMode {
    SameUser,
    Password { password: String },
}

#[derive(Debug, Clone)]
pub struct ControlPlaneSettings {
    pub enabled: bool,
    pub socket_path: PathBuf,
    pub auth_mode: ControlAuthMode,
}

pub fn resolve_control_plane_settings(
    project_root: &Path,
    project: &ProjectConfig,
    global: &GlobalConfig,
) -> Result<ControlPlaneSettings, String> {
    let socket_path = if Path::new(&project.automation.socket_path).is_absolute() {
        PathBuf::from(&project.automation.socket_path)
    } else {
        project_root.join(&project.automation.socket_path)
    };
    let auth_mode_name = global
        .socket_auth_mode
        .clone()
        .unwrap_or_else(|| project.automation.socket_auth.clone());
    let auth_mode = match auth_mode_name.as_str() {
        "same-user" => ControlAuthMode::SameUser,
        "password" => {
            let password = load_socket_password(global.socket_password_file.as_deref())?
                .ok_or_else(|| {
                    format!(
                        "socket auth mode is password but no password is configured (set PNEVMA_SOCKET_PASSWORD, store Keychain item {}/{}, or provide socket_password_file with mode 0600)",
                        crate::auth_secret::SOCKET_KEYCHAIN_SERVICE,
                        crate::auth_secret::SOCKET_KEYCHAIN_ACCOUNT
                    )
                })?;
            ControlAuthMode::Password { password }
        }
        other => {
            return Err(format!(
                "unsupported socket auth mode '{other}', expected same-user or password"
            ));
        }
    };

    Ok(ControlPlaneSettings {
        enabled: project.automation.socket_enabled,
        socket_path,
        auth_mode,
    })
}

pub struct ControlServerHandle {
    socket_path: PathBuf,
    shutdown_tx: tokio::sync::oneshot::Sender<()>,
    join: tokio::task::JoinHandle<()>,
}

impl ControlServerHandle {
    pub fn socket_path(&self) -> &Path {
        &self.socket_path
    }

    pub async fn shutdown(self) {
        let _ = self.shutdown_tx.send(());
        let _ = self.join.await;
    }
}

#[cfg(unix)]
pub async fn start_control_plane(
    state: Arc<AppState>,
    settings: ControlPlaneSettings,
) -> Result<Option<ControlServerHandle>, String> {
    use std::os::unix::fs::PermissionsExt;
    use tokio::net::UnixListener;

    if !settings.enabled {
        return Ok(None);
    }

    if let Some(parent) = settings.socket_path.parent() {
        tokio::fs::create_dir_all(parent)
            .await
            .map_err(|e| e.to_string())?;
    }
    if settings.socket_path.exists() {
        tokio::fs::remove_file(&settings.socket_path)
            .await
            .map_err(|e| e.to_string())?;
    }

    let listener = UnixListener::bind(&settings.socket_path).map_err(|e| e.to_string())?;
    std::fs::set_permissions(
        &settings.socket_path,
        std::fs::Permissions::from_mode(0o600),
    )
    .map_err(|e| e.to_string())?;

    let socket_path = settings.socket_path.clone();
    let accept_settings = settings.clone();
    let (shutdown_tx, mut shutdown_rx) = tokio::sync::oneshot::channel::<()>();
    let join = tokio::spawn(async move {
        loop {
            tokio::select! {
                _ = &mut shutdown_rx => {
                    break;
                }
                accepted = listener.accept() => {
                    let Ok((stream, _addr)) = accepted else {
                        continue;
                    };
                    let state = Arc::clone(&state);
                    let settings = accept_settings.clone();
                    tokio::spawn(async move {
                        let _ = handle_unix_client(state, settings, stream).await;
                    });
                }
            }
        }
        let _ = tokio::fs::remove_file(&socket_path).await;
    });

    Ok(Some(ControlServerHandle {
        socket_path: settings.socket_path,
        shutdown_tx,
        join,
    }))
}

#[cfg(not(unix))]
pub async fn start_control_plane(
    _state: Arc<AppState>,
    _settings: ControlPlaneSettings,
) -> Result<Option<ControlServerHandle>, String> {
    Ok(None)
}

#[cfg(unix)]
async fn handle_unix_client(
    state: Arc<AppState>,
    settings: ControlPlaneSettings,
    stream: tokio::net::UnixStream,
) -> Result<(), String> {
    use tokio::io::{AsyncBufReadExt, AsyncWriteExt, BufReader};

    verify_same_user_peer(&stream, &settings.auth_mode)?;

    const MAX_LINE_BYTES: usize = 1024 * 1024; // 1 MB

    let (read_half, mut write_half) = stream.into_split();
    let mut reader = BufReader::new(read_half);
    let mut line = String::new();
    loop {
        line.clear();
        let bytes = reader
            .read_line(&mut line)
            .await
            .map_err(|e| e.to_string())?;
        if bytes == 0 {
            break;
        }
        if line.len() > MAX_LINE_BYTES {
            let _ = write_half
                .write_all(b"{\"ok\":false,\"error\":{\"code\":\"payload_too_large\",\"message\":\"request exceeds 1 MB limit\"}}\n")
                .await;
            continue;
        }
        let raw = line.trim_end_matches(['\r', '\n']);
        if raw.is_empty() {
            continue;
        }

        let request = match serde_json::from_str::<ControlRequest>(raw) {
            Ok(req) => req,
            Err(err) => {
                let response =
                    ControlResponse::err(String::new(), "invalid_request", err.to_string());
                let wire = serde_json::to_string(&response).map_err(|e| e.to_string())? + "\n";
                write_half
                    .write_all(wire.as_bytes())
                    .await
                    .map_err(|e| e.to_string())?;
                continue;
            }
        };

        let response = process_request(&state, &settings, request).await;
        let wire = serde_json::to_string(&response).map_err(|e| e.to_string())? + "\n";
        write_half
            .write_all(wire.as_bytes())
            .await
            .map_err(|e| e.to_string())?;
    }
    Ok(())
}

#[cfg(unix)]
fn verify_same_user_peer(
    stream: &tokio::net::UnixStream,
    auth_mode: &ControlAuthMode,
) -> Result<(), String> {
    if !matches!(auth_mode, ControlAuthMode::SameUser) {
        return Ok(());
    }
    let creds = stream.peer_cred().map_err(|e| e.to_string())?;
    let peer_uid = creds.uid();
    // SAFETY: geteuid() is always safe — returns the effective UID of the calling process.
    let self_uid = unsafe { libc::geteuid() } as u32;
    if peer_uid != self_uid {
        return Err("socket peer uid mismatch".to_string());
    }
    Ok(())
}

fn parse_string_param(params: &Value, key: &str) -> Result<String, String> {
    parse_optional_string_param(params, key)
        .filter(|v| !v.trim().is_empty())
        .ok_or_else(|| format!("missing required string param: {key}"))
}

fn parse_string_param_aliases(
    params: &Value,
    keys: &[&str],
    label: &str,
) -> Result<String, String> {
    keys.iter()
        .find_map(|key| parse_optional_string_param(params, key))
        .filter(|v| !v.trim().is_empty())
        .ok_or_else(|| format!("missing required string param: {label}"))
}

fn parse_optional_string_param(params: &Value, key: &str) -> Option<String> {
    params
        .get(key)
        .and_then(Value::as_str)
        .map(ToString::to_string)
}

fn parse_optional_bool_param(params: &Value, key: &str) -> Option<bool> {
    params.get(key).and_then(Value::as_bool)
}

fn parse_optional_i64_param(params: &Value, key: &str) -> Option<i64> {
    params.get(key).and_then(Value::as_i64)
}

fn parse_optional_string_list_param(params: &Value, key: &str) -> Option<Vec<String>> {
    match params.get(key) {
        Some(Value::Array(values)) => Some(
            values
                .iter()
                .filter_map(Value::as_str)
                .map(str::trim)
                .filter(|value| !value.is_empty())
                .map(ToString::to_string)
                .collect(),
        ),
        Some(Value::String(raw)) => Some(
            raw.split(',')
                .map(str::trim)
                .filter(|value| !value.is_empty())
                .map(ToString::to_string)
                .collect(),
        ),
        _ => None,
    }
}

fn validate_control_request(request: &ControlRequest) -> Result<(), String> {
    if request.id.trim().is_empty() {
        return Err("request id must not be empty".to_string());
    }
    if request.id.len() > MAX_CONTROL_REQUEST_ID_BYTES {
        return Err(format!(
            "request id exceeds {MAX_CONTROL_REQUEST_ID_BYTES} byte limit"
        ));
    }
    if !request
        .id
        .chars()
        .all(|c| c.is_ascii_alphanumeric() || matches!(c, '_' | '-' | ':' | '.'))
    {
        return Err("request id contains invalid characters".to_string());
    }

    if request.method.is_empty() {
        return Err("request method must not be empty".to_string());
    }
    if request.method.len() > MAX_CONTROL_METHOD_BYTES {
        return Err(format!(
            "request method exceeds {MAX_CONTROL_METHOD_BYTES} byte limit"
        ));
    }
    if !request
        .method
        .chars()
        .all(|c| c.is_ascii_alphanumeric() || matches!(c, '_' | '-' | '.'))
    {
        return Err("request method contains invalid characters".to_string());
    }

    Ok(())
}

async fn process_request(
    state: &AppState,
    settings: &ControlPlaneSettings,
    request: ControlRequest,
) -> ControlResponse {
    if let Err(err) = validate_control_request(&request) {
        return ControlResponse::err(request.id.clone(), "invalid_request", err);
    }

    let request_id = request.id.clone();
    let method = request.method.clone();
    let params = request.params.clone();

    if let Err(err) = authorize_request(&request, settings) {
        append_automation_audit(
            state,
            "AutomationRequestFailed",
            json!({
                "request_id": request.id,
                "method": method,
                "error": err,
            }),
        )
        .await;
        return ControlResponse::err(request_id, "unauthorized", err);
    }

    let redacted_params = redact_event_params(&params);
    append_automation_audit(
        state,
        "AutomationRequestReceived",
        json!({
            "request_id": request.id,
            "method": method,
            "params": redacted_params,
        }),
    )
    .await;

    let routed = route_method(state, &method, &params).await;
    match routed {
        Ok(result) => {
            append_automation_audit(
                state,
                "AutomationRequestCompleted",
                json!({
                    "request_id": request.id,
                    "method": method,
                }),
            )
            .await;
            ControlResponse::ok(request_id, result)
        }
        Err((code, message)) => {
            append_automation_audit(
                state,
                "AutomationRequestFailed",
                json!({
                    "request_id": request.id,
                    "method": method,
                    "error": message,
                }),
            )
            .await;
            ControlResponse::err(request_id, &code, message)
        }
    }
}

fn authorize_request(
    request: &ControlRequest,
    settings: &ControlPlaneSettings,
) -> Result<(), String> {
    match &settings.auth_mode {
        ControlAuthMode::SameUser => Ok(()),
        ControlAuthMode::Password { password } => {
            let supplied = request
                .auth
                .as_ref()
                .and_then(|auth| auth.password.as_ref())
                .cloned()
                .ok_or_else(|| "missing auth.password".to_string())?;
            use subtle::ConstantTimeEq;
            let supplied_bytes = supplied.as_bytes();
            let password_bytes = password.as_bytes();
            if supplied_bytes.len() == password_bytes.len()
                && supplied_bytes.ct_eq(password_bytes).into()
            {
                Ok(())
            } else {
                Err("invalid password".to_string())
            }
        }
    }
}

pub async fn route_method(
    state: &AppState,
    method: &str,
    params: &Value,
) -> Result<Value, (String, String)> {
    let result = match method {
        "environment.readiness" => {
            let path = parse_optional_string_param(params, "path");
            let readiness = commands::get_environment_readiness(
                Some(commands::EnvironmentReadinessInput { path }),
                state,
            )
            .await
            .map_err(|e| ("internal_error".to_string(), e))?;
            serde_json::to_value(readiness)
                .map_err(|e| ("internal_error".to_string(), e.to_string()))?
        }
        "environment.init_global_config" => {
            let default_provider = parse_optional_string_param(params, "default_provider");
            let result = commands::initialize_global_config(
                Some(commands::InitializeGlobalConfigInput { default_provider }),
                state,
            )
            .await
            .map_err(|e| ("internal_error".to_string(), e))?;
            serde_json::to_value(result)
                .map_err(|e| ("internal_error".to_string(), e.to_string()))?
        }
        "project.initialize_scaffold" => {
            let path = parse_string_param(params, "path")
                .map_err(|e| ("invalid_params".to_string(), e))?;
            let project_name = parse_optional_string_param(params, "project_name");
            let project_brief = parse_optional_string_param(params, "project_brief");
            let default_provider = parse_optional_string_param(params, "default_provider");
            let result = commands::initialize_project_scaffold(
                commands::InitializeProjectScaffoldInput {
                    path,
                    project_name,
                    project_brief,
                    default_provider,
                },
                state,
            )
            .await
            .map_err(|e| ("internal_error".to_string(), e))?;
            serde_json::to_value(result)
                .map_err(|e| ("internal_error".to_string(), e.to_string()))?
        }
        "project.open" => {
            let path = parse_string_param(params, "path")
                .map_err(|e| ("invalid_params".to_string(), e))?;
            let project_id = commands::open_project(path, &state.emitter, state)
                .await
                .map_err(|e| ("internal_error".to_string(), e))?;
            let status = commands::project_status(state)
                .await
                .map_err(|e| ("internal_error".to_string(), e))?;
            serde_json::to_value(commands::ProjectOpenResponse { project_id, status })
                .map_err(|e| ("internal_error".to_string(), e.to_string()))?
        }
        "project.close" => {
            commands::close_project(state)
                .await
                .map_err(|e| ("internal_error".to_string(), e))?;
            serde_json::to_value(commands::OkResponse { ok: true })
                .map_err(|e| ("internal_error".to_string(), e.to_string()))?
        }
        "project.trust" => {
            let path = parse_string_param(params, "path")
                .map_err(|e| ("invalid_params".to_string(), e))?;
            commands::trust_workspace(path)
                .await
                .map_err(|e| ("internal_error".to_string(), e))?;
            serde_json::to_value(commands::OkResponse { ok: true })
                .map_err(|e| ("internal_error".to_string(), e.to_string()))?
        }
        "project.status" => serde_json::to_value(
            commands::project_status(state)
                .await
                .map_err(|e| ("internal_error".to_string(), e))?,
        )
        .map_err(|e| ("internal_error".to_string(), e.to_string()))?,
        "project.summary" => serde_json::to_value(
            commands::project_summary(state)
                .await
                .map_err(|e| ("internal_error".to_string(), e))?,
        )
        .map_err(|e| ("internal_error".to_string(), e.to_string()))?,
        "project.cleanup_data" => serde_json::to_value(
            commands::cleanup_project_data(
                parse_optional_bool_param(params, "dry_run").unwrap_or(false),
                state,
            )
            .await
            .map_err(|e| ("internal_error".to_string(), e))?,
        )
        .map_err(|e| ("internal_error".to_string(), e.to_string()))?,
        "task.create" => {
            let title = parse_string_param(params, "title")
                .map_err(|e| ("invalid_params".to_string(), e))?;
            let goal = parse_string_param(params, "goal")
                .map_err(|e| ("invalid_params".to_string(), e))?;
            let priority =
                parse_optional_string_param(params, "priority").unwrap_or_else(|| "P1".to_string());
            let scope = parse_optional_string_list_param(params, "scope").unwrap_or_default();
            let acceptance_criteria =
                parse_optional_string_list_param(params, "acceptance_criteria")
                    .filter(|items| !items.is_empty())
                    .unwrap_or_else(|| vec!["manual review".to_string()]);
            let constraints =
                parse_optional_string_list_param(params, "constraints").unwrap_or_default();
            let dependencies =
                parse_optional_string_list_param(params, "dependencies").unwrap_or_default();
            let id = commands::create_task(
                commands::CreateTaskInput {
                    title,
                    goal,
                    scope,
                    acceptance_criteria,
                    constraints,
                    dependencies,
                    priority,
                    auto_dispatch: None,
                    agent_profile_override: None,
                    execution_mode: None,
                    timeout_minutes: None,
                    max_retries: None,
                },
                &state.emitter,
                state,
            )
            .await
            .map_err(|e| ("internal_error".to_string(), e))?;
            json!({ "task_id": id })
        }
        "task.list" => serde_json::to_value(
            commands::list_tasks(state)
                .await
                .map_err(|e| ("internal_error".to_string(), e))?,
        )
        .map_err(|e| ("internal_error".to_string(), e.to_string()))?,
        "task.update" => {
            let id = parse_string_param_aliases(params, &["id", "task_id"], "task_id")
                .map_err(|e| ("invalid_params".to_string(), e))?;
            let title = parse_optional_string_param(params, "title");
            let goal = parse_optional_string_param(params, "goal");
            let scope = parse_optional_string_list_param(params, "scope");
            let acceptance_criteria =
                parse_optional_string_list_param(params, "acceptance_criteria");
            let constraints = parse_optional_string_list_param(params, "constraints");
            let dependencies = parse_optional_string_list_param(params, "dependencies");
            let priority = parse_optional_string_param(params, "priority");
            let status = parse_optional_string_param(params, "status");
            let handoff_summary = parse_optional_string_param(params, "handoff_summary");
            let task = commands::update_task(
                commands::UpdateTaskInput {
                    id,
                    title,
                    goal,
                    scope,
                    acceptance_criteria,
                    constraints,
                    dependencies,
                    priority,
                    status,
                    handoff_summary,
                },
                &state.emitter,
                state,
            )
            .await
            .map_err(|e| ("internal_error".to_string(), e))?;
            serde_json::to_value(task).map_err(|e| ("internal_error".to_string(), e.to_string()))?
        }
        "task.dispatch" => {
            let task_id = parse_string_param_aliases(params, &["task_id", "id"], "task_id")
                .map_err(|e| ("invalid_params".to_string(), e))?;
            let status = commands::dispatch_task(task_id, &state.emitter, state)
                .await
                .map_err(|e| ("internal_error".to_string(), e))?;
            serde_json::to_value(commands::TaskDispatchResponse { status })
                .map_err(|e| ("internal_error".to_string(), e.to_string()))?
        }
        "task.dispatch_next_ready" => {
            let next = commands::list_tasks(state)
                .await
                .map_err(|e| ("internal_error".to_string(), e))?
                .into_iter()
                .filter(|task| task.status == "Ready")
                .min_by(|a, b| a.created_at.cmp(&b.created_at))
                .map(|task| task.id);
            if let Some(task_id) = next {
                let status = commands::dispatch_task(task_id.clone(), &state.emitter, state)
                    .await
                    .map_err(|e| ("internal_error".to_string(), e))?;
                json!({"dispatched": true, "task_id": task_id, "status": status})
            } else {
                json!({"dispatched": false})
            }
        }
        "task.poll" => {
            let tasks = commands::list_tasks(state)
                .await
                .map_err(|e| ("internal_error".to_string(), e))?;
            let ready: Vec<_> = tasks.into_iter().filter(|t| t.status == "Ready").collect();
            let pool_state = commands::pool_state(state)
                .await
                .map_err(|e| ("internal_error".to_string(), e))?;
            json!({
                "ready_tasks": ready,
                "pool": pool_state,
            })
        }
        "task.claim" => {
            let task_id = parse_string_param(params, "task_id")
                .map_err(|e| ("invalid_params".to_string(), e))?;
            let status = commands::dispatch_task(task_id, &state.emitter, state)
                .await
                .map_err(|e| ("internal_error".to_string(), e))?;
            json!({ "status": status })
        }
        "workflow.list_defs" => serde_json::to_value(
            commands::list_workflow_defs(state)
                .await
                .map_err(|e| ("internal_error".to_string(), e))?,
        )
        .map_err(|e| ("internal_error".to_string(), e.to_string()))?,
        "workflow.instantiate" => {
            let workflow_name = parse_string_param(params, "workflow_name")
                .map_err(|e| ("invalid_params".to_string(), e))?;
            let result = commands::instantiate_workflow(
                commands::InstantiateWorkflowInput { workflow_name },
                &state.emitter,
                state,
            )
            .await
            .map_err(|e| ("internal_error".to_string(), e))?;
            serde_json::to_value(result)
                .map_err(|e| ("internal_error".to_string(), e.to_string()))?
        }
        "workflow.list_instances" => serde_json::to_value(
            commands::list_workflow_instances(state)
                .await
                .map_err(|e| ("internal_error".to_string(), e))?,
        )
        .map_err(|e| ("internal_error".to_string(), e.to_string()))?,
        "workflow.list" => serde_json::to_value(
            commands::list_workflows(state)
                .await
                .map_err(|e| ("internal_error".to_string(), e))?,
        )
        .map_err(|e| ("internal_error".to_string(), e.to_string()))?,
        "workflow.get" => {
            let id =
                parse_string_param(params, "id").map_err(|e| ("invalid_params".to_string(), e))?;
            serde_json::to_value(
                commands::get_workflow(id, state)
                    .await
                    .map_err(|e| ("internal_error".to_string(), e))?,
            )
            .map_err(|e| ("internal_error".to_string(), e.to_string()))?
        }
        "workflow.create" => {
            let name = parse_string_param(params, "name")
                .map_err(|e| ("invalid_params".to_string(), e))?;
            let definition_yaml = parse_string_param(params, "definition_yaml")
                .map_err(|e| ("invalid_params".to_string(), e))?;
            let description = parse_optional_string_param(params, "description");
            serde_json::to_value(
                commands::create_workflow(
                    commands::CreateWorkflowInput {
                        name,
                        description,
                        definition_yaml,
                    },
                    state,
                )
                .await
                .map_err(|e| ("internal_error".to_string(), e))?,
            )
            .map_err(|e| ("internal_error".to_string(), e.to_string()))?
        }
        "workflow.update" => {
            let id =
                parse_string_param(params, "id").map_err(|e| ("invalid_params".to_string(), e))?;
            let name = parse_optional_string_param(params, "name");
            let description = parse_optional_string_param(params, "description");
            let definition_yaml = parse_optional_string_param(params, "definition_yaml");
            serde_json::to_value(
                commands::update_workflow(
                    commands::UpdateWorkflowInput {
                        id,
                        name,
                        description,
                        definition_yaml,
                    },
                    state,
                )
                .await
                .map_err(|e| ("internal_error".to_string(), e))?,
            )
            .map_err(|e| ("internal_error".to_string(), e.to_string()))?
        }
        "workflow.delete" => {
            let id =
                parse_string_param(params, "id").map_err(|e| ("invalid_params".to_string(), e))?;
            commands::delete_workflow(id, state)
                .await
                .map_err(|e| ("internal_error".to_string(), e))?;
            json!({"ok": true})
        }
        "workflow.dispatch" => {
            let workflow_name = parse_string_param(params, "workflow_name")
                .map_err(|e| ("invalid_params".to_string(), e))?;
            let params_val = params.get("params").cloned();
            let result = commands::dispatch_workflow(
                commands::DispatchWorkflowInput {
                    workflow_name,
                    params: params_val,
                },
                &state.emitter,
                state,
            )
            .await
            .map_err(|e| ("internal_error".to_string(), e))?;
            serde_json::to_value(result)
                .map_err(|e| ("internal_error".to_string(), e.to_string()))?
        }
        "workflow.get_instance" => {
            let id =
                parse_string_param(params, "id").map_err(|e| ("invalid_params".to_string(), e))?;
            serde_json::to_value(
                commands::get_workflow_instance(id, state)
                    .await
                    .map_err(|e| ("internal_error".to_string(), e))?,
            )
            .map_err(|e| ("internal_error".to_string(), e.to_string()))?
        }
        "agent_profile.list" => serde_json::to_value(
            commands::list_agent_profiles(state)
                .await
                .map_err(|e| ("internal_error".to_string(), e))?,
        )
        .map_err(|e| ("internal_error".to_string(), e.to_string()))?,
        "session.new" => {
            let name = parse_optional_string_param(params, "name")
                .unwrap_or_else(|| "session".to_string());
            let cwd = parse_optional_string_param(params, "cwd").unwrap_or_else(|| ".".to_string());
            let command = parse_optional_string_param(params, "command")
                .filter(|s| !s.trim().is_empty())
                .unwrap_or_else(|| "zsh".to_string());
            let session_id =
                commands::create_session(commands::SessionInput { name, cwd, command }, state)
                    .await
                    .map_err(|e| ("internal_error".to_string(), e))?;
            let binding = commands::get_session_binding(session_id.clone(), state)
                .await
                .map_err(|e| ("internal_error".to_string(), e))?;
            serde_json::to_value(commands::SessionNewResponse {
                session_id,
                binding,
            })
            .map_err(|e| ("internal_error".to_string(), e.to_string()))?
        }
        "session.list" => serde_json::to_value(
            commands::list_sessions(state)
                .await
                .map_err(|e| ("internal_error".to_string(), e))?,
        )
        .map_err(|e| ("internal_error".to_string(), e.to_string()))?,
        "session.binding" => {
            let session_id =
                parse_string_param_aliases(params, &["session_id", "id"], "session_id")
                    .map_err(|e| ("invalid_params".to_string(), e))?;
            serde_json::to_value(
                commands::get_session_binding(session_id, state)
                    .await
                    .map_err(|e| ("internal_error".to_string(), e))?,
            )
            .map_err(|e| ("internal_error".to_string(), e.to_string()))?
        }
        "session.send_input" => {
            let session_id =
                parse_string_param_aliases(params, &["session_id", "id"], "session_id")
                    .map_err(|e| ("invalid_params".to_string(), e))?;
            let input = parse_string_param_aliases(params, &["input", "data"], "input")
                .map_err(|e| ("invalid_params".to_string(), e))?;
            commands::send_session_input(session_id, input, state)
                .await
                .map_err(|e| ("internal_error".to_string(), e))?;
            serde_json::to_value(commands::OkResponse { ok: true })
                .map_err(|e| ("internal_error".to_string(), e.to_string()))?
        }
        "session.resize" => {
            let session_id =
                parse_string_param_aliases(params, &["session_id", "id"], "session_id")
                    .map_err(|e| ("invalid_params".to_string(), e))?;
            let cols = parse_optional_i64_param(params, "cols")
                .filter(|value| *value > 0)
                .ok_or_else(|| {
                    (
                        "invalid_params".to_string(),
                        "missing required positive integer param: cols".to_string(),
                    )
                })? as u16;
            let rows = parse_optional_i64_param(params, "rows")
                .filter(|value| *value > 0)
                .ok_or_else(|| {
                    (
                        "invalid_params".to_string(),
                        "missing required positive integer param: rows".to_string(),
                    )
                })? as u16;
            commands::resize_session(session_id, cols, rows, state)
                .await
                .map_err(|e| ("internal_error".to_string(), e))?;
            serde_json::to_value(commands::OkResponse { ok: true })
                .map_err(|e| ("internal_error".to_string(), e.to_string()))?
        }
        "session.scrollback" => {
            let session_id =
                parse_string_param_aliases(params, &["session_id", "id"], "session_id")
                    .map_err(|e| ("invalid_params".to_string(), e))?;
            let offset = parse_optional_i64_param(params, "offset")
                .map(|value| {
                    u64::try_from(value).map_err(|_| {
                        (
                            "invalid_params".to_string(),
                            "offset must be a non-negative integer".to_string(),
                        )
                    })
                })
                .transpose()?;
            let limit = parse_optional_i64_param(params, "limit")
                .map(|value| {
                    usize::try_from(value).map_err(|_| {
                        (
                            "invalid_params".to_string(),
                            "limit must be a non-negative integer".to_string(),
                        )
                    })
                })
                .transpose()?;
            let scrollback = commands::get_scrollback(
                commands::ScrollbackInput {
                    session_id,
                    offset,
                    limit,
                },
                state,
            )
            .await
            .map_err(|e| ("internal_error".to_string(), e))?;
            serde_json::to_value(scrollback)
                .map_err(|e| ("internal_error".to_string(), e.to_string()))?
        }
        "session.timeline" => {
            let session_id = parse_string_param(params, "session_id")
                .map_err(|e| ("invalid_params".to_string(), e))?;
            let limit = parse_optional_i64_param(params, "limit");
            let timeline = commands::get_session_timeline(
                commands::SessionTimelineInput { session_id, limit },
                state,
            )
            .await
            .map_err(|e| ("internal_error".to_string(), e))?;
            serde_json::to_value(timeline)
                .map_err(|e| ("internal_error".to_string(), e.to_string()))?
        }
        "session.recovery.options" => {
            let session_id = parse_string_param(params, "session_id")
                .map_err(|e| ("invalid_params".to_string(), e))?;
            let options = commands::get_session_recovery_options(session_id, state)
                .await
                .map_err(|e| ("internal_error".to_string(), e))?;
            serde_json::to_value(options)
                .map_err(|e| ("internal_error".to_string(), e.to_string()))?
        }
        "session.recovery.execute" => {
            let session_id = parse_string_param(params, "session_id")
                .map_err(|e| ("invalid_params".to_string(), e))?;
            let action = parse_string_param(params, "action")
                .map_err(|e| ("invalid_params".to_string(), e))?;
            let result = commands::recover_session(
                commands::SessionRecoveryInput { session_id, action },
                &state.emitter,
                state,
            )
            .await
            .map_err(|e| ("internal_error".to_string(), e))?;
            result
        }
        "project.daily_brief" => serde_json::to_value(
            commands::get_daily_brief(state)
                .await
                .map_err(|e| ("internal_error".to_string(), e))?,
        )
        .map_err(|e| ("internal_error".to_string(), e.to_string()))?,
        "project.search" => {
            let query = parse_string_param(params, "query")
                .map_err(|e| ("invalid_params".to_string(), e))?;
            let limit = parse_optional_i64_param(params, "limit").map(|v| v.max(1) as usize);
            let items =
                commands::search_project(commands::SearchProjectInput { query, limit }, state)
                    .await
                    .map_err(|e| ("internal_error".to_string(), e))?;
            serde_json::to_value(items)
                .map_err(|e| ("internal_error".to_string(), e.to_string()))?
        }
        "rules.list" => serde_json::to_value(
            commands::list_rules(state)
                .await
                .map_err(|e| ("internal_error".to_string(), e))?,
        )
        .map_err(|e| ("internal_error".to_string(), e.to_string()))?,
        "rules.upsert" => {
            let name = parse_string_param(params, "name")
                .map_err(|e| ("invalid_params".to_string(), e))?;
            let content = parse_string_param(params, "content")
                .map_err(|e| ("invalid_params".to_string(), e))?;
            let id = parse_optional_string_param(params, "id");
            let active = parse_optional_bool_param(params, "active");
            let row = commands::upsert_rule(
                commands::RuleUpsertInput {
                    id,
                    name,
                    content,
                    scope: Some("rule".to_string()),
                    active,
                },
                &state.emitter,
                state,
            )
            .await
            .map_err(|e| ("internal_error".to_string(), e))?;
            serde_json::to_value(row).map_err(|e| ("internal_error".to_string(), e.to_string()))?
        }
        "rules.toggle" => {
            let id =
                parse_string_param(params, "id").map_err(|e| ("invalid_params".to_string(), e))?;
            let active = parse_optional_bool_param(params, "active")
                .ok_or_else(|| ("invalid_params".to_string(), "missing active".to_string()))?;
            let row = commands::toggle_rule(
                commands::RuleToggleInput { id, active },
                &state.emitter,
                state,
            )
            .await
            .map_err(|e| ("internal_error".to_string(), e))?;
            serde_json::to_value(row).map_err(|e| ("internal_error".to_string(), e.to_string()))?
        }
        "rules.delete" => {
            let id =
                parse_string_param(params, "id").map_err(|e| ("invalid_params".to_string(), e))?;
            commands::delete_rule(id, &state.emitter, state)
                .await
                .map_err(|e| ("internal_error".to_string(), e))?;
            json!({"ok": true})
        }
        "rules.usage" => {
            let rule_id = parse_string_param(params, "rule_id")
                .map_err(|e| ("invalid_params".to_string(), e))?;
            let limit = parse_optional_i64_param(params, "limit");
            let rows =
                commands::list_rule_usage(commands::RuleUsageInput { rule_id, limit }, state)
                    .await
                    .map_err(|e| ("internal_error".to_string(), e))?;
            serde_json::to_value(rows).map_err(|e| ("internal_error".to_string(), e.to_string()))?
        }
        "conventions.list" => serde_json::to_value(
            commands::list_conventions(state)
                .await
                .map_err(|e| ("internal_error".to_string(), e))?,
        )
        .map_err(|e| ("internal_error".to_string(), e.to_string()))?,
        "conventions.upsert" => {
            let name = parse_string_param(params, "name")
                .map_err(|e| ("invalid_params".to_string(), e))?;
            let content = parse_string_param(params, "content")
                .map_err(|e| ("invalid_params".to_string(), e))?;
            let id = parse_optional_string_param(params, "id");
            let active = parse_optional_bool_param(params, "active");
            let row = commands::upsert_convention(
                commands::RuleUpsertInput {
                    id,
                    name,
                    content,
                    scope: Some("convention".to_string()),
                    active,
                },
                &state.emitter,
                state,
            )
            .await
            .map_err(|e| ("internal_error".to_string(), e))?;
            serde_json::to_value(row).map_err(|e| ("internal_error".to_string(), e.to_string()))?
        }
        "conventions.toggle" => {
            let id =
                parse_string_param(params, "id").map_err(|e| ("invalid_params".to_string(), e))?;
            let active = parse_optional_bool_param(params, "active")
                .ok_or_else(|| ("invalid_params".to_string(), "missing active".to_string()))?;
            let row = commands::toggle_convention(
                commands::RuleToggleInput { id, active },
                &state.emitter,
                state,
            )
            .await
            .map_err(|e| ("internal_error".to_string(), e))?;
            serde_json::to_value(row).map_err(|e| ("internal_error".to_string(), e.to_string()))?
        }
        "conventions.delete" => {
            let id =
                parse_string_param(params, "id").map_err(|e| ("invalid_params".to_string(), e))?;
            commands::delete_convention(id, &state.emitter, state)
                .await
                .map_err(|e| ("internal_error".to_string(), e))?;
            json!({"ok": true})
        }
        "workspace.files" => {
            let query = parse_optional_string_param(params, "query");
            let limit = parse_optional_i64_param(params, "limit").map(|v| v.max(1) as usize);
            let items = commands::list_project_files(
                Some(commands::ListProjectFilesInput { query, limit }),
                state,
            )
            .await
            .map_err(|e| ("internal_error".to_string(), e))?;
            serde_json::to_value(items)
                .map_err(|e| ("internal_error".to_string(), e.to_string()))?
        }
        "workspace.file.open" => {
            let path = parse_string_param(params, "path")
                .map_err(|e| ("invalid_params".to_string(), e))?;
            let mode = parse_optional_string_param(params, "mode");
            let opened =
                commands::open_file_target(commands::OpenFileTargetInput { path, mode }, state)
                    .await
                    .map_err(|e| ("internal_error".to_string(), e))?;
            serde_json::to_value(opened)
                .map_err(|e| ("internal_error".to_string(), e.to_string()))?
        }
        "notification.create" => {
            let title = parse_string_param(params, "title")
                .map_err(|e| ("invalid_params".to_string(), e))?;
            let body = parse_string_param(params, "body")
                .map_err(|e| ("invalid_params".to_string(), e))?;
            let level = parse_optional_string_param(params, "level");
            let notification = commands::create_notification(
                commands::NotificationInput {
                    title,
                    body,
                    level,
                    task_id: None,
                    session_id: None,
                },
                &state.emitter,
                state,
            )
            .await
            .map_err(|e| ("internal_error".to_string(), e))?;
            serde_json::to_value(notification)
                .map_err(|e| ("internal_error".to_string(), e.to_string()))?
        }
        "notification.list" => {
            let unread_only = parse_optional_bool_param(params, "unread_only").unwrap_or(false);
            let items = commands::list_notifications(
                Some(commands::NotificationListInput { unread_only }),
                state,
            )
            .await
            .map_err(|e| ("internal_error".to_string(), e))?;
            serde_json::to_value(items)
                .map_err(|e| ("internal_error".to_string(), e.to_string()))?
        }
        "notification.mark_read" => {
            let notification_id = parse_string_param(params, "notification_id")
                .map_err(|e| ("invalid_params".to_string(), e))?;
            commands::mark_notification_read(notification_id, &state.emitter, state)
                .await
                .map_err(|e| ("internal_error".to_string(), e))?;
            json!({"ok": true})
        }
        "notification.clear" => {
            commands::clear_notifications(&state.emitter, state)
                .await
                .map_err(|e| ("internal_error".to_string(), e))?;
            json!({"ok": true})
        }
        "review.get_pack" => {
            let task_id = parse_string_param(params, "task_id")
                .map_err(|e| ("invalid_params".to_string(), e))?;
            let review = commands::get_review_pack(task_id, state)
                .await
                .map_err(|e| ("internal_error".to_string(), e))?;
            serde_json::to_value(review)
                .map_err(|e| ("internal_error".to_string(), e.to_string()))?
        }
        "review.diff" => {
            let task_id = parse_string_param(params, "task_id")
                .map_err(|e| ("invalid_params".to_string(), e))?;
            let diff = commands::get_task_diff(commands::TaskDiffInput { task_id }, state)
                .await
                .map_err(|e| ("internal_error".to_string(), e))?;
            serde_json::to_value(diff).map_err(|e| ("internal_error".to_string(), e.to_string()))?
        }
        "artifact.capture" => {
            let kind = parse_string_param(params, "kind")
                .map_err(|e| ("invalid_params".to_string(), e))?;
            let content = parse_string_param(params, "content")
                .map_err(|e| ("invalid_params".to_string(), e))?;
            let task_id = parse_optional_string_param(params, "task_id");
            let title = parse_optional_string_param(params, "title");
            let artifact = commands::capture_knowledge(
                commands::KnowledgeCaptureInput {
                    task_id,
                    kind,
                    title,
                    content,
                },
                &state.emitter,
                state,
            )
            .await
            .map_err(|e| ("internal_error".to_string(), e))?;
            serde_json::to_value(artifact)
                .map_err(|e| ("internal_error".to_string(), e.to_string()))?
        }
        "artifact.list" => serde_json::to_value(
            commands::list_artifacts(state)
                .await
                .map_err(|e| ("internal_error".to_string(), e))?,
        )
        .map_err(|e| ("internal_error".to_string(), e.to_string()))?,
        "review.approve" => {
            let task_id = parse_string_param(params, "task_id")
                .map_err(|e| ("invalid_params".to_string(), e))?;
            let note = parse_optional_string_param(params, "note");
            commands::approve_review(
                commands::ReviewDecisionInput { task_id, note },
                &state.emitter,
                state,
            )
            .await
            .map_err(|e| ("internal_error".to_string(), e))?;
            json!({"ok": true})
        }
        "review.approve_next" => {
            let next = commands::list_tasks(state)
                .await
                .map_err(|e| ("internal_error".to_string(), e))?
                .into_iter()
                .filter(|task| task.status == "Review")
                .min_by(|a, b| a.created_at.cmp(&b.created_at))
                .map(|task| task.id);
            if let Some(task_id) = next {
                commands::approve_review(
                    commands::ReviewDecisionInput {
                        task_id: task_id.clone(),
                        note: Some("approved via quick action".to_string()),
                    },
                    &state.emitter,
                    state,
                )
                .await
                .map_err(|e| ("internal_error".to_string(), e))?;
                json!({"approved": true, "task_id": task_id})
            } else {
                json!({"approved": false})
            }
        }
        "review.reject" => {
            let task_id = parse_string_param(params, "task_id")
                .map_err(|e| ("invalid_params".to_string(), e))?;
            let note = parse_optional_string_param(params, "note");
            commands::reject_review(
                commands::ReviewDecisionInput { task_id, note },
                &state.emitter,
                state,
            )
            .await
            .map_err(|e| ("internal_error".to_string(), e))?;
            json!({"ok": true})
        }
        "merge.queue.list" => {
            let items = commands::list_merge_queue(state)
                .await
                .map_err(|e| ("internal_error".to_string(), e))?;
            serde_json::to_value(items)
                .map_err(|e| ("internal_error".to_string(), e.to_string()))?
        }
        "merge.queue.execute" => {
            let task_id = parse_string_param(params, "task_id")
                .map_err(|e| ("invalid_params".to_string(), e))?;
            commands::merge_queue_execute(task_id, &state.emitter, state)
                .await
                .map_err(|e| ("internal_error".to_string(), e))?;
            json!({"ok": true})
        }
        "merge.queue.reorder" => {
            let task_id = parse_string_param(params, "task_id")
                .map_err(|e| ("invalid_params".to_string(), e))?;
            let direction = parse_string_param(params, "direction")
                .map_err(|e| ("invalid_params".to_string(), e))?;
            let items = commands::move_merge_queue_item(
                commands::MoveMergeQueueInput { task_id, direction },
                &state.emitter,
                state,
            )
            .await
            .map_err(|e| ("internal_error".to_string(), e))?;
            serde_json::to_value(items)
                .map_err(|e| ("internal_error".to_string(), e.to_string()))?
        }
        "checkpoint.create" => {
            let description = parse_optional_string_param(params, "description");
            let task_id = parse_optional_string_param(params, "task_id");
            let checkpoint = commands::checkpoint_create(
                commands::CheckpointInput {
                    description,
                    task_id,
                },
                state,
            )
            .await
            .map_err(|e| ("internal_error".to_string(), e))?;
            serde_json::to_value(checkpoint)
                .map_err(|e| ("internal_error".to_string(), e.to_string()))?
        }
        "checkpoint.list" => {
            let checkpoints = commands::checkpoint_list(state)
                .await
                .map_err(|e| ("internal_error".to_string(), e))?;
            serde_json::to_value(checkpoints)
                .map_err(|e| ("internal_error".to_string(), e.to_string()))?
        }
        "checkpoint.restore" => {
            let checkpoint_id = parse_string_param(params, "checkpoint_id")
                .map_err(|e| ("invalid_params".to_string(), e))?;
            commands::checkpoint_restore(checkpoint_id, &state.emitter, state)
                .await
                .map_err(|e| ("internal_error".to_string(), e))?;
            json!({"ok": true})
        }
        "task.draft" => {
            let text = parse_string_param(params, "text")
                .map_err(|e| ("invalid_params".to_string(), e))?;
            let draft = commands::draft_task_contract(commands::DraftTaskInput { text }, state)
                .await
                .map_err(|e| ("internal_error".to_string(), e))?;
            serde_json::to_value(draft)
                .map_err(|e| ("internal_error".to_string(), e.to_string()))?
        }
        "keybindings.list" => serde_json::to_value(
            commands::list_keybindings(state)
                .await
                .map_err(|e| ("internal_error".to_string(), e))?,
        )
        .map_err(|e| ("internal_error".to_string(), e.to_string()))?,
        "keybindings.set" => {
            let action = parse_string_param(params, "action")
                .map_err(|e| ("invalid_params".to_string(), e))?;
            let shortcut = parse_string_param(params, "shortcut")
                .map_err(|e| ("invalid_params".to_string(), e))?;
            let rows =
                commands::set_keybinding(commands::SetKeybindingInput { action, shortcut }, state)
                    .await
                    .map_err(|e| ("internal_error".to_string(), e))?;
            serde_json::to_value(rows).map_err(|e| ("internal_error".to_string(), e.to_string()))?
        }
        "keybindings.reset" => serde_json::to_value(
            commands::reset_keybindings(state)
                .await
                .map_err(|e| ("internal_error".to_string(), e))?,
        )
        .map_err(|e| ("internal_error".to_string(), e.to_string()))?,
        "onboarding.state" => serde_json::to_value(
            commands::get_onboarding_state(state)
                .await
                .map_err(|e| ("internal_error".to_string(), e))?,
        )
        .map_err(|e| ("internal_error".to_string(), e.to_string()))?,
        "onboarding.advance" => {
            let step = parse_string_param(params, "step")
                .map_err(|e| ("invalid_params".to_string(), e))?;
            let completed = parse_optional_bool_param(params, "completed");
            let dismissed = parse_optional_bool_param(params, "dismissed");
            let row = commands::advance_onboarding_step(
                commands::AdvanceOnboardingInput {
                    step,
                    completed,
                    dismissed,
                },
                state,
            )
            .await
            .map_err(|e| ("internal_error".to_string(), e))?;
            serde_json::to_value(row).map_err(|e| ("internal_error".to_string(), e.to_string()))?
        }
        "onboarding.reset" => serde_json::to_value(
            commands::reset_onboarding(state)
                .await
                .map_err(|e| ("internal_error".to_string(), e))?,
        )
        .map_err(|e| ("internal_error".to_string(), e.to_string()))?,
        "telemetry.status" => serde_json::to_value(
            commands::get_telemetry_status(state)
                .await
                .map_err(|e| ("internal_error".to_string(), e))?,
        )
        .map_err(|e| ("internal_error".to_string(), e.to_string()))?,
        "telemetry.set" => {
            let opted_in = parse_optional_bool_param(params, "opted_in")
                .ok_or_else(|| ("invalid_params".to_string(), "missing opted_in".to_string()))?;
            let status =
                commands::set_telemetry_opt_in(commands::SetTelemetryInput { opted_in }, state)
                    .await
                    .map_err(|e| ("internal_error".to_string(), e))?;
            serde_json::to_value(status)
                .map_err(|e| ("internal_error".to_string(), e.to_string()))?
        }
        "telemetry.export" => {
            let path = parse_optional_string_param(params, "path");
            let limit = parse_optional_i64_param(params, "limit");
            let output = commands::export_telemetry_bundle(
                Some(commands::ExportTelemetryInput { path, limit }),
                state,
            )
            .await
            .map_err(|e| ("internal_error".to_string(), e))?;
            json!({"path": output})
        }
        "telemetry.clear" => {
            commands::clear_telemetry(state)
                .await
                .map_err(|e| ("internal_error".to_string(), e))?;
            json!({"ok": true})
        }
        "settings.ghostty.audit" => {
            let action = parse_string_param(params, "action")
                .map_err(|e| ("invalid_params".to_string(), e))?;
            let changed_keys =
                parse_optional_string_list_param(params, "changed_keys").unwrap_or_default();
            let diagnostics =
                parse_optional_string_list_param(params, "diagnostics").unwrap_or_default();
            let applied = parse_optional_bool_param(params, "applied")
                .ok_or_else(|| ("invalid_params".to_string(), "missing applied".to_string()))?;
            let managed_path = parse_string_param(params, "managed_path")
                .map_err(|e| ("invalid_params".to_string(), e))?;
            let recorded = commands::audit_ghostty_settings(
                commands::GhosttyAuditInput {
                    action,
                    changed_keys,
                    diagnostics,
                    applied,
                    managed_path,
                },
                state,
            )
            .await
            .map_err(|e| ("internal_error".to_string(), e))?;
            json!({ "recorded": recorded })
        }
        "feedback.submit" => {
            let category = parse_string_param(params, "category")
                .map_err(|e| ("invalid_params".to_string(), e))?;
            let body = parse_string_param(params, "body")
                .map_err(|e| ("invalid_params".to_string(), e))?;
            let contact = parse_optional_string_param(params, "contact");
            let feedback = commands::submit_feedback(
                commands::FeedbackInput {
                    category,
                    body,
                    contact,
                },
                state,
            )
            .await
            .map_err(|e| ("internal_error".to_string(), e))?;
            serde_json::to_value(feedback)
                .map_err(|e| ("internal_error".to_string(), e.to_string()))?
        }
        "partner.metrics.report" => {
            let days = parse_optional_i64_param(params, "days");
            let report = commands::partner_metrics_report(
                Some(commands::PartnerMetricsInput { days }),
                state,
            )
            .await
            .map_err(|e| ("internal_error".to_string(), e))?;
            serde_json::to_value(report)
                .map_err(|e| ("internal_error".to_string(), e.to_string()))?
        }
        "ssh.list_profiles" => serde_json::to_value(
            commands::list_ssh_profiles(state)
                .await
                .map_err(|e| ("internal_error".to_string(), e))?,
        )
        .map_err(|e| ("internal_error".to_string(), e.to_string()))?,
        "ssh.connect" => {
            let profile_id = parse_string_param(params, "profile_id")
                .map_err(|e| ("invalid_params".to_string(), e))?;
            let session_id = commands::connect_ssh(profile_id, state)
                .await
                .map_err(|e| ("internal_error".to_string(), e))?;
            json!({"session_id": session_id})
        }
        "ssh.import_config" => serde_json::to_value(
            commands::import_ssh_config(state)
                .await
                .map_err(|e| ("internal_error".to_string(), e))?,
        )
        .map_err(|e| ("internal_error".to_string(), e.to_string()))?,
        "ssh.discover_tailscale" => serde_json::to_value(
            commands::discover_tailscale(state)
                .await
                .map_err(|e| ("internal_error".to_string(), e))?,
        )
        .map_err(|e| ("internal_error".to_string(), e.to_string()))?,
        "analytics.usage_breakdown" => {
            let days = parse_optional_i64_param(params, "days");
            serde_json::to_value(
                commands::get_usage_breakdown(days, state)
                    .await
                    .map_err(|e| ("internal_error".to_string(), e))?,
            )
            .map_err(|e| ("internal_error".to_string(), e.to_string()))?
        }
        "analytics.usage_by_model" => serde_json::to_value(
            commands::get_usage_by_model(state)
                .await
                .map_err(|e| ("internal_error".to_string(), e))?,
        )
        .map_err(|e| ("internal_error".to_string(), e.to_string()))?,
        "analytics.usage_daily_trend" => {
            let days = parse_optional_i64_param(params, "days");
            serde_json::to_value(
                commands::get_usage_daily_trend(days, state)
                    .await
                    .map_err(|e| ("internal_error".to_string(), e))?,
            )
            .map_err(|e| ("internal_error".to_string(), e.to_string()))?
        }
        "analytics.error_signatures" => {
            let limit = parse_optional_i64_param(params, "limit");
            serde_json::to_value(
                commands::list_error_signatures(limit, state)
                    .await
                    .map_err(|e| ("internal_error".to_string(), e))?,
            )
            .map_err(|e| ("internal_error".to_string(), e.to_string()))?
        }
        _ => {
            return Err((
                "method_not_found".to_string(),
                format!("unknown method: {method}"),
            ));
        }
    };
    Ok(result)
}

fn redact_event_params(params: &Value) -> Value {
    let raw = params.to_string();
    let redacted = redact_secrets(&raw);
    serde_json::from_str(&redacted).unwrap_or(Value::String(redacted))
}

async fn append_automation_audit(state: &AppState, event_type: &str, payload: Value) {
    let (db, project_id, redaction_secrets) = {
        let current = state.current.lock().await;
        let Some(ctx) = current.as_ref() else {
            return;
        };
        (
            ctx.db.clone(),
            ctx.project_id,
            Arc::clone(&ctx.redaction_secrets),
        )
    };
    let current_secrets = commands::current_redaction_secrets(&redaction_secrets).await;
    let safe_payload = commands::redact_payload_for_log_with_secrets(payload, &current_secrets);
    let _ = db
        .append_event(NewEvent {
            id: Uuid::new_v4().to_string(),
            project_id: project_id.to_string(),
            task_id: None,
            session_id: None,
            trace_id: Uuid::new_v4().to_string(),
            source: "automation".to_string(),
            event_type: event_type.to_string(),
            payload: safe_payload,
        })
        .await;
}

#[cfg(unix)]
pub async fn send_request(
    socket_path: &Path,
    request: &ControlRequest,
) -> Result<ControlResponse, String> {
    use tokio::io::{AsyncBufReadExt, AsyncWriteExt, BufReader};
    use tokio::net::UnixStream;

    let mut stream = UnixStream::connect(socket_path)
        .await
        .map_err(|e| e.to_string())?;
    let request_wire = serde_json::to_string(request).map_err(|e| e.to_string())? + "\n";
    stream
        .write_all(request_wire.as_bytes())
        .await
        .map_err(|e| e.to_string())?;
    let mut reader = BufReader::new(stream);
    let mut line = String::new();
    reader
        .read_line(&mut line)
        .await
        .map_err(|e| e.to_string())?;
    if line.trim().is_empty() {
        return Err("empty response from control socket".to_string());
    }
    serde_json::from_str::<ControlResponse>(line.trim()).map_err(|e| e.to_string())
}

#[cfg(not(unix))]
pub async fn send_request(
    _socket_path: &Path,
    _request: &ControlRequest,
) -> Result<ControlResponse, String> {
    Err("unix sockets are not supported on this platform".to_string())
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::event_emitter::NullEmitter;
    use serde_json::json;
    use std::sync::Arc;

    fn request_with_password(password: Option<&str>) -> ControlRequest {
        ControlRequest {
            id: "req-1".to_string(),
            method: "project.status".to_string(),
            params: json!({}),
            auth: password.map(|value| ControlAuthEnvelope {
                password: Some(value.to_string()),
            }),
        }
    }

    fn password_settings(password: &str) -> ControlPlaneSettings {
        ControlPlaneSettings {
            enabled: true,
            socket_path: PathBuf::from(".pnevma/run/control.sock"),
            auth_mode: ControlAuthMode::Password {
                password: password.to_string(),
            },
        }
    }

    #[test]
    fn authorize_password_mode_requires_auth_password() {
        let settings = password_settings("secret");
        let request = request_with_password(None);
        let err = authorize_request(&request, &settings).expect_err("missing password should fail");
        assert_eq!(err, "missing auth.password");
    }

    #[test]
    fn authorize_password_mode_rejects_wrong_password() {
        let settings = password_settings("secret");
        let request = request_with_password(Some("wrong"));
        let err = authorize_request(&request, &settings).expect_err("wrong password should fail");
        assert_eq!(err, "invalid password");
    }

    #[test]
    fn authorize_password_mode_accepts_correct_password() {
        let settings = password_settings("secret");
        let request = request_with_password(Some("secret"));
        authorize_request(&request, &settings).expect("correct password should pass");
    }

    #[test]
    fn authorize_same_user_mode_skips_password_requirement() {
        let settings = ControlPlaneSettings {
            enabled: true,
            socket_path: PathBuf::from(".pnevma/run/control.sock"),
            auth_mode: ControlAuthMode::SameUser,
        };
        let request = request_with_password(None);
        authorize_request(&request, &settings).expect("same-user mode should pass");
    }

    #[test]
    fn validate_control_request_rejects_invalid_id_and_method() {
        let mut request = request_with_password(None);
        request.id = "bad id".to_string();
        let err = validate_control_request(&request).expect_err("spaces should fail");
        assert!(err.contains("request id"));

        request.id = "req-1".to_string();
        request.method = "project status".to_string();
        let err = validate_control_request(&request).expect_err("spaces should fail");
        assert!(err.contains("request method"));
    }

    #[test]
    fn validate_control_request_accepts_safe_values() {
        let request = request_with_password(None);
        validate_control_request(&request).expect("safe request should pass");
    }

    #[tokio::test]
    async fn session_scrollback_route_is_registered() {
        let state = AppState::new(Arc::new(NullEmitter));
        let err = route_method(
            &state,
            "session.scrollback",
            &json!({
                "session_id": Uuid::new_v4().to_string()
            }),
        )
        .await
        .expect_err("missing project should still route to the session.scrollback handler");
        assert_eq!(err.0, "internal_error");
        assert_eq!(err.1, "no open project");
    }
}
