//! Rust-owned PTY session backend — no tmux dependency.
//!
//! Ported from `pnevma-remote-helper`'s `open_pty_pair` / `spawn_session_child` pattern,
//! adapted for tokio async I/O.
#![allow(unsafe_code)]

use async_trait::async_trait;
use std::collections::HashMap;
use std::os::fd::{AsRawFd, FromRawFd, OwnedFd};
use std::path::PathBuf;
use std::sync::Arc;
use tokio::io::{AsyncRead, AsyncWrite};
use tokio::sync::{oneshot, RwLock};
use uuid::Uuid;

use super::SessionBackendKillResult;
use super::{BackendHandle, SessionBackend, SessionBackendKind, SessionDurability};
use crate::error::SessionError;

/// A live PTY session tracked by the backend.
///
/// Holds an `Arc` to the master fd so it stays alive as long as the session
/// exists in the HashMap — preventing a use-after-free if `resize()` races
/// with child exit and fd close.
struct PtySession {
    pid: u32,
    master: Arc<tokio::io::unix::AsyncFd<OwnedFd>>,
}

/// Rust-owned PTY backend. Each session gets its own pseudo-terminal pair.
///
/// Sessions are ephemeral — they do not survive app restarts because the
/// master fd is lost when the process exits.
pub struct LocalPtyBackend {
    sessions: Arc<RwLock<HashMap<Uuid, PtySession>>>,
}

impl LocalPtyBackend {
    pub fn new() -> Self {
        Self {
            sessions: Arc::new(RwLock::new(HashMap::new())),
        }
    }
}

impl Default for LocalPtyBackend {
    fn default() -> Self {
        Self::new()
    }
}

#[async_trait]
impl SessionBackend for LocalPtyBackend {
    async fn create(
        &self,
        session_id: Uuid,
        cwd: &str,
        command: &str,
    ) -> Result<BackendHandle, SessionError> {
        let (master_fd, slave_fd) =
            open_pty_pair().map_err(|e| SessionError::SpawnFailed(e.to_string()))?;

        let cwd = PathBuf::from(cwd);
        let shell_command = if command.trim().is_empty() {
            resolve_user_shell()
        } else {
            command.to_string()
        };

        let mut child = spawn_pty_child(slave_fd, &cwd, &shell_command)
            .map_err(|e| SessionError::SpawnFailed(e.to_string()))?;

        let pid = child.id().ok_or_else(|| {
            SessionError::SpawnFailed("child exited before PID could be read".to_string())
        })?;

        // Wrap the master fd into async read/write halves.
        // We use AsyncFd for non-blocking I/O on the pty master.
        let master_async = tokio::io::unix::AsyncFd::new(master_fd)
            .map_err(|e| SessionError::SpawnFailed(format!("AsyncFd failed: {e}")))?;
        let master_arc = Arc::new(master_async);

        // Track the session — storing the Arc keeps the fd alive as long as
        // the session entry exists, preventing ioctl on a stale fd number.
        self.sessions.write().await.insert(
            session_id,
            PtySession {
                pid,
                master: master_arc.clone(),
            },
        );

        let reader = PtyReader {
            fd: master_arc.clone(),
        };
        let writer = PtyWriter { fd: master_arc };

        // Spawn exit-watcher task
        let (exit_tx, exit_rx) = oneshot::channel();
        let sessions = self.sessions.clone();
        tokio::spawn(async move {
            let code = child.wait().await.ok().and_then(|s| s.code());
            sessions.write().await.remove(&session_id);
            let _ = exit_tx.send(code);
        });

        Ok(BackendHandle {
            pid: Some(pid),
            reader: Box::new(reader),
            writer: Box::new(writer),
            exit_notify: exit_rx,
        })
    }

    async fn attach(&self, _session_id: Uuid) -> Result<BackendHandle, SessionError> {
        // LocalPty sessions don't support re-attach — the reader/writer are
        // consumed on creation. Re-attach would require the socket proxy
        // layer (Phase 3).
        Err(SessionError::SpawnFailed(
            "LocalPtyBackend does not support re-attach without proxy".to_string(),
        ))
    }

    async fn terminate(&self, session_id: Uuid) -> Result<SessionBackendKillResult, SessionError> {
        let session = self.sessions.write().await.remove(&session_id);
        let Some(session) = session else {
            return Ok(SessionBackendKillResult::AlreadyGone);
        };

        // SIGTERM first
        // SAFETY: sending a signal to a known PID
        let rc = unsafe { libc::kill(session.pid as i32, libc::SIGTERM) };
        if rc == -1 {
            let err = std::io::Error::last_os_error();
            if err.raw_os_error() == Some(libc::ESRCH) {
                return Ok(SessionBackendKillResult::AlreadyGone);
            }
            return Err(SessionError::SpawnFailed(format!(
                "kill SIGTERM failed: {err}"
            )));
        }

        // Wait up to 1s for graceful exit, then SIGKILL with PID verification
        let pid = session.pid as i32;
        tokio::spawn(async move {
            tokio::time::sleep(std::time::Duration::from_secs(1)).await;
            // SAFETY: waitpid checks if this PID is still our child before SIGKILL.
            // If waitpid returns the PID, the process already exited — skip SIGKILL.
            // If waitpid returns 0, the process is still alive — SIGKILL is safe.
            // If waitpid returns -1 (ECHILD), the PID is gone — skip SIGKILL.
            unsafe {
                let mut status: i32 = 0;
                let rc = libc::waitpid(pid, &mut status, libc::WNOHANG);
                if rc == 0 {
                    // Process still alive, safe to SIGKILL
                    libc::kill(pid, libc::SIGKILL);
                }
            }
        });

        Ok(SessionBackendKillResult::Killed)
    }

    async fn resize(&self, session_id: Uuid, cols: u16, rows: u16) -> Result<(), SessionError> {
        let sessions = self.sessions.read().await;
        let session = sessions
            .get(&session_id)
            .ok_or_else(|| SessionError::NotFound(session_id.to_string()))?;

        let winsize = libc::winsize {
            ws_row: rows,
            ws_col: cols,
            ws_xpixel: 0,
            ws_ypixel: 0,
        };

        // SAFETY: ioctl TIOCSWINSZ on a known master pty fd. The fd is
        // guaranteed alive because `PtySession` holds an Arc to the AsyncFd.
        let rc = unsafe {
            libc::ioctl(
                session.master.as_ref().as_raw_fd(),
                libc::TIOCSWINSZ,
                &winsize,
            )
        };
        if rc == -1 {
            return Err(SessionError::SpawnFailed(format!(
                "ioctl TIOCSWINSZ failed: {}",
                std::io::Error::last_os_error()
            )));
        }

        Ok(())
    }

    async fn is_alive(&self, session_id: Uuid) -> bool {
        let sessions = self.sessions.read().await;
        let Some(session) = sessions.get(&session_id) else {
            return false;
        };
        // SAFETY: kill(pid, 0) checks process existence without sending a signal
        unsafe { libc::kill(session.pid as i32, 0) == 0 }
    }

    fn backend_kind(&self) -> SessionBackendKind {
        SessionBackendKind::LocalPty
    }

    fn durability(&self) -> SessionDurability {
        SessionDurability::Ephemeral
    }
}

/// Open a PTY master/slave pair using `openpty()`.
fn open_pty_pair() -> Result<(OwnedFd, OwnedFd), std::io::Error> {
    let mut master: i32 = -1;
    let mut slave: i32 = -1;
    let mut winsize = libc::winsize {
        ws_row: 24,
        ws_col: 80,
        ws_xpixel: 0,
        ws_ypixel: 0,
    };

    // SAFETY: openpty is a POSIX function, output pointers are valid
    let rc = unsafe {
        libc::openpty(
            &mut master,
            &mut slave,
            std::ptr::null_mut(),
            std::ptr::null_mut(),
            &mut winsize,
        )
    };
    if rc == -1 {
        return Err(std::io::Error::last_os_error());
    }

    // SAFETY: openpty returned valid file descriptors
    let master = unsafe { OwnedFd::from_raw_fd(master) };
    let slave = unsafe { OwnedFd::from_raw_fd(slave) };

    // Set master to non-blocking for tokio AsyncFd
    // SAFETY: fcntl on a valid fd
    unsafe {
        let flags = libc::fcntl(master.as_raw_fd(), libc::F_GETFL);
        libc::fcntl(master.as_raw_fd(), libc::F_SETFL, flags | libc::O_NONBLOCK);
    }

    Ok((master, slave))
}

/// Spawn a child process attached to the slave side of a PTY.
fn spawn_pty_child(
    slave_fd: OwnedFd,
    cwd: &std::path::Path,
    command: &str,
) -> Result<tokio::process::Child, std::io::Error> {
    let slave_file = std::fs::File::from(slave_fd);
    let stdin = slave_file.try_clone()?;
    let stdout = slave_file.try_clone()?;
    let stderr = slave_file;
    let tty_fd = stderr.as_raw_fd();

    let mut cmd = tokio::process::Command::new("/bin/sh");
    cmd.arg("-c").arg(command);
    cmd.current_dir(cwd);
    cmd.stdin(std::process::Stdio::from(stdin));
    cmd.stdout(std::process::Stdio::from(stdout));
    cmd.stderr(std::process::Stdio::from(stderr));

    // Set up as session leader with controlling terminal
    // SAFETY: setsid + TIOCSCTTY are standard POSIX session setup for PTY children
    unsafe {
        cmd.pre_exec(move || {
            if libc::setsid() == -1 {
                return Err(std::io::Error::last_os_error());
            }
            if libc::ioctl(tty_fd, libc::TIOCSCTTY as _, 0) == -1 {
                return Err(std::io::Error::last_os_error());
            }
            Ok(())
        });
    }

    // Inject a safe PATH for GUI-launched processes
    cmd.env("PATH", super::tmux_compat::gui_safe_path());
    if std::env::var_os("TERM").is_none() {
        cmd.env("TERM", "xterm-256color");
    }

    cmd.spawn()
}

fn resolve_user_shell() -> String {
    std::env::var("SHELL").unwrap_or_else(|_| "/bin/zsh".to_string())
}

/// Async reader wrapping a PTY master fd via tokio's `AsyncFd`.
struct PtyReader {
    fd: Arc<tokio::io::unix::AsyncFd<OwnedFd>>,
}

impl AsyncRead for PtyReader {
    fn poll_read(
        self: std::pin::Pin<&mut Self>,
        cx: &mut std::task::Context<'_>,
        buf: &mut tokio::io::ReadBuf<'_>,
    ) -> std::task::Poll<std::io::Result<()>> {
        loop {
            let mut guard = match self.fd.poll_read_ready(cx) {
                std::task::Poll::Ready(Ok(guard)) => guard,
                std::task::Poll::Ready(Err(e)) => return std::task::Poll::Ready(Err(e)),
                std::task::Poll::Pending => return std::task::Poll::Pending,
            };

            let fd = self.fd.as_ref().as_raw_fd();
            let slice = buf.initialize_unfilled();
            // SAFETY: reading from a valid PTY master fd into a valid buffer
            let rc = unsafe { libc::read(fd, slice.as_mut_ptr() as *mut _, slice.len()) };

            if rc >= 0 {
                buf.advance(rc as usize);
                return std::task::Poll::Ready(Ok(()));
            }

            let err = std::io::Error::last_os_error();
            if err.kind() == std::io::ErrorKind::WouldBlock {
                guard.clear_ready();
                continue;
            }

            return std::task::Poll::Ready(Err(err));
        }
    }
}

/// Async writer wrapping a PTY master fd via tokio's `AsyncFd`.
struct PtyWriter {
    fd: Arc<tokio::io::unix::AsyncFd<OwnedFd>>,
}

impl AsyncWrite for PtyWriter {
    fn poll_write(
        self: std::pin::Pin<&mut Self>,
        cx: &mut std::task::Context<'_>,
        buf: &[u8],
    ) -> std::task::Poll<std::io::Result<usize>> {
        loop {
            let mut guard = match self.fd.poll_write_ready(cx) {
                std::task::Poll::Ready(Ok(guard)) => guard,
                std::task::Poll::Ready(Err(e)) => return std::task::Poll::Ready(Err(e)),
                std::task::Poll::Pending => return std::task::Poll::Pending,
            };

            let fd = self.fd.as_ref().as_raw_fd();
            // SAFETY: writing to a valid PTY master fd from a valid buffer
            let rc = unsafe { libc::write(fd, buf.as_ptr() as *const _, buf.len()) };

            if rc >= 0 {
                return std::task::Poll::Ready(Ok(rc as usize));
            }

            let err = std::io::Error::last_os_error();
            if err.kind() == std::io::ErrorKind::WouldBlock {
                guard.clear_ready();
                continue;
            }

            return std::task::Poll::Ready(Err(err));
        }
    }

    fn poll_flush(
        self: std::pin::Pin<&mut Self>,
        _cx: &mut std::task::Context<'_>,
    ) -> std::task::Poll<std::io::Result<()>> {
        std::task::Poll::Ready(Ok(()))
    }

    fn poll_shutdown(
        self: std::pin::Pin<&mut Self>,
        _cx: &mut std::task::Context<'_>,
    ) -> std::task::Poll<std::io::Result<()>> {
        std::task::Poll::Ready(Ok(()))
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use tokio::io::{AsyncReadExt, AsyncWriteExt};

    #[tokio::test]
    async fn local_pty_spawn_echo_and_read_output() {
        let backend = LocalPtyBackend::new();
        let session_id = Uuid::new_v4();

        let handle = backend
            .create(session_id, "/tmp", "echo hello_pty_test && exit 0")
            .await
            .expect("create session");

        assert!(handle.pid.is_some());

        let mut reader = handle.reader;
        let mut output = Vec::new();
        let mut buf = [0u8; 4096];

        // Read output with a timeout
        let deadline = tokio::time::Instant::now() + std::time::Duration::from_secs(5);
        loop {
            let read = tokio::select! {
                r = reader.read(&mut buf) => r,
                _ = tokio::time::sleep_until(deadline) => break,
            };
            match read {
                Ok(0) => break,
                Ok(n) => {
                    output.extend_from_slice(&buf[..n]);
                    let text = String::from_utf8_lossy(&output);
                    if text.contains("hello_pty_test") {
                        break;
                    }
                }
                Err(_) => break,
            }
        }

        let text = String::from_utf8_lossy(&output);
        assert!(
            text.contains("hello_pty_test"),
            "expected 'hello_pty_test' in output, got: {text}"
        );
    }

    #[tokio::test]
    async fn local_pty_resize() {
        let backend = LocalPtyBackend::new();
        let session_id = Uuid::new_v4();

        let _handle = backend
            .create(session_id, "/tmp", "sleep 10")
            .await
            .expect("create session");

        // Resize should succeed
        backend
            .resize(session_id, 132, 50)
            .await
            .expect("resize should succeed");

        // Clean up
        backend
            .terminate(session_id)
            .await
            .expect("terminate should succeed");
    }

    #[tokio::test]
    async fn local_pty_terminate() {
        let backend = LocalPtyBackend::new();
        let session_id = Uuid::new_v4();

        let handle = backend
            .create(session_id, "/tmp", "sleep 60")
            .await
            .expect("create session");

        assert!(backend.is_alive(session_id).await);

        let result = backend
            .terminate(session_id)
            .await
            .expect("terminate should succeed");
        assert_eq!(result, SessionBackendKillResult::Killed);

        // Wait for exit notification
        let code = tokio::time::timeout(std::time::Duration::from_secs(3), handle.exit_notify)
            .await
            .expect("should receive exit within 3s")
            .expect("channel should not be dropped");

        // Process was killed, exit code should be non-zero or None (signal death)
        assert!(code.is_none() || code != Some(0));
    }

    #[tokio::test]
    async fn local_pty_is_alive_false_for_unknown() {
        let backend = LocalPtyBackend::new();
        assert!(!backend.is_alive(Uuid::new_v4()).await);
    }

    #[tokio::test]
    async fn local_pty_terminate_unknown_returns_already_gone() {
        let backend = LocalPtyBackend::new();
        let result = backend
            .terminate(Uuid::new_v4())
            .await
            .expect("terminate unknown");
        assert_eq!(result, SessionBackendKillResult::AlreadyGone);
    }

    #[tokio::test]
    async fn local_pty_backend_kind_and_durability() {
        let backend = LocalPtyBackend::new();
        assert_eq!(backend.backend_kind(), SessionBackendKind::LocalPty);
        assert_eq!(backend.durability(), SessionDurability::Ephemeral);
    }

    #[tokio::test]
    async fn local_pty_send_input_and_read_echo() {
        let backend = LocalPtyBackend::new();
        let session_id = Uuid::new_v4();

        let handle = backend
            .create(session_id, "/tmp", "/bin/sh")
            .await
            .expect("create shell session");

        let mut writer = handle.writer;
        let mut reader = handle.reader;

        // Give the shell a moment to start
        tokio::time::sleep(std::time::Duration::from_millis(200)).await;

        // Send a command
        writer
            .write_all(b"echo pty_input_test_marker\n")
            .await
            .expect("write input");

        let mut output = Vec::new();
        let mut buf = [0u8; 4096];
        let deadline = tokio::time::Instant::now() + std::time::Duration::from_secs(5);
        loop {
            let read = tokio::select! {
                r = reader.read(&mut buf) => r,
                _ = tokio::time::sleep_until(deadline) => break,
            };
            match read {
                Ok(0) => break,
                Ok(n) => {
                    output.extend_from_slice(&buf[..n]);
                    let text = String::from_utf8_lossy(&output);
                    if text.contains("pty_input_test_marker") {
                        break;
                    }
                }
                Err(_) => break,
            }
        }

        let text = String::from_utf8_lossy(&output);
        assert!(
            text.contains("pty_input_test_marker"),
            "expected marker in output, got: {text}"
        );

        backend.terminate(session_id).await.ok();
    }
}
