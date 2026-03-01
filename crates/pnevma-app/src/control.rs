use crate::commands;
use crate::state::AppState;
use pnevma_core::{GlobalConfig, ProjectConfig};
use pnevma_db::NewEvent;
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use std::path::{Path, PathBuf};
use tauri::{AppHandle, Manager};
use uuid::Uuid;

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
            let password = std::env::var("PNEVMA_SOCKET_PASSWORD")
                .ok()
                .or_else(|| read_password_file(global.socket_password_file.as_deref()).ok())
                .filter(|raw| !raw.trim().is_empty())
                .ok_or_else(|| {
                    "socket auth mode is password but no password is configured".to_string()
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

fn read_password_file(path: Option<&str>) -> Result<String, String> {
    let Some(path) = path else {
        return Err("no password file configured".to_string());
    };
    let raw = std::fs::read_to_string(path).map_err(|e| e.to_string())?;
    Ok(raw.trim().to_string())
}

pub struct ControlServerHandle {
    socket_path: PathBuf,
    shutdown_tx: tokio::sync::oneshot::Sender<()>,
    join: tauri::async_runtime::JoinHandle<()>,
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
    app: AppHandle,
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
    let join = tauri::async_runtime::spawn(async move {
        loop {
            tokio::select! {
                _ = &mut shutdown_rx => {
                    break;
                }
                accepted = listener.accept() => {
                    let Ok((stream, _addr)) = accepted else {
                        continue;
                    };
                    let app = app.clone();
                    let settings = accept_settings.clone();
                    tauri::async_runtime::spawn(async move {
                        let _ = handle_unix_client(app, settings, stream).await;
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
    _app: AppHandle,
    _settings: ControlPlaneSettings,
) -> Result<Option<ControlServerHandle>, String> {
    Ok(None)
}

#[cfg(unix)]
async fn handle_unix_client(
    app: AppHandle,
    settings: ControlPlaneSettings,
    stream: tokio::net::UnixStream,
) -> Result<(), String> {
    use tokio::io::{AsyncBufReadExt, AsyncWriteExt, BufReader};

    verify_same_user_peer(&stream, &settings.auth_mode)?;

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

        let response = process_request(&app, &settings, request).await;
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
    let self_uid = unsafe { libc::geteuid() } as u32;
    if peer_uid != self_uid {
        return Err("socket peer uid mismatch".to_string());
    }
    Ok(())
}

fn parse_string_param(params: &Value, key: &str) -> Result<String, String> {
    params
        .get(key)
        .and_then(Value::as_str)
        .map(ToString::to_string)
        .filter(|v| !v.trim().is_empty())
        .ok_or_else(|| format!("missing required string param: {key}"))
}

fn parse_optional_string_param(params: &Value, key: &str) -> Option<String> {
    params
        .get(key)
        .and_then(Value::as_str)
        .map(ToString::to_string)
}

async fn process_request(
    app: &AppHandle,
    settings: &ControlPlaneSettings,
    request: ControlRequest,
) -> ControlResponse {
    let request_id = request.id.clone();
    let method = request.method.clone();
    let params = request.params.clone();
    let safe_params = params.clone();

    if let Err(err) = authorize_request(&request, settings) {
        append_automation_audit(
            app,
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

    append_automation_audit(
        app,
        "AutomationRequestReceived",
        json!({
            "request_id": request.id,
            "method": method,
            "params": safe_params,
        }),
    )
    .await;

    let routed = route_method(app, &method, &params).await;
    match routed {
        Ok(result) => {
            append_automation_audit(
                app,
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
                app,
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
            if supplied == *password {
                Ok(())
            } else {
                Err("invalid password".to_string())
            }
        }
    }
}

async fn route_method(
    app: &AppHandle,
    method: &str,
    params: &Value,
) -> Result<Value, (String, String)> {
    let result = match method {
        "project.status" => serde_json::to_value(
            commands::project_status(app.state::<AppState>())
                .await
                .map_err(|e| ("internal_error".to_string(), e))?,
        )
        .map_err(|e| ("internal_error".to_string(), e.to_string()))?,
        "task.list" => serde_json::to_value(
            commands::list_tasks(app.state::<AppState>())
                .await
                .map_err(|e| ("internal_error".to_string(), e))?,
        )
        .map_err(|e| ("internal_error".to_string(), e.to_string()))?,
        "task.dispatch" => {
            let task_id = parse_string_param(params, "task_id")
                .map_err(|e| ("invalid_params".to_string(), e))?;
            let status = commands::dispatch_task(task_id, app.clone(), app.state::<AppState>())
                .await
                .map_err(|e| ("internal_error".to_string(), e))?;
            json!({ "status": status })
        }
        "session.send_input" => {
            let session_id = parse_string_param(params, "session_id")
                .map_err(|e| ("invalid_params".to_string(), e))?;
            let input = parse_string_param(params, "input")
                .map_err(|e| ("invalid_params".to_string(), e))?;
            commands::send_session_input(session_id, input, app.state::<AppState>())
                .await
                .map_err(|e| ("internal_error".to_string(), e))?;
            json!({"ok": true})
        }
        "notification.create" => {
            let title = parse_string_param(params, "title")
                .map_err(|e| ("invalid_params".to_string(), e))?;
            let body = parse_string_param(params, "body")
                .map_err(|e| ("invalid_params".to_string(), e))?;
            let level = parse_optional_string_param(params, "level");
            let notification = commands::create_notification(
                commands::NotificationInput { title, body, level },
                app.clone(),
                app.state::<AppState>(),
            )
            .await
            .map_err(|e| ("internal_error".to_string(), e))?;
            serde_json::to_value(notification)
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

async fn append_automation_audit(app: &AppHandle, event_type: &str, payload: Value) {
    let state = app.state::<AppState>();
    let current = state.current.lock().await;
    let Some(ctx) = current.as_ref() else {
        return;
    };
    let _ = ctx
        .db
        .append_event(NewEvent {
            id: Uuid::new_v4().to_string(),
            project_id: ctx.project_id.to_string(),
            task_id: None,
            session_id: None,
            trace_id: Uuid::new_v4().to_string(),
            source: "automation".to_string(),
            event_type: event_type.to_string(),
            payload,
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
