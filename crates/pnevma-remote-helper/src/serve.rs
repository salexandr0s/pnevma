use std::os::unix::fs::PermissionsExt;
use std::sync::Arc;

use tokio::io::{AsyncBufReadExt, AsyncWriteExt, BufReader, BufWriter};
use tokio::net::{UnixListener, UnixStream};
use tokio::sync::broadcast;

use crate::protocol::{
    RpcNotification, RpcRequest, RpcResponse, SessionCreateParams, SessionIdParams,
    SessionResizeParams, SessionSignalParams,
};
use crate::{HelperError, HelperPaths, HelperRuntime};

const CONTROL_SOCKET_NAME: &str = "control.sock";
const NOTIFICATION_CHANNEL_CAPACITY: usize = 64;

pub async fn run_serve(paths: HelperPaths) -> Result<(), HelperError> {
    let socket_path = paths.state_root.join(CONTROL_SOCKET_NAME);

    // Ensure state directory exists.
    paths.ensure_layout()?;

    // Clean up stale socket from a previous unclean shutdown.
    cleanup_stale_socket(&socket_path);

    let listener = UnixListener::bind(&socket_path)?;
    std::fs::set_permissions(&socket_path, std::fs::Permissions::from_mode(0o600))?;

    let runtime = Arc::new(HelperRuntime::new(paths));
    let (notify_tx, _) = broadcast::channel::<RpcNotification>(NOTIFICATION_CHANNEL_CAPACITY);

    // Start the session state watcher for push notifications.
    let watcher_handle = crate::watcher::spawn_session_watcher(runtime.clone(), notify_tx.clone());

    // Set up signal handlers for graceful shutdown.
    let mut sigterm = tokio::signal::unix::signal(tokio::signal::unix::SignalKind::terminate())?;
    let mut sigint = tokio::signal::unix::signal(tokio::signal::unix::SignalKind::interrupt())?;

    loop {
        tokio::select! {
            accept_result = listener.accept() => {
                match accept_result {
                    Ok((stream, _addr)) => {
                        let rt = runtime.clone();
                        let ntx = notify_tx.subscribe();
                        tokio::spawn(handle_connection(stream, rt, ntx));
                    }
                    Err(e) => {
                        eprintln!("accept error: {e}");
                    }
                }
            }
            _ = sigterm.recv() => break,
            _ = sigint.recv() => break,
        }
    }

    // Cleanup.
    let _ = std::fs::remove_file(&socket_path);
    watcher_handle.abort();
    Ok(())
}

fn cleanup_stale_socket(socket_path: &std::path::Path) {
    if socket_path.exists() {
        // Try connecting to see if a server is actually listening.
        match std::os::unix::net::UnixStream::connect(socket_path) {
            Ok(_) => {
                // Another serve instance is running — we should not remove it.
                // The caller will get a bind error, which is the correct behavior.
            }
            Err(_) => {
                // Stale socket — safe to remove.
                let _ = std::fs::remove_file(socket_path);
            }
        }
    }
}

async fn handle_connection(
    stream: UnixStream,
    runtime: Arc<HelperRuntime>,
    mut notifications: broadcast::Receiver<RpcNotification>,
) {
    let (reader, writer) = stream.into_split();
    let mut lines = BufReader::new(reader).lines();
    let writer = Arc::new(tokio::sync::Mutex::new(BufWriter::new(writer)));

    // Forward push notifications to this client.
    let notify_writer = writer.clone();
    let notify_task = tokio::spawn(async move {
        while let Ok(notification) = notifications.recv().await {
            let Ok(mut line) = serde_json::to_string(&notification) else {
                continue;
            };
            line.push('\n');
            let mut w = notify_writer.lock().await;
            if w.write_all(line.as_bytes()).await.is_err() {
                break;
            }
            let _ = w.flush().await;
        }
    });

    // Process request lines.
    while let Ok(Some(line)) = lines.next_line().await {
        let response = dispatch_request(&runtime, &line).await;
        let Ok(mut response_line) = serde_json::to_string(&response) else {
            continue;
        };
        response_line.push('\n');
        let mut w = writer.lock().await;
        if w.write_all(response_line.as_bytes()).await.is_err() {
            break;
        }
        let _ = w.flush().await;
    }

    notify_task.abort();
}

async fn dispatch_request(runtime: &Arc<HelperRuntime>, line: &str) -> RpcResponse {
    let request: RpcRequest = match serde_json::from_str(line) {
        Ok(r) => r,
        Err(e) => {
            return RpcResponse::err(0, -32700, format!("parse error: {e}"));
        }
    };

    let id = request.id;
    let result = match request.method.as_str() {
        "session.status" => handle_session_status(runtime, &request.params).await,
        "session.create" => handle_session_create(runtime, &request.params).await,
        "session.signal" => handle_session_signal(runtime, &request.params).await,
        "session.terminate" => handle_session_terminate(runtime, &request.params).await,
        "session.resize" => handle_session_resize(runtime, &request.params).await,
        "session.list" => handle_session_list(runtime).await,
        "health" => handle_health(runtime).await,
        other => Err(RpcResponse::err(
            id,
            -32601,
            format!("unknown method: {other}"),
        )),
    };

    match result {
        Ok(value) => RpcResponse::ok(id, value),
        Err(resp) => resp,
    }
}

async fn handle_session_status(
    runtime: &Arc<HelperRuntime>,
    params: &serde_json::Value,
) -> Result<serde_json::Value, RpcResponse> {
    let p: SessionIdParams = serde_json::from_value(params.clone())
        .map_err(|e| RpcResponse::err(0, -32602, format!("invalid params: {e}")))?;
    let rt = runtime.clone();
    let result = tokio::task::spawn_blocking(move || rt.session_status(&p.session_id))
        .await
        .map_err(|e| RpcResponse::err(0, -32603, format!("internal error: {e}")))?
        .map_err(|e| RpcResponse::err(0, -1, e.to_string()))?;
    serde_json::to_value(result)
        .map_err(|e| RpcResponse::err(0, -32603, format!("serialization error: {e}")))
}

async fn handle_session_create(
    runtime: &Arc<HelperRuntime>,
    params: &serde_json::Value,
) -> Result<serde_json::Value, RpcResponse> {
    let p: SessionCreateParams = serde_json::from_value(params.clone())
        .map_err(|e| RpcResponse::err(0, -32602, format!("invalid params: {e}")))?;
    let rt = runtime.clone();
    let result = tokio::task::spawn_blocking(move || {
        rt.create_session(&p.session_id, &p.cwd, p.command.as_deref())
    })
    .await
    .map_err(|e| RpcResponse::err(0, -32603, format!("internal error: {e}")))?
    .map_err(|e| RpcResponse::err(0, -1, e.to_string()))?;
    serde_json::to_value(result)
        .map_err(|e| RpcResponse::err(0, -32603, format!("serialization error: {e}")))
}

async fn handle_session_signal(
    runtime: &Arc<HelperRuntime>,
    params: &serde_json::Value,
) -> Result<serde_json::Value, RpcResponse> {
    let p: SessionSignalParams = serde_json::from_value(params.clone())
        .map_err(|e| RpcResponse::err(0, -32602, format!("invalid params: {e}")))?;
    let rt = runtime.clone();
    tokio::task::spawn_blocking(move || rt.signal_session(&p.session_id, &p.signal))
        .await
        .map_err(|e| RpcResponse::err(0, -32603, format!("internal error: {e}")))?
        .map_err(|e| RpcResponse::err(0, -1, e.to_string()))?;
    Ok(serde_json::json!({"ok": true}))
}

async fn handle_session_terminate(
    runtime: &Arc<HelperRuntime>,
    params: &serde_json::Value,
) -> Result<serde_json::Value, RpcResponse> {
    let p: SessionIdParams = serde_json::from_value(params.clone())
        .map_err(|e| RpcResponse::err(0, -32602, format!("invalid params: {e}")))?;
    let rt = runtime.clone();
    tokio::task::spawn_blocking(move || rt.terminate_session(&p.session_id))
        .await
        .map_err(|e| RpcResponse::err(0, -32603, format!("internal error: {e}")))?
        .map_err(|e| RpcResponse::err(0, -1, e.to_string()))?;
    Ok(serde_json::json!({"ok": true}))
}

async fn handle_session_resize(
    runtime: &Arc<HelperRuntime>,
    params: &serde_json::Value,
) -> Result<serde_json::Value, RpcResponse> {
    let p: SessionResizeParams = serde_json::from_value(params.clone())
        .map_err(|e| RpcResponse::err(0, -32602, format!("invalid params: {e}")))?;
    let rt = runtime.clone();
    tokio::task::spawn_blocking(move || rt.resize_session(&p.session_id, p.cols, p.rows))
        .await
        .map_err(|e| RpcResponse::err(0, -32603, format!("internal error: {e}")))?
        .map_err(|e| RpcResponse::err(0, -1, e.to_string()))?;
    Ok(serde_json::json!({"ok": true}))
}

async fn handle_session_list(
    runtime: &Arc<HelperRuntime>,
) -> Result<serde_json::Value, RpcResponse> {
    let rt = runtime.clone();
    let sessions = tokio::task::spawn_blocking(move || rt.list_sessions())
        .await
        .map_err(|e| RpcResponse::err(0, -32603, format!("internal error: {e}")))?
        .map_err(|e| RpcResponse::err(0, -1, e.to_string()))?;
    serde_json::to_value(serde_json::json!({"sessions": sessions}))
        .map_err(|e| RpcResponse::err(0, -32603, format!("serialization error: {e}")))
}

async fn handle_health(runtime: &Arc<HelperRuntime>) -> Result<serde_json::Value, RpcResponse> {
    let rt = runtime.clone();
    let health = tokio::task::spawn_blocking(move || rt.health())
        .await
        .map_err(|e| RpcResponse::err(0, -32603, format!("internal error: {e}")))?
        .map_err(|e| RpcResponse::err(0, -1, e.to_string()))?;
    serde_json::to_value(health)
        .map_err(|e| RpcResponse::err(0, -32603, format!("serialization error: {e}")))
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::time::Duration;
    use tokio::io::{AsyncBufReadExt, AsyncWriteExt, BufReader};

    #[tokio::test]
    async fn serve_responds_to_health_request() {
        let root = tempfile::tempdir().unwrap();
        let paths = HelperPaths::new(root.path().join("helper"), root.path().join("state"));
        paths.ensure_layout().unwrap();
        let socket_path = paths.state_root.join(CONTROL_SOCKET_NAME);

        let serve_paths = paths.clone();
        let handle = tokio::spawn(async move {
            let _ = run_serve(serve_paths).await;
        });

        // Wait for socket to appear.
        for _ in 0..20 {
            if socket_path.exists() {
                break;
            }
            tokio::time::sleep(Duration::from_millis(50)).await;
        }

        let stream = tokio::net::UnixStream::connect(&socket_path).await.unwrap();
        let (reader, mut writer) = tokio::io::split(stream);

        writer
            .write_all(b"{\"id\":1,\"method\":\"health\",\"params\":{}}\n")
            .await
            .unwrap();
        writer.flush().await.unwrap();

        let mut lines = BufReader::new(reader).lines();
        let response_line = lines.next_line().await.unwrap().unwrap();
        let response: serde_json::Value = serde_json::from_str(&response_line).unwrap();

        assert_eq!(response["id"], 1);
        assert!(response["result"]["version"].is_string());
        assert!(response["result"]["protocol_version"].is_string());
        assert!(response["error"].is_null());

        handle.abort();
    }

    #[tokio::test]
    async fn serve_responds_to_session_list() {
        let root = tempfile::tempdir().unwrap();
        let paths = HelperPaths::new(root.path().join("helper"), root.path().join("state"));
        paths.ensure_layout().unwrap();
        let socket_path = paths.state_root.join(CONTROL_SOCKET_NAME);

        let serve_paths = paths.clone();
        let handle = tokio::spawn(async move {
            let _ = run_serve(serve_paths).await;
        });

        for _ in 0..20 {
            if socket_path.exists() {
                break;
            }
            tokio::time::sleep(Duration::from_millis(50)).await;
        }

        let stream = tokio::net::UnixStream::connect(&socket_path).await.unwrap();
        let (reader, mut writer) = tokio::io::split(stream);

        writer
            .write_all(b"{\"id\":2,\"method\":\"session.list\",\"params\":{}}\n")
            .await
            .unwrap();
        writer.flush().await.unwrap();

        let mut lines = BufReader::new(reader).lines();
        let response_line = lines.next_line().await.unwrap().unwrap();
        let response: serde_json::Value = serde_json::from_str(&response_line).unwrap();

        assert_eq!(response["id"], 2);
        let sessions = response["result"]["sessions"].as_array().unwrap();
        assert!(sessions.is_empty());
        assert!(response["error"].is_null());

        handle.abort();
    }

    #[tokio::test]
    async fn serve_returns_error_for_unknown_method() {
        let root = tempfile::tempdir().unwrap();
        let paths = HelperPaths::new(root.path().join("helper"), root.path().join("state"));
        paths.ensure_layout().unwrap();
        let socket_path = paths.state_root.join(CONTROL_SOCKET_NAME);

        let serve_paths = paths.clone();
        let handle = tokio::spawn(async move {
            let _ = run_serve(serve_paths).await;
        });

        for _ in 0..20 {
            if socket_path.exists() {
                break;
            }
            tokio::time::sleep(Duration::from_millis(50)).await;
        }

        let stream = tokio::net::UnixStream::connect(&socket_path).await.unwrap();
        let (reader, mut writer) = tokio::io::split(stream);

        writer
            .write_all(b"{\"id\":3,\"method\":\"bogus\",\"params\":{}}\n")
            .await
            .unwrap();
        writer.flush().await.unwrap();

        let mut lines = BufReader::new(reader).lines();
        let response_line = lines.next_line().await.unwrap().unwrap();
        let response: serde_json::Value = serde_json::from_str(&response_line).unwrap();

        assert_eq!(response["id"], 3);
        assert!(response["error"]["message"]
            .as_str()
            .unwrap()
            .contains("unknown method"));

        handle.abort();
    }

    #[test]
    fn stale_socket_is_cleaned_up() {
        let root = tempfile::tempdir().unwrap();
        let socket_path = root.path().join("control.sock");
        // Create a regular file pretending to be a stale socket.
        std::fs::write(&socket_path, b"stale").unwrap();
        cleanup_stale_socket(&socket_path);
        assert!(!socket_path.exists());
    }
}
