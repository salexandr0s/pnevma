use thiserror::Error;

#[derive(Debug, Error)]
pub enum SshError {
    #[error("IO error: {0}")]
    Io(#[from] std::io::Error),
    #[error("parse error: {0}")]
    Parse(String),
    #[error("not found: {0}")]
    NotFound(String),
    #[error("command error: {0}")]
    Command(String),
}
