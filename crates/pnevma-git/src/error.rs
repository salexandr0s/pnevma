use thiserror::Error;

#[derive(Debug, Error)]
pub enum GitError {
    #[error("io error: {0}")]
    Io(#[from] std::io::Error),

    #[error("git command failed: {0}")]
    Command(String),

    #[error("lease violation: {0}")]
    LeaseViolation(String),

    #[error("worktree not found: {0}")]
    WorktreeNotFound(String),

    #[error("hook error: {0}")]
    Hook(String),
}
