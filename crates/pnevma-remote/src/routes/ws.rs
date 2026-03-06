use axum::{
    extract::{
        ws::{Message, WebSocket, WebSocketUpgrade},
        ConnectInfo, State,
    },
    http::StatusCode,
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
const WS_PING_INTERVAL: Duration = Duration::from_secs(30);
const WS_IDLE_TIMEOUT: Duration = Duration::from_secs(90);

#[derive(Debug, Deserialize)]
struct SessionListEntry {
    id: String,
}

pub async fn ws_handler(
    ws: WebSocketUpgrade,
    ConnectInfo(addr): ConnectInfo<SocketAddr>,
    State(state): State<WsState>,
) -> impl IntoResponse {
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
            handle_socket(socket, state.router, state.remote_events).await;
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

fn is_valid_channel(name: &str) -> bool {
    !name.is_empty()
        && name.len() <= 64
        && name
            .chars()
            .all(|c| c.is_alphanumeric() || matches!(c, '_' | '-' | ':' | '.'))
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
) {
    let (mut sender, mut receiver) = socket.split();
    let mut subscribed_sessions: HashSet<String> = HashSet::new();
    let mut subscribed_channels: HashSet<String> = HashSet::new();
    let mut event_rx = remote_events.subscribe();

    let mut message_count: u32 = 0;
    let mut window_start = Instant::now();
    let mut last_client_activity = Instant::now();
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
                    let message = WsServerMessage::Error {
                        message: "rate limit exceeded: too many messages per second".to_string(),
                    };
                    if !send_ws_message(&mut sender, &message).await {
                        break;
                    }
                    continue;
                }

                let client_msg: WsClientMessage = match serde_json::from_str(&text) {
                    Ok(m) => m,
                    Err(e) => {
                        let message = WsServerMessage::Error {
                            message: format!("invalid message: {e}"),
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
                        } else if !subscribed_sessions.contains(&session_id) {
                            WsServerMessage::Error {
                                message: format!(
                                    "not subscribed to session {session_id} — subscribe first"
                                ),
                            }
                        } else {
                            let params = serde_json::json!({
                                "session_id": session_id,
                                "input": data
                            });
                            rpc_result(
                                "session.send_input".to_string(),
                                router.route("session.send_input", &params).await,
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
                        } else {
                            rpc_result(id, router.route(&method, &params).await)
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
        authorize_session_channel, event_channels, is_allowed_channel, is_valid_channel,
        is_valid_rpc_id, is_valid_rpc_method, validate_session_input, MAX_RPC_ID_LEN,
        MAX_RPC_METHOD_LEN, MAX_SESSION_INPUT_BYTES,
    };
    use crate::CommandRouter;
    use async_trait::async_trait;
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
}
