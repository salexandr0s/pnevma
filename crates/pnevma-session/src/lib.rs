#![deny(unsafe_code)]

pub mod backend;
pub mod error;
pub mod model;
pub mod socket_server;
pub mod supervisor;

use std::path::{Path, PathBuf};

pub use backend::{
    BackendHandle, SessionBackend, SessionBackendKillResult, SessionBackendKind, SessionDurability,
};
pub use error::SessionError;
pub use model::{SessionHealth, SessionMetadata, SessionStatus};
pub use supervisor::{ScrollbackSlice, SessionEvent, SessionSupervisor};

/// Resolve a binary name to its full path, searching common macOS locations
/// in addition to the inherited PATH (which may be minimal for GUI apps).
pub fn resolve_binary(name: &str) -> PathBuf {
    let extra_dirs = ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin"];
    for dir in &extra_dirs {
        let candidate = Path::new(dir).join(name);
        if candidate.exists() {
            return candidate;
        }
    }
    // Fall back to bare name (rely on PATH)
    PathBuf::from(name)
}
