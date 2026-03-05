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
use std::{
    collections::HashSet,
    net::{IpAddr, SocketAddr},
    sync::{
        atomic::{AtomicUsize, Ordering},
        Arc,
    },
    time::Instant,
};

use crate::CommandRouter;

/// Shared per-IP WebSocket connection counter.
pub type WsConnectionCounts = Arc<DashMap<IpAddr, Arc<AtomicUsize>>>;

/// Combined state passed to the WS handler.
#[derive(Clone)]
pub struct WsState {
    pub router: Arc<dyn CommandRouter>,
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

#[derive(Debug, Serialize)]
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

    ws.max_message_size(65_536)
        .on_upgrade(move |socket| async move {
            handle_socket(socket, state.router).await;
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

async fn handle_socket(socket: WebSocket, router: Arc<dyn CommandRouter>) {
    let (mut sender, mut receiver) = socket.split();
    let mut subscribed_sessions: HashSet<String> = HashSet::new();

    let mut message_count: u32 = 0;
    let mut window_start = Instant::now();
    const MAX_MESSAGES_PER_SECOND: u32 = 60;

    while let Some(Ok(msg)) = receiver.next().await {
        let text = match msg {
            Message::Text(t) => t,
            Message::Close(_) => break,
            _ => continue,
        };

        // Rate limit check
        let now = Instant::now();
        if now.duration_since(window_start).as_secs() >= 1 {
            message_count = 0;
            window_start = now;
        }
        message_count += 1;
        if message_count > MAX_MESSAGES_PER_SECOND {
            let err = serde_json::to_string(&WsServerMessage::Error {
                message: "rate limit exceeded: too many messages per second".to_string(),
            })
            .unwrap_or_default();
            let _ = sender.send(Message::Text(err.into())).await;
            continue;
        }

        let client_msg: WsClientMessage = match serde_json::from_str(&text) {
            Ok(m) => m,
            Err(e) => {
                let err = serde_json::to_string(&WsServerMessage::Error {
                    message: format!("invalid message: {e}"),
                })
                .unwrap_or_default();
                let _ = sender.send(Message::Text(err.into())).await;
                continue;
            }
        };

        let response = match client_msg {
            WsClientMessage::Subscribe { channel } => {
                if !is_valid_channel(&channel) {
                    WsServerMessage::Error {
                        message: format!("invalid channel name: {channel}"),
                    }
                } else {
                    tracing::debug!(%channel, "WebSocket subscribe");
                    // Track session subscriptions for access control
                    if let Some(session_id) = channel.strip_prefix("session:") {
                        subscribed_sessions.insert(session_id.to_string());
                    }
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
                    if let Some(session_id) = channel.strip_prefix("session:") {
                        subscribed_sessions.remove(session_id);
                    }
                    WsServerMessage::Unsubscribed { channel }
                }
            }
            // SessionInput is a dedicated typed message — it intentionally bypasses
            // the generic RPC allowlist since the WS connection is already authenticated.
            WsClientMessage::SessionInput { session_id, data } => {
                if !subscribed_sessions.contains(&session_id) {
                    WsServerMessage::Error {
                        message: format!(
                            "not subscribed to session {session_id} — subscribe first"
                        ),
                    }
                } else {
                    let params = serde_json::json!({ "id": session_id, "data": data });
                    rpc_result(
                        session_id,
                        router.route("session.send_input", &params).await,
                    )
                }
            }
            WsClientMessage::Rpc { id, method, params } => {
                if !super::rpc_allowlist::is_allowed(&method) {
                    rpc_result(id, Err(format!("method not allowed via RPC: {method}")))
                } else {
                    rpc_result(id, router.route(&method, &params).await)
                }
            }
        };

        let text = match serde_json::to_string(&response) {
            Ok(t) => t,
            Err(e) => {
                tracing::error!("Failed to serialize WS response: {e}");
                continue;
            }
        };

        if sender.send(Message::Text(text.into())).await.is_err() {
            break;
        }
    }
}

#[cfg(test)]
mod tests {
    use super::super::rpc_allowlist;
    use super::is_valid_channel;

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
}
