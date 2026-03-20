use std::{
    net::SocketAddr,
    sync::{Arc, Mutex},
    time::Duration,
};

use async_trait::async_trait;
use axum::{
    routing::{get, post},
    Router,
};
use dashmap::DashMap;
use futures::{SinkExt, StreamExt};
use pnevma_remote::{
    auth::TokenRole,
    routes::{
        api,
        ws::{
            ws_handler, WsClientMessage, WsServerMessage, WsState,
            DEFAULT_MAX_CONSECUTIVE_RATE_VIOLATIONS, DEFAULT_MAX_MESSAGES_PER_SECOND,
        },
    },
    CommandRouter, RemoteEventEnvelope,
};
use serde_json::{json, Value};
use tokio::{net::TcpListener, sync::broadcast, task::JoinHandle};
use tokio_tungstenite::{connect_async, tungstenite::Message};
use uuid::Uuid;

#[derive(Default)]
struct RecordingRouter {
    authorized_sessions: Mutex<Vec<String>>,
    calls: Mutex<Vec<(String, Value)>>,
}

impl RecordingRouter {
    fn with_authorized_session(session_id: String) -> Self {
        Self {
            authorized_sessions: Mutex::new(vec![session_id]),
            calls: Mutex::new(Vec::new()),
        }
    }

    fn recorded_call(&self, method: &str) -> Option<Value> {
        self.calls
            .lock()
            .expect("router call lock poisoned")
            .iter()
            .find_map(|(recorded_method, params)| {
                if recorded_method == method {
                    Some(params.clone())
                } else {
                    None
                }
            })
    }
}

#[async_trait]
impl CommandRouter for RecordingRouter {
    async fn route(&self, method: &str, params: &Value) -> Result<Value, String> {
        self.calls
            .lock()
            .expect("router call lock poisoned")
            .push((method.to_string(), params.clone()));

        match method {
            "session.list" => {
                let sessions = self
                    .authorized_sessions
                    .lock()
                    .expect("authorized session lock poisoned")
                    .clone();
                Ok(Value::Array(
                    sessions.into_iter().map(|id| json!({ "id": id })).collect(),
                ))
            }
            "session.send_input" => Ok(json!({ "ok": true })),
            "task.dispatch" => Ok(json!({ "status": "started" })),
            _ => Ok(json!({})),
        }
    }
}

struct TestServer {
    address: SocketAddr,
    events: broadcast::Sender<RemoteEventEnvelope>,
    join: JoinHandle<()>,
}

impl TestServer {
    async fn spawn(router_impl: Arc<RecordingRouter>) -> Self {
        Self::spawn_with_config(router_impl, true, 4).await
    }

    async fn spawn_with_config(
        router_impl: Arc<RecordingRouter>,
        allow_session_input: bool,
        max_ws_per_ip: usize,
    ) -> Self {
        Self::build(
            router_impl,
            allow_session_input,
            max_ws_per_ip,
            TokenRole::Operator,
        )
        .await
    }

    async fn spawn_with_role(router_impl: Arc<RecordingRouter>, role: TokenRole) -> Self {
        Self::build(router_impl, true, 4, role).await
    }

    async fn spawn_with_ws_rate_limit(
        router_impl: Arc<RecordingRouter>,
        max_messages_per_second: u32,
        max_consecutive_rate_violations: u32,
    ) -> Self {
        Self::build_with_limits(
            router_impl,
            true,
            4,
            role_operator(),
            max_messages_per_second,
            max_consecutive_rate_violations,
        )
        .await
    }

    async fn build(
        router_impl: Arc<RecordingRouter>,
        allow_session_input: bool,
        max_ws_per_ip: usize,
        role: TokenRole,
    ) -> Self {
        Self::build_with_limits(
            router_impl,
            allow_session_input,
            max_ws_per_ip,
            role,
            DEFAULT_MAX_MESSAGES_PER_SECOND,
            DEFAULT_MAX_CONSECUTIVE_RATE_VIOLATIONS,
        )
        .await
    }

    async fn build_with_limits(
        router_impl: Arc<RecordingRouter>,
        allow_session_input: bool,
        max_ws_per_ip: usize,
        role: TokenRole,
        max_messages_per_second: u32,
        max_consecutive_rate_violations: u32,
    ) -> Self {
        let router: Arc<dyn CommandRouter> = router_impl.clone();
        let (events, _rx) = broadcast::channel(64);
        let ws_state = WsState {
            router: router.clone(),
            remote_events: events.clone(),
            connection_counts: Arc::new(DashMap::new()),
            max_ws_per_ip,
            max_messages_per_second,
            max_consecutive_rate_violations,
            allowed_origins: vec![],
            allow_session_input,
        };

        // Inject a test auth context so RBAC-gated routes succeed.
        let inject_auth = axum::middleware::from_fn(
            move |mut req: axum::extract::Request, next: axum::middleware::Next| async move {
                req.extensions_mut().insert(
                    pnevma_remote::middleware::audit::AuditAuthContext::authenticated_request(
                        "test".to_string(),
                        "test-token".to_string(),
                        pnevma_remote::middleware::audit::AuthTokenSource::AuthorizationHeader,
                        role,
                    ),
                );
                next.run(req).await
            },
        );

        let app = Router::new()
            .merge(
                Router::new()
                    .route("/api/ws", get(ws_handler))
                    .with_state(ws_state),
            )
            .merge(
                Router::new()
                    .route("/api/tasks/{id}/dispatch", post(api::task_dispatch))
                    .with_state(router),
            )
            .layer(inject_auth);

        let listener = TcpListener::bind("127.0.0.1:0")
            .await
            .expect("bind test listener");
        let address = listener.local_addr().expect("listener address");
        let join = tokio::spawn(async move {
            axum::serve(
                listener,
                app.into_make_service_with_connect_info::<SocketAddr>(),
            )
            .await
            .expect("serve test app");
        });

        Self {
            address,
            events,
            join,
        }
    }
}

fn role_operator() -> TokenRole {
    TokenRole::Operator
}

impl Drop for TestServer {
    fn drop(&mut self) {
        self.join.abort();
    }
}

async fn read_ws_message(
    stream: &mut tokio_tungstenite::WebSocketStream<
        tokio_tungstenite::MaybeTlsStream<tokio::net::TcpStream>,
    >,
) -> WsServerMessage {
    loop {
        let frame = tokio::time::timeout(Duration::from_secs(2), stream.next())
            .await
            .expect("timely websocket message")
            .expect("websocket stream still open")
            .expect("websocket frame");

        match frame {
            Message::Text(text) => {
                return serde_json::from_str(&text).expect("valid ws server message");
            }
            Message::Ping(payload) => {
                stream
                    .send(Message::Pong(payload))
                    .await
                    .expect("respond to ping");
            }
            Message::Pong(_) => {}
            other => panic!("expected text-compatible websocket flow, got {other:?}"),
        }
    }
}

async fn try_read_ws_message(
    stream: &mut tokio_tungstenite::WebSocketStream<
        tokio_tungstenite::MaybeTlsStream<tokio::net::TcpStream>,
    >,
) -> Option<WsServerMessage> {
    loop {
        let next_frame = tokio::time::timeout(Duration::from_secs(2), stream.next())
            .await
            .ok()?;
        let frame = next_frame?.ok()?;

        match frame {
            Message::Text(text) => {
                return Some(serde_json::from_str(&text).expect("valid ws server message"));
            }
            Message::Ping(payload) => {
                stream
                    .send(Message::Pong(payload))
                    .await
                    .expect("respond to ping");
            }
            Message::Pong(_) => {}
            Message::Close(_) => return None,
            other => panic!("expected text-compatible websocket flow, got {other:?}"),
        }
    }
}

#[tokio::test]
async fn rest_dispatch_route_injects_task_id() {
    let router_impl = Arc::new(RecordingRouter::default());
    let server = TestServer::spawn(router_impl.clone()).await;

    let task_id = Uuid::new_v4().to_string();
    let response = reqwest::Client::new()
        .post(format!(
            "http://{}/api/tasks/{task_id}/dispatch",
            server.address
        ))
        .json(&json!({}))
        .send()
        .await
        .expect("dispatch request");

    assert!(response.status().is_success());
    assert_eq!(
        router_impl.recorded_call("task.dispatch"),
        Some(json!({ "task_id": task_id }))
    );
}

#[tokio::test]
async fn ws_requires_subscription_then_fans_out_authorized_session_events() {
    let session_id = Uuid::new_v4().to_string();
    let other_session_id = Uuid::new_v4().to_string();
    let router_impl = Arc::new(RecordingRouter::with_authorized_session(session_id.clone()));
    let server = TestServer::spawn(router_impl.clone()).await;

    let (mut stream, _) = connect_async(format!("ws://{}/api/ws", server.address))
        .await
        .expect("connect websocket");

    let send_input_before_subscribe = serde_json::to_string(&WsClientMessage::SessionInput {
        session_id: session_id.clone(),
        data: "pwd\n".to_string(),
    })
    .expect("serialize session input");
    stream
        .send(Message::Text(send_input_before_subscribe.into()))
        .await
        .expect("send session input before subscribe");

    match read_ws_message(&mut stream).await {
        WsServerMessage::Error { message } => {
            assert!(message.contains("subscribe first"));
        }
        other => panic!("expected subscription error, got {other:?}"),
    }

    let unauthorized_subscribe = serde_json::to_string(&WsClientMessage::Subscribe {
        channel: format!("session:{other_session_id}"),
    })
    .expect("serialize unauthorized subscribe");
    stream
        .send(Message::Text(unauthorized_subscribe.into()))
        .await
        .expect("send unauthorized subscribe");

    match read_ws_message(&mut stream).await {
        WsServerMessage::Error { message } => {
            assert!(message.contains("not authorized"));
        }
        other => panic!("expected authorization error, got {other:?}"),
    }

    let authorized_subscribe = serde_json::to_string(&WsClientMessage::Subscribe {
        channel: format!("session:{session_id}"),
    })
    .expect("serialize authorized subscribe");
    stream
        .send(Message::Text(authorized_subscribe.into()))
        .await
        .expect("send authorized subscribe");

    match read_ws_message(&mut stream).await {
        WsServerMessage::Subscribed { channel } => {
            assert_eq!(channel, format!("session:{session_id}"));
        }
        other => panic!("expected subscribed response, got {other:?}"),
    }

    server
        .events
        .send(RemoteEventEnvelope {
            event: "session_output".to_string(),
            payload: json!({ "session_id": other_session_id, "chunk": "ignore me" }),
        })
        .expect("send other session output");
    server
        .events
        .send(RemoteEventEnvelope {
            event: "session_output".to_string(),
            payload: json!({ "session_id": session_id, "chunk": "hello" }),
        })
        .expect("send authorized session output");

    match read_ws_message(&mut stream).await {
        WsServerMessage::Event { channel, payload } => {
            assert_eq!(channel, format!("session:{session_id}"));
            assert_eq!(payload.get("chunk").and_then(Value::as_str), Some("hello"));
        }
        other => panic!("expected session event, got {other:?}"),
    }

    let send_input_after_subscribe = serde_json::to_string(&WsClientMessage::SessionInput {
        session_id: session_id.clone(),
        data: "ls\n".to_string(),
    })
    .expect("serialize session input after subscribe");
    stream
        .send(Message::Text(send_input_after_subscribe.into()))
        .await
        .expect("send session input after subscribe");

    match read_ws_message(&mut stream).await {
        WsServerMessage::RpcResult { id, ok, result, .. } => {
            assert_eq!(id, "session.send_input");
            assert!(ok);
            assert_eq!(result, Some(json!({ "ok": true })));
        }
        other => panic!("expected rpc result, got {other:?}"),
    }

    assert_eq!(
        router_impl.recorded_call("session.send_input"),
        Some(json!({ "session_id": session_id, "input": "ls\n" }))
    );
}

#[tokio::test]
async fn ws_generic_event_subscriptions_fan_out() {
    let router_impl = Arc::new(RecordingRouter::default());
    let server = TestServer::spawn(router_impl).await;

    let (mut stream, _) = connect_async(format!("ws://{}/api/ws", server.address))
        .await
        .expect("connect websocket");

    let subscribe = serde_json::to_string(&WsClientMessage::Subscribe {
        channel: "task_updated".to_string(),
    })
    .expect("serialize generic subscribe");
    stream
        .send(Message::Text(subscribe.into()))
        .await
        .expect("send generic subscribe");

    match read_ws_message(&mut stream).await {
        WsServerMessage::Subscribed { channel } => assert_eq!(channel, "task_updated"),
        other => panic!("expected subscribed response, got {other:?}"),
    }

    server
        .events
        .send(RemoteEventEnvelope {
            event: "task_updated".to_string(),
            payload: json!({ "task_id": Uuid::new_v4().to_string() }),
        })
        .expect("send task update");

    match read_ws_message(&mut stream).await {
        WsServerMessage::Event { channel, payload } => {
            assert_eq!(channel, "task_updated");
            assert!(payload.get("task_id").is_some());
        }
        other => panic!("expected task event, got {other:?}"),
    }
}

#[tokio::test]
async fn ws_rejects_excessive_subscriptions() {
    let router_impl = Arc::new(RecordingRouter::default());
    let session_ids = vec![
        Uuid::new_v4().to_string(),
        Uuid::new_v4().to_string(),
        Uuid::new_v4().to_string(),
    ];
    *router_impl
        .authorized_sessions
        .lock()
        .expect("authorized session lock poisoned") = session_ids.clone();
    let server = TestServer::spawn(router_impl).await;

    let (mut stream, _) = connect_async(format!("ws://{}/api/ws", server.address))
        .await
        .expect("connect websocket");

    for channel in [
        "project_opened".to_string(),
        "task_updated".to_string(),
        "notification_created".to_string(),
        "notification_cleared".to_string(),
        "notification_updated".to_string(),
        "cost_updated".to_string(),
        format!("session:{}", session_ids[0]),
        format!("session:{}", session_ids[1]),
    ] {
        let subscribe = serde_json::to_string(&WsClientMessage::Subscribe { channel })
            .expect("serialize subscribe");
        stream
            .send(Message::Text(subscribe.into()))
            .await
            .expect("send subscribe");
        match read_ws_message(&mut stream).await {
            WsServerMessage::Subscribed { .. } => {}
            other => panic!("expected successful subscription, got {other:?}"),
        }
    }

    let subscribe = serde_json::to_string(&WsClientMessage::Subscribe {
        channel: format!("session:{}", session_ids[2]),
    })
    .expect("serialize capped subscribe");
    stream
        .send(Message::Text(subscribe.into()))
        .await
        .expect("send capped subscribe");

    match read_ws_message(&mut stream).await {
        WsServerMessage::Error { message } => {
            assert!(message.contains("subscription limit exceeded"));
        }
        other => panic!("expected subscription cap error, got {other:?}"),
    }
}

#[tokio::test]
async fn ws_rpc_blocks_workflow_definition_mutation() {
    let router_impl = Arc::new(RecordingRouter::default());
    let server = TestServer::spawn(router_impl).await;

    let (mut stream, _) = connect_async(format!("ws://{}/api/ws", server.address))
        .await
        .expect("connect websocket");

    let rpc = serde_json::to_string(&WsClientMessage::Rpc {
        id: "req-1".to_string(),
        method: "workflow.create".to_string(),
        params: json!({"name": "danger"}),
    })
    .expect("serialize blocked rpc");
    stream
        .send(Message::Text(rpc.into()))
        .await
        .expect("send blocked rpc");

    match read_ws_message(&mut stream).await {
        WsServerMessage::RpcResult { id, ok, error, .. } => {
            assert_eq!(id, "req-1");
            assert!(!ok);
            assert!(error
                .as_deref()
                .unwrap_or_default()
                .contains("method not allowed"));
        }
        other => panic!("expected rpc rejection, got {other:?}"),
    }
}

#[tokio::test]
async fn session_input_denied_when_config_disabled() {
    let session_id = Uuid::new_v4().to_string();
    let router_impl = Arc::new(RecordingRouter::with_authorized_session(session_id.clone()));
    let server = TestServer::spawn_with_config(router_impl, false, 4).await;

    let (mut stream, _) = connect_async(format!("ws://{}/api/ws", server.address))
        .await
        .expect("connect websocket");

    // Subscribe to the session channel first so that failure is about the policy,
    // not about missing subscription.
    let subscribe = serde_json::to_string(&WsClientMessage::Subscribe {
        channel: format!("session:{session_id}"),
    })
    .expect("serialize subscribe");
    stream
        .send(Message::Text(subscribe.into()))
        .await
        .expect("send subscribe");

    match read_ws_message(&mut stream).await {
        WsServerMessage::Subscribed { .. } => {}
        other => panic!("expected subscribed response, got {other:?}"),
    }

    let input = serde_json::to_string(&WsClientMessage::SessionInput {
        session_id: session_id.clone(),
        data: "pwd\n".to_string(),
    })
    .expect("serialize session input");
    stream
        .send(Message::Text(input.into()))
        .await
        .expect("send session input");

    match read_ws_message(&mut stream).await {
        WsServerMessage::Error { message } => {
            assert!(
                message.contains("disabled by policy"),
                "expected 'disabled by policy', got: {message}"
            );
        }
        other => panic!("expected policy error, got {other:?}"),
    }
}

#[tokio::test]
async fn session_input_denied_without_subscription() {
    let session_id = Uuid::new_v4().to_string();
    let router_impl = Arc::new(RecordingRouter::with_authorized_session(session_id.clone()));
    let server = TestServer::spawn_with_config(router_impl, true, 4).await;

    let (mut stream, _) = connect_async(format!("ws://{}/api/ws", server.address))
        .await
        .expect("connect websocket");

    // Do NOT subscribe — send input directly.
    let input = serde_json::to_string(&WsClientMessage::SessionInput {
        session_id: session_id.clone(),
        data: "pwd\n".to_string(),
    })
    .expect("serialize session input");
    stream
        .send(Message::Text(input.into()))
        .await
        .expect("send session input without subscription");

    match read_ws_message(&mut stream).await {
        WsServerMessage::Error { message } => {
            assert!(
                message.contains("subscribe first"),
                "expected 'subscribe first', got: {message}"
            );
        }
        other => panic!("expected subscription error, got {other:?}"),
    }
}

#[tokio::test]
async fn session_input_denied_for_readonly_role() {
    let session_id = Uuid::new_v4().to_string();
    let router_impl = Arc::new(RecordingRouter::with_authorized_session(session_id.clone()));
    let server = TestServer::spawn_with_role(router_impl, TokenRole::ReadOnly).await;

    let (mut stream, _) = connect_async(format!("ws://{}/api/ws", server.address))
        .await
        .expect("connect websocket");

    // Subscribe to the session channel so the role check is reached.
    let subscribe = serde_json::to_string(&WsClientMessage::Subscribe {
        channel: format!("session:{session_id}"),
    })
    .expect("serialize subscribe");
    stream
        .send(Message::Text(subscribe.into()))
        .await
        .expect("send subscribe");

    match read_ws_message(&mut stream).await {
        WsServerMessage::Subscribed { .. } => {}
        other => panic!("expected subscribed response, got {other:?}"),
    }

    let input = serde_json::to_string(&WsClientMessage::SessionInput {
        session_id: session_id.clone(),
        data: "ls\n".to_string(),
    })
    .expect("serialize session input");
    stream
        .send(Message::Text(input.into()))
        .await
        .expect("send session input as readonly");

    match read_ws_message(&mut stream).await {
        WsServerMessage::Error { message } => {
            assert!(
                message.contains("operator role"),
                "expected 'operator role', got: {message}"
            );
        }
        other => panic!("expected operator role error, got {other:?}"),
    }
}

#[tokio::test]
async fn session_input_allowed_narrow_positive() {
    let session_id = Uuid::new_v4().to_string();
    let router_impl = Arc::new(RecordingRouter::with_authorized_session(session_id.clone()));
    let server = TestServer::spawn(router_impl).await;

    let (mut stream, _) = connect_async(format!("ws://{}/api/ws", server.address))
        .await
        .expect("connect websocket");

    // Subscribe to the session channel.
    let subscribe = serde_json::to_string(&WsClientMessage::Subscribe {
        channel: format!("session:{session_id}"),
    })
    .expect("serialize subscribe");
    stream
        .send(Message::Text(subscribe.into()))
        .await
        .expect("send subscribe");

    match read_ws_message(&mut stream).await {
        WsServerMessage::Subscribed { .. } => {}
        other => panic!("expected subscribed response, got {other:?}"),
    }

    let input = serde_json::to_string(&WsClientMessage::SessionInput {
        session_id: session_id.clone(),
        data: "echo hello\n".to_string(),
    })
    .expect("serialize session input");
    stream
        .send(Message::Text(input.into()))
        .await
        .expect("send session input");

    match read_ws_message(&mut stream).await {
        WsServerMessage::RpcResult { ok, result, .. } => {
            assert!(ok, "expected ok: true for session input");
            assert_eq!(result, Some(json!({ "ok": true })));
        }
        other => panic!("expected rpc result, got {other:?}"),
    }
}

#[tokio::test]
async fn ws_rpc_rejects_operator_method_for_readonly() {
    let router_impl = Arc::new(RecordingRouter::default());
    let server = TestServer::spawn_with_role(router_impl, TokenRole::ReadOnly).await;

    let (mut stream, _) = connect_async(format!("ws://{}/api/ws", server.address))
        .await
        .expect("connect websocket");

    let rpc = serde_json::to_string(&WsClientMessage::Rpc {
        id: "req-readonly".to_string(),
        method: "task.dispatch".to_string(),
        params: json!({"task_id": "some-task"}),
    })
    .expect("serialize rpc");
    stream
        .send(Message::Text(rpc.into()))
        .await
        .expect("send rpc as readonly");

    match read_ws_message(&mut stream).await {
        WsServerMessage::RpcResult { id, ok, error, .. } => {
            assert_eq!(id, "req-readonly");
            assert!(!ok);
            assert!(
                error
                    .as_deref()
                    .unwrap_or_default()
                    .contains("requires operator role"),
                "expected 'requires operator role', got: {:?}",
                error
            );
        }
        other => panic!("expected rpc rejection, got {other:?}"),
    }
}

#[tokio::test]
async fn ws_per_ip_connection_cap_enforced() {
    let router_impl = Arc::new(RecordingRouter::default());
    let server = TestServer::spawn_with_config(router_impl, true, 2).await;

    // Open 2 WS connections successfully.
    let (_stream1, _) = connect_async(format!("ws://{}/api/ws", server.address))
        .await
        .expect("connect websocket 1");
    let (_stream2, _) = connect_async(format!("ws://{}/api/ws", server.address))
        .await
        .expect("connect websocket 2");

    // The 3rd connection should be rejected with 429 at the HTTP upgrade level.
    let result = connect_async(format!("ws://{}/api/ws", server.address)).await;
    match result {
        Err(tokio_tungstenite::tungstenite::Error::Http(response)) => {
            assert_eq!(
                response.status(),
                reqwest::StatusCode::TOO_MANY_REQUESTS,
                "expected 429 status, got {}",
                response.status()
            );
        }
        Err(other) => panic!("expected HTTP 429 error, got: {other:?}"),
        Ok(_) => panic!("expected 3rd connection to be rejected, but it succeeded"),
    }
}

#[tokio::test]
async fn ws_message_rate_burst_triggers_error() {
    let router_impl = Arc::new(RecordingRouter::default());
    let server = TestServer::spawn_with_ws_rate_limit(router_impl, 5, 2).await;

    let (mut stream, _) = connect_async(format!("ws://{}/api/ws", server.address))
        .await
        .expect("connect websocket");

    // Send >60 messages in a tight loop. Use Subscribe messages for channels
    // that will get "channel not allowed" errors — that is fine, the rate
    // limiter counts all messages regardless.
    for i in 0..20 {
        let msg = serde_json::to_string(&WsClientMessage::Subscribe {
            channel: format!("bogus_channel_{i}"),
        })
        .expect("serialize subscribe");
        if stream.send(Message::Text(msg.into())).await.is_err() {
            // Connection may have been closed by the server after rate violations.
            break;
        }
    }

    // Read responses — we expect at least one rate-limit error among them.
    let mut saw_rate_limit = false;
    for _ in 0..20 {
        match try_read_ws_message(&mut stream).await {
            Some(WsServerMessage::Error { message }) if message.contains("rate limit") => {
                saw_rate_limit = true;
                break;
            }
            Some(_) => {
                // "channel not allowed" or other responses — keep reading.
            }
            None => {
                // The server may have disconnected us after consecutive violations.
                break;
            }
        }
    }

    assert!(
        saw_rate_limit,
        "expected at least one rate-limit error in the response stream"
    );
}

#[tokio::test]
async fn ws_event_payload_does_not_leak_secrets() {
    // Verify that if an event payload contains secret-shaped strings,
    // the WS broadcast preserves whatever was sent (it doesn't add secrets).
    // In the real system, redaction happens before publishing to the broadcast
    // channel. This test verifies the WS layer is a faithful pass-through and
    // that a pre-redacted payload arrives intact.
    let session_id = Uuid::new_v4().to_string();
    let router_impl = Arc::new(RecordingRouter::with_authorized_session(session_id.clone()));
    let server = TestServer::spawn(router_impl).await;

    let (mut stream, _) = connect_async(format!("ws://{}/api/ws", server.address))
        .await
        .expect("connect websocket");

    // Subscribe to session channel
    let subscribe = serde_json::to_string(&WsClientMessage::Subscribe {
        channel: format!("session:{session_id}"),
    })
    .expect("serialize subscribe");
    stream
        .send(Message::Text(subscribe.into()))
        .await
        .expect("send subscribe");
    let _ = read_ws_message(&mut stream).await; // consume Subscribed

    // Send an event with pre-redacted content (simulating what pnevma-commands does).
    let redacted_chunk = "API key: [REDACTED] and token: [REDACTED]";
    server
        .events
        .send(RemoteEventEnvelope {
            event: "session_output".to_string(),
            payload: json!({
                "session_id": session_id,
                "chunk": redacted_chunk,
            }),
        })
        .expect("send redacted event");

    match read_ws_message(&mut stream).await {
        WsServerMessage::Event { payload, .. } => {
            let chunk = payload
                .get("chunk")
                .and_then(Value::as_str)
                .expect("chunk field");
            assert_eq!(
                chunk, redacted_chunk,
                "WS layer must faithfully transmit the pre-redacted payload"
            );
            assert!(
                !chunk.contains("sk-ant-api03"),
                "chunk must not contain raw API keys"
            );
            assert!(
                !chunk.contains("ghp_"),
                "chunk must not contain raw GitHub tokens"
            );
        }
        other => panic!("expected event, got {other:?}"),
    }
}
