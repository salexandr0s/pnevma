use thiserror::Error;

#[derive(Debug, Error)]
pub enum SessionError {
    #[error("io error: {0}")]
    Io(#[from] std::io::Error),

    #[error("session not found: {0}")]
    NotFound(String),

    #[error("session spawn failed: {0}")]
    SpawnFailed(String),

    #[error("session limit reached: {0}")]
    LimitReached(String),

    #[error("scrollback too large: {size} bytes (max {max})")]
    ScrollbackTooLarge { size: u64, max: usize },
}
