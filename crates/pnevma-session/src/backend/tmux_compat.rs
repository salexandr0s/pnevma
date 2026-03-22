use async_trait::async_trait;
use std::path::{Path, PathBuf};
use tokio::process::Command;
use tokio::sync::oneshot;
use uuid::Uuid;

use super::SessionBackendKillResult;
use super::{BackendHandle, SessionBackend, SessionBackendKind, SessionDurability};
use crate::error::SessionError;

/// Legacy tmux-based session backend.
///
/// Extracts all tmux interaction from the supervisor into a `SessionBackend`
/// implementation. Tmux sessions are durable (survive app restarts).
#[derive(Debug, Clone)]
pub struct TmuxCompatBackend {
    tmux_bin: PathBuf,
    script_bin: PathBuf,
    tmux_tmpdir: PathBuf,
}

impl TmuxCompatBackend {
    pub fn new(tmux_tmpdir: impl AsRef<Path>) -> Self {
        Self {
            tmux_bin: crate::resolve_binary("tmux"),
            script_bin: crate::resolve_binary("script"),
            tmux_tmpdir: tmux_tmpdir.as_ref().to_path_buf(),
        }
    }

    /// Create with a custom tmux binary path (for testing with fake tmux).
    #[cfg(test)]
    pub(crate) fn with_tmux_bin(tmux_tmpdir: impl AsRef<Path>, tmux_bin: PathBuf) -> Self {
        Self {
            tmux_bin,
            script_bin: crate::resolve_binary("script"),
            tmux_tmpdir: tmux_tmpdir.as_ref().to_path_buf(),
        }
    }

    pub fn tmux_tmpdir(&self) -> &Path {
        &self.tmux_tmpdir
    }

    async fn ensure_tmpdir(&self) -> Result<(), SessionError> {
        tokio::fs::create_dir_all(&self.tmux_tmpdir).await?;
        Ok(())
    }

    fn tmux_command(&self) -> Command {
        let mut cmd = Command::new(&self.tmux_bin);
        cmd.env("TMUX_TMPDIR", &self.tmux_tmpdir);
        cmd.env("PATH", gui_safe_path());
        cmd
    }

    fn script_command(&self) -> Command {
        let mut cmd = Command::new(&self.script_bin);
        cmd.env("TMUX_TMPDIR", &self.tmux_tmpdir);
        cmd.env("PATH", gui_safe_path());
        if let Some(term) = fallback_script_term(std::env::var_os("TERM")) {
            cmd.env("TERM", term);
        }
        cmd
    }

    /// Create the tmux session (server-side). Does not attach a client.
    async fn create_tmux_session(
        &self,
        session_id: Uuid,
        cwd: &str,
        command: &str,
    ) -> Result<(), SessionError> {
        self.ensure_tmpdir().await?;
        let name = tmux_name(session_id);

        if self.has_session(&name).await {
            return Ok(());
        }

        let explicit_shell = explicit_shell_command(command);

        let mut args = vec![
            "new-session".to_string(),
            "-d".to_string(),
            "-s".to_string(),
            name.clone(),
            "-c".to_string(),
            cwd.to_string(),
        ];
        if let Some(explicit_shell) = explicit_shell.as_ref() {
            args.push(explicit_shell.clone());
        }

        let out = self
            .tmux_command()
            .args(args)
            .output()
            .await
            .map_err(|e| SessionError::SpawnFailed(e.to_string()))?;

        if !out.status.success() {
            let stderr = String::from_utf8_lossy(&out.stderr).to_string();
            return Err(SessionError::SpawnFailed(format!(
                "tmux new-session failed: {}",
                stderr.trim()
            )));
        }

        // Hide the tmux status bar
        let _ = self
            .tmux_command()
            .args(["set", "-t", &name, "status", "off"])
            .output()
            .await;

        // Allow escape-sequence passthrough for Ghostty
        match self
            .tmux_command()
            .args(["set", "-t", &name, "allow-passthrough", "all"])
            .output()
            .await
        {
            Ok(out) if !out.status.success() => {
                let stderr = String::from_utf8_lossy(&out.stderr);
                tracing::warn!(
                    session_id = %session_id,
                    "tmux set allow-passthrough failed: {}",
                    stderr.trim()
                );
            }
            Err(e) => {
                tracing::warn!(
                    session_id = %session_id,
                    "tmux set allow-passthrough failed: {e}"
                );
            }
            _ => {}
        }

        // Send non-shell commands as literal keystrokes
        if !command.trim().is_empty() && explicit_shell.is_none() {
            tracing::warn!(
                session_id = %session_id,
                command = %command.trim(),
                "tmux send-keys fallback: command not in recognized shell allowlist"
            );
            let send_out = self
                .tmux_command()
                .args(["send-keys", "-t", &name, "-l", command])
                .output()
                .await
                .map_err(|e| SessionError::SpawnFailed(e.to_string()))?;

            if !send_out.status.success() {
                let stderr = String::from_utf8_lossy(&send_out.stderr).to_string();
                tracing::warn!(session_id = %session_id, "tmux send-keys failed: {}", stderr.trim());
            }

            let enter_out = self
                .tmux_command()
                .args(["send-keys", "-t", &name, "Enter"])
                .output()
                .await
                .map_err(|e| SessionError::SpawnFailed(e.to_string()))?;

            if !enter_out.status.success() {
                let stderr = String::from_utf8_lossy(&enter_out.stderr).to_string();
                tracing::warn!(session_id = %session_id, "tmux send-keys Enter failed: {}", stderr.trim());
            }
        }

        Ok(())
    }

    /// Attach a `script` client to an existing tmux session, returning I/O
    /// streams via `BackendHandle`.
    async fn attach_tmux_client(&self, session_id: Uuid) -> Result<BackendHandle, SessionError> {
        self.ensure_tmpdir().await?;
        let tmux_target = tmux_name(session_id);
        let tmux_bin_str = self.tmux_bin.to_string_lossy().to_string();

        let mut child = self
            .script_command()
            .args([
                "-q",
                "/dev/null",
                &tmux_bin_str,
                "attach-session",
                "-t",
                &tmux_target,
            ])
            .stdin(std::process::Stdio::piped())
            .stdout(std::process::Stdio::piped())
            .stderr(std::process::Stdio::piped())
            .spawn()
            .map_err(|e| SessionError::SpawnFailed(e.to_string()))?;

        let pid = child.id();
        let stdin = child
            .stdin
            .take()
            .ok_or_else(|| SessionError::SpawnFailed("attach stdin unavailable".to_string()))?;
        let stdout = child
            .stdout
            .take()
            .ok_or_else(|| SessionError::SpawnFailed("attach stdout unavailable".to_string()))?;
        let stderr = child.stderr.take();

        // Merge stdout + stderr concurrently via a channel-backed reader.
        // Each stream gets its own reader task; output is interleaved in arrival order.
        let reader: Box<dyn tokio::io::AsyncRead + Send + Unpin> = if let Some(stderr) = stderr {
            Box::new(ChannelMergedReader::new(stdout, stderr))
        } else {
            Box::new(stdout)
        };

        let (exit_tx, exit_rx) = oneshot::channel();
        let tmux_tmpdir = self.tmux_tmpdir.clone();
        let tmux_bin = self.tmux_bin.clone();
        tokio::spawn(async move {
            let code = child.wait().await.ok().and_then(|s| s.code());
            // Check if tmux session is still alive after script exits
            let tmux_alive =
                tmux_has_session_name(&tmux_name(session_id), &tmux_tmpdir, &tmux_bin).await;
            // If tmux is still alive, the client detached — not a real exit.
            // Send None to signal detach vs Some(code) for actual exit.
            let exit_code = if tmux_alive { None } else { code };
            let _ = exit_tx.send(exit_code);
        });

        Ok(BackendHandle {
            pid,
            reader,
            writer: Box::new(stdin),
            exit_notify: exit_rx,
        })
    }

    async fn has_session(&self, name: &str) -> bool {
        tmux_has_session_name(name, &self.tmux_tmpdir, &self.tmux_bin).await
    }
}

#[async_trait]
impl SessionBackend for TmuxCompatBackend {
    async fn create(
        &self,
        session_id: Uuid,
        cwd: &str,
        command: &str,
    ) -> Result<BackendHandle, SessionError> {
        self.create_tmux_session(session_id, cwd, command).await?;
        self.attach_tmux_client(session_id).await
    }

    async fn attach(&self, session_id: Uuid) -> Result<BackendHandle, SessionError> {
        if !self.has_session(&tmux_name(session_id)).await {
            return Err(SessionError::SpawnFailed(format!(
                "tmux session not found for {}",
                session_id
            )));
        }
        self.attach_tmux_client(session_id).await
    }

    async fn terminate(&self, session_id: Uuid) -> Result<SessionBackendKillResult, SessionError> {
        self.ensure_tmpdir().await?;
        let name = tmux_name(session_id);
        let out = self
            .tmux_command()
            .args(["kill-session", "-t", &name])
            .output()
            .await
            .map_err(|e| SessionError::SpawnFailed(e.to_string()))?;

        if out.status.success() {
            return Ok(SessionBackendKillResult::Killed);
        }

        let stderr = String::from_utf8_lossy(&out.stderr).to_string();
        if stderr.contains("can't find session") {
            return Ok(SessionBackendKillResult::AlreadyGone);
        }

        Err(SessionError::SpawnFailed(format!(
            "tmux kill-session failed: {}",
            stderr.trim()
        )))
    }

    async fn resize(&self, session_id: Uuid, cols: u16, rows: u16) -> Result<(), SessionError> {
        self.ensure_tmpdir().await?;
        let name = tmux_name(session_id);

        let out = self
            .tmux_command()
            .args([
                "resize-window",
                "-t",
                &name,
                "-x",
                &cols.to_string(),
                "-y",
                &rows.to_string(),
            ])
            .output()
            .await
            .map_err(|e| SessionError::SpawnFailed(e.to_string()))?;

        if !out.status.success() {
            let stderr = String::from_utf8_lossy(&out.stderr);
            if !stderr.contains("no current client") && !stderr.contains("can't find session") {
                return Err(SessionError::SpawnFailed(format!(
                    "tmux resize-window failed: {}",
                    stderr.trim()
                )));
            }
        }

        Ok(())
    }

    async fn is_alive(&self, session_id: Uuid) -> bool {
        self.has_session(&tmux_name(session_id)).await
    }

    fn backend_kind(&self) -> SessionBackendKind {
        SessionBackendKind::TmuxCompat
    }

    fn durability(&self) -> SessionDurability {
        SessionDurability::Durable
    }
}

/// Merged async reader that interleaves two streams concurrently.
///
/// Spawns a reader task per stream; output is forwarded through an mpsc
/// channel in arrival order. Correctly handles concurrent stdout + stderr.
struct ChannelMergedReader {
    rx: tokio::sync::mpsc::Receiver<Vec<u8>>,
    buf: Vec<u8>,
    offset: usize,
}

impl ChannelMergedReader {
    fn new<A, B>(primary: A, secondary: B) -> Self
    where
        A: tokio::io::AsyncRead + Send + Unpin + 'static,
        B: tokio::io::AsyncRead + Send + Unpin + 'static,
    {
        let (tx, rx) = tokio::sync::mpsc::channel(64);
        Self::spawn_reader(primary, tx.clone());
        Self::spawn_reader(secondary, tx);
        Self {
            rx,
            buf: Vec::new(),
            offset: 0,
        }
    }

    fn spawn_reader<R: tokio::io::AsyncRead + Send + Unpin + 'static>(
        mut reader: R,
        tx: tokio::sync::mpsc::Sender<Vec<u8>>,
    ) {
        tokio::spawn(async move {
            let mut buf = [0u8; 4096];
            loop {
                match tokio::io::AsyncReadExt::read(&mut reader, &mut buf).await {
                    Ok(0) | Err(_) => break,
                    Ok(n) => {
                        if tx.send(buf[..n].to_vec()).await.is_err() {
                            break;
                        }
                    }
                }
            }
        });
    }
}

impl tokio::io::AsyncRead for ChannelMergedReader {
    fn poll_read(
        self: std::pin::Pin<&mut Self>,
        cx: &mut std::task::Context<'_>,
        buf: &mut tokio::io::ReadBuf<'_>,
    ) -> std::task::Poll<std::io::Result<()>> {
        let this = self.get_mut();

        // Drain any buffered data first
        if this.offset < this.buf.len() {
            let remaining = &this.buf[this.offset..];
            let to_copy = remaining.len().min(buf.remaining());
            buf.put_slice(&remaining[..to_copy]);
            this.offset += to_copy;
            if this.offset >= this.buf.len() {
                this.buf.clear();
                this.offset = 0;
            }
            return std::task::Poll::Ready(Ok(()));
        }

        // Try to receive more data
        match this.rx.poll_recv(cx) {
            std::task::Poll::Ready(Some(data)) => {
                let to_copy = data.len().min(buf.remaining());
                buf.put_slice(&data[..to_copy]);
                if to_copy < data.len() {
                    this.buf = data;
                    this.offset = to_copy;
                }
                std::task::Poll::Ready(Ok(()))
            }
            std::task::Poll::Ready(None) => {
                // All senders dropped — EOF
                std::task::Poll::Ready(Ok(()))
            }
            std::task::Poll::Pending => std::task::Poll::Pending,
        }
    }
}

pub(crate) fn tmux_name(session_id: Uuid) -> String {
    format!("pnevma_{}", session_id.simple())
}

pub(crate) fn gui_safe_path() -> String {
    let extra = ["/opt/homebrew/bin", "/opt/homebrew/sbin", "/usr/local/bin"];
    let current = std::env::var("PATH").unwrap_or_default();
    let mut parts: Vec<&str> = extra
        .iter()
        .copied()
        .filter(|dir| !current.split(':').any(|p| p == *dir))
        .collect();
    if !current.is_empty() {
        parts.push(&current);
    }
    parts.join(":")
}

pub(crate) fn explicit_shell_command(command: &str) -> Option<String> {
    let trimmed = command.trim();
    if trimmed.is_empty() || trimmed.split_whitespace().count() != 1 {
        return None;
    }

    let shell_name = std::path::Path::new(trimmed)
        .file_name()
        .and_then(|name| name.to_str())?;

    ["zsh", "bash", "sh", "fish", "claude", "codex"]
        .contains(&shell_name)
        .then(|| trimmed.to_string())
}

pub(crate) fn fallback_script_term(term: Option<std::ffi::OsString>) -> Option<&'static str> {
    match term.as_ref().and_then(|term| term.to_str()) {
        Some(term) if !term.is_empty() && term != "dumb" && term != "unknown" => None,
        _ => Some("xterm-256color"),
    }
}

pub(crate) async fn tmux_has_session_name(name: &str, tmux_tmpdir: &Path, tmux_bin: &Path) -> bool {
    let _ = tokio::fs::create_dir_all(tmux_tmpdir).await;

    Command::new(tmux_bin)
        .env("TMUX_TMPDIR", tmux_tmpdir)
        .args(["has-session", "-t", name])
        .status()
        .await
        .map(|status| status.success())
        .unwrap_or(false)
}
