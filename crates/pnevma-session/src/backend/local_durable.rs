use async_trait::async_trait;
use std::path::{Path, PathBuf};
use std::time::Duration;
use tokio::process::Command;
use tokio::sync::oneshot;
use uuid::Uuid;

use super::SessionBackendKillResult;
use super::{BackendHandle, SessionBackend, SessionBackendKind, SessionDurability};
use crate::error::SessionError;

/// Local durable session backend via pnevma-remote-helper.
///
/// Sessions survive app restarts because the actual shell process runs inside
/// a detached `pnevma-remote-helper session-runner` daemon. This backend
/// communicates with the helper via its RPC Unix socket for management
/// operations (create, terminate, resize, status) and spawns the helper's
/// `session attach` command as a child process for I/O relay.
#[derive(Debug, Clone)]
pub struct LocalDurableBackend {
    helper_bin: PathBuf,
    state_root: PathBuf,
}

impl LocalDurableBackend {
    pub fn new(helper_bin: impl AsRef<Path>, state_root: impl AsRef<Path>) -> Self {
        Self {
            helper_bin: helper_bin.as_ref().to_path_buf(),
            state_root: state_root.as_ref().to_path_buf(),
        }
    }

    pub fn state_root(&self) -> &Path {
        &self.state_root
    }

    /// Ensure the helper daemon (`pnevma-remote-helper serve`) is running.
    async fn ensure_daemon(&self) -> Result<(), SessionError> {
        let socket_path = self.state_root.join("control.sock");

        // Quick check: is the socket already connectable?
        if socket_path.exists() {
            let path = socket_path.clone();
            let connectable = tokio::task::spawn_blocking(move || {
                std::os::unix::net::UnixStream::connect(&path).is_ok()
            })
            .await
            .unwrap_or(false);
            if connectable {
                return Ok(());
            }
        }

        tokio::fs::create_dir_all(&self.state_root).await?;

        // Spawn the daemon detached.
        let child = Command::new(&self.helper_bin)
            .arg("serve")
            .env("PNEVMA_REMOTE_HELPER_STATE_ROOT", &self.state_root)
            .env("PNEVMA_REMOTE_HELPER_PATH", &self.helper_bin)
            .stdin(std::process::Stdio::null())
            .stdout(std::process::Stdio::null())
            .stderr(std::process::Stdio::null())
            .spawn()
            .map_err(|e| {
                SessionError::SpawnFailed(format!(
                    "failed to start helper daemon at {}: {e}",
                    self.helper_bin.display()
                ))
            })?;

        if let Some(pid) = child.id() {
            let pid_path = self.state_root.join("daemon.pid");
            let _ = tokio::fs::write(&pid_path, format!("{pid}\n")).await;
        }

        // Wait for the control socket to appear (up to 3s).
        for _ in 0..30 {
            tokio::time::sleep(Duration::from_millis(100)).await;
            if socket_path.exists() {
                let path = socket_path.clone();
                let ok = tokio::task::spawn_blocking(move || {
                    std::os::unix::net::UnixStream::connect(&path).is_ok()
                })
                .await
                .unwrap_or(false);
                if ok {
                    return Ok(());
                }
            }
        }

        Err(SessionError::SpawnFailed(
            "helper daemon started but control socket not available after 3s".to_string(),
        ))
    }

    /// Send a JSON-RPC request to the helper daemon and return the result.
    async fn rpc_call(
        &self,
        method: &str,
        params: serde_json::Value,
    ) -> Result<serde_json::Value, SessionError> {
        use tokio::io::{AsyncBufReadExt, AsyncWriteExt, BufReader};
        use tokio::net::UnixStream;

        let socket_path = self.state_root.join("control.sock");
        let stream = UnixStream::connect(&socket_path)
            .await
            .map_err(|e| SessionError::SpawnFailed(format!("cannot connect to helper: {e}")))?;
        let (reader, mut writer) = stream.into_split();

        let request = serde_json::json!({
            "id": 1,
            "method": method,
            "params": params,
        });
        let mut line = serde_json::to_string(&request)
            .map_err(|e| SessionError::SpawnFailed(format!("serialize rpc: {e}")))?;
        line.push('\n');
        writer.write_all(line.as_bytes()).await?;
        writer.flush().await?;

        let mut lines = BufReader::new(reader).lines();
        // Read lines until we get one with "id":1 (skip notifications).
        while let Ok(Some(resp_line)) = lines.next_line().await {
            let resp: serde_json::Value = match serde_json::from_str(&resp_line) {
                Ok(v) => v,
                Err(_) => continue,
            };
            // Skip push notifications (no "id" field).
            if resp.get("id").is_none() {
                continue;
            }
            if let Some(error) = resp.get("error") {
                let msg = error
                    .get("message")
                    .and_then(|m| m.as_str())
                    .unwrap_or("unknown rpc error");
                return Err(SessionError::SpawnFailed(msg.to_string()));
            }
            return resp
                .get("result")
                .cloned()
                .ok_or_else(|| SessionError::SpawnFailed("rpc: missing result".to_string()));
        }
        Err(SessionError::SpawnFailed(
            "rpc: connection closed without response".to_string(),
        ))
    }

    /// Spawn `pnevma-remote-helper session attach` as a child process and
    /// return a BackendHandle with its piped I/O.
    async fn spawn_attach_client(&self, session_id: Uuid) -> Result<BackendHandle, SessionError> {
        let mut child = Command::new(&self.helper_bin)
            .args(["session", "attach", "--session-id", &session_id.to_string()])
            .env("PNEVMA_REMOTE_HELPER_STATE_ROOT", &self.state_root)
            .env("PNEVMA_REMOTE_HELPER_PATH", &self.helper_bin)
            .stdin(std::process::Stdio::piped())
            .stdout(std::process::Stdio::piped())
            .stderr(std::process::Stdio::null())
            .spawn()
            .map_err(|e| SessionError::SpawnFailed(format!("attach spawn: {e}")))?;

        let pid = child.id();
        let stdin = child
            .stdin
            .take()
            .ok_or_else(|| SessionError::SpawnFailed("attach stdin unavailable".to_string()))?;
        let stdout = child
            .stdout
            .take()
            .ok_or_else(|| SessionError::SpawnFailed("attach stdout unavailable".to_string()))?;

        let (exit_tx, exit_rx) = oneshot::channel();
        let state_root = self.state_root.clone();
        let sid = session_id;
        tokio::spawn(async move {
            let code = child.wait().await.ok().and_then(|s| s.code());
            // Check if the session runner is still alive (detach vs real exit).
            let runner_alive = session_runner_alive(&state_root, sid).await;
            let exit_code = if runner_alive { None } else { code };
            let _ = exit_tx.send(exit_code);
        });

        Ok(BackendHandle {
            pid,
            reader: Box::new(stdout),
            writer: Box::new(stdin),
            exit_notify: exit_rx,
        })
    }

    /// Check whether the session runner process is alive by reading its PID file.
    async fn runner_alive(&self, session_id: Uuid) -> bool {
        session_runner_alive(&self.state_root, session_id).await
    }
}

async fn session_runner_alive(state_root: &Path, session_id: Uuid) -> bool {
    let pid_path = state_root
        .join("sessions")
        .join(session_id.to_string())
        .join("runner.pid");
    let Ok(contents) = tokio::fs::read_to_string(&pid_path).await else {
        return false;
    };
    let Ok(pid) = contents.trim().parse::<u32>() else {
        return false;
    };
    pid_is_alive(pid).await
}

async fn pid_is_alive(pid: u32) -> bool {
    Command::new("kill")
        .args(["-0", &pid.to_string()])
        .stdin(std::process::Stdio::null())
        .stdout(std::process::Stdio::null())
        .stderr(std::process::Stdio::null())
        .status()
        .await
        .map(|s| s.success())
        .unwrap_or(false)
}

async fn send_sigterm(pid: u32) {
    let _ = Command::new("kill")
        .args(["-TERM", &pid.to_string()])
        .stdin(std::process::Stdio::null())
        .stdout(std::process::Stdio::null())
        .stderr(std::process::Stdio::null())
        .status()
        .await;
}

/// Stop the helper daemon by sending SIGTERM to its PID.
pub async fn stop_helper_daemon(state_root: &Path) {
    let pid_path = state_root.join("daemon.pid");
    if let Ok(contents) = tokio::fs::read_to_string(&pid_path).await {
        if let Ok(pid) = contents.trim().parse::<u32>() {
            if pid > 0 {
                send_sigterm(pid).await;
            }
        }
    }
    let _ = tokio::fs::remove_file(&pid_path).await;
    let _ = tokio::fs::remove_file(state_root.join("control.sock")).await;
}

#[async_trait]
impl SessionBackend for LocalDurableBackend {
    async fn create(
        &self,
        session_id: Uuid,
        cwd: &str,
        command: &str,
    ) -> Result<BackendHandle, SessionError> {
        self.ensure_daemon().await?;
        self.rpc_call(
            "session.create",
            serde_json::json!({
                "session_id": session_id.to_string(),
                "cwd": cwd,
                "command": command,
            }),
        )
        .await?;

        // Give the runner a moment to start and set up the FIFO.
        tokio::time::sleep(Duration::from_millis(200)).await;

        self.spawn_attach_client(session_id).await
    }

    async fn attach(&self, session_id: Uuid) -> Result<BackendHandle, SessionError> {
        self.ensure_daemon().await?;

        if !self.runner_alive(session_id).await {
            return Err(SessionError::SpawnFailed(format!(
                "session runner not found for {session_id}"
            )));
        }

        self.spawn_attach_client(session_id).await
    }

    async fn terminate(&self, session_id: Uuid) -> Result<SessionBackendKillResult, SessionError> {
        // Try RPC first; fall back to direct PID kill if daemon is gone.
        match self
            .rpc_call(
                "session.terminate",
                serde_json::json!({"session_id": session_id.to_string()}),
            )
            .await
        {
            Ok(_) => Ok(SessionBackendKillResult::Killed),
            Err(_) => {
                // Daemon might be down. Check if runner is alive and kill directly.
                if self.runner_alive(session_id).await {
                    let pid_path = self
                        .state_root
                        .join("sessions")
                        .join(session_id.to_string())
                        .join("runner.pid");
                    if let Ok(contents) = tokio::fs::read_to_string(&pid_path).await {
                        if let Ok(pid) = contents.trim().parse::<u32>() {
                            send_sigterm(pid).await;
                        }
                    }
                    Ok(SessionBackendKillResult::Killed)
                } else {
                    Ok(SessionBackendKillResult::AlreadyGone)
                }
            }
        }
    }

    async fn resize(&self, session_id: Uuid, cols: u16, rows: u16) -> Result<(), SessionError> {
        self.rpc_call(
            "session.resize",
            serde_json::json!({
                "session_id": session_id.to_string(),
                "cols": cols,
                "rows": rows,
            }),
        )
        .await?;
        Ok(())
    }

    async fn is_alive(&self, session_id: Uuid) -> bool {
        self.runner_alive(session_id).await
    }

    fn backend_kind(&self) -> SessionBackendKind {
        SessionBackendKind::LocalDurable
    }

    fn durability(&self) -> SessionDurability {
        SessionDurability::Durable
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn backend_kind_and_durability() {
        let backend = LocalDurableBackend::new("/usr/bin/pnevma-remote-helper", "/tmp/test");
        assert_eq!(backend.backend_kind(), SessionBackendKind::LocalDurable);
        assert_eq!(backend.durability(), SessionDurability::Durable);
    }
}
