use serde::{Deserialize, Serialize};

/// Identifies the backend implementation driving a session.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub enum SessionBackendKind {
    /// Legacy tmux-based backend (Phase 2 extraction, kept for rollback).
    TmuxCompat,
    /// Rust-owned PTY backend — no tmux dependency.
    LocalPty,
    /// Remote durable session via SSH + pnevma-remote-helper.
    RemoteSshDurable,
}

/// Whether a session can survive process/app restarts.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub enum SessionDurability {
    /// Session state is persisted and can be re-attached after restart.
    Durable,
    /// Session is lost if the owning process exits.
    Ephemeral,
}

/// Lifecycle states for the proxy ↔ backend connection.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub enum SessionLifecycleState {
    /// A client is actively connected and relaying I/O.
    Attached,
    /// No client connected; backend is still running.
    Detached,
    /// Client is reconnecting after a disconnect.
    Reattaching,
    /// Backend process exited normally or was terminated.
    Exited,
    /// Backend process was lost unexpectedly (crash, network).
    Lost,
    /// An unrecoverable error occurred.
    Error,
}
