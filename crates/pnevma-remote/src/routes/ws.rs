use axum::{
    extract::{
        ws::{Message, WebSocket, WebSocketUpgrade},
        ConnectInfo, Extension, State,
    },
    http::{HeaderMap, StatusCode},
    response::IntoResponse,
};
use dashmap::DashMap;
use futures::{SinkExt, StreamExt};
use serde::{Deserialize, Serialize};
use serde_json::Value;
use std::{
    collections::HashSet,
    net::{IpAddr, SocketAddr},
    sync::{
        atomic::{AtomicUsize, Ordering},
        Arc,
    },
    time::{Duration, Instant},
};
use tokio::time::MissedTickBehavior;
use uuid::Uuid;

use crate::middleware::audit::{AuditAuthContext, AuthTokenSource};
use crate::CommandRouter;
use crate::RemoteEventEnvelope;

/// Shared per-IP WebSocket connection counter.
pub type WsConnectionCounts = Arc<DashMap<IpAddr, Arc<AtomicUsize>>>;

/// Combined state passed to the WS handler.
#[derive(Clone)]
pub struct WsState {
    pub router: Arc<dyn CommandRouter>,
    pub remote_events: tokio::sync::broadcast::Sender<RemoteEventEnvelope>,
    pub connection_counts: WsConnectionCounts,
    pub max_ws_per_ip: usize,
    pub allowed_origins: Vec<String>,
    pub allow_session_input: bool,
}

#[derive(Debug, Deserialize, Serialize)]
#[serde(tag = "type", rename_all = "snake_case")]
pub enum WsClientMessage {
    Subscribe {
        channel: String,
    },
    Unsubscribe {
        channel: String,
    },
    SessionInput {
        session_id: String,
        data: String,
    },
    Rpc {
        id: String,
        method: String,
        #[serde(default)]
        params: serde_json::Value,
    },
}

#[derive(Debug, Deserialize, Serialize)]
#[serde(tag = "type", rename_all = "snake_case")]
pub enum WsServerMessage {
    Subscribed {
        channel: String,
    },
    Unsubscribed {
        channel: String,
    },
    Event {
        channel: String,
        payload: serde_json::Value,
    },
    RpcResult {
        id: String,
        ok: bool,
        #[serde(skip_serializing_if = "Option::is_none")]
        result: Option<serde_json::Value>,
        #[serde(skip_serializing_if = "Option::is_none")]
        error: Option<String>,
    },
    Error {
        message: String,
    },
}

const ALLOWED_EVENT_CHANNELS: &[&str] = &[
    "fleet_updated",
    "project_opened",
    "task_updated",
    "notification_created",
    "notification_cleared",
    "notification_updated",
    "cost_updated",
];
const MAX_WS_MESSAGE_SIZE: usize = 65_536;
const MAX_MESSAGES_PER_SECOND: u32 = 60;
const MAX_SUBSCRIPTIONS_PER_CONNECTION: usize = 8;
const MAX_SESSION_INPUT_BYTES: usize = 16 * 1024;
const MAX_RPC_ID_LEN: usize = 128;
const MAX_RPC_METHOD_LEN: usize = 128;
const MAX_CONSECUTIVE_RATE_VIOLATIONS: u32 = 5;
const WS_PING_INTERVAL: Duration = Duration::from_secs(30);
const WS_IDLE_TIMEOUT: Duration = Duration::from_secs(90);

#[derive(Debug, Deserialize)]
struct SessionListEntry {
    id: String,
}

pub async fn ws_handler(
    ws: WebSocketUpgrade,
    headers: HeaderMap,
    ConnectInfo(addr): ConnectInfo<SocketAddr>,
    State(state): State<WsState>,
    auth: Option<Extension<AuditAuthContext>>,
) -> impl IntoResponse {
    let auth_context = auth.map(|Extension(ctx)| ctx);
    if let Err(status) = validate_ws_origin(&headers, auth_context.as_ref(), &state.allowed_origins)
    {
        return status.into_response();
    }

    let ip = addr.ip();
    let counts = state.connection_counts.clone();
    let max = state.max_ws_per_ip;

    // Atomically check and reserve a connection slot before upgrading.
    let counter = counts
        .entry(ip)
        .or_insert_with(|| Arc::new(AtomicUsize::new(0)))
        .clone();

    let current = counter.fetch_add(1, Ordering::SeqCst);
    if current >= max {
        // Exceeded limit — release the slot we just claimed and reject.
        counter.fetch_sub(1, Ordering::SeqCst);
        tracing::warn!(remote_ip = %ip, max, "WebSocket connection limit exceeded");
        return StatusCode::TOO_MANY_REQUESTS.into_response();
    }

    ws.max_message_size(MAX_WS_MESSAGE_SIZE)
        .on_upgrade(move |socket| async move {
            handle_socket(
                socket,
                state.router,
                state.remote_events,
                auth_context,
                state.allow_session_input,
            )
            .await;
            // Release the slot when the connection closes.
            counter.fetch_sub(1, Ordering::SeqCst);
        })
}

fn rpc_result(id: String, result: Result<serde_json::Value, String>) -> WsServerMessage {
    match result {
        Ok(value) => WsServerMessage::RpcResult {
            id,
            ok: true,
            result: Some(value),
            error: None,
        },
        Err(e) => WsServerMessage::RpcResult {
            id,
            ok: false,
            result: None,
            error: Some(e),
        },
    }
}

/// Sanitize a router error so internal details are never sent to the client.
fn sanitize_router_result(
    result: Result<serde_json::Value, String>,
    context: &str,
) -> Result<serde_json::Value, String> {
    result.map_err(|e| {
        let error_id = uuid::Uuid::new_v4().to_string();
        tracing::warn!(error_id = %error_id, context = %context, error = %e, "WS RPC call failed");
        format!("internal error (ref: {error_id})")
    })
}

fn is_valid_channel(name: &str) -> bool {
    !name.is_empty()
        && name.len() <= 64
        && name
            .chars()
            .all(|c| c.is_alphanumeric() || matches!(c, '_' | '-' | ':' | '.'))
}

fn normalize_origin(origin: &str) -> String {
    origin.trim().trim_end_matches('/').to_string()
}

fn configured_ws_origins(allowed_origins: &[String]) -> Vec<String> {
    if allowed_origins.is_empty() {
        vec!["https://localhost".to_string()]
    } else {
        allowed_origins
            .iter()
            .map(|origin| normalize_origin(origin))
            .collect()
    }
}

fn validate_ws_origin(
    headers: &HeaderMap,
    auth_context: Option<&AuditAuthContext>,
    allowed_origins: &[String],
) -> Result<(), StatusCode> {
    if let Some(origin) = headers.get(axum::http::header::ORIGIN) {
        let origin = origin.to_str().map_err(|_| StatusCode::FORBIDDEN)?;
        if configured_ws_origins(allowed_origins)
            .iter()
            .any(|allowed| allowed == &normalize_origin(origin))
        {
            return Ok(());
        }
        tracing::warn!(origin, "WebSocket origin rejected");
        return Err(StatusCode::FORBIDDEN);
    }

    if matches!(
        auth_context.and_then(|ctx| ctx.token_source),
        Some(AuthTokenSource::QueryParam)
    ) {
        tracing::warn!("WebSocket upgrade missing Origin while using query-token auth");
        return Err(StatusCode::FORBIDDEN);
    }

    Ok(())
}

fn session_channel_id(name: &str) -> Option<&str> {
    name.strip_prefix("session:")
}

fn is_allowed_channel(name: &str) -> bool {
    if !is_valid_channel(name) {
        return false;
    }

    if let Some(session_id) = session_channel_id(name) {
        return Uuid::parse_str(session_id).is_ok();
    }

    ALLOWED_EVENT_CHANNELS.contains(&name)
}

fn event_channels(event: &RemoteEventEnvelope) -> Vec<String> {
    let mut channels = vec![event.event.clone()];
    if matches!(
        event.event.as_str(),
        "project_opened"
            | "project_open_failed"
            | "task_updated"
            | "notification_created"
            | "notification_cleared"
            | "notification_updated"
            | "cost_updated"
            | "session_spawned"
            | "session_heartbeat"
            | "session_exited"
    ) {
        channels.push("fleet_updated".to_string());
    }
    if event.event == "session_output" {
        if let Some(session_id) = event.payload.get("session_id").and_then(|v| v.as_str()) {
            channels.push(format!("session:{session_id}"));
        }
    }
    channels
}

fn is_valid_rpc_id(id: &str) -> bool {
    !id.is_empty()
        && id.len() <= MAX_RPC_ID_LEN
        && id
            .chars()
            .all(|c| c.is_ascii_alphanumeric() || matches!(c, '_' | '-' | ':' | '.'))
}

fn is_valid_rpc_method(method: &str) -> bool {
    !method.is_empty()
        && method.len() <= MAX_RPC_METHOD_LEN
        && method
            .chars()
            .all(|c| c.is_ascii_alphanumeric() || matches!(c, '_' | '-' | '.'))
}

fn validate_session_input(session_id: &str, data: &str) -> Result<(), String> {
    Uuid::parse_str(session_id).map_err(|_| format!("invalid session id: {session_id}"))?;
    if data.len() > MAX_SESSION_INPUT_BYTES {
        return Err(format!(
            "session input exceeds {} byte limit",
            MAX_SESSION_INPUT_BYTES
        ));
    }
    if data.contains('\0') {
        return Err("session input must not contain NUL bytes".to_string());
    }
    Ok(())
}

async fn send_ws_message(
    sender: &mut futures::stream::SplitSink<WebSocket, Message>,
    message: &WsServerMessage,
) -> bool {
    let text = match serde_json::to_string(message) {
        Ok(t) => t,
        Err(e) => {
            tracing::error!("Failed to serialize WS response: {e}");
            return true;
        }
    };

    sender.send(Message::Text(text.into())).await.is_ok()
}

async fn authorize_session_channel(
    router: &Arc<dyn CommandRouter>,
    session_id: &str,
) -> Result<(), String> {
    Uuid::parse_str(session_id)
        .map_err(|_| format!("invalid session channel: session:{session_id}"))?;

    let value = router.route("session.list", &Value::Null).await?;
    let sessions: Vec<SessionListEntry> =
        serde_json::from_value(value).map_err(|e| format!("invalid session.list response: {e}"))?;

    if sessions.iter().any(|session| session.id == session_id) {
        Ok(())
    } else {
        Err(format!("session not found or not authorized: {session_id}"))
    }
}

async fn handle_socket(
    socket: WebSocket,
    router: Arc<dyn CommandRouter>,
    remote_events: tokio::sync::broadcast::Sender<RemoteEventEnvelope>,
    auth_context: Option<AuditAuthContext>,
    allow_session_input: bool,
) {
    let (mut sender, mut receiver) = socket.split();
    let mut subscribed_sessions: HashSet<String> = HashSet::new();
    let mut subscribed_channels: HashSet<String> = HashSet::new();
    let mut event_rx = remote_events.subscribe();

    let is_operator = auth_context
        .as_ref()
        .and_then(|ctx| ctx.role)
        .map(|r| r == crate::auth::TokenRole::Operator)
        .unwrap_or(false);

    let mut message_count: u32 = 0;
    let mut window_start = Instant::now();
    let mut last_client_activity = Instant::now();
    // Tracks consecutive 1-second windows where the client exceeded the rate
    // limit. Resets to 0 on any window where the client stays within limits
    // (see the `consecutive_rate_violations = 0` below). This means a client
    // is only disconnected after MAX_CONSECUTIVE_RATE_VIOLATIONS *consecutive*
    // over-limit windows — not a lifetime total.
    let mut consecutive_rate_violations: u32 = 0;
    let mut heartbeat = tokio::time::interval(WS_PING_INTERVAL);
    heartbeat.set_missed_tick_behavior(MissedTickBehavior::Delay);
    heartbeat.tick().await;

    loop {
        tokio::select! {
            event = event_rx.recv() => {
                match event {
                    Ok(event) => {
                        for channel in event_channels(&event) {
                            if !subscribed_channels.contains(&channel) {
                                continue;
                            }
                            let message = WsServerMessage::Event {
                                channel,
                                payload: event.payload.clone(),
                            };
                            if !send_ws_message(&mut sender, &message).await {
                                return;
                            }
                        }
                    }
                    Err(tokio::sync::broadcast::error::RecvError::Lagged(_)) => {}
                    Err(tokio::sync::broadcast::error::RecvError::Closed) => return,
                }
            }
            _ = heartbeat.tick() => {
                if Instant::now().duration_since(last_client_activity) > WS_IDLE_TIMEOUT {
                    let _ = sender.send(Message::Close(None)).await;
                    return;
                }
                if sender.send(Message::Ping(Vec::new().into())).await.is_err() {
                    return;
                }
            }
            maybe_msg = receiver.next() => {
                let Some(Ok(msg)) = maybe_msg else {
                    break;
                };

                let text = match msg {
                    Message::Text(t) => {
                        last_client_activity = Instant::now();
                        t
                    }
                    Message::Ping(payload) => {
                        last_client_activity = Instant::now();
                        if sender.send(Message::Pong(payload)).await.is_err() {
                            break;
                        }
                        continue;
                    }
                    Message::Pong(_) => {
                        last_client_activity = Instant::now();
                        continue;
                    }
                    Message::Binary(_) => {
                        let message = WsServerMessage::Error {
                            message: "binary websocket messages are not supported".to_string(),
                        };
                        if !send_ws_message(&mut sender, &message).await {
                            break;
                        }
                        continue;
                    }
                    Message::Close(_) => break,
                };

                let now = Instant::now();
                if now.duration_since(window_start).as_secs() >= 1 {
                    message_count = 0;
                    window_start = now;
                }
                message_count += 1;
                if message_count > MAX_MESSAGES_PER_SECOND {
                    consecutive_rate_violations += 1;
                    if consecutive_rate_violations >= MAX_CONSECUTIVE_RATE_VIOLATIONS {
                        tracing::warn!(
                            subject = auth_context.as_ref().map(|ctx| ctx.subject.as_str()).unwrap_or("-"),
                            violations = MAX_CONSECUTIVE_RATE_VIOLATIONS,
                            "disconnecting WebSocket client after consecutive rate-limit violations"
                        );
                        let _ = sender.send(Message::Close(None)).await;
                        break;
                    }
                    let message = WsServerMessage::Error {
                        message: "rate limit exceeded: too many messages per second".to_string(),
                    };
                    if !send_ws_message(&mut sender, &message).await {
                        break;
                    }
                    continue;
                }

                consecutive_rate_violations = 0;

                let client_msg: WsClientMessage = match serde_json::from_str(&text) {
                    Ok(m) => m,
                    Err(e) => {
                        tracing::debug!(error = %e, "malformed WebSocket message");
                        let message = WsServerMessage::Error {
                            message: "invalid message format".to_string(),
                        };
                        if !send_ws_message(&mut sender, &message).await {
                            break;
                        }
                        continue;
                    }
                };

                let response = match client_msg {
                    WsClientMessage::Subscribe { channel } => {
                        if !is_allowed_channel(&channel) {
                            WsServerMessage::Error {
                                message: format!("channel not allowed: {channel}"),
                            }
                        } else if !subscribed_channels.contains(&channel)
                            && subscribed_channels.len() >= MAX_SUBSCRIPTIONS_PER_CONNECTION
                        {
                            WsServerMessage::Error {
                                message: format!(
                                    "subscription limit exceeded: max {} channels per connection",
                                    MAX_SUBSCRIPTIONS_PER_CONNECTION
                                ),
                            }
                        } else if let Some(session_id) = session_channel_id(&channel) {
                            match authorize_session_channel(&router, session_id).await {
                                Ok(()) => {
                                    tracing::debug!(%channel, "WebSocket subscribe");
                                    subscribed_channels.insert(channel.clone());
                                    subscribed_sessions.insert(session_id.to_string());
                                    WsServerMessage::Subscribed { channel }
                                }
                                Err(message) => WsServerMessage::Error { message },
                            }
                        } else {
                            tracing::debug!(%channel, "WebSocket subscribe");
                            subscribed_channels.insert(channel.clone());
                            WsServerMessage::Subscribed { channel }
                        }
                    }
                    WsClientMessage::Unsubscribe { channel } => {
                        if !is_valid_channel(&channel) {
                            WsServerMessage::Error {
                                message: format!("invalid channel name: {channel}"),
                            }
                        } else {
                            tracing::debug!(%channel, "WebSocket unsubscribe");
                            subscribed_channels.remove(&channel);
                            if let Some(session_id) = channel.strip_prefix("session:") {
                                subscribed_sessions.remove(session_id);
                            }
                            WsServerMessage::Unsubscribed { channel }
                        }
                    }
                    WsClientMessage::SessionInput { session_id, data } => {
                        if let Err(message) = validate_session_input(&session_id, &data) {
                            WsServerMessage::Error { message }
                        } else if !allow_session_input {
                            tracing::warn!(
                                subject = auth_context
                                    .as_ref()
                                    .map(|ctx| ctx.subject.as_str())
                                    .unwrap_or("-"),
                                token_id = auth_context
                                    .as_ref()
                                    .and_then(|ctx| ctx.token_id.as_deref())
                                    .unwrap_or("-"),
                                session_id = %session_id,
                                "blocked remote session input attempt"
                            );
                            WsServerMessage::Error {
                                message: "remote session input is disabled by policy".to_string(),
                            }
                        } else if !subscribed_sessions.contains(&session_id) {
                            WsServerMessage::Error {
                                message: format!(
                                    "not subscribed to session {session_id} — subscribe first"
                                ),
                            }
                        } else {
                            tracing::warn!(
                                subject = auth_context
                                    .as_ref()
                                    .map(|ctx| ctx.subject.as_str())
                                    .unwrap_or("-"),
                                token_id = auth_context
                                    .as_ref()
                                    .and_then(|ctx| ctx.token_id.as_deref())
                                    .unwrap_or("-"),
                                session_id = %session_id,
                                "remote session input accepted"
                            );
                            let params = serde_json::json!({
                                "session_id": session_id,
                                "input": data
                            });
                            rpc_result(
                                "session.send_input".to_string(),
                                sanitize_router_result(
                                    router.route("session.send_input", &params).await,
                                    "session.send_input",
                                ),
                            )
                        }
                    }
                    WsClientMessage::Rpc { id, method, params } => {
                        if !is_valid_rpc_id(&id) {
                            rpc_result(id, Err("invalid rpc id".to_string()))
                        } else if !is_valid_rpc_method(&method) {
                            rpc_result(id, Err("invalid rpc method".to_string()))
                        } else if !super::rpc_allowlist::is_allowed(&method) {
                            rpc_result(id, Err(format!("method not allowed via RPC: {method}")))
                        } else if super::rpc_allowlist::requires_operator(&method) && !is_operator {
                            rpc_result(id, Err(format!("method requires operator role: {method}")))
                        } else {
                            rpc_result(
                                id,
                                sanitize_router_result(
                                    router.route(&method, &params).await,
                                    &method,
                                ),
                            )
                        }
                    }
                };

                if !send_ws_message(&mut sender, &response).await {
                    break;
                }
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::super::rpc_allowlist;
    use super::{
        authorize_session_channel, configured_ws_origins, event_channels, is_allowed_channel,
        is_valid_channel, is_valid_rpc_id, is_valid_rpc_method, validate_session_input,
        validate_ws_origin, MAX_RPC_ID_LEN, MAX_RPC_METHOD_LEN, MAX_SESSION_INPUT_BYTES,
    };
    use crate::middleware::audit::{AuditAuthContext, AuthTokenSource};
    use crate::CommandRouter;
    use async_trait::async_trait;
    use axum::http::{header, HeaderMap, StatusCode};
    use serde_json::{json, Value};
    use std::sync::Arc;
    use uuid::Uuid;

    #[test]
    fn ws_rpc_rejects_blocked_methods() {
        assert!(!rpc_allowlist::is_allowed("session.new"));
        assert!(!rpc_allowlist::is_allowed("trust_workspace"));
        assert!(!rpc_allowlist::is_allowed("ssh.connect"));
    }

    #[test]
    fn ws_rpc_allows_safe_methods() {
        assert!(rpc_allowlist::is_allowed("task.list"));
        assert!(rpc_allowlist::is_allowed("project.status"));
        assert!(!rpc_allowlist::is_allowed("workflow.create"));
        assert!(!rpc_allowlist::is_allowed("workflow.update"));
        assert!(!rpc_allowlist::is_allowed("workflow.delete"));
    }

    #[test]
    fn valid_channel_names_accepted() {
        assert!(is_valid_channel("session:abc-123"));
        assert!(is_valid_channel("tasks"));
        assert!(is_valid_channel("project.status"));
        assert!(is_valid_channel("a_b-c:d.e"));
    }

    #[test]
    fn invalid_channel_names_rejected() {
        assert!(!is_valid_channel(""));
        assert!(!is_valid_channel(&"a".repeat(65)));
        assert!(!is_valid_channel("foo bar"));
        assert!(!is_valid_channel("foo/bar"));
        assert!(!is_valid_channel("foo<bar>"));
        assert!(!is_valid_channel("test\n"));
    }

    #[test]
    fn allowed_channels_are_explicitly_bounded() {
        let session_id = Uuid::new_v4().to_string();
        assert!(is_allowed_channel("task_updated"));
        assert!(is_allowed_channel("notification_created"));
        assert!(is_allowed_channel(&format!("session:{session_id}")));
        assert!(!is_allowed_channel("session_output"));
        assert!(!is_allowed_channel("task.deleted"));
    }

    #[test]
    fn rpc_identifiers_and_methods_are_bounded() {
        assert!(is_valid_rpc_id("req-1"));
        assert!(!is_valid_rpc_id(""));
        assert!(!is_valid_rpc_id(&"a".repeat(MAX_RPC_ID_LEN + 1)));
        assert!(is_valid_rpc_method("task.list"));
        assert!(!is_valid_rpc_method("task list"));
        assert!(!is_valid_rpc_method(&"m".repeat(MAX_RPC_METHOD_LEN + 1)));
    }

    #[test]
    fn session_input_is_bounded_and_rejects_nul() {
        assert!(validate_session_input(&Uuid::new_v4().to_string(), "pwd\n").is_ok());
        assert!(validate_session_input("not-a-uuid", "pwd\n").is_err());
        assert!(validate_session_input(&Uuid::new_v4().to_string(), "\0").is_err());
        assert!(validate_session_input(
            &Uuid::new_v4().to_string(),
            &"x".repeat(MAX_SESSION_INPUT_BYTES + 1)
        )
        .is_err());
    }

    #[test]
    fn configured_ws_origins_fall_back_to_localhost() {
        assert_eq!(
            configured_ws_origins(&[]),
            vec!["https://localhost".to_string()]
        );
    }

    #[test]
    fn validate_ws_origin_accepts_configured_origin() {
        let mut headers = HeaderMap::new();
        headers.insert(header::ORIGIN, "https://example.com".parse().unwrap());
        assert!(validate_ws_origin(&headers, None, &["https://example.com".to_string()]).is_ok());
    }

    #[test]
    fn validate_ws_origin_rejects_query_token_without_origin() {
        let headers = HeaderMap::new();
        let auth = AuditAuthContext::websocket_authenticated(
            "operator".to_string(),
            "token123".to_string(),
            AuthTokenSource::QueryParam,
            crate::auth::TokenRole::Operator,
        );
        assert_eq!(
            validate_ws_origin(&headers, Some(&auth), &["https://example.com".to_string()]),
            Err(StatusCode::FORBIDDEN)
        );
    }

    #[test]
    fn validate_ws_origin_allows_header_auth_without_origin() {
        let headers = HeaderMap::new();
        let auth = AuditAuthContext::websocket_authenticated(
            "operator".to_string(),
            "token123".to_string(),
            AuthTokenSource::AuthorizationHeader,
            crate::auth::TokenRole::Operator,
        );
        assert!(
            validate_ws_origin(&headers, Some(&auth), &["https://example.com".to_string()]).is_ok()
        );
    }

    #[test]
    fn session_output_events_are_fanned_out_to_scoped_channel() {
        let session_id = Uuid::new_v4().to_string();
        let channels = event_channels(&crate::RemoteEventEnvelope {
            event: "session_output".to_string(),
            payload: json!({ "session_id": session_id }),
        });
        assert!(channels.contains(&"session_output".to_string()));
        assert!(channels
            .iter()
            .any(|channel| channel.starts_with("session:")));
    }

    #[test]
    fn fleet_relevant_events_are_fanned_out_to_fleet_updated() {
        let channels = event_channels(&crate::RemoteEventEnvelope {
            event: "session_heartbeat".to_string(),
            payload: json!({}),
        });
        assert!(channels.contains(&"session_heartbeat".to_string()));
        assert!(channels.contains(&"fleet_updated".to_string()));
    }

    #[derive(Clone)]
    struct StaticRouter {
        value: Result<Value, String>,
    }

    #[async_trait]
    impl CommandRouter for StaticRouter {
        async fn route(&self, _method: &str, _params: &Value) -> Result<Value, String> {
            self.value.clone()
        }
    }

    #[tokio::test]
    async fn session_channel_authorization_accepts_known_session() {
        let session_id = Uuid::new_v4().to_string();
        let router: Arc<dyn CommandRouter> = Arc::new(StaticRouter {
            value: Ok(json!([{ "id": session_id.clone() }])),
        });

        authorize_session_channel(&router, &session_id)
            .await
            .expect("known session should be authorized");
    }

    #[tokio::test]
    async fn session_channel_authorization_rejects_unknown_session() {
        let session_id = Uuid::new_v4().to_string();
        let router: Arc<dyn CommandRouter> = Arc::new(StaticRouter {
            value: Ok(json!([{ "id": Uuid::new_v4().to_string() }])),
        });

        let err = authorize_session_channel(&router, &session_id)
            .await
            .expect_err("unknown session should be rejected");
        assert!(err.contains("not authorized"));
    }

    #[tokio::test]
    async fn session_channel_authorization_rejects_invalid_router_response() {
        let router: Arc<dyn CommandRouter> = Arc::new(StaticRouter {
            value: Ok(json!({ "unexpected": true })),
        });

        let err = authorize_session_channel(&router, &Uuid::new_v4().to_string())
            .await
            .expect_err("invalid session list payload should be rejected");
        assert!(err.contains("invalid session.list response"));
    }

    #[test]
    fn requires_operator_returns_true_for_write_methods() {
        for method in rpc_allowlist::WRITE_METHODS {
            assert!(
                rpc_allowlist::requires_operator(method),
                "{method} should require operator role"
            );
        }
    }

    #[test]
    fn requires_operator_returns_false_for_read_methods() {
        for method in rpc_allowlist::READ_METHODS {
            assert!(
                !rpc_allowlist::requires_operator(method),
                "{method} should NOT require operator role"
            );
        }
    }

    #[test]
    fn is_operator_derived_from_token_role() {
        use crate::auth::TokenRole;

        let read_only_ctx = AuditAuthContext::websocket_authenticated(
            "user".to_string(),
            "tok1".to_string(),
            AuthTokenSource::AuthorizationHeader,
            TokenRole::ReadOnly,
        );
        let operator_ctx = AuditAuthContext::websocket_authenticated(
            "admin".to_string(),
            "tok2".to_string(),
            AuthTokenSource::AuthorizationHeader,
            TokenRole::Operator,
        );

        // ReadOnly → is_operator = false
        let is_op_readonly = read_only_ctx
            .role
            .map(|r| r == TokenRole::Operator)
            .unwrap_or(false);
        assert!(!is_op_readonly, "ReadOnly role must not be operator");

        // Operator → is_operator = true
        let is_op_operator = operator_ctx
            .role
            .map(|r| r == TokenRole::Operator)
            .unwrap_or(false);
        assert!(is_op_operator, "Operator role must be operator");

        // No auth context → is_operator = false
        let no_role: Option<TokenRole> = None;
        let is_op_none = no_role.map(|r| r == TokenRole::Operator).unwrap_or(false);
        assert!(!is_op_none, "None role must not be operator");
    }
}
