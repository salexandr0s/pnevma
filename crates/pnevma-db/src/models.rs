use chrono::{DateTime, Utc};
use serde::{Deserialize, Serialize};
use sqlx::FromRow;

#[derive(Debug, Clone, Serialize, Deserialize, FromRow)]
pub struct ProjectRow {
    pub id: String,
    pub name: String,
    pub path: String,
    pub brief: Option<String>,
    pub config_path: Option<String>,
    pub created_at: DateTime<Utc>,
}

#[derive(Debug, Clone, Serialize, Deserialize, FromRow)]
pub struct SessionRow {
    pub id: String,
    pub project_id: String,
    pub name: String,
    pub r#type: Option<String>,
    pub status: String,
    pub pid: Option<i64>,
    pub cwd: String,
    pub command: String,
    pub branch: Option<String>,
    pub worktree_id: Option<String>,
    pub started_at: DateTime<Utc>,
    pub last_heartbeat: DateTime<Utc>,
}

#[derive(Debug, Clone, Serialize, Deserialize, FromRow)]
pub struct PaneRow {
    pub id: String,
    pub project_id: String,
    pub session_id: Option<String>,
    pub r#type: String,
    pub position: String,
    pub label: String,
    pub metadata_json: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize, FromRow)]
pub struct PaneLayoutTemplateRow {
    pub id: String,
    pub project_id: String,
    pub name: String,
    pub display_name: String,
    pub pane_graph_json: String,
    pub is_system: bool,
    pub created_at: DateTime<Utc>,
    pub updated_at: DateTime<Utc>,
}

#[derive(Debug, Clone, Serialize, Deserialize, FromRow)]
pub struct TaskRow {
    pub id: String,
    pub project_id: String,
    pub title: String,
    pub goal: String,
    pub scope_json: String,
    pub dependencies_json: String,
    pub acceptance_json: String,
    pub constraints_json: String,
    pub priority: String,
    pub status: String,
    pub branch: Option<String>,
    pub worktree_id: Option<String>,
    pub handoff_summary: Option<String>,
    pub created_at: DateTime<Utc>,
    pub updated_at: DateTime<Utc>,
    /// When true, task auto-dispatches when dependencies complete.
    #[serde(default)]
    pub auto_dispatch: bool,
    /// Override agent profile for this specific task.
    pub agent_profile_override: Option<String>,
    /// Execution isolation mode: "worktree" (default) or "main".
    pub execution_mode: Option<String>,
    /// Timeout override in minutes for this task.
    pub timeout_minutes: Option<i64>,
    /// Max retry attempts (0 = no retries).
    pub max_retries: Option<i64>,
    /// Loop iteration number (0 = original task, 1+ = loop iteration).
    #[serde(default)]
    pub loop_iteration: i64,
    /// JSON context for loop iterations (iteration number, feedback, trigger task).
    pub loop_context_json: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize, FromRow)]
pub struct EventRow {
    pub id: String,
    pub project_id: String,
    pub task_id: Option<String>,
    pub session_id: Option<String>,
    pub trace_id: String,
    pub source: String,
    pub event_type: String,
    pub payload_json: String,
    pub timestamp: DateTime<Utc>,
}

#[derive(Debug, Clone, Serialize, Deserialize, FromRow)]
pub struct CostRow {
    pub id: String,
    pub agent_run_id: Option<String>,
    pub task_id: String,
    pub session_id: String,
    pub provider: String,
    pub model: Option<String>,
    pub tokens_in: i64,
    pub tokens_out: i64,
    pub estimated_usd: f64,
    pub tracked: bool,
    pub timestamp: DateTime<Utc>,
}

#[derive(Debug, Clone, Serialize, Deserialize, FromRow)]
pub struct WorktreeRow {
    pub id: String,
    pub project_id: String,
    pub task_id: String,
    pub path: String,
    pub branch: String,
    pub lease_status: String,
    pub lease_started: DateTime<Utc>,
    pub last_active: DateTime<Utc>,
}

#[derive(Debug, Clone, Serialize, Deserialize, FromRow)]
pub struct ArtifactRow {
    pub id: String,
    pub project_id: String,
    pub task_id: Option<String>,
    pub r#type: String,
    pub path: String,
    pub description: Option<String>,
    pub created_at: DateTime<Utc>,
}

#[derive(Debug, Clone, Serialize, Deserialize, FromRow)]
pub struct CheckRunRow {
    pub id: String,
    pub project_id: String,
    pub task_id: String,
    pub status: String,
    pub summary: Option<String>,
    pub created_at: DateTime<Utc>,
}

#[derive(Debug, Clone, Serialize, Deserialize, FromRow)]
pub struct CheckResultRow {
    pub id: String,
    pub check_run_id: String,
    pub project_id: String,
    pub task_id: String,
    pub description: String,
    pub check_type: String,
    pub command: Option<String>,
    pub passed: bool,
    pub output: Option<String>,
    pub created_at: DateTime<Utc>,
}

#[derive(Debug, Clone, Serialize, Deserialize, FromRow)]
pub struct ReviewRow {
    pub id: String,
    pub task_id: String,
    pub status: String,
    pub review_pack_path: String,
    pub reviewer_notes: Option<String>,
    pub approved_at: Option<DateTime<Utc>>,
}

#[derive(Debug, Clone, Serialize, Deserialize, FromRow)]
pub struct MergeQueueRow {
    pub id: String,
    pub project_id: String,
    pub task_id: String,
    pub status: String,
    pub blocked_reason: Option<String>,
    pub approved_at: DateTime<Utc>,
    pub started_at: Option<DateTime<Utc>>,
    pub completed_at: Option<DateTime<Utc>>,
}

#[derive(Debug, Clone, Serialize, Deserialize, FromRow)]
pub struct NotificationRow {
    pub id: String,
    pub project_id: String,
    pub task_id: Option<String>,
    pub session_id: Option<String>,
    pub title: String,
    pub body: String,
    pub level: String,
    pub unread: bool,
    pub created_at: DateTime<Utc>,
}

#[derive(Debug, Clone, Serialize, Deserialize, FromRow)]
pub struct SecretRefRow {
    pub id: String,
    pub project_id: Option<String>,
    pub scope: String,
    pub name: String,
    pub keychain_service: String,
    pub keychain_account: String,
    pub created_at: DateTime<Utc>,
    pub updated_at: DateTime<Utc>,
}

#[derive(Debug, Clone, Serialize, Deserialize, FromRow)]
pub struct CheckpointRow {
    pub id: String,
    pub project_id: String,
    pub task_id: Option<String>,
    pub git_ref: String,
    pub session_metadata_json: String,
    pub created_at: DateTime<Utc>,
    pub description: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize, FromRow)]
pub struct RuleRow {
    pub id: String,
    pub project_id: String,
    pub name: String,
    pub path: String,
    pub scope: Option<String>,
    pub active: bool,
}

#[derive(Debug, Clone, Serialize, Deserialize, FromRow)]
pub struct ContextRuleUsageRow {
    pub id: String,
    pub project_id: String,
    pub run_id: String,
    pub rule_id: String,
    pub included: bool,
    pub reason: String,
    pub created_at: DateTime<Utc>,
}

#[derive(Debug, Clone, Serialize, Deserialize, FromRow)]
pub struct OnboardingStateRow {
    pub project_id: String,
    pub step: String,
    pub completed: bool,
    pub dismissed: bool,
    pub updated_at: DateTime<Utc>,
}

#[derive(Debug, Clone, Serialize, Deserialize, FromRow)]
pub struct TelemetryEventRow {
    pub id: String,
    pub project_id: String,
    pub event_type: String,
    pub payload_json: String,
    pub anonymized: bool,
    pub created_at: DateTime<Utc>,
}

#[derive(Debug, Clone, Serialize, Deserialize, FromRow)]
pub struct FeedbackRow {
    pub id: String,
    pub project_id: String,
    pub category: String,
    pub body: String,
    pub contact: Option<String>,
    pub artifact_path: Option<String>,
    pub created_at: DateTime<Utc>,
}

#[derive(Debug, Clone, Serialize, Deserialize, FromRow)]
pub struct WorkflowRow {
    pub id: String,
    pub project_id: String,
    pub name: String,
    pub description: Option<String>,
    pub definition_yaml: String,
    pub source: String,
    pub created_at: DateTime<Utc>,
    pub updated_at: DateTime<Utc>,
}

#[derive(Debug, Clone, Serialize, Deserialize, FromRow)]
pub struct WorkflowInstanceRow {
    pub id: String,
    pub project_id: String,
    pub workflow_name: String,
    pub description: Option<String>,
    pub status: String,
    pub created_at: DateTime<Utc>,
    pub updated_at: DateTime<Utc>,
    pub params_json: Option<String>,
    pub stage_results_json: Option<String>,
    pub expanded_steps_json: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize, FromRow)]
pub struct WorkflowTaskRow {
    pub workflow_id: String,
    pub step_index: i64,
    pub iteration: i64,
    pub task_id: String,
}

#[derive(Debug, Clone, Serialize, Deserialize, FromRow)]
pub struct SshProfileRow {
    pub id: String,
    pub project_id: String,
    pub name: String,
    pub host: String,
    pub port: i64,
    pub user: Option<String>,
    pub identity_file: Option<String>,
    pub proxy_jump: Option<String>,
    pub tags_json: String,
    pub source: String,
    pub created_at: DateTime<Utc>,
    pub updated_at: DateTime<Utc>,
}

#[derive(Debug, Clone, Serialize, Deserialize, FromRow)]
pub struct CostHourlyAggregateRow {
    pub id: String,
    pub project_id: String,
    pub provider: String,
    pub model: String,
    pub period_start: String,
    pub tokens_in: i64,
    pub tokens_out: i64,
    pub estimated_usd: f64,
    pub record_count: i64,
}

#[derive(Debug, Clone, Serialize, Deserialize, FromRow)]
pub struct ErrorSignatureRow {
    pub id: String,
    pub project_id: String,
    pub signature_hash: String,
    pub canonical_message: String,
    pub category: String,
    pub first_seen: DateTime<Utc>,
    pub last_seen: DateTime<Utc>,
    pub total_count: i64,
    pub sample_output: Option<String>,
    pub remediation_hint: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize, FromRow)]
pub struct ErrorSignatureDailyRow {
    pub id: String,
    pub signature_id: String,
    pub date: String,
    pub count: i64,
    pub signature_hash: Option<String>,
    pub category: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize, FromRow)]
pub struct CostDailyAggregateRow {
    pub id: String,
    pub project_id: String,
    pub provider: String,
    pub model: String,
    pub period_date: String,
    pub tokens_in: i64,
    pub tokens_out: i64,
    pub estimated_usd: f64,
    pub record_count: i64,
    pub tasks_completed: i64,
    pub files_changed: i64,
}

#[derive(Debug, Clone, Serialize, Deserialize, FromRow)]
pub struct TaskStoryRow {
    pub id: String,
    pub task_id: String,
    pub sequence_number: i64,
    pub title: String,
    pub status: String,
    pub started_at: Option<DateTime<Utc>>,
    pub completed_at: Option<DateTime<Utc>>,
    pub output_summary: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize, FromRow)]
pub struct StoryProgressRow {
    pub total: i64,
    pub completed: i64,
    pub failed: i64,
    pub in_progress: i64,
}

#[derive(Debug, Clone, Serialize, Deserialize, FromRow)]
pub struct AgentProfileRow {
    pub id: String,
    pub project_id: String,
    pub name: String,
    pub provider: String,
    pub model: String,
    pub token_budget: i64,
    pub timeout_minutes: i64,
    pub max_concurrent: i64,
    pub stations_json: String,
    pub config_json: String,
    pub active: bool,
    pub created_at: DateTime<Utc>,
    pub updated_at: DateTime<Utc>,
    pub role: String,                  // NEW - migration 0015
    pub system_prompt: Option<String>, // NEW - migration 0015
    pub source: String,
    pub source_path: Option<String>,
    pub user_modified: bool,
}

#[derive(Debug, Clone, Serialize, Deserialize, FromRow)]
pub struct GlobalWorkflowRow {
    pub id: String,
    pub name: String,
    pub description: Option<String>,
    pub definition_yaml: String,
    pub source: String,
    pub created_at: DateTime<Utc>,
    pub updated_at: DateTime<Utc>,
}

#[derive(Debug, Clone, Serialize, Deserialize, FromRow)]
pub struct TaskExternalSourceRow {
    pub id: String,
    pub project_id: String,
    pub task_id: String,
    pub kind: String,
    pub external_id: String,
    pub identifier: String,
    pub url: String,
    pub state: String,
    pub synced_at: DateTime<Utc>,
}

#[derive(Debug, Clone, Serialize, Deserialize, FromRow)]
pub struct AutomationRunRow {
    pub id: String,
    pub project_id: String,
    pub task_id: String,
    pub run_id: String,
    pub origin: String,
    pub provider: String,
    pub model: Option<String>,
    pub status: String,
    pub attempt: i64,
    pub started_at: DateTime<Utc>,
    pub finished_at: Option<DateTime<Utc>>,
    pub duration_seconds: Option<f64>,
    pub tokens_in: i64,
    pub tokens_out: i64,
    pub cost_usd: f64,
    pub summary: Option<String>,
    pub error_message: Option<String>,
    pub created_at: DateTime<Utc>,
}

#[derive(Debug, Clone, Serialize, Deserialize, FromRow)]
pub struct AutomationRetryRow {
    pub id: String,
    pub project_id: String,
    pub run_id: String,
    pub task_id: String,
    pub attempt: i64,
    pub reason: String,
    pub retry_after: DateTime<Utc>,
    pub retried_at: Option<DateTime<Utc>>,
    pub outcome: Option<String>,
    pub created_at: DateTime<Utc>,
}

#[derive(Debug, Clone, Serialize, Deserialize, FromRow)]
pub struct GlobalAgentProfileRow {
    pub id: String,
    pub name: String,
    pub role: String,
    pub provider: String,
    pub model: String,
    pub token_budget: i64,
    pub timeout_minutes: i64,
    pub max_concurrent: i64,
    pub stations_json: String,
    pub config_json: String,
    pub system_prompt: Option<String>,
    pub active: bool,
    pub created_at: DateTime<Utc>,
    pub updated_at: DateTime<Utc>,
    pub source: String,
    pub source_path: Option<String>,
    pub user_modified: bool,
}

#[derive(Debug, Clone, Serialize, Deserialize, FromRow)]
pub struct GlobalSshProfileRow {
    pub id: String,
    pub name: String,
    pub host: String,
    pub port: i64,
    pub user: Option<String>,
    pub identity_file: Option<String>,
    pub proxy_jump: Option<String>,
    pub tags_json: String,
    pub source: String,
    pub created_at: DateTime<Utc>,
    pub updated_at: DateTime<Utc>,
}
