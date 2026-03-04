use thiserror::Error;

#[derive(Debug, Error)]
pub enum RemoteError {
    #[error("Tailscale not available: {0}")]
    NoTailscale(String),
    #[error("TLS error: {0}")]
    Tls(String),
    #[error("Server error: {0}")]
    Server(String),
    #[error("Auth error: {0}")]
    Auth(String),
    #[error("IO error: {0}")]
    Io(#[from] std::io::Error),
}
