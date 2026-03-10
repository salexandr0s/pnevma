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
    /// Pass --dangerously-skip-permissions (worktree isolation is the safety boundary).
    #[serde(default)]
    pub auto_approve: bool,
    /// Allow npm exec / npx in provider allowlists when auto-approve is enabled.
    #[serde(default)]
    pub allow_npx: bool,
    /// Output format: "stream-json" for structured output, "text" for raw.
    #[serde(default = "default_output_format")]
    pub output_format: String,
    /// Path to compiled task-context.md to inject as CLAUDE.md in worktree.
    #[serde(default)]
    pub context_file: Option<String>,
    /// Optional thread ID for resuming an existing conversation thread.
    #[serde(default)]
    pub thread_id: Option<String>,
    /// Dynamic tool definitions to register with the agent.
    #[serde(default)]
    pub dynamic_tools: Vec<DynamicToolDef>,
}

fn default_output_format() -> String {
    "stream-json".to_string()
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
    ThreadStarted {
        thread_id: String,
    },
    TurnStarted {
        turn_id: String,
        thread_id: String,
    },
    TurnCompleted {
        turn_id: String,
        thread_id: String,
        finish_reason: String,
    },
    RateLimitUpdated {
        remaining: u32,
        reset_at: Option<DateTime<Utc>>,
    },
    SemanticHeartbeat {
        thread_id: String,
        timestamp: DateTime<Utc>,
    },
    DynamicToolCall {
        call_id: String,
        tool_name: String,
        params: serde_json::Value,
    },
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct DynamicToolDef {
    pub name: String,
    pub description: String,
    pub parameters_schema: serde_json::Value,
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
    pub thread_id: Option<String>,
    pub turn_id: Option<String>,
}

#[async_trait]
pub trait AgentAdapter: Send + Sync {
    async fn spawn(&self, config: AgentConfig) -> Result<AgentHandle, AgentError>;
    async fn send(&self, handle: &AgentHandle, input: TaskPayload) -> Result<(), AgentError>;
    async fn interrupt(&self, handle: &AgentHandle) -> Result<(), AgentError>;
    async fn stop(&self, handle: &AgentHandle) -> Result<(), AgentError>;
    fn events(&self, handle: &AgentHandle) -> broadcast::Receiver<AgentEvent>;
    async fn parse_usage(&self, handle: &AgentHandle) -> Result<CostRecord, AgentError>;
    async fn send_tool_result(
        &self,
        _handle: &AgentHandle,
        _call_id: &str,
        _result: serde_json::Value,
    ) -> Result<(), AgentError> {
        Err(AgentError::Unsupported(
            "send_tool_result not supported".into(),
        ))
    }
}
