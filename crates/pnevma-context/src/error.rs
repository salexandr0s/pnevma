use thiserror::Error;

#[derive(Debug, Error)]
pub enum ContextError {
    #[error("context compile failed: {0}")]
    Compile(String),

    #[error("io error: {0}")]
    Io(#[from] std::io::Error),
}
