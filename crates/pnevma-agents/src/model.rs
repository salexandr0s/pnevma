use crate::error::AgentError;
use async_trait::async_trait;
use chrono::{DateTime, Utc};
use serde::{Deserialize, Serialize};
use tokio::sync::broadcast;
use uuid::Uuid;

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct AgentConfig {
    pub provider: String,
    pub model: Option<String>,
    pub env: Vec<(String, String)>,
    pub working_dir: String,
    pub timeout_minutes: u64,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct TaskPayload {
    pub task_id: Uuid,
    pub objective: String,
    pub constraints: Vec<String>,
    pub project_rules: Vec<String>,
    pub worktree_path: String,
    pub branch_name: String,
    pub acceptance_checks: Vec<String>,
    pub relevant_file_paths: Vec<String>,
    pub prior_context_summary: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub enum AgentStatus {
    Running,
    Paused,
    Waiting,
    Completed,
    Failed,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub enum AgentEvent {
    OutputChunk(String),
    ToolUse {
        name: String,
        input: String,
        output: String,
    },
    StatusChange(AgentStatus),
    Error(String),
    UsageUpdate {
        tokens_in: u64,
        tokens_out: u64,
        cost_usd: f64,
    },
    Complete {
        summary: String,
    },
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct CostRecord {
    pub provider: String,
    pub model: Option<String>,
    pub tokens_in: u64,
    pub tokens_out: u64,
    pub estimated_cost_usd: f64,
    pub timestamp: DateTime<Utc>,
    pub task_id: Uuid,
    pub session_id: Uuid,
}

#[derive(Debug, Clone)]
pub struct AgentHandle {
    pub id: Uuid,
    pub provider: String,
    pub task_id: Uuid,
}

#[async_trait]
pub trait AgentAdapter: Send + Sync {
    async fn spawn(&self, config: AgentConfig) -> Result<AgentHandle, AgentError>;
    async fn send(&self, handle: &AgentHandle, input: TaskPayload) -> Result<(), AgentError>;
    async fn interrupt(&self, handle: &AgentHandle) -> Result<(), AgentError>;
    async fn stop(&self, handle: &AgentHandle) -> Result<(), AgentError>;
    fn events(&self, handle: &AgentHandle) -> broadcast::Receiver<AgentEvent>;
    async fn parse_usage(&self, handle: &AgentHandle) -> Result<CostRecord, AgentError>;
}
