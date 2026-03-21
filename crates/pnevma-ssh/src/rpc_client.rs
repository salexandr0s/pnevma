use std::collections::HashMap;
use std::path::Path;
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::Arc;
use std::time::Duration;

use tokio::io::{AsyncBufReadExt, AsyncWriteExt, BufReader, BufWriter};
use tokio::net::UnixStream;
use tokio::sync::{oneshot, Mutex};

use crate::SshError;

const RPC_CALL_TIMEOUT: Duration = Duration::from_secs(10);

pub struct RpcClient {
    writer: Arc<Mutex<BufWriter<tokio::net::unix::OwnedWriteHalf>>>,
    pending: Arc<Mutex<HashMap<u64, oneshot::Sender<serde_json::Value>>>>,
    next_id: AtomicU64,
    alive: Arc<AtomicBool>,
    _reader_task: tokio::task::JoinHandle<()>,
}

impl RpcClient {
    pub async fn connect(socket_path: &Path) -> Result<Self, SshError> {
        let stream = UnixStream::connect(socket_path).await?;
        let (reader, writer) = stream.into_split();

        let pending: Arc<Mutex<HashMap<u64, oneshot::Sender<serde_json::Value>>>> =
            Arc::new(Mutex::new(HashMap::new()));
        let alive = Arc::new(AtomicBool::new(true));

        let pending_clone = pending.clone();
        let alive_clone = alive.clone();
        let reader_task = tokio::spawn(async move {
            let mut lines = BufReader::new(reader).lines();
            while let Ok(Some(line)) = lines.next_line().await {
                let Ok(value) = serde_json::from_str::<serde_json::Value>(&line) else {
                    continue;
                };
                // Only route responses (messages with an "id" field).
                // Notifications (no id) are silently dropped for now.
                if let Some(id) = value.get("id").and_then(|v| v.as_u64()) {
                    let mut map = pending_clone.lock().await;
                    if let Some(tx) = map.remove(&id) {
                        let _ = tx.send(value);
                    }
                }
            }
            alive_clone.store(false, Ordering::Release);
        });

        Ok(Self {
            writer: Arc::new(Mutex::new(BufWriter::new(writer))),
            pending,
            next_id: AtomicU64::new(1),
            alive,
            _reader_task: reader_task,
        })
    }

    pub fn is_alive(&self) -> bool {
        self.alive.load(Ordering::Acquire)
    }

    pub async fn call(
        &self,
        method: &str,
        params: serde_json::Value,
    ) -> Result<serde_json::Value, SshError> {
        if !self.is_alive() {
            return Err(SshError::Command("RPC connection closed".to_string()));
        }

        let id = self.next_id.fetch_add(1, Ordering::Relaxed);
        let request = serde_json::json!({
            "id": id,
            "method": method,
            "params": params,
        });
        let mut line = serde_json::to_string(&request)
            .map_err(|e| SshError::Command(format!("serialize error: {e}")))?;
        line.push('\n');

        let (tx, rx) = oneshot::channel();
        self.pending.lock().await.insert(id, tx);

        {
            let mut w = self.writer.lock().await;
            w.write_all(line.as_bytes()).await?;
            w.flush().await?;
        }

        let response = tokio::time::timeout(RPC_CALL_TIMEOUT, rx)
            .await
            .map_err(|_| SshError::Command("RPC call timed out".to_string()))?
            .map_err(|_| SshError::Command("RPC channel closed".to_string()))?;

        if let Some(error) = response.get("error") {
            if !error.is_null() {
                let message = error
                    .get("message")
                    .and_then(|m| m.as_str())
                    .unwrap_or("unknown RPC error");
                return Err(SshError::Command(message.to_string()));
            }
        }

        response
            .get("result")
            .cloned()
            .ok_or_else(|| SshError::Command("missing result in RPC response".to_string()))
    }
}

impl Drop for RpcClient {
    fn drop(&mut self) {
        self._reader_task.abort();
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use tokio::net::UnixListener;

    #[tokio::test]
    async fn client_sends_request_and_receives_response() {
        let dir = tempfile::tempdir().unwrap();
        let socket_path = dir.path().join("test.sock");

        let listener = UnixListener::bind(&socket_path).unwrap();

        // Mock server: echo back the request id with a fixed result.
        let server_handle = tokio::spawn(async move {
            let (stream, _) = listener.accept().await.unwrap();
            let (reader, mut writer) = tokio::io::split(stream);
            let mut lines = BufReader::new(reader).lines();
            if let Ok(Some(line)) = lines.next_line().await {
                let req: serde_json::Value = serde_json::from_str(&line).unwrap();
                let id = req["id"].as_u64().unwrap();
                let resp = serde_json::json!({"id": id, "result": {"ok": true}});
                let mut resp_line = serde_json::to_string(&resp).unwrap();
                resp_line.push('\n');
                writer.write_all(resp_line.as_bytes()).await.unwrap();
                writer.flush().await.unwrap();
            }
        });

        let client = RpcClient::connect(&socket_path).await.unwrap();
        let result = client.call("health", serde_json::json!({})).await.unwrap();
        assert_eq!(result["ok"], true);

        server_handle.await.unwrap();
    }

    #[tokio::test]
    async fn client_reports_rpc_error() {
        let dir = tempfile::tempdir().unwrap();
        let socket_path = dir.path().join("test.sock");

        let listener = UnixListener::bind(&socket_path).unwrap();

        let server_handle = tokio::spawn(async move {
            let (stream, _) = listener.accept().await.unwrap();
            let (reader, mut writer) = tokio::io::split(stream);
            let mut lines = BufReader::new(reader).lines();
            if let Ok(Some(line)) = lines.next_line().await {
                let req: serde_json::Value = serde_json::from_str(&line).unwrap();
                let id = req["id"].as_u64().unwrap();
                let resp =
                    serde_json::json!({"id": id, "error": {"code": -1, "message": "not found"}});
                let mut resp_line = serde_json::to_string(&resp).unwrap();
                resp_line.push('\n');
                writer.write_all(resp_line.as_bytes()).await.unwrap();
                writer.flush().await.unwrap();
            }
        });

        let client = RpcClient::connect(&socket_path).await.unwrap();
        let err = client
            .call("session.status", serde_json::json!({"session_id": "nope"}))
            .await
            .unwrap_err();
        assert!(err.to_string().contains("not found"));

        server_handle.await.unwrap();
    }
}
