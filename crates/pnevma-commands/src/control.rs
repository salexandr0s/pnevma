use crate::auth_secret::load_socket_password;
use crate::command_registry::{default_registry, AccessLevel};
use crate::commands;
use crate::state::AppState;
use pnevma_context::redact_secrets;
use pnevma_core::{GlobalConfig, ProjectConfig};
use pnevma_db::NewEvent;
use pnevma_session::{SessionBackendKillResult, SessionStatus, SessionSupervisor};
use secrecy::{ExposeSecret, SecretString};
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use std::collections::{HashMap, VecDeque};
use std::path::{Path, PathBuf};
use std::sync::Arc;
use std::time::{Duration, Instant};
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

#[derive(Clone)]
pub enum ControlAuthMode {
    SameUser,
    Password { password: SecretString },
}

impl std::fmt::Debug for ControlAuthMode {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::SameUser => write!(f, "SameUser"),
            Self::Password { .. } => f
                .debug_struct("Password")
                .field("password", &"[REDACTED]")
                .finish(),
        }
    }
}

#[derive(Debug, Clone)]
pub struct ControlPlaneSettings {
    pub enabled: bool,
    pub socket_path: PathBuf,
    pub auth_mode: ControlAuthMode,
    pub socket_rate_limit_rpm: u32,
}

#[derive(Clone)]
struct SocketRateLimiter {
    requests_per_minute: usize,
    windows: Arc<std::sync::Mutex<HashMap<u32, VecDeque<Instant>>>>,
}

impl SocketRateLimiter {
    fn new(requests_per_minute: u32) -> Self {
        Self {
            requests_per_minute: requests_per_minute.max(1) as usize,
            windows: Arc::new(std::sync::Mutex::new(HashMap::new())),
        }
    }

    fn allow(&self, peer_uid: u32) -> bool {
        let mut guard = self
            .windows
            .lock()
            .expect("socket rate-limit lock poisoned");
        let now = Instant::now();
        let cutoff = now.checked_sub(Duration::from_secs(60)).unwrap_or(now);
        let window = guard.entry(peer_uid).or_default();
        while window.front().is_some_and(|ts| *ts < cutoff) {
            window.pop_front();
        }
        if window.len() >= self.requests_per_minute {
            return false;
        }
        window.push_back(now);
        true
    }
}

const AUTH_FAILURE_THRESHOLD: u32 = 5;
const AUTH_FAILURE_WINDOW_SECS: u64 = 60;

type AuthFailureState = HashMap<u32, (Instant, u32, bool)>;

#[derive(Clone)]
struct AuthFailureTracker {
    /// Map from peer_uid → (window_start, failure_count, already_fired)
    state: Arc<std::sync::Mutex<AuthFailureState>>,
}

impl AuthFailureTracker {
    fn new() -> Self {
        Self {
            state: Arc::new(std::sync::Mutex::new(HashMap::new())),
        }
    }

    /// Record an auth failure for a peer UID. Returns `true` exactly once when
    /// the threshold is first exceeded within the window.
    fn record_failure(&self, peer_uid: u32) -> bool {
        let mut guard = self
            .state
            .lock()
            .expect("auth failure tracker lock poisoned");
        let now = Instant::now();
        let entry = guard.entry(peer_uid).or_insert((now, 0, false));
        let window = Duration::from_secs(AUTH_FAILURE_WINDOW_SECS);
        if now.duration_since(entry.0) > window {
            // Reset window
            *entry = (now, 1, false);
            return false;
        }
        entry.1 += 1;
        if entry.1 >= AUTH_FAILURE_THRESHOLD && !entry.2 {
            entry.2 = true; // Fire once per window
            return true;
        }
        false
    }
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
    // Resolve auth mode: global override (string) takes precedence, then project config (enum).
    let resolved_auth = if let Some(ref mode_str) = global.socket_auth_mode {
        match mode_str.as_str() {
            "same-user" => pnevma_core::SocketAuth::SameUser,
            "password" => pnevma_core::SocketAuth::Password,
            other => {
                return Err(format!(
                    "unsupported socket auth mode '{other}', expected same-user or password"
                ));
            }
        }
    } else {
        project.automation.socket_auth
    };
    let auth_mode = match resolved_auth {
        pnevma_core::SocketAuth::SameUser => ControlAuthMode::SameUser,
        pnevma_core::SocketAuth::Password => {
            let password = load_socket_password(global.socket_password_file.as_deref())?
                .ok_or_else(|| {
                    format!(
                        "socket auth mode is password but no password is configured (set PNEVMA_SOCKET_PASSWORD, store Keychain item {}/{}, or provide socket_password_file with mode 0600)",
                        crate::auth_secret::SOCKET_KEYCHAIN_SERVICE,
                        crate::auth_secret::SOCKET_KEYCHAIN_ACCOUNT
                    )
                })?;
            ControlAuthMode::Password {
                password: SecretString::from(password),
            }
        }
    };

    Ok(ControlPlaneSettings {
        enabled: project.automation.socket_enabled,
        socket_path,
        auth_mode,
        socket_rate_limit_rpm: project.automation.socket_rate_limit_rpm,
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
    let rate_limiter = SocketRateLimiter::new(settings.socket_rate_limit_rpm);
    let auth_failure_tracker = AuthFailureTracker::new();
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
                    let rate_limiter = rate_limiter.clone();
                    let auth_tracker = auth_failure_tracker.clone();
                    tokio::spawn(async move {
                        let _ = handle_unix_client(state, settings, rate_limiter, auth_tracker, stream).await;
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
    rate_limiter: SocketRateLimiter,
    auth_tracker: AuthFailureTracker,
    stream: tokio::net::UnixStream,
) -> Result<(), String> {
    use tokio::io::{AsyncBufReadExt, AsyncWriteExt, BufReader};

    let peer_uid = peer_uid(&stream)?;
    verify_same_user_peer(peer_uid, &settings.auth_mode)?;

    const MAX_LINE_BYTES: usize = 1024 * 1024; // 1 MB

    let (read_half, mut write_half) = stream.into_split();
    let mut reader = BufReader::new(read_half);
    let mut line = String::new();
    loop {
        line.clear();
        // Bounded line reading: read up to MAX_LINE_BYTES + 1 bytes looking
        // for a newline. If we exceed the limit before finding one, drain the
        // rest of the oversized line and return an error response.
        let mut found_newline = false;
        let mut overflow = false;
        loop {
            let buf = reader.fill_buf().await.map_err(|e| e.to_string())?;
            if buf.is_empty() {
                // EOF
                break;
            }
            if let Some(pos) = buf.iter().position(|&b| b == b'\n') {
                // Found newline within buffer
                let to_consume = pos + 1; // include the newline
                if line.len() + to_consume > MAX_LINE_BYTES + 1 {
                    overflow = true;
                    reader.consume(to_consume);
                } else {
                    let chunk = &buf[..to_consume];
                    line.push_str(&String::from_utf8_lossy(chunk));
                    reader.consume(to_consume);
                }
                found_newline = true;
                break;
            } else {
                // No newline in buffer — consume it all
                let len = buf.len();
                if line.len() + len > MAX_LINE_BYTES {
                    // Would exceed limit — mark as overflow and drain until newline
                    overflow = true;
                    reader.consume(len);
                    // Continue draining until we find a newline
                    loop {
                        let drain_buf = reader.fill_buf().await.map_err(|e| e.to_string())?;
                        if drain_buf.is_empty() {
                            break;
                        }
                        if let Some(pos) = drain_buf.iter().position(|&b| b == b'\n') {
                            reader.consume(pos + 1);
                            found_newline = true;
                            break;
                        }
                        let drain_len = drain_buf.len();
                        reader.consume(drain_len);
                    }
                    break;
                }
                let chunk = &buf[..len];
                line.push_str(&String::from_utf8_lossy(chunk));
                reader.consume(len);
            }
        }

        if line.is_empty() && !found_newline && !overflow {
            // EOF with no data
            break;
        }

        if overflow {
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

        if !rate_limiter.allow(peer_uid) {
            tracing::warn!(
                peer_uid,
                limit_rpm = settings.socket_rate_limit_rpm,
                "control plane rate limit exceeded"
            );
            let response = ControlResponse::err(
                request.id.clone(),
                "rate_limited",
                "control plane rate limit exceeded",
            );
            let wire = serde_json::to_string(&response).map_err(|e| e.to_string())? + "\n";
            write_half
                .write_all(wire.as_bytes())
                .await
                .map_err(|e| e.to_string())?;
            continue;
        }

        let request_id = request.id.clone();
        let method = request.method.clone();
        let response =
            process_request(&state, &settings, request, peer_uid, &settings.auth_mode).await;
        log_control_plane_request(
            peer_uid,
            &settings.auth_mode,
            &request_id,
            &method,
            &response,
        );
        if let Some(ref err) = response.error {
            if err.code == "unauthorized" && auth_tracker.record_failure(peer_uid) {
                tracing::warn!(
                    peer_uid,
                    "auth failure threshold exceeded: 5 failures within 60s"
                );
                append_automation_audit(
                    &state,
                    "AutomationAuthThresholdExceeded",
                    json!({
                        "peer_uid": peer_uid,
                        "auth_mode": auth_mode_name(&settings.auth_mode),
                        "failure_count": 5,
                        "window_seconds": 60,
                    }),
                )
                .await;
            }
        }
        let wire = serde_json::to_string(&response).map_err(|e| e.to_string())? + "\n";
        write_half
            .write_all(wire.as_bytes())
            .await
            .map_err(|e| e.to_string())?;
    }
    Ok(())
}

#[cfg(unix)]
fn verify_same_user_peer(peer_uid: u32, auth_mode: &ControlAuthMode) -> Result<(), String> {
    if !matches!(auth_mode, ControlAuthMode::SameUser) {
        return Ok(());
    }
    let self_uid = crate::platform::current_euid();
    if peer_uid != self_uid {
        return Err("socket peer uid mismatch".to_string());
    }
    Ok(())
}

#[cfg(unix)]
fn peer_uid(stream: &tokio::net::UnixStream) -> Result<u32, String> {
    let creds = stream.peer_cred().map_err(|e| e.to_string())?;
    Ok(creds.uid())
}

fn auth_mode_name(auth_mode: &ControlAuthMode) -> &'static str {
    match auth_mode {
        ControlAuthMode::SameUser => "same-user",
        ControlAuthMode::Password { .. } => "password",
    }
}

fn is_mutating_control_method(method: &str) -> bool {
    default_registry().access_level(method) != AccessLevel::ReadOnly
}

fn log_control_plane_request(
    peer_uid: u32,
    auth_mode: &ControlAuthMode,
    request_id: &str,
    method: &str,
    response: &ControlResponse,
) {
    let mutating = is_mutating_control_method(method);
    let error_code = response
        .error
        .as_ref()
        .map(|err| err.code.as_str())
        .unwrap_or("-");

    if mutating {
        tracing::info!(
            peer_uid,
            auth_mode = auth_mode_name(auth_mode),
            request_id,
            method,
            mutation = true,
            ok = response.ok,
            error_code,
            "control plane request"
        );
    } else {
        tracing::debug!(
            peer_uid,
            auth_mode = auth_mode_name(auth_mode),
            request_id,
            method,
            mutation = false,
            ok = response.ok,
            error_code,
            "control plane request"
        );
    }
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

fn session_kill_result(
    session_id: String,
    outcome: &str,
    message: Option<String>,
) -> commands::SessionKillResult {
    commands::SessionKillResult {
        session_id,
        outcome: outcome.to_string(),
        message,
    }
}

async fn finalize_session_exit(
    supervisor: &SessionSupervisor,
    session_id: Uuid,
    outcome: &str,
    exit_code: Option<i32>,
) -> commands::SessionKillResult {
    let session_id_string = session_id.to_string();
    match supervisor.mark_exit(session_id, exit_code).await {
        Ok(()) => session_kill_result(session_id_string, outcome, None),
        Err(err) => session_kill_result(
            session_id_string,
            "failed",
            Some(format!("failed to record session exit: {err}")),
        ),
    }
}

async fn kill_live_session(
    supervisor: &SessionSupervisor,
    session_id: Uuid,
) -> commands::SessionKillResult {
    if supervisor.get(session_id).await.is_none() {
        return session_kill_result(session_id.to_string(), "not_found", None);
    }

    match supervisor.kill_session_backend(session_id).await {
        Ok(SessionBackendKillResult::Killed) => {
            finalize_session_exit(supervisor, session_id, "killed", Some(-9)).await
        }
        Ok(SessionBackendKillResult::AlreadyGone) => {
            finalize_session_exit(supervisor, session_id, "already_gone", None).await
        }
        Err(err) => session_kill_result(session_id.to_string(), "failed", Some(err.to_string())),
    }
}

async fn kill_all_live_sessions(supervisor: &SessionSupervisor) -> commands::SessionKillAllResult {
    let sessions = supervisor.list().await;
    let mut result = commands::SessionKillAllResult {
        requested: 0,
        killed: 0,
        already_gone: 0,
        failed: 0,
        failures: Vec::new(),
    };

    for session in sessions {
        if session.status == SessionStatus::Complete {
            continue;
        }

        result.requested += 1;
        let kill_result = kill_live_session(supervisor, session.id).await;
        match kill_result.outcome.as_str() {
            "killed" => result.killed += 1,
            "already_gone" | "not_found" => result.already_gone += 1,
            "failed" => {
                result.failed += 1;
                result.failures.push(commands::SessionKillFailure {
                    session_id: kill_result.session_id,
                    message: kill_result
                        .message
                        .unwrap_or_else(|| "session kill failed".to_string()),
                });
            }
            _ => {
                result.failed += 1;
                result.failures.push(commands::SessionKillFailure {
                    session_id: kill_result.session_id,
                    message: format!("unexpected kill outcome {}", kill_result.outcome),
                });
            }
        }
    }

    result
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
    peer_uid: u32,
    auth_mode: &ControlAuthMode,
) -> ControlResponse {
    if let Err(err) = validate_control_request(&request) {
        return ControlResponse::err(request.id.clone(), "invalid_request", err);
    }

    let request_id = request.id.clone();
    let method = request.method.clone();
    let params = request.params.clone();
    let mode_name = auth_mode_name(auth_mode);

    if let Err(err) = authorize_request(&request, settings) {
        append_automation_audit(
            state,
            "AutomationRequestFailed",
            json!({
                "request_id": request.id,
                "method": method,
                "error": err,
                "peer_uid": peer_uid,
                "auth_mode": mode_name,
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
            "peer_uid": peer_uid,
            "auth_mode": mode_name,
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
                    "peer_uid": peer_uid,
                    "auth_mode": mode_name,
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
                    "peer_uid": peer_uid,
                    "auth_mode": mode_name,
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
            let password_bytes = password.expose_secret().as_bytes();
            // Use fixed-length comparison to avoid leaking password length.
            // ct_eq on slices of different lengths is not constant-time in subtle,
            // so we hash both to a fixed size first.
            use sha2::{Digest, Sha256};
            let supplied_hash = Sha256::digest(supplied_bytes);
            let password_hash = Sha256::digest(password_bytes);
            if !bool::from(supplied_hash.ct_eq(&password_hash)) {
                return Err("invalid password".to_string());
            }
            // Password auth accepted — now check command access level.
            let access_level = default_registry().access_level(&request.method);
            if access_level == AccessLevel::Privileged {
                return Err("privileged command requires same-user auth".to_string());
            }
            Ok(())
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
            let checkout_path = parse_optional_string_param(params, "checkout_path");
            let client_activation_token =
                parse_optional_string_param(params, "client_activation_token");
            let project_id = commands::open_project(
                path,
                checkout_path,
                client_activation_token,
                &state.emitter,
                state,
            )
            .await
            .map_err(|e| ("internal_error".to_string(), e))?;
            let status = commands::project_status(state)
                .await
                .map_err(|e| ("internal_error".to_string(), e))?;
            serde_json::to_value(commands::ProjectOpenResponse { project_id, status })
                .map_err(|e| ("internal_error".to_string(), e.to_string()))?
        }
        "project.close" => {
            let close_mode = parse_optional_string_param(params, "mode")
                .map(|value| {
                    commands::ProjectCloseMode::parse(&value)
                        .map_err(|e| ("invalid_params".to_string(), e))
                })
                .transpose()?
                .unwrap_or(commands::ProjectCloseMode::WorkspaceClose);
            commands::close_project_with_mode(close_mode, state)
                .await
                .map_err(|e| ("internal_error".to_string(), e))?;
            serde_json::to_value(commands::OkResponse { ok: true })
                .map_err(|e| ("internal_error".to_string(), e.to_string()))?
        }
        "project.trust" => {
            let path = parse_string_param(params, "path")
                .map_err(|e| ("invalid_params".to_string(), e))?;
            commands::trust_workspace(path, state)
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
        "project.automation" => serde_json::to_value(
            commands::automation_status(state)
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
        "project.resolve_pr_url" => {
            let url =
                parse_string_param(params, "url").map_err(|e| ("invalid_params".to_string(), e))?;
            serde_json::to_value(
                commands::resolve_pr_url(&url, state)
                    .await
                    .map_err(|e| ("internal_error".to_string(), e))?,
            )
            .map_err(|e| ("internal_error".to_string(), e.to_string()))?
        }
        "project.resolve_issue_url" => {
            let url =
                parse_string_param(params, "url").map_err(|e| ("invalid_params".to_string(), e))?;
            serde_json::to_value(
                commands::resolve_issue_url(&url, state)
                    .await
                    .map_err(|e| ("internal_error".to_string(), e))?,
            )
            .map_err(|e| ("internal_error".to_string(), e.to_string()))?
        }
        "project.list_files" => serde_json::to_value(
            commands::list_project_files_flat(state)
                .await
                .map_err(|e| ("internal_error".to_string(), e))?,
        )
        .map_err(|e| ("internal_error".to_string(), e.to_string()))?,
        "project.list_prs" => serde_json::to_value(
            commands::pr_list(state)
                .await
                .map_err(|e| ("internal_error".to_string(), e))?,
        )
        .map_err(|e| ("internal_error".to_string(), e.to_string()))?,
        "project.list_issues" => serde_json::to_value(
            commands::list_github_issues(state)
                .await
                .map_err(|e| ("internal_error".to_string(), e))?,
        )
        .map_err(|e| ("internal_error".to_string(), e.to_string()))?,
        "workspace_opener.list_branches" => {
            let input: commands::WorkspaceOpenerPathInput = serde_json::from_value(params.clone())
                .map_err(|e| ("invalid_params".to_string(), e.to_string()))?;
            serde_json::to_value(
                commands::list_branches_for_path(input)
                    .await
                    .map_err(|e| ("internal_error".to_string(), e))?,
            )
            .map_err(|e| ("internal_error".to_string(), e.to_string()))?
        }
        "workspace_opener.github_status" => {
            let input: commands::WorkspaceOpenerPathInput = serde_json::from_value(params.clone())
                .map_err(|e| ("invalid_params".to_string(), e.to_string()))?;
            serde_json::to_value(
                commands::github_status_for_path(input)
                    .await
                    .map_err(|e| ("internal_error".to_string(), e))?,
            )
            .map_err(|e| ("internal_error".to_string(), e.to_string()))?
        }
        "workspace_opener.github_connect" => {
            let input: commands::WorkspaceOpenerPathInput = serde_json::from_value(params.clone())
                .map_err(|e| ("invalid_params".to_string(), e.to_string()))?;
            serde_json::to_value(
                commands::github_connect_for_path(input)
                    .await
                    .map_err(|e| ("internal_error".to_string(), e))?,
            )
            .map_err(|e| ("internal_error".to_string(), e.to_string()))?
        }
        "workspace_opener.list_issues" => {
            let input: commands::WorkspaceOpenerPathInput = serde_json::from_value(params.clone())
                .map_err(|e| ("invalid_params".to_string(), e.to_string()))?;
            serde_json::to_value(
                commands::list_github_issues_for_path(input)
                    .await
                    .map_err(|e| ("internal_error".to_string(), e))?,
            )
            .map_err(|e| ("internal_error".to_string(), e.to_string()))?
        }
        "workspace_opener.list_prs" => {
            let input: commands::WorkspaceOpenerPathInput = serde_json::from_value(params.clone())
                .map_err(|e| ("invalid_params".to_string(), e.to_string()))?;
            serde_json::to_value(
                commands::list_github_pull_requests_for_path(input)
                    .await
                    .map_err(|e| ("internal_error".to_string(), e))?,
            )
            .map_err(|e| ("internal_error".to_string(), e.to_string()))?
        }
        "workspace_opener.create_from_issue" => {
            let input: commands::WorkspaceOpenerIssueLaunchInput =
                serde_json::from_value(params.clone())
                    .map_err(|e| ("invalid_params".to_string(), e.to_string()))?;
            serde_json::to_value(
                commands::create_workspace_from_issue(input, state)
                    .await
                    .map_err(|e| ("internal_error".to_string(), e))?,
            )
            .map_err(|e| ("internal_error".to_string(), e.to_string()))?
        }
        "workspace_opener.create_from_pr" => {
            let input: commands::WorkspaceOpenerPullRequestLaunchInput =
                serde_json::from_value(params.clone())
                    .map_err(|e| ("invalid_params".to_string(), e.to_string()))?;
            serde_json::to_value(
                commands::create_workspace_from_pull_request(input, state)
                    .await
                    .map_err(|e| ("internal_error".to_string(), e))?,
            )
            .map_err(|e| ("internal_error".to_string(), e.to_string()))?
        }
        "workspace_opener.create_from_branch" => {
            let input: commands::WorkspaceOpenerBranchLaunchInput =
                serde_json::from_value(params.clone())
                    .map_err(|e| ("invalid_params".to_string(), e.to_string()))?;
            serde_json::to_value(
                commands::create_workspace_from_branch(input)
                    .await
                    .map_err(|e| ("internal_error".to_string(), e))?,
            )
            .map_err(|e| ("internal_error".to_string(), e.to_string()))?
        }
        "git.list_branches" => serde_json::to_value(
            commands::list_branches(state)
                .await
                .map_err(|e| ("internal_error".to_string(), e))?,
        )
        .map_err(|e| ("internal_error".to_string(), e.to_string()))?,
        "git.checkout" => {
            let branch = parse_string_param(params, "branch")
                .map_err(|e| ("invalid_params".to_string(), e))?;
            serde_json::to_value(
                commands::checkout_branch(&branch, state)
                    .await
                    .map_err(|e| ("internal_error".to_string(), e))?,
            )
            .map_err(|e| ("internal_error".to_string(), e.to_string()))?
        }
        "workspace.changes_summary" => serde_json::to_value(
            commands::changes_summary(state)
                .await
                .map_err(|e| ("internal_error".to_string(), e))?,
        )
        .map_err(|e| ("internal_error".to_string(), e.to_string()))?,
        "review.check_summary" => serde_json::to_value(
            commands::check_summary(state)
                .await
                .map_err(|e| ("internal_error".to_string(), e))?,
        )
        .map_err(|e| ("internal_error".to_string(), e.to_string()))?,
        "merge.queue.readiness" => serde_json::to_value(
            commands::merge_queue_readiness(state)
                .await
                .map_err(|e| ("internal_error".to_string(), e))?,
        )
        .map_err(|e| ("internal_error".to_string(), e.to_string()))?,
        "workspace.commit_and_push" => {
            let message = parse_string_param(params, "message")
                .map_err(|e| ("invalid_params".to_string(), e))?;
            serde_json::to_value(
                commands::commit_and_push(&message, state)
                    .await
                    .map_err(|e| ("internal_error".to_string(), e))?,
            )
            .map_err(|e| ("internal_error".to_string(), e.to_string()))?
        }
        "workspace.commit" => {
            let message = parse_string_param(params, "message")
                .map_err(|e| ("invalid_params".to_string(), e))?;
            serde_json::to_value(
                commands::commit(&message, state)
                    .await
                    .map_err(|e| ("internal_error".to_string(), e))?,
            )
            .map_err(|e| ("internal_error".to_string(), e.to_string()))?
        }
        "workspace.push" => serde_json::to_value(
            commands::push(state)
                .await
                .map_err(|e| ("internal_error".to_string(), e))?,
        )
        .map_err(|e| ("internal_error".to_string(), e.to_string()))?,
        "ports.list" => serde_json::to_value(
            commands::list_ports(state)
                .await
                .map_err(|e| ("internal_error".to_string(), e))?,
        )
        .map_err(|e| ("internal_error".to_string(), e.to_string()))?,
        "project.command_center_snapshot" => serde_json::to_value(
            commands::command_center_snapshot(state)
                .await
                .map_err(|e| ("internal_error".to_string(), e))?,
        )
        .map_err(|e| ("internal_error".to_string(), e.to_string()))?,
        "fleet.snapshot" => serde_json::to_value(
            commands::fleet_snapshot(state)
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
            // Atomically claim the oldest Ready task at the DB level to prevent
            // TOCTOU races between listing and dispatching (C13).
            let (project_id, db) = {
                let current = state.current.lock().await;
                let ctx = current
                    .as_ref()
                    .ok_or_else(|| ("internal_error".to_string(), "no open project".to_string()))?;
                (ctx.project_id, ctx.db.clone())
            };
            let claimed = db
                .claim_next_ready_task(&project_id.to_string())
                .await
                .map_err(|e| ("internal_error".to_string(), e.to_string()))?;
            if let Some(task_id) = claimed {
                match commands::dispatch_task(task_id.clone(), &state.emitter, state).await {
                    Ok(status) => json!({"dispatched": true, "task_id": task_id, "status": status}),
                    Err(e) => {
                        // Revert claimed task from Dispatching → Ready so it can be retried.
                        if let Err(revert_err) = db
                            .update_task_status(&task_id, "Dispatching", "Ready")
                            .await
                        {
                            tracing::warn!(task_id, error = %revert_err, "failed to revert Dispatching task to Ready");
                        }
                        return Err(("internal_error".to_string(), e));
                    }
                }
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
        "agent_profile.get" => {
            let id =
                parse_string_param(params, "id").map_err(|e| ("invalid_params".to_string(), e))?;
            serde_json::to_value(
                commands::get_agent_profile(id, state)
                    .await
                    .map_err(|e| ("internal_error".to_string(), e))?,
            )
            .map_err(|e| ("internal_error".to_string(), e.to_string()))?
        }
        "agent_profile.create" => {
            let name = parse_string_param(params, "name")
                .map_err(|e| ("invalid_params".to_string(), e))?;
            let role = parse_optional_string_param(params, "role");
            let provider = parse_optional_string_param(params, "provider");
            let model = parse_optional_string_param(params, "model");
            let token_budget = params.get("token_budget").and_then(|v| v.as_i64());
            let timeout_minutes = params.get("timeout_minutes").and_then(|v| v.as_i64());
            let max_concurrent = params.get("max_concurrent").and_then(|v| v.as_i64());
            let stations: Option<Vec<String>> = params
                .get("stations")
                .and_then(|v| serde_json::from_value(v.clone()).ok());
            let config_json = parse_optional_string_param(params, "config_json");
            let system_prompt = parse_optional_string_param(params, "system_prompt");
            serde_json::to_value(
                commands::create_agent_profile(
                    commands::CreateAgentProfileInput {
                        name,
                        role,
                        provider,
                        model,
                        token_budget,
                        timeout_minutes,
                        max_concurrent,
                        stations,
                        config_json,
                        system_prompt,
                    },
                    state,
                )
                .await
                .map_err(|e| ("internal_error".to_string(), e))?,
            )
            .map_err(|e| ("internal_error".to_string(), e.to_string()))?
        }
        "agent_profile.update" => {
            let id =
                parse_string_param(params, "id").map_err(|e| ("invalid_params".to_string(), e))?;
            let name = parse_optional_string_param(params, "name");
            let role = parse_optional_string_param(params, "role");
            let provider = parse_optional_string_param(params, "provider");
            let model = parse_optional_string_param(params, "model");
            let token_budget = params.get("token_budget").and_then(|v| v.as_i64());
            let timeout_minutes = params.get("timeout_minutes").and_then(|v| v.as_i64());
            let max_concurrent = params.get("max_concurrent").and_then(|v| v.as_i64());
            let stations: Option<Vec<String>> = params
                .get("stations")
                .and_then(|v| serde_json::from_value(v.clone()).ok());
            let config_json = parse_optional_string_param(params, "config_json");
            let system_prompt = parse_optional_string_param(params, "system_prompt");
            let active = params.get("active").and_then(|v| v.as_bool());
            serde_json::to_value(
                commands::update_agent_profile(
                    commands::UpdateAgentProfileInput {
                        id,
                        name,
                        role,
                        provider,
                        model,
                        token_budget,
                        timeout_minutes,
                        max_concurrent,
                        stations,
                        config_json,
                        system_prompt,
                        active,
                    },
                    state,
                )
                .await
                .map_err(|e| ("internal_error".to_string(), e))?,
            )
            .map_err(|e| ("internal_error".to_string(), e.to_string()))?
        }
        "agent_profile.delete" => {
            let id =
                parse_string_param(params, "id").map_err(|e| ("invalid_params".to_string(), e))?;
            commands::delete_agent_profile(id, state)
                .await
                .map_err(|e| ("internal_error".to_string(), e))?;
            json!({"ok": true})
        }
        "agent_profile.copy_to_global" => {
            let id =
                parse_string_param(params, "id").map_err(|e| ("invalid_params".to_string(), e))?;
            let new_id = commands::copy_agent_to_global(id, state)
                .await
                .map_err(|e| ("internal_error".to_string(), e))?;
            json!({"id": new_id})
        }
        // ─── Global workflow commands ──────────────────────────────────
        "global_workflow.list" => serde_json::to_value(
            commands::list_global_workflows(state)
                .await
                .map_err(|e| ("internal_error".to_string(), e))?,
        )
        .map_err(|e| ("internal_error".to_string(), e.to_string()))?,
        "global_workflow.get" => {
            let id =
                parse_string_param(params, "id").map_err(|e| ("invalid_params".to_string(), e))?;
            serde_json::to_value(
                commands::get_global_workflow(id, state)
                    .await
                    .map_err(|e| ("internal_error".to_string(), e))?,
            )
            .map_err(|e| ("internal_error".to_string(), e.to_string()))?
        }
        "global_workflow.create" => {
            let name = parse_string_param(params, "name")
                .map_err(|e| ("invalid_params".to_string(), e))?;
            let definition_yaml = parse_string_param(params, "definition_yaml")
                .map_err(|e| ("invalid_params".to_string(), e))?;
            let description = parse_optional_string_param(params, "description");
            serde_json::to_value(
                commands::create_global_workflow(
                    commands::CreateGlobalWorkflowInput {
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
        "global_workflow.update" => {
            let id =
                parse_string_param(params, "id").map_err(|e| ("invalid_params".to_string(), e))?;
            let name = parse_optional_string_param(params, "name");
            let description = parse_optional_string_param(params, "description");
            let definition_yaml = parse_optional_string_param(params, "definition_yaml");
            serde_json::to_value(
                commands::update_global_workflow(
                    commands::UpdateGlobalWorkflowInput {
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
        "global_workflow.delete" => {
            let id =
                parse_string_param(params, "id").map_err(|e| ("invalid_params".to_string(), e))?;
            commands::delete_global_workflow(id, state)
                .await
                .map_err(|e| ("internal_error".to_string(), e))?;
            json!({"ok": true})
        }
        "global_workflow.copy_to_project" => {
            let id =
                parse_string_param(params, "id").map_err(|e| ("invalid_params".to_string(), e))?;
            let new_id = commands::copy_global_workflow_to_project(id, state)
                .await
                .map_err(|e| ("internal_error".to_string(), e))?;
            json!({"id": new_id})
        }
        "global_workflow.list_all" => serde_json::to_value(
            commands::list_all_workflows(state)
                .await
                .map_err(|e| ("internal_error".to_string(), e))?,
        )
        .map_err(|e| ("internal_error".to_string(), e.to_string()))?,
        "workflow.copy_to_global" => {
            let id =
                parse_string_param(params, "id").map_err(|e| ("invalid_params".to_string(), e))?;
            let new_id = commands::copy_workflow_to_global(id, state)
                .await
                .map_err(|e| ("internal_error".to_string(), e))?;
            json!({"id": new_id})
        }
        // ─── Global agent commands ─────────────────────────────────────
        "global_agent.list" => serde_json::to_value(
            commands::list_global_agents(state)
                .await
                .map_err(|e| ("internal_error".to_string(), e))?,
        )
        .map_err(|e| ("internal_error".to_string(), e.to_string()))?,
        "global_agent.get" => {
            let id =
                parse_string_param(params, "id").map_err(|e| ("invalid_params".to_string(), e))?;
            serde_json::to_value(
                commands::get_global_agent(id, state)
                    .await
                    .map_err(|e| ("internal_error".to_string(), e))?,
            )
            .map_err(|e| ("internal_error".to_string(), e.to_string()))?
        }
        "global_agent.create" => {
            let name = parse_string_param(params, "name")
                .map_err(|e| ("invalid_params".to_string(), e))?;
            let role = parse_optional_string_param(params, "role");
            let provider = parse_optional_string_param(params, "provider");
            let model = parse_optional_string_param(params, "model");
            let token_budget = params.get("token_budget").and_then(|v| v.as_i64());
            let timeout_minutes = params.get("timeout_minutes").and_then(|v| v.as_i64());
            let max_concurrent = params.get("max_concurrent").and_then(|v| v.as_i64());
            let stations: Option<Vec<String>> = params
                .get("stations")
                .and_then(|v| serde_json::from_value(v.clone()).ok());
            let config_json = parse_optional_string_param(params, "config_json");
            let system_prompt = parse_optional_string_param(params, "system_prompt");
            serde_json::to_value(
                commands::create_global_agent(
                    commands::CreateGlobalAgentInput {
                        name,
                        role,
                        provider,
                        model,
                        token_budget,
                        timeout_minutes,
                        max_concurrent,
                        stations,
                        config_json,
                        system_prompt,
                    },
                    state,
                )
                .await
                .map_err(|e| ("internal_error".to_string(), e))?,
            )
            .map_err(|e| ("internal_error".to_string(), e.to_string()))?
        }
        "global_agent.update" => {
            let id =
                parse_string_param(params, "id").map_err(|e| ("invalid_params".to_string(), e))?;
            let name = parse_optional_string_param(params, "name");
            let role = parse_optional_string_param(params, "role");
            let provider = parse_optional_string_param(params, "provider");
            let model = parse_optional_string_param(params, "model");
            let token_budget = params.get("token_budget").and_then(|v| v.as_i64());
            let timeout_minutes = params.get("timeout_minutes").and_then(|v| v.as_i64());
            let max_concurrent = params.get("max_concurrent").and_then(|v| v.as_i64());
            let stations: Option<Vec<String>> = params
                .get("stations")
                .and_then(|v| serde_json::from_value(v.clone()).ok());
            let config_json = parse_optional_string_param(params, "config_json");
            let system_prompt = parse_optional_string_param(params, "system_prompt");
            let active = params.get("active").and_then(|v| v.as_bool());
            serde_json::to_value(
                commands::update_global_agent(
                    commands::UpdateGlobalAgentInput {
                        id,
                        name,
                        role,
                        provider,
                        model,
                        token_budget,
                        timeout_minutes,
                        max_concurrent,
                        stations,
                        config_json,
                        system_prompt,
                        active,
                    },
                    state,
                )
                .await
                .map_err(|e| ("internal_error".to_string(), e))?,
            )
            .map_err(|e| ("internal_error".to_string(), e.to_string()))?
        }
        "global_agent.delete" => {
            let id =
                parse_string_param(params, "id").map_err(|e| ("invalid_params".to_string(), e))?;
            commands::delete_global_agent(id, state)
                .await
                .map_err(|e| ("internal_error".to_string(), e))?;
            json!({"ok": true})
        }
        "global_agent.copy_to_project" => {
            let id =
                parse_string_param(params, "id").map_err(|e| ("invalid_params".to_string(), e))?;
            let new_id = commands::copy_global_agent_to_project(id, state)
                .await
                .map_err(|e| ("internal_error".to_string(), e))?;
            json!({"id": new_id})
        }
        "global_agent.list_all" => serde_json::to_value(
            commands::list_all_agents(state)
                .await
                .map_err(|e| ("internal_error".to_string(), e))?,
        )
        .map_err(|e| ("internal_error".to_string(), e.to_string()))?,
        "session.new" => {
            {
                let current = state.current.lock().await;
                if current.is_none() {
                    return Err(("no_project".to_string(), "no open project".to_string()));
                }
            }
            let name = parse_optional_string_param(params, "name")
                .unwrap_or_else(|| "session".to_string());
            let cwd = parse_optional_string_param(params, "cwd").unwrap_or_else(|| ".".to_string());
            let command = parse_optional_string_param(params, "command").unwrap_or_default();
            let remote_target = params
                .get("remote_target")
                .cloned()
                .map(serde_json::from_value::<commands::SessionRemoteTargetInput>)
                .transpose()
                .map_err(|e| ("invalid_params".to_string(), e.to_string()))?;
            let session_id = commands::create_session(
                commands::SessionInput {
                    name,
                    cwd,
                    command,
                    remote_target,
                },
                state,
            )
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
        "session.list_live" => serde_json::to_value(
            commands::list_live_session_views(state)
                .await
                .map_err(|e| ("internal_error".to_string(), e))?,
        )
        .map_err(|e| ("internal_error".to_string(), e.to_string()))?,
        "session.kill" => {
            let session_id =
                parse_string_param_aliases(params, &["session_id", "id"], "session_id")
                    .map_err(|e| ("invalid_params".to_string(), e))?;
            let sid = Uuid::parse_str(&session_id)
                .map_err(|e| ("invalid_params".to_string(), e.to_string()))?;
            let supervisor = {
                let current = state.current.lock().await;
                current
                    .as_ref()
                    .ok_or_else(|| ("no_project".to_string(), "no open project".to_string()))?
                    .sessions
                    .clone()
            };
            serde_json::to_value(kill_live_session(&supervisor, sid).await)
                .map_err(|e| ("internal_error".to_string(), e.to_string()))?
        }
        "session.kill_all" => {
            let supervisor = {
                let current = state.current.lock().await;
                current
                    .as_ref()
                    .ok_or_else(|| ("no_project".to_string(), "no open project".to_string()))?
                    .sessions
                    .clone()
            };
            serde_json::to_value(kill_all_live_sessions(&supervisor).await)
                .map_err(|e| ("internal_error".to_string(), e.to_string()))?
        }
        "session.binding" => {
            let session_id =
                parse_string_param_aliases(params, &["session_id", "id"], "session_id")
                    .map_err(|e| ("invalid_params".to_string(), e))?;
            {
                let current = state.current.lock().await;
                if current.is_none() {
                    return Err(("no_project".to_string(), "no open project".to_string()));
                }
            }
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
            let cols_i64 = parse_optional_i64_param(params, "cols")
                .filter(|value| *value > 0)
                .ok_or_else(|| {
                    (
                        "invalid_params".to_string(),
                        "missing required positive integer param: cols".to_string(),
                    )
                })?;
            let cols = u16::try_from(cols_i64).map_err(|_| {
                (
                    "invalid_params".to_string(),
                    format!("cols value {} exceeds u16 range", cols_i64),
                )
            })?;
            let rows_i64 = parse_optional_i64_param(params, "rows")
                .filter(|value| *value > 0)
                .ok_or_else(|| {
                    (
                        "invalid_params".to_string(),
                        "missing required positive integer param: rows".to_string(),
                    )
                })?;
            let rows = u16::try_from(rows_i64).map_err(|_| {
                (
                    "invalid_params".to_string(),
                    format!("rows value {} exceeds u16 range", rows_i64),
                )
            })?;
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
        "fleet.action" => {
            let action = parse_string_param(params, "action")
                .map_err(|e| ("invalid_params".to_string(), e))?;
            let target_project_id = parse_optional_string_param(params, "project_id");
            let current_project_id = {
                let current = state.current.lock().await;
                current.as_ref().map(|ctx| ctx.project_id.to_string())
            };
            if let Some(target_project_id) = target_project_id {
                if current_project_id.as_deref() != Some(target_project_id.as_str()) {
                    return Err((
                        "internal_error".to_string(),
                        "fleet.action currently requires the target project to be open on this runtime"
                            .to_string(),
                    ));
                }
            }

            match action.as_str() {
                "kill_session" => {
                    let session_id = parse_string_param(params, "session_id")
                        .map_err(|e| ("invalid_params".to_string(), e))?;
                    let sid = Uuid::parse_str(&session_id)
                        .map_err(|e| ("invalid_params".to_string(), e.to_string()))?;
                    let supervisor = {
                        let current = state.current.lock().await;
                        current
                            .as_ref()
                            .ok_or_else(|| {
                                ("no_project".to_string(), "no open project".to_string())
                            })?
                            .sessions
                            .clone()
                    };
                    let result = kill_live_session(&supervisor, sid).await;
                    serde_json::to_value(commands::FleetActionResultView {
                        ok: matches!(result.outcome.as_str(), "killed" | "already_gone"),
                        action,
                        session_id: Some(session_id),
                    })
                    .map_err(|e| ("internal_error".to_string(), e.to_string()))?
                }
                "restart_session" | "reattach_session" => {
                    let session_id = parse_string_param(params, "session_id")
                        .map_err(|e| ("invalid_params".to_string(), e))?;
                    let recovery_action = if action == "restart_session" {
                        "restart".to_string()
                    } else {
                        "reattach".to_string()
                    };
                    let _ = commands::recover_session(
                        commands::SessionRecoveryInput {
                            session_id: session_id.clone(),
                            action: recovery_action,
                        },
                        &state.emitter,
                        state,
                    )
                    .await
                    .map_err(|e| ("internal_error".to_string(), e))?;
                    serde_json::to_value(commands::FleetActionResultView {
                        ok: true,
                        action,
                        session_id: Some(session_id),
                    })
                    .map_err(|e| ("internal_error".to_string(), e.to_string()))?
                }
                _ => {
                    return Err((
                        "invalid_params".to_string(),
                        format!("unsupported fleet action: {action}"),
                    ))
                }
            }
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
        "project.secrets.list" => {
            let input: commands::ProjectSecretListInput = serde_json::from_value(params.clone())
                .unwrap_or(commands::ProjectSecretListInput { scope: None });
            let rows = commands::list_project_secrets(input.scope, state)
                .await
                .map_err(|e| ("internal_error".to_string(), e))?;
            serde_json::to_value(rows).map_err(|e| ("internal_error".to_string(), e.to_string()))?
        }
        "project.secrets.upsert" => {
            let input: commands::ProjectSecretUpsertInput = serde_json::from_value(params.clone())
                .map_err(|e| ("invalid_params".to_string(), e.to_string()))?;
            let row = commands::upsert_project_secret(input, &state.emitter, state)
                .await
                .map_err(|e| ("internal_error".to_string(), e))?;
            serde_json::to_value(row).map_err(|e| ("internal_error".to_string(), e.to_string()))?
        }
        "project.secrets.delete" => {
            let input: commands::ProjectSecretDeleteInput = serde_json::from_value(params.clone())
                .map_err(|e| ("invalid_params".to_string(), e.to_string()))?;
            commands::delete_project_secret(input, &state.emitter, state)
                .await
                .map_err(|e| ("internal_error".to_string(), e))?;
            json!({"ok": true})
        }
        "project.secrets.import_env" => {
            let input: commands::ProjectSecretImportInput = serde_json::from_value(params.clone())
                .map_err(|e| ("invalid_params".to_string(), e.to_string()))?;
            let result = commands::import_project_secrets(input, &state.emitter, state)
                .await
                .map_err(|e| ("internal_error".to_string(), e))?;
            serde_json::to_value(result)
                .map_err(|e| ("internal_error".to_string(), e.to_string()))?
        }
        "project.secrets.export_env_template" => {
            let input: commands::ProjectSecretExportTemplateInput =
                serde_json::from_value(params.clone())
                    .unwrap_or(commands::ProjectSecretExportTemplateInput { path: None });
            let result = commands::export_project_secret_template(input, state)
                .await
                .map_err(|e| ("internal_error".to_string(), e))?;
            serde_json::to_value(result)
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
                Some(commands::ListProjectFilesInput {
                    query,
                    limit,
                    path: None,
                    recursive: None,
                }),
                state,
            )
            .await
            .map_err(|e| ("internal_error".to_string(), e))?;
            serde_json::to_value(items)
                .map_err(|e| ("internal_error".to_string(), e.to_string()))?
        }
        "workspace.files.tree" => {
            let query = parse_optional_string_param(params, "query");
            let limit = parse_optional_i64_param(params, "limit").map(|v| v.max(1) as usize);
            let path = parse_optional_string_param(params, "path");
            let recursive = parse_optional_bool_param(params, "recursive");
            let items = commands::list_project_file_tree(
                Some(commands::ListProjectFilesInput {
                    query,
                    limit,
                    path,
                    recursive,
                }),
                state,
            )
            .await
            .map_err(|e| ("internal_error".to_string(), e))?;
            serde_json::to_value(items)
                .map_err(|e| ("internal_error".to_string(), e.to_string()))?
        }
        "workspace.changes" => {
            let items = commands::list_workspace_changes(state)
                .await
                .map_err(|e| ("internal_error".to_string(), e))?;
            serde_json::to_value(items)
                .map_err(|e| ("internal_error".to_string(), e.to_string()))?
        }
        "workspace.change.diff" => {
            let path = parse_string_param(params, "path")
                .map_err(|e| ("invalid_params".to_string(), e))?;
            let diff =
                commands::get_workspace_change_diff(commands::ProjectFilePathInput { path }, state)
                    .await
                    .map_err(|e| ("internal_error".to_string(), e))?;
            serde_json::to_value(diff).map_err(|e| ("internal_error".to_string(), e.to_string()))?
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
        "workspace.file.write" => {
            let path = parse_string_param(params, "path")
                .map_err(|e| ("invalid_params".to_string(), e))?;
            // Use raw extraction instead of parse_string_param so empty/whitespace content is allowed.
            let content = params
                .get("content")
                .and_then(|v| v.as_str())
                .map(|s| s.to_string())
                .ok_or_else(|| {
                    (
                        "invalid_params".to_string(),
                        "missing required param: content".to_string(),
                    )
                })?;
            let result =
                commands::write_file_target(commands::WriteFileInput { path, content }, state)
                    .await
                    .map_err(|e| {
                        let code = if e.contains("not found")
                            || e.contains("escapes")
                            || e.contains("not a file")
                        {
                            "invalid_params"
                        } else if e.contains("no open project") {
                            "precondition_failed"
                        } else {
                            "internal_error"
                        };
                        (code.to_string(), e)
                    })?;
            serde_json::to_value(result)
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
        "settings.app.get" => serde_json::to_value(
            commands::get_app_settings(state)
                .await
                .map_err(|e| ("internal_error".to_string(), e))?,
        )
        .map_err(|e| ("internal_error".to_string(), e.to_string()))?,
        "settings.app.set" => {
            let input: commands::SetAppSettingsInput = serde_json::from_value(params.clone())
                .map_err(|e| ("invalid_params".to_string(), e.to_string()))?;
            let settings = commands::set_app_settings(input, state)
                .await
                .map_err(|e| ("internal_error".to_string(), e))?;
            serde_json::to_value(settings)
                .map_err(|e| ("internal_error".to_string(), e.to_string()))?
        }
        "usage.providers.overview" => {
            let input: commands::ProviderUsageOverviewInput = serde_json::from_value(
                params.clone(),
            )
            .unwrap_or(commands::ProviderUsageOverviewInput {
                force_refresh: false,
                local_usage_days: 30,
            });
            let overview = commands::get_provider_usage_overview(input, state)
                .await
                .map_err(|e| ("internal_error".to_string(), e))?;
            serde_json::to_value(overview)
                .map_err(|e| ("internal_error".to_string(), e.to_string()))?
        }
        "usage.providers.settings.get" => serde_json::to_value(
            commands::get_provider_usage_settings(state)
                .await
                .map_err(|e| ("internal_error".to_string(), e))?,
        )
        .map_err(|e| ("internal_error".to_string(), e.to_string()))?,
        "usage.providers.settings.set" => {
            let input: commands::SetProviderUsageSettingsInput =
                serde_json::from_value(params.clone())
                    .map_err(|e| ("invalid_params".to_string(), e.to_string()))?;
            let settings = commands::set_provider_usage_settings(input, state)
                .await
                .map_err(|e| ("internal_error".to_string(), e))?;
            serde_json::to_value(settings)
                .map_err(|e| ("internal_error".to_string(), e.to_string()))?
        }
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
        "ssh.create_profile" | "ssh.upsert_profile" => {
            let name = parse_string_param(params, "name")
                .map_err(|e| ("invalid_params".to_string(), e))?;
            let host = parse_string_param(params, "host")
                .map_err(|e| ("invalid_params".to_string(), e))?;
            let port_i64 = parse_optional_i64_param(params, "port").unwrap_or(22);
            let port = u16::try_from(port_i64).map_err(|_| {
                (
                    "invalid_params".to_string(),
                    format!("port value {} exceeds u16 range", port_i64),
                )
            })?;
            let input = commands::SshProfileInput {
                id: parse_optional_string_param(params, "id"),
                name,
                host,
                port,
                user: parse_optional_string_param(params, "user"),
                identity_file: parse_optional_string_param(params, "identity_file"),
                proxy_jump: parse_optional_string_param(params, "proxy_jump"),
                tags: Vec::new(),
                source: Some("manual".to_string()),
            };
            let id = commands::upsert_ssh_profile(input, state)
                .await
                .map_err(|e| ("internal_error".to_string(), e))?;
            json!({ "id": id })
        }
        "ssh.delete_profile" => {
            let id =
                parse_string_param(params, "id").map_err(|e| ("invalid_params".to_string(), e))?;
            commands::delete_ssh_profile(id, state)
                .await
                .map_err(|e| ("internal_error".to_string(), e))?;
            json!({ "ok": true })
        }
        "ssh.connect" => {
            let profile_id = parse_string_param(params, "profile_id")
                .map_err(|e| ("invalid_params".to_string(), e))?;
            let session_id = commands::connect_ssh(profile_id, state)
                .await
                .map_err(|e| ("internal_error".to_string(), e))?;
            json!({"session_id": session_id})
        }
        "ssh.disconnect" => {
            let profile_id = parse_string_param(params, "profile_id")
                .map_err(|e| ("invalid_params".to_string(), e))?;
            commands::disconnect_ssh(profile_id, state)
                .await
                .map_err(|e| ("internal_error".to_string(), e))?;
            json!({ "ok": true })
        }
        "ssh.runtime.ensure_helper" => {
            let profile_id = parse_string_param(params, "profile_id")
                .map_err(|e| ("invalid_params".to_string(), e))?;
            serde_json::to_value(
                commands::ensure_ssh_runtime_helper(profile_id, state)
                    .await
                    .map_err(|e| ("internal_error".to_string(), e))?,
            )
            .map_err(|e| ("internal_error".to_string(), e.to_string()))?
        }
        "ssh.runtime.health" => {
            let profile_id = parse_string_param(params, "profile_id")
                .map_err(|e| ("invalid_params".to_string(), e))?;
            serde_json::to_value(
                commands::ssh_runtime_health(profile_id, state)
                    .await
                    .map_err(|e| ("internal_error".to_string(), e))?,
            )
            .map_err(|e| ("internal_error".to_string(), e.to_string()))?
        }
        "ssh.files.read" => {
            let profile_id = parse_string_param(params, "profile_id")
                .map_err(|e| ("invalid_params".to_string(), e))?;
            let path = parse_string_param(params, "path")
                .map_err(|e| ("invalid_params".to_string(), e))?;
            let limit = parse_optional_i64_param(params, "limit").map(|v| v as usize);
            serde_json::to_value(
                commands::read_remote_file_contents(profile_id, path, limit, state)
                    .await
                    .map_err(|e| ("internal_error".to_string(), e))?,
            )
            .map_err(|e| ("internal_error".to_string(), e.to_string()))?
        }
        "ssh.files.list" => {
            let profile_id = parse_string_param(params, "profile_id")
                .map_err(|e| ("invalid_params".to_string(), e))?;
            let path = parse_string_param(params, "path")
                .map_err(|e| ("invalid_params".to_string(), e))?;
            serde_json::to_value(
                commands::list_remote_directory_entries(profile_id, path, state)
                    .await
                    .map_err(|e| ("internal_error".to_string(), e))?,
            )
            .map_err(|e| ("internal_error".to_string(), e.to_string()))?
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
        "usage.local_snapshot" => {
            let days = parse_optional_i64_param(params, "days");
            let from = parse_optional_string_param(params, "from");
            let to = parse_optional_string_param(params, "to");
            let snapshots = if from.is_some() || to.is_some() {
                commands::get_local_usage_for_dates(from, to).await
            } else {
                commands::get_local_usage(days).await
            };
            serde_json::to_value(snapshots)
                .map_err(|e| ("internal_error".to_string(), e.to_string()))?
        }
        "system.resource_snapshot" => serde_json::to_value(
            commands::get_resource_snapshot(state)
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
        "analytics.usage_summary" => {
            let scope = parse_optional_string_param(params, "scope");
            let from = parse_optional_string_param(params, "from");
            let to = parse_optional_string_param(params, "to");
            serde_json::to_value(
                commands::get_usage_summary(scope, from, to, state)
                    .await
                    .map_err(|e| ("internal_error".to_string(), e))?,
            )
            .map_err(|e| ("internal_error".to_string(), e.to_string()))?
        }
        "analytics.usage_sessions" => {
            let scope = parse_optional_string_param(params, "scope");
            let from = parse_optional_string_param(params, "from");
            let to = parse_optional_string_param(params, "to");
            serde_json::to_value(
                commands::get_usage_sessions(scope, from, to, state)
                    .await
                    .map_err(|e| ("internal_error".to_string(), e))?,
            )
            .map_err(|e| ("internal_error".to_string(), e.to_string()))?
        }
        "analytics.usage_tasks" => {
            let scope = parse_optional_string_param(params, "scope");
            let from = parse_optional_string_param(params, "from");
            let to = parse_optional_string_param(params, "to");
            serde_json::to_value(
                commands::get_usage_tasks(scope, from, to, state)
                    .await
                    .map_err(|e| ("internal_error".to_string(), e))?,
            )
            .map_err(|e| ("internal_error".to_string(), e.to_string()))?
        }
        "analytics.usage_diagnostics" => {
            let scope = parse_optional_string_param(params, "scope");
            let from = parse_optional_string_param(params, "from");
            let to = parse_optional_string_param(params, "to");
            serde_json::to_value(
                commands::get_usage_diagnostics(scope, from, to, state)
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
        "tracker.poll" => {
            let limit = parse_optional_i64_param(params, "limit").map(|v| v as usize);
            let labels = parse_optional_string_list_param(params, "labels");
            serde_json::to_value(
                commands::tracker_poll(commands::TrackerPollInput { limit, labels }, state)
                    .await
                    .map_err(|e| ("internal_error".to_string(), e))?,
            )
            .map_err(|e| ("internal_error".to_string(), e.to_string()))?
        }
        "tracker.status" => serde_json::to_value(
            commands::tracker_status(state)
                .await
                .map_err(|e| ("internal_error".to_string(), e))?,
        )
        .map_err(|e| ("internal_error".to_string(), e.to_string()))?,

        // ── Harness Config ──────────────────────────────────────────────
        "harness.config.list" => serde_json::to_value(
            commands::list_harness_configs(state)
                .await
                .map_err(|e| ("internal_error".to_string(), e))?,
        )
        .map_err(|e| ("internal_error".to_string(), e.to_string()))?,
        "harness.config.read" => {
            let key =
                parse_string_param(params, "key").map_err(|e| ("invalid_params".to_string(), e))?;
            serde_json::to_value(
                commands::read_harness_config(commands::ReadHarnessConfigInput { key }, state)
                    .await
                    .map_err(|e| ("internal_error".to_string(), e))?,
            )
            .map_err(|e| ("internal_error".to_string(), e.to_string()))?
        }
        "harness.config.write" => {
            let key =
                parse_string_param(params, "key").map_err(|e| ("invalid_params".to_string(), e))?;
            let content = parse_string_param(params, "content")
                .map_err(|e| ("invalid_params".to_string(), e))?;
            serde_json::to_value(
                commands::write_harness_config(
                    commands::WriteHarnessConfigInput { key, content },
                    state,
                )
                .await
                .map_err(|e| ("internal_error".to_string(), e))?,
            )
            .map_err(|e| ("internal_error".to_string(), e.to_string()))?
        }

        // ── Browser Tool Result ─────────────────────────────────────────
        "browser.tool_result" => {
            let call_id = parse_string_param(params, "call_id")
                .map_err(|e| ("invalid_params".to_string(), e))?;
            let result = params
                .get("result")
                .cloned()
                .unwrap_or(serde_json::json!({"error": "missing result"}));
            commands::browser_tools::complete_browser_tool_call(
                &call_id,
                result,
                &state.browser_tool_pending,
            );
            serde_json::json!({"ok": true})
        }

        // ── Plan Management ─────────────────────────────────────────────
        "plan.list" => commands::list_plans(state)
            .await
            .map_err(|e| ("internal_error".to_string(), e))?,
        "plan.read" => {
            let id =
                parse_string_param(params, "id").map_err(|e| ("invalid_params".to_string(), e))?;
            commands::read_plan(commands::PlanReadInput { id }, state)
                .await
                .map_err(|e| ("internal_error".to_string(), e))?
        }
        "plan.write" => {
            let id =
                parse_string_param(params, "id").map_err(|e| ("invalid_params".to_string(), e))?;
            let title = parse_optional_string_param(params, "title");
            let status = parse_optional_string_param(params, "status");
            let content = parse_optional_string_param(params, "content");
            commands::write_plan(
                commands::PlanWriteInput {
                    id,
                    title,
                    status,
                    content,
                },
                state,
            )
            .await
            .map_err(|e| ("internal_error".to_string(), e))?
        }
        "plan.delete" => {
            let id =
                parse_string_param(params, "id").map_err(|e| ("invalid_params".to_string(), e))?;
            commands::delete_plan(commands::PlanDeleteInput { id }, state)
                .await
                .map_err(|e| ("internal_error".to_string(), e))?
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
                password: SecretString::from(password.to_string()),
            },
            socket_rate_limit_rpm: 60,
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
            socket_rate_limit_rpm: 60,
        };
        let request = request_with_password(None);
        authorize_request(&request, &settings).expect("same-user mode should pass");
    }

    #[test]
    fn authorize_password_mode_rejects_privileged_commands() {
        let settings = password_settings("secret");
        let mut request = request_with_password(Some("secret"));
        // session.new is a privileged command
        request.method = "session.new".to_string();
        let err = authorize_request(&request, &settings)
            .expect_err("privileged command should be rejected in password mode");
        assert!(
            err.contains("privileged"),
            "error should mention 'privileged': {err}"
        );
    }

    #[test]
    fn authorize_password_mode_allows_standard_commands() {
        let settings = password_settings("secret");
        let mut request = request_with_password(Some("secret"));
        // task.new is a standard command
        request.method = "task.new".to_string();
        authorize_request(&request, &settings).expect("standard command should pass");
    }

    #[test]
    fn authorize_same_user_allows_privileged_commands() {
        let settings = ControlPlaneSettings {
            enabled: true,
            socket_path: PathBuf::from(".pnevma/run/control.sock"),
            auth_mode: ControlAuthMode::SameUser,
            socket_rate_limit_rpm: 60,
        };
        let mut request = request_with_password(None);
        request.method = "session.new".to_string();
        authorize_request(&request, &settings).expect("same-user mode should allow privileged");
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

    #[tokio::test]
    async fn workspace_files_tree_route_is_registered() {
        let state = AppState::new(Arc::new(NullEmitter));
        let err = route_method(&state, "workspace.files.tree", &json!({}))
            .await
            .expect_err("missing project should still route to the file tree handler");
        assert_eq!(err.0, "internal_error");
        assert_eq!(err.1, "no open project");
    }

    #[tokio::test]
    async fn git_checkout_route_is_registered() {
        let state = AppState::new(Arc::new(NullEmitter));
        let err = route_method(&state, "git.checkout", &json!({ "branch": "main" }))
            .await
            .expect_err("missing project should still route to the git.checkout handler");
        assert_eq!(err.0, "internal_error");
        assert_eq!(err.1, "no open project");
    }

    #[tokio::test]
    async fn fleet_snapshot_route_is_registered() {
        let state = AppState::new(Arc::new(NullEmitter));
        let value = route_method(&state, "fleet.snapshot", &Value::Null)
            .await
            .expect("fleet snapshot route should be available without an open project");
        assert!(value.get("machine_id").is_some());
        assert!(value.get("projects").is_some());
    }

    #[tokio::test]
    async fn fleet_action_route_is_registered() {
        let state = AppState::new(Arc::new(NullEmitter));
        let err = route_method(
            &state,
            "fleet.action",
            &json!({
                "action": "kill_session",
                "session_id": Uuid::new_v4().to_string(),
            }),
        )
        .await
        .expect_err("missing project should still hit the fleet action handler");
        assert_eq!(err.0, "no_project");
        assert_eq!(err.1, "no open project");
    }

    // ── G.6: route dispatch coverage ────────────────────────────────────

    #[tokio::test]
    async fn unknown_method_returns_method_not_found() {
        let state = AppState::new(Arc::new(NullEmitter));
        let err = route_method(&state, "nonexistent.method", &json!({}))
            .await
            .expect_err("unknown method should fail");
        assert_eq!(err.0, "method_not_found");
    }

    #[tokio::test]
    async fn unknown_namespace_returns_method_not_found() {
        let state = AppState::new(Arc::new(NullEmitter));
        let err = route_method(&state, "bogus.action", &json!({}))
            .await
            .expect_err("unknown namespace should fail");
        assert_eq!(err.0, "method_not_found");
    }

    #[tokio::test]
    async fn task_create_missing_params_returns_error() {
        let state = AppState::new(Arc::new(NullEmitter));
        let err = route_method(&state, "task.create", &json!({}))
            .await
            .expect_err("missing required params should fail");
        assert_eq!(err.0, "invalid_params");
    }

    #[tokio::test]
    async fn project_open_missing_path_returns_error() {
        let state = AppState::new(Arc::new(NullEmitter));
        let err = route_method(&state, "project.open", &json!({}))
            .await
            .expect_err("missing path should fail");
        assert_eq!(err.0, "invalid_params");
    }

    #[tokio::test]
    async fn environment_readiness_route_is_reachable() {
        let state = AppState::new(Arc::new(NullEmitter));
        // Should succeed even without an open project
        let result = route_method(&state, "environment.readiness", &json!({})).await;
        assert!(result.is_ok());
    }

    #[tokio::test]
    async fn keybindings_list_route_is_reachable() {
        let state = AppState::new(Arc::new(NullEmitter));
        // keybindings.list reads from a file — verify the route is reached,
        // not that it succeeds (it may error if the file doesn't exist)
        let result = route_method(&state, "keybindings.list", &json!({})).await;
        // Route is reachable if we get a value OR an internal_error (not method_not_found)
        match result {
            Ok(_) => {} // success is fine
            Err((code, _)) => assert_ne!(code, "method_not_found"),
        }
    }

    #[test]
    fn auth_failure_tracker_fires_at_threshold() {
        let tracker = AuthFailureTracker::new();
        let uid = 1001;
        for _ in 0..4 {
            assert!(
                !tracker.record_failure(uid),
                "should not fire below threshold"
            );
        }
        assert!(tracker.record_failure(uid), "should fire at threshold");
    }

    #[test]
    fn auth_failure_tracker_fires_once_per_window() {
        let tracker = AuthFailureTracker::new();
        let uid = 1002;
        for _ in 0..5 {
            tracker.record_failure(uid);
        }
        // Further failures in same window should not fire again
        assert!(
            !tracker.record_failure(uid),
            "should not fire twice in same window"
        );
    }

    #[test]
    fn auth_failure_tracker_isolates_uids() {
        let tracker = AuthFailureTracker::new();
        for _ in 0..5 {
            tracker.record_failure(1001);
        }
        // Different UID should not have reached threshold
        assert!(
            !tracker.record_failure(1002),
            "different UID should not inherit failures"
        );
    }

    #[test]
    fn debug_impl_redacts_control_auth_mode() {
        let mode = ControlAuthMode::Password {
            password: SecretString::from("top-secret"),
        };
        let output = format!("{:?}", mode);
        assert!(output.contains("[REDACTED]"));
        assert!(!output.contains("top-secret"));

        let same_user = ControlAuthMode::SameUser;
        let output = format!("{:?}", same_user);
        assert!(output.contains("SameUser"));
    }
}
