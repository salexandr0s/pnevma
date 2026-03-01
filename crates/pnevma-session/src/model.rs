use chrono::{DateTime, Utc};
use serde::{Deserialize, Serialize};
use uuid::Uuid;

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub enum SessionStatus {
    Running,
    Waiting,
    Error,
    Complete,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub enum SessionHealth {
    Active,
    Idle,
    Stuck,
    Waiting,
    Error,
    Complete,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct SessionMetadata {
    pub id: Uuid,
    pub project_id: Uuid,
    pub name: String,
    pub status: SessionStatus,
    pub health: SessionHealth,
    pub pid: Option<u32>,
    pub cwd: String,
    pub command: String,
    pub branch: Option<String>,
    pub worktree_id: Option<Uuid>,
    pub started_at: DateTime<Utc>,
    pub last_heartbeat: DateTime<Utc>,
    pub scrollback_path: String,
    pub exit_code: Option<i32>,
    pub ended_at: Option<DateTime<Utc>>,
}
