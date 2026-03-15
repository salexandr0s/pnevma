#![forbid(unsafe_code)]

pub mod error;
pub mod model;
pub mod supervisor;

pub use error::SessionError;
pub use model::{SessionHealth, SessionMetadata, SessionStatus};
pub use supervisor::{
    resolve_binary, ScrollbackSlice, SessionBackendKillResult, SessionEvent, SessionSupervisor,
};
