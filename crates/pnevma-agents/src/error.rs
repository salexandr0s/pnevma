use thiserror::Error;

#[derive(Debug, Error)]
pub enum AgentError {
    #[error("io error: {0}")]
    Io(#[from] std::io::Error),

    #[error("adapter unavailable: {0}")]
    Unavailable(String),

    #[error("spawn failed: {0}")]
    Spawn(String),

    #[error("protocol parse failed: {0}")]
    Parse(String),

    #[error("unsupported operation: {0}")]
    Unsupported(String),

    #[error("protocol error: {0}")]
    Protocol(String),

    #[error("rate limited: retry after {retry_after_ms}ms")]
    RateLimit { retry_after_ms: u64 },

    #[error("invalid agent config: {0}")]
    InvalidConfig(String),
}
