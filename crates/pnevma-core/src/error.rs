use thiserror::Error;

#[derive(Debug, Error)]
pub enum CoreError {
    #[error("io error: {0}")]
    Io(#[from] std::io::Error),

    #[error("serialization error: {0}")]
    Serialization(String),

    #[error("invalid configuration: {0}")]
    InvalidConfig(String),

    #[error("task transition rejected: {0}")]
    InvalidTransition(String),
}
