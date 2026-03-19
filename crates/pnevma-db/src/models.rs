use chrono::{DateTime, Utc};
use serde::{Deserialize, Serialize};
use sqlx::FromRow;

fn default_session_backend() -> String {
    "tmux_compat".to_string()
}

fn default_session_durability() -> String {
    "durable".to_string()
}

fn default_session_lifecycle_state() -> String {
    "attached".to_string()
}

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
    #[serde(default = "default_session_backend")]
    pub backend: String,
    #[serde(default = "default_session_durability")]
    pub durability: String,
    #[serde(default = "default_session_lifecycle_state")]
    pub lifecycle_state: String,
    pub status: String,
    pub pid: Option<i64>,
    pub cwd: String,
    pub command: String,
    pub branch: Option<String>,
    pub worktree_id: Option<String>,
    #[serde(default)]
    pub connection_id: Option<String>,
    #[serde(default)]
    pub remote_session_id: Option<String>,
    #[serde(default)]
    pub controller_id: Option<String>,
    pub started_at: DateTime<Utc>,
    pub last_heartbeat: DateTime<Utc>,
    #[serde(default)]
    pub last_output_at: Option<DateTime<Utc>>,
    #[serde(default)]
    pub detached_at: Option<DateTime<Utc>>,
    #[serde(default)]
    pub last_error: Option<String>,
    #[serde(default)]
    pub restore_status: Option<String>,
    #[serde(default)]
    pub exit_code: Option<i64>,
    #[serde(default)]
    pub ended_at: Option<String>,
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
    /// Task this was forked from.
    #[serde(default)]
    pub forked_from_task_id: Option<String>,
    /// One-line summary of the fork lineage.
    #[serde(default)]
    pub lineage_summary: Option<String>,
    /// Fork depth (0 = root).
    #[serde(default)]
    pub lineage_depth: i64,
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
    pub backend: String,
    pub keychain_service: Option<String>,
    pub keychain_account: Option<String>,
    pub env_file_path: Option<String>,
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
    #[serde(default)]
    pub thinking_level: Option<String>,
    #[serde(default)]
    pub thinking_budget: Option<i64>,
    #[serde(default)]
    pub tool_restrictions_json: Option<String>,
    #[serde(default)]
    pub extra_flags_json: Option<String>,
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
    #[serde(default)]
    pub title: Option<String>,
    #[serde(default)]
    pub description: Option<String>,
    #[serde(default)]
    pub labels_json: Option<String>,
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
    #[serde(default)]
    pub thinking_level: Option<String>,
    #[serde(default)]
    pub thinking_budget: Option<i64>,
    #[serde(default)]
    pub tool_restrictions_json: Option<String>,
    #[serde(default)]
    pub extra_flags_json: Option<String>,
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

// ── Wave 1: Intake, PRs, CI, Telemetry ──────────────────────────────────────

#[derive(Debug, Clone, Serialize, Deserialize, FromRow)]
pub struct IntakeQueueRow {
    pub id: String,
    pub project_id: String,
    pub kind: String,
    pub external_id: String,
    pub identifier: String,
    pub title: String,
    pub url: String,
    pub state: String,
    pub priority: Option<String>,
    pub labels_json: String,
    pub source_updated_at: Option<String>,
    pub ingested_at: String,
    pub status: String,
    pub promoted_task_id: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize, FromRow)]
pub struct PullRequestRow {
    pub id: String,
    pub project_id: String,
    pub task_id: Option<String>,
    pub number: i64,
    pub title: String,
    pub source_branch: String,
    pub target_branch: String,
    pub remote_url: String,
    pub status: String,
    pub checks_status: Option<String>,
    pub review_status: Option<String>,
    pub mergeable: bool,
    pub head_sha: Option<String>,
    pub created_at: String,
    pub updated_at: String,
    pub merged_at: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize, FromRow)]
pub struct PrCheckRunRow {
    pub id: String,
    pub pr_id: String,
    pub name: String,
    pub status: String,
    pub conclusion: Option<String>,
    pub details_url: Option<String>,
    pub started_at: Option<String>,
    pub completed_at: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize, FromRow)]
pub struct CiPipelineRow {
    pub id: String,
    pub project_id: String,
    pub task_id: Option<String>,
    pub pr_id: Option<String>,
    pub provider: String,
    pub run_number: Option<i64>,
    pub workflow_name: Option<String>,
    pub head_sha: Option<String>,
    pub status: String,
    pub conclusion: Option<String>,
    pub html_url: Option<String>,
    pub started_at: Option<String>,
    pub completed_at: Option<String>,
    pub created_at: String,
    pub updated_at: String,
}

#[derive(Debug, Clone, Serialize, Deserialize, FromRow)]
pub struct CiJobRow {
    pub id: String,
    pub pipeline_id: String,
    pub name: String,
    pub status: String,
    pub conclusion: Option<String>,
    pub started_at: Option<String>,
    pub completed_at: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize, FromRow)]
pub struct DeploymentRow {
    pub id: String,
    pub project_id: String,
    pub task_id: Option<String>,
    pub environment: String,
    pub status: String,
    pub ref_name: Option<String>,
    pub sha: Option<String>,
    pub url: Option<String>,
    pub created_at: String,
    pub updated_at: String,
}

#[derive(Debug, Clone, Serialize, Deserialize, FromRow)]
pub struct TelemetryMetricRow {
    pub id: String,
    pub project_id: String,
    pub metric_name: String,
    pub metric_value: f64,
    pub tags_json: String,
    pub recorded_at: String,
}

#[derive(Debug, Clone, Serialize, Deserialize, FromRow)]
pub struct FleetSnapshotRow {
    pub id: String,
    pub project_id: String,
    pub active_sessions: i64,
    pub active_dispatches: i64,
    pub queued_dispatches: i64,
    pub pool_max: i64,
    pub pool_utilization: f64,
    pub total_cost_usd: f64,
    pub tasks_ready: i64,
    pub tasks_in_progress: i64,
    pub tasks_failed: i64,
    pub captured_at: String,
}

#[derive(Debug, Clone, Serialize, Deserialize, FromRow)]
pub struct AgentPerformanceRow {
    pub id: String,
    pub project_id: String,
    pub provider: String,
    pub model: String,
    pub period_start: String,
    pub period_end: String,
    pub runs_total: i64,
    pub runs_success: i64,
    pub runs_failed: i64,
    pub avg_duration_seconds: Option<f64>,
    pub tokens_in: i64,
    pub tokens_out: i64,
    pub cost_usd: f64,
    pub p95_duration_seconds: Option<f64>,
}

// ── Wave 2: Session Restore, Attention, Review ──────────────────────────────

#[derive(Debug, Clone, Serialize, Deserialize, FromRow)]
pub struct SessionRestoreLogRow {
    pub id: String,
    pub session_id: String,
    pub project_id: String,
    pub action: String,
    pub outcome: String,
    pub error_message: Option<String>,
    pub created_at: String,
}

#[derive(Debug, Clone, Serialize, Deserialize, FromRow)]
pub struct AttentionRuleRow {
    pub id: String,
    pub project_id: String,
    pub name: String,
    pub description: Option<String>,
    pub event_type: String,
    pub condition_json: String,
    pub action: String,
    pub severity: String,
    pub enabled: bool,
    pub cooldown_seconds: i64,
    pub last_triggered: Option<String>,
    pub created_at: String,
    pub updated_at: String,
}

#[derive(Debug, Clone, Serialize, Deserialize, FromRow)]
pub struct ReviewFileRow {
    pub id: String,
    pub project_id: String,
    pub task_id: String,
    pub file_path: String,
    pub status: String,
    pub reviewer_notes: Option<String>,
    pub created_at: String,
    pub updated_at: String,
}

#[derive(Debug, Clone, Serialize, Deserialize, FromRow)]
pub struct ReviewCommentRow {
    pub id: String,
    pub project_id: String,
    pub task_id: String,
    pub file_path: Option<String>,
    pub line_number: Option<i64>,
    pub body: String,
    pub author: String,
    pub resolved: bool,
    pub created_at: String,
}

#[derive(Debug, Clone, Serialize, Deserialize, FromRow)]
pub struct ReviewChecklistItemRow {
    pub id: String,
    pub project_id: String,
    pub task_id: String,
    pub label: String,
    pub checked: bool,
    pub sort_order: i64,
    pub created_at: String,
}

// ── Wave 3: Lineage, Hooks ──────────────────────────────────────────────────

#[derive(Debug, Clone, Serialize, Deserialize, FromRow)]
pub struct TaskLineageRow {
    pub id: String,
    pub project_id: String,
    pub parent_task_id: String,
    pub child_task_id: String,
    pub fork_reason: Option<String>,
    pub created_at: String,
}

#[derive(Debug, Clone, Serialize, Deserialize, FromRow)]
pub struct AgentHookRow {
    pub id: String,
    pub project_id: String,
    pub name: String,
    pub hook_type: String,
    pub command: String,
    pub timeout_seconds: i64,
    pub enabled: bool,
    pub sort_order: i64,
    pub created_at: String,
    pub updated_at: String,
}

// ── Wave 4: Ports, Workspace Hooks, Editor Profiles ─────────────────────────

#[derive(Debug, Clone, Serialize, Deserialize, FromRow)]
pub struct PortAllocationRow {
    pub id: String,
    pub project_id: String,
    pub task_id: Option<String>,
    pub session_id: Option<String>,
    pub port: i64,
    pub protocol: String,
    pub label: Option<String>,
    pub allocated_at: String,
    pub released_at: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize, FromRow)]
pub struct WorkspaceHookRunRow {
    pub id: String,
    pub project_id: String,
    pub hook_name: String,
    pub phase: String,
    pub trigger_event: Option<String>,
    pub status: String,
    pub exit_code: Option<i64>,
    pub stdout: Option<String>,
    pub stderr: Option<String>,
    pub duration_ms: Option<i64>,
    pub started_at: String,
    pub completed_at: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize, FromRow)]
pub struct EditorProfileRow {
    pub id: String,
    pub project_id: String,
    pub name: String,
    pub editor: String,
    pub settings_json: String,
    pub extensions_json: String,
    pub keybindings_json: String,
    pub active: bool,
    pub created_at: String,
    pub updated_at: String,
}
