pub mod local_durable;
pub mod local_pty;
pub mod tmux_compat;

use async_trait::async_trait;
use tokio::io::{AsyncRead, AsyncWrite};
use tokio::sync::oneshot;
use uuid::Uuid;

use crate::error::SessionError;
pub use pnevma_session_protocol::{SessionBackendKind, SessionDurability};

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum SessionBackendKillResult {
    Killed,
    AlreadyGone,
}

pub use local_durable::LocalDurableBackend;
pub use local_pty::LocalPtyBackend;
pub use tmux_compat::TmuxCompatBackend;

/// Handle returned by a backend after creating or attaching to a session.
///
/// Provides async read/write streams for terminal I/O and a notification
/// channel for process exit.
pub struct BackendHandle {
    /// PID of the backend process, if available.
    pub pid: Option<u32>,
    /// Async reader for terminal output from the backend.
    pub reader: Box<dyn AsyncRead + Send + Unpin>,
    /// Async writer for terminal input to the backend.
    pub writer: Box<dyn AsyncWrite + Send + Unpin>,
    /// Fires when the backend process exits, carrying the exit code.
    pub exit_notify: oneshot::Receiver<Option<i32>>,
}

/// Trait abstracting session backend implementations.
///
/// Each backend manages the lifecycle of a terminal process: creation,
/// attachment (connecting I/O streams), resize, liveness check, and
/// termination. The supervisor owns reader tasks, scrollback persistence,
/// redaction, and event broadcast — those are backend-agnostic.
#[async_trait]
pub trait SessionBackend: Send + Sync {
    /// Create a new session with the given command in the given directory.
    async fn create(
        &self,
        session_id: Uuid,
        cwd: &str,
        command: &str,
    ) -> Result<BackendHandle, SessionError>;

    /// Attach to an existing session (reconnect I/O streams).
    async fn attach(&self, session_id: Uuid) -> Result<BackendHandle, SessionError>;

    /// Terminate a session, killing the backend process.
    async fn terminate(&self, session_id: Uuid) -> Result<SessionBackendKillResult, SessionError>;

    /// Resize the terminal of the given session.
    async fn resize(&self, session_id: Uuid, cols: u16, rows: u16) -> Result<(), SessionError>;

    /// Check whether the backend process for this session is still alive.
    async fn is_alive(&self, session_id: Uuid) -> bool;

    /// The kind of backend this implementation represents.
    fn backend_kind(&self) -> SessionBackendKind;

    /// Whether sessions created by this backend survive app restarts.
    fn durability(&self) -> SessionDurability;
}
