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
    routes::{
        api,
        ws::{ws_handler, WsClientMessage, WsServerMessage, WsState},
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
        let router: Arc<dyn CommandRouter> = router_impl.clone();
        let (events, _rx) = broadcast::channel(64);
        let ws_state = WsState {
            router: router.clone(),
            remote_events: events.clone(),
            connection_counts: Arc::new(DashMap::new()),
            max_ws_per_ip: 4,
        };

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
            );

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
    let frame = tokio::time::timeout(Duration::from_secs(2), stream.next())
        .await
        .expect("timely websocket message")
        .expect("websocket stream still open")
        .expect("websocket frame");

    let Message::Text(text) = frame else {
        panic!("expected text frame");
    };

    serde_json::from_str(&text).expect("valid ws server message")
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
