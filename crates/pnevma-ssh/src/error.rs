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
    #[error("unsupported remote helper platform: {0}")]
    UnsupportedRemoteHelperPlatform(String),
    #[error("missing remote helper artifact: {0}")]
    MissingRemoteHelperArtifact(String),
    #[error("remote helper artifact digest mismatch: {0}")]
    RemoteHelperDigestMismatch(String),
    #[error("remote helper version mismatch: {0}")]
    RemoteHelperVersionMismatch(String),
    #[error("remote helper protocol mismatch: {0}")]
    RemoteHelperProtocolMismatch(String),
    #[error("remote helper dependency check failed: {0}")]
    RemoteHelperDependency(String),
    #[error("passphrase application failed: {0}")]
    PassphraseApplicationFailed(String),
}
