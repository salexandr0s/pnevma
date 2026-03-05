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
    net::{IpAddr, SocketAddr},
    sync::{
        atomic::{AtomicUsize, Ordering},
        Arc,
    },
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

    ws.on_upgrade(move |socket| async move {
        handle_socket(socket, state.router).await;
        // Release the slot when the connection closes.
        counter.fetch_sub(1, Ordering::SeqCst);
    })
}

async fn handle_socket(socket: WebSocket, router: Arc<dyn CommandRouter>) {
    let (mut sender, mut receiver) = socket.split();

    while let Some(Ok(msg)) = receiver.next().await {
        let text = match msg {
            Message::Text(t) => t,
            Message::Close(_) => break,
            _ => continue,
        };

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
                tracing::debug!(%channel, "WebSocket subscribe");
                WsServerMessage::Subscribed { channel }
            }
            WsClientMessage::Unsubscribe { channel } => {
                tracing::debug!(%channel, "WebSocket unsubscribe");
                WsServerMessage::Unsubscribed { channel }
            }
            WsClientMessage::SessionInput { session_id, data } => {
                let params = serde_json::json!({ "id": session_id, "data": data });
                match router.route("session.send_input", &params).await {
                    Ok(result) => WsServerMessage::RpcResult {
                        id: session_id,
                        ok: true,
                        result: Some(result),
                        error: None,
                    },
                    Err(e) => WsServerMessage::RpcResult {
                        id: session_id,
                        ok: false,
                        result: None,
                        error: Some(e),
                    },
                }
            }
            WsClientMessage::Rpc { id, method, params } => {
                if !super::rpc_allowlist::is_allowed(&method) {
                    WsServerMessage::RpcResult {
                        id,
                        ok: false,
                        result: None,
                        error: Some(format!("method not allowed via RPC: {method}")),
                    }
                } else {
                    match router.route(&method, &params).await {
                        Ok(result) => WsServerMessage::RpcResult {
                            id,
                            ok: true,
                            result: Some(result),
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
}
