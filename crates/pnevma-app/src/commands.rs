use crate::command_registry::{default_registry, RegisteredCommand};
use crate::control::{resolve_control_plane_settings, start_control_plane};
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
    WorkflowInstanceRow, WorktreeRow,
};
use pnevma_git::GitService;
use pnevma_session::{
    ScrollbackSlice, SessionEvent, SessionHealth, SessionMetadata, SessionStatus, SessionSupervisor,
};
use regex::Regex;
use serde::{Deserialize, Serialize};
use serde_json::json;
use std::collections::{HashMap, HashSet};
use std::path::{Path, PathBuf};
use std::sync::{Arc, OnceLock};
use tauri::{AppHandle, Emitter, Manager, State};
use tokio::process::Command as TokioCommand;
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

fn sanitize_file_stem(input: &str) -> String {
    let mut out = String::new();
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
    let trimmed = out.trim_matches('-').to_string();
    if trimmed.is_empty() {
        "entry".to_string()
    } else {
        trimmed
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
            let mut entries = tokio::fs::read_dir(parent)
                .await
                .map_err(|e| e.to_string())?;
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
    let start = idx.saturating_sub(80);
    let end = (idx + lower_query.len() + 120).min(text.len());
    let mut snippet = text[start..end].replace('\n', " ");
    if start > 0 {
        snippet.insert_str(0, "...");
    }
    if end < text.len() {
        snippet.push_str("...");
    }
    snippet
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
    TokioCommand::new("tmux")
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

fn slugify(input: &str) -> String {
    let mut out = String::with_capacity(input.len());
    let mut prev_dash = false;
    for ch in input.chars() {
        let c = ch.to_ascii_lowercase();
        if c.is_ascii_alphanumeric() {
            out.push(c);
            prev_dash = false;
            continue;
        }
        if !prev_dash {
            out.push('-');
            prev_dash = true;
        }
    }
    let trimmed = out.trim_matches('-');
    if trimmed.is_empty() {
        "task".to_string()
    } else {
        trimmed.to_string()
    }
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
        created_at: row.created_at,
        updated_at: row.updated_at,
        queued_position: None,
        cost_usd,
    })
}

/// Emit a `task_updated` event with the full task view when possible.
/// Falls back to just the task_id if fetching/converting the row fails.
async fn emit_enriched_task_event(app: &AppHandle, db: &Db, task_id: &str) {
    let view = async {
        let row = db.get_task(task_id).await.ok()??;
        let cost = db.task_cost_total(task_id).await.ok();
        task_row_to_view(row, cost).ok()
    }
    .await;
    match view {
        Some(v) => {
            let _ = app.emit("task_updated", json!({"task": v}));
        }
        None => {
            let _ = app.emit("task_updated", json!({"task_id": task_id}));
        }
    }
}

/// Build a serializable session view from a SessionRow.
fn session_row_to_event_payload(row: &SessionRow) -> serde_json::Value {
    json!({
        "id": row.id,
        "project_id": row.project_id,
        "name": row.name,
        "status": row.status,
        "pid": row.pid,
        "cwd": row.cwd,
        "command": row.command,
        "started_at": row.started_at.to_rfc3339(),
        "last_heartbeat": row.last_heartbeat.to_rfc3339(),
    })
}

async fn load_texts(paths: &[String], project_path: &Path) -> Vec<String> {
    let mut out = Vec::new();
    for path in paths {
        let candidate = if Path::new(path).is_absolute() {
            PathBuf::from(path)
        } else {
            project_path.join(path)
        };
        if let Ok(text) = tokio::fs::read_to_string(&candidate).await {
            out.push(text);
        }
    }
    out
}

async fn load_rule_texts(config: &ProjectConfig, project_path: &Path) -> Vec<String> {
    load_texts(&config.rules.paths, project_path).await
}

async fn load_convention_texts(config: &ProjectConfig, project_path: &Path) -> Vec<String> {
    load_texts(&config.conventions.paths, project_path).await
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
    app: Option<&AppHandle>,
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
        if let Some(app) = app {
            emit_enriched_task_event(app, db, &task.id.to_string()).await;
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

fn redaction_authorization_regex() -> &'static Regex {
    static RE: OnceLock<Regex> = OnceLock::new();
    RE.get_or_init(|| {
        Regex::new(r"(?i)(authorization\s*:\s*bearer\s+)[^\s]+")
            .expect("authorization redaction regex must compile")
    })
}

fn redaction_key_value_regex() -> &'static Regex {
    static RE: OnceLock<Regex> = OnceLock::new();
    RE.get_or_init(|| {
        Regex::new(
            r#"(?i)\b(api[_-]?key|token|secret|password)\b\s*[:=]\s*("[^"]*"|'[^']*'|[^\s,;]+)"#,
        )
        .expect("key-value redaction regex must compile")
    })
}

fn redact_patterns(input: &str) -> String {
    let first = redaction_authorization_regex()
        .replace_all(input, "$1[REDACTED]")
        .to_string();
    redaction_key_value_regex()
        .replace_all(&first, "$1=[REDACTED]")
        .to_string()
}

fn redact_text(input: &str, secrets: &[String]) -> String {
    let mut redacted = redact_patterns(input);
    for secret in secrets {
        if secret.is_empty() {
            continue;
        }
        redacted = redacted.replace(secret, "[REDACTED]");
    }
    redacted
}

fn redact_json_value(value: serde_json::Value, secrets: &[String]) -> serde_json::Value {
    match value {
        serde_json::Value::String(text) => serde_json::Value::String(redact_text(&text, secrets)),
        serde_json::Value::Array(items) => serde_json::Value::Array(
            items
                .into_iter()
                .map(|item| redact_json_value(item, secrets))
                .collect(),
        ),
        serde_json::Value::Object(map) => {
            let mut out = serde_json::Map::new();
            for (key, value) in map {
                out.insert(key, redact_json_value(value, secrets));
            }
            serde_json::Value::Object(out)
        }
        other => other,
    }
}

pub(crate) fn redact_payload_for_log(payload: serde_json::Value) -> serde_json::Value {
    redact_json_value(payload, &[])
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
    app: &AppHandle,
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
    let _ = app.emit("notification_created", json!(out.clone()));
    Ok(out)
}

async fn store_keychain_secret(service: &str, account: &str, value: &str) -> Result<(), String> {
    let status = TokioCommand::new("security")
        .args([
            "add-generic-password",
            "-U",
            "-s",
            service,
            "-a",
            account,
            "-w",
            value,
        ])
        .status()
        .await
        .map_err(|e| e.to_string())?;
    if status.success() {
        Ok(())
    } else {
        Err("security add-generic-password failed".to_string())
    }
}

async fn read_keychain_secret(service: &str, account: &str) -> Result<String, String> {
    let out = TokioCommand::new("security")
        .args(["find-generic-password", "-s", service, "-a", account, "-w"])
        .output()
        .await
        .map_err(|e| e.to_string())?;
    if !out.status.success() {
        return Err("security find-generic-password failed".to_string());
    }
    let value = String::from_utf8_lossy(&out.stdout).trim().to_string();
    Ok(value)
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
        env.push((secret.name.clone(), value.clone()));
        values.push(value);
    }
    Ok((env, values))
}

async fn git_output(repo_root: &Path, args: &[&str]) -> Result<String, String> {
    let out = TokioCommand::new("git")
        .args(args)
        .current_dir(repo_root)
        .output()
        .await
        .map_err(|e| e.to_string())?;
    if !out.status.success() {
        return Err(String::from_utf8_lossy(&out.stderr).trim().to_string());
    }
    Ok(String::from_utf8_lossy(&out.stdout).to_string())
}

async fn git_output_in(dir: &Path, args: &[&str]) -> Result<String, String> {
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
                let out = TokioCommand::new("zsh")
                    .arg("-lc")
                    .arg(&command)
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
        &git_output_in(&worktree_path, &["diff", "--", "."]).await?,
        secrets,
    );
    let changed_files_raw =
        git_output_in(&worktree_path, &["diff", "--name-only", "--", "."]).await?;
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

async fn stop_control_plane(state: &AppState) {
    let prior = {
        let mut slot = state.control_plane.lock().await;
        slot.take()
    };
    if let Some(handle) = prior {
        handle.shutdown().await;
    }
}

async fn restart_control_plane(
    app: &AppHandle,
    state: &AppState,
    project_path: &Path,
    project_config: &ProjectConfig,
    global_config: &GlobalConfig,
) -> Result<(), String> {
    stop_control_plane(state).await;
    let settings = resolve_control_plane_settings(project_path, project_config, global_config)?;
    let next = start_control_plane(app.clone(), settings).await?;
    let mut slot = state.control_plane.lock().await;
    *slot = next;
    Ok(())
}

async fn cleanup_task_worktree(
    db: &Db,
    git: &Arc<GitService>,
    project_id: Uuid,
    task_id: Uuid,
    app: Option<&AppHandle>,
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
            if let Some(app) = app {
                emit_enriched_task_event(app, db, &task_id_str).await;
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
    let safe_payload = redact_json_value(payload, &[]);
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
    let safe_payload = redact_payload_for_log(payload);
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

fn spawn_session_bridge(app: AppHandle, db: Db, sessions: SessionSupervisor, project_id: Uuid) {
    let mut rx = sessions.subscribe();
    tauri::async_runtime::spawn(async move {
        while let Ok(event) = rx.recv().await {
            match event {
                SessionEvent::Spawned(meta) => {
                    let row = session_row_from_meta(&meta);
                    let _ = db.upsert_session(&row).await;
                    let _ = app.emit(
                        "session_spawned",
                        json!({"session_id": meta.id, "name": meta.name, "session": session_row_to_event_payload(&row)}),
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
                    let safe_chunk = redact_text(&chunk, &[]);
                    let _ = app.emit(
                        "session_output",
                        json!({"session_id": session_id, "chunk": safe_chunk.clone()}),
                    );
                    append_event(
                        &db,
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
                        let _ = create_notification_row(
                            &db,
                            &app,
                            project_id,
                            None,
                            Some(session_id),
                            osc_title(&attention.code),
                            &body,
                            Some(osc_level(&attention.code)),
                            "osc",
                            &[],
                        )
                        .await;
                    }
                }
                SessionEvent::Heartbeat { session_id, health } => {
                    let session_payload = if let Some(meta) = sessions.get(session_id).await {
                        let row = session_row_from_meta(&meta);
                        let _ = db.upsert_session(&row).await;
                        Some(session_row_to_event_payload(&row))
                    } else {
                        None
                    };
                    let mut payload =
                        json!({"session_id": session_id, "health": format!("{:?}", health)});
                    if let Some(s) = session_payload {
                        payload["session"] = s;
                    }
                    let _ = app.emit("session_heartbeat", payload);
                }
                SessionEvent::Exited { session_id, code } => {
                    let session_payload = if let Some(meta) = sessions.get(session_id).await {
                        let row = session_row_from_meta(&meta);
                        let _ = db.upsert_session(&row).await;
                        Some(session_row_to_event_payload(&row))
                    } else {
                        None
                    };
                    let mut payload = json!({"session_id": session_id, "code": code});
                    if let Some(s) = session_payload {
                        payload["session"] = s;
                    }
                    let _ = app.emit("session_exited", payload);
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
    });
}

#[tauri::command]
pub async fn open_project(
    path: String,
    app: AppHandle,
    state: State<'_, AppState>,
) -> Result<String, String> {
    let path_buf = PathBuf::from(path.clone());
    let config_path = path_buf.join("pnevma.toml");

    // --- Workspace trust gate ---
    let config_content = std::fs::read_to_string(&config_path).map_err(|e| e.to_string())?;
    let current_fingerprint = sha256_hex(config_content.as_bytes());
    let path_str_for_trust = path_buf.to_string_lossy().to_string();
    let global_db = GlobalDb::open().await.map_err(|e| e.to_string())?;
    let trust = global_db
        .is_path_trusted(&path_str_for_trust)
        .await
        .map_err(|e| e.to_string())?;
    match trust {
        Some(record) if record.fingerprint == current_fingerprint => {
            // Trusted and unchanged — proceed
        }
        Some(_) => {
            return Err("workspace_config_changed".to_string());
        }
        None => {
            return Err("workspace_not_trusted".to_string());
        }
    }

    let cfg = load_project_config(&config_path).map_err(|e| e.to_string())?;
    let global_cfg = load_global_config().map_err(|e| e.to_string())?;

    let db = Db::open(&path_buf).await.map_err(|e| e.to_string())?;
    let path_str = path_buf.to_string_lossy().to_string();
    let existing = db
        .find_project_by_path(&path_str)
        .await
        .map_err(|e| e.to_string())?;
    let project_id = existing
        .as_ref()
        .and_then(|p| Uuid::parse_str(&p.id).ok())
        .unwrap_or_else(Uuid::new_v4);

    db.upsert_project(
        &project_id.to_string(),
        &cfg.project.name,
        &path_str,
        Some(&cfg.project.brief),
        Some(config_path.to_string_lossy().as_ref()),
    )
    .await
    .map_err(|e| e.to_string())?;

    let sessions = SessionSupervisor::new(path_buf.join(".pnevma/data"));
    let adapters = pnevma_agents::AdapterRegistry::detect();
    let pool = DispatchPool::new(cfg.agents.max_concurrent);
    let git = Arc::new(GitService::new(&path_buf));
    spawn_session_bridge(app.clone(), db.clone(), sessions.clone(), project_id);
    {
        let sessions = sessions.clone();
        tokio::spawn(async move {
            let mut ticker = tokio::time::interval(std::time::Duration::from_secs(30));
            loop {
                ticker.tick().await;
                sessions.refresh_health().await;
            }
        });
    }

    let session_rows = reconcile_persisted_sessions(&db, project_id, path_buf.as_path()).await?;
    let restore_root = path_buf.join(".pnevma/data");
    for row in session_rows {
        if let Some(meta) = session_meta_from_row(&row, &restore_root) {
            let session_id = meta.id;
            append_event(
                &db,
                project_id,
                None,
                Some(session_id),
                "session",
                "SessionHealthChanged",
                json!({"status": row.status}),
            )
            .await;
            sessions.register_restored(meta).await;
            if row.status == "waiting" {
                match sessions.attach_existing(session_id).await {
                    Ok(()) => {
                        append_event(
                            &db,
                            project_id,
                            None,
                            Some(session_id),
                            "session",
                            "SessionReattached",
                            json!({}),
                        )
                        .await;
                    }
                    Err(err) => {
                        append_event(
                            &db,
                            project_id,
                            None,
                            Some(session_id),
                            "session",
                            "SessionReattachFailed",
                            json!({"error": err.to_string()}),
                        )
                        .await;
                    }
                }
            }
        }
    }

    ensure_default_panes(&db, project_id).await?;
    ensure_system_layout_templates(&db, project_id).await?;
    ensure_scope_rows_from_config(&db, project_id, &path_buf, &cfg, "rule").await?;
    ensure_scope_rows_from_config(&db, project_id, &path_buf, &cfg, "convention").await?;

    let ctx = ProjectContext {
        project_id,
        project_path: path_buf.clone(),
        config: cfg.clone(),
        global_config: global_cfg.clone(),
        db: db.clone(),
        sessions: sessions.clone(),
        git,
        adapters,
        pool,
    };

    {
        let mut current = state.current.lock().await;
        *current = Some(ctx);
    }

    if let Err(err) =
        restart_control_plane(&app, state.inner(), path_buf.as_path(), &cfg, &global_cfg).await
    {
        let mut current = state.current.lock().await;
        *current = None;
        return Err(err);
    }

    {
        let mut recents = state.recents.lock().await;
        recents.retain(|r| r.path != path);
        recents.insert(
            0,
            RecentProject {
                id: project_id.to_string(),
                name: cfg.project.name.clone(),
                path,
            },
        );
        recents.truncate(20);
    }

    append_event(
        &db,
        project_id,
        None,
        None,
        "system",
        "ProjectOpened",
        json!({"path": path_str}),
    )
    .await;
    append_telemetry_event(
        &db,
        project_id,
        &global_cfg,
        "project.open",
        json!({"path": path_str}),
    )
    .await;

    Ok(project_id.to_string())
}

#[tauri::command]
pub async fn close_project(state: State<'_, AppState>) -> Result<(), String> {
    let (db, project_id) = {
        let current = state.current.lock().await;
        let Some(ctx) = current.as_ref() else {
            return {
                drop(current);
                stop_control_plane(state.inner()).await;
                Ok(())
            };
        };
        (ctx.db.clone(), ctx.project_id)
    };

    append_event(
        &db,
        project_id,
        None,
        None,
        "system",
        "ProjectClosed",
        json!({}),
    )
    .await;

    {
        let mut current = state.current.lock().await;
        *current = None;
    }
    stop_control_plane(state.inner()).await;
    Ok(())
}

#[tauri::command]
pub async fn list_recent_projects(
    state: State<'_, AppState>,
) -> Result<Vec<RecentProject>, String> {
    Ok(state.recents.lock().await.clone())
}

#[tauri::command]
pub async fn trust_workspace(path: String) -> Result<(), String> {
    let path_buf = PathBuf::from(&path);
    let config_path = path_buf.join("pnevma.toml");
    let content = std::fs::read_to_string(&config_path).map_err(|e| e.to_string())?;
    let fingerprint = sha256_hex(content.as_bytes());
    let canonical = path_buf.to_string_lossy().to_string();
    let global_db = GlobalDb::open().await.map_err(|e| e.to_string())?;
    global_db
        .trust_path(&canonical, &fingerprint)
        .await
        .map_err(|e| e.to_string())?;
    Ok(())
}

#[tauri::command]
pub async fn revoke_workspace_trust(path: String) -> Result<(), String> {
    let global_db = GlobalDb::open().await.map_err(|e| e.to_string())?;
    global_db
        .revoke_trust(&path)
        .await
        .map_err(|e| e.to_string())?;
    Ok(())
}

#[tauri::command]
pub async fn list_trusted_workspaces() -> Result<Vec<TrustRecord>, String> {
    let global_db = GlobalDb::open().await.map_err(|e| e.to_string())?;
    global_db
        .list_trusted_paths()
        .await
        .map_err(|e| e.to_string())
}

#[tauri::command]
pub async fn create_session(
    input: SessionInput,
    state: State<'_, AppState>,
) -> Result<String, String> {
    let current = state.current.lock().await;
    let ctx = current
        .as_ref()
        .ok_or_else(|| "no open project".to_string())?;
    let cwd = if Path::new(&input.cwd).is_relative() {
        ctx.project_path
            .join(&input.cwd)
            .to_string_lossy()
            .to_string()
    } else {
        input.cwd.clone()
    };

    let session = ctx
        .sessions
        .spawn_shell(
            ctx.project_id,
            input.name.clone(),
            cwd.clone(),
            input.command.clone(),
        )
        .await
        .map_err(|e| e.to_string())?;

    let row = session_row_from_meta(&session);
    ctx.db
        .upsert_session(&row)
        .await
        .map_err(|e| e.to_string())?;

    append_event(
        &ctx.db,
        ctx.project_id,
        None,
        Some(session.id),
        "session",
        "SessionSpawned",
        json!({"name": input.name, "cwd": cwd}),
    )
    .await;

    Ok(row.id)
}

#[tauri::command]
pub async fn list_sessions(state: State<'_, AppState>) -> Result<Vec<SessionRow>, String> {
    let current = state.current.lock().await;
    let ctx = current
        .as_ref()
        .ok_or_else(|| "no open project".to_string())?;
    ctx.db
        .list_sessions(&ctx.project_id.to_string())
        .await
        .map_err(|e| e.to_string())
}

#[tauri::command]
pub async fn restart_session(
    session_id: String,
    state: State<'_, AppState>,
) -> Result<String, String> {
    let current = state.current.lock().await;
    let ctx = current
        .as_ref()
        .ok_or_else(|| "no open project".to_string())?;

    let sessions = ctx
        .db
        .list_sessions(&ctx.project_id.to_string())
        .await
        .map_err(|e| e.to_string())?;
    let mut prior = sessions
        .into_iter()
        .find(|row| row.id == session_id)
        .ok_or_else(|| format!("session not found: {session_id}"))?;
    let prior_session_id = Uuid::parse_str(&prior.id).ok();

    let cwd = if Path::new(&prior.cwd).is_relative() {
        ctx.project_path
            .join(&prior.cwd)
            .to_string_lossy()
            .to_string()
    } else {
        prior.cwd.clone()
    };

    let new_meta = ctx
        .sessions
        .spawn_shell(
            ctx.project_id,
            prior.name.clone(),
            cwd.clone(),
            prior.command.clone(),
        )
        .await
        .map_err(|e| e.to_string())?;

    prior.status = "complete".to_string();
    prior.pid = None;
    prior.last_heartbeat = Utc::now();
    ctx.db
        .upsert_session(&prior)
        .await
        .map_err(|e| e.to_string())?;
    if let Some(old_id) = prior_session_id {
        let _ = ctx.sessions.kill_session_backend(old_id).await;
        let _ = ctx.sessions.mark_exit(old_id, None).await;
    }

    let row = session_row_from_meta(&new_meta);
    ctx.db
        .upsert_session(&row)
        .await
        .map_err(|e| e.to_string())?;

    let panes = ctx
        .db
        .list_panes(&ctx.project_id.to_string())
        .await
        .map_err(|e| e.to_string())?;
    for mut pane in panes {
        if pane.session_id.as_deref() != Some(prior.id.as_str()) {
            continue;
        }
        pane.session_id = Some(row.id.clone());
        ctx.db.upsert_pane(&pane).await.map_err(|e| e.to_string())?;
    }

    append_event(
        &ctx.db,
        ctx.project_id,
        None,
        Some(new_meta.id),
        "session",
        "SessionSpawned",
        json!({"restart_of": prior.id, "cwd": cwd}),
    )
    .await;

    Ok(row.id)
}

#[tauri::command]
pub async fn send_session_input(
    session_id: String,
    input: String,
    state: State<'_, AppState>,
) -> Result<(), String> {
    let current = state.current.lock().await;
    let ctx = current
        .as_ref()
        .ok_or_else(|| "no open project".to_string())?;
    let session_id = Uuid::parse_str(&session_id).map_err(|e| e.to_string())?;
    ctx.sessions
        .send_input(session_id, &input)
        .await
        .map_err(|e| e.to_string())
}

#[tauri::command]
pub async fn resize_session(
    session_id: String,
    cols: u16,
    rows: u16,
    state: State<'_, AppState>,
) -> Result<(), String> {
    let current = state.current.lock().await;
    let ctx = current
        .as_ref()
        .ok_or_else(|| "no open project".to_string())?;
    let session_id = Uuid::parse_str(&session_id).map_err(|e| e.to_string())?;
    ctx.sessions
        .resize(session_id, cols, rows)
        .await
        .map_err(|e| e.to_string())
}

#[tauri::command]
pub async fn get_scrollback(
    input: ScrollbackInput,
    state: State<'_, AppState>,
) -> Result<ScrollbackSlice, String> {
    let current = state.current.lock().await;
    let ctx = current
        .as_ref()
        .ok_or_else(|| "no open project".to_string())?;
    let session_id = Uuid::parse_str(&input.session_id).map_err(|e| e.to_string())?;

    ctx.sessions
        .read_scrollback(
            session_id,
            input.offset.unwrap_or(0),
            input.limit.unwrap_or(64 * 1024),
        )
        .await
        .map_err(|e| e.to_string())
}

#[tauri::command]
pub async fn restore_sessions(state: State<'_, AppState>) -> Result<Vec<SessionRow>, String> {
    let current = state.current.lock().await;
    let ctx = current
        .as_ref()
        .ok_or_else(|| "no open project".to_string())?;
    let rows =
        reconcile_persisted_sessions(&ctx.db, ctx.project_id, ctx.project_path.as_path()).await?;
    for row in &rows {
        if row.status != "waiting" {
            continue;
        }
        if let Ok(id) = Uuid::parse_str(&row.id) {
            let _ = ctx.sessions.attach_existing(id).await;
        }
    }
    Ok(rows)
}

#[tauri::command]
pub async fn reattach_session(
    session_id: String,
    state: State<'_, AppState>,
) -> Result<(), String> {
    let current = state.current.lock().await;
    let ctx = current
        .as_ref()
        .ok_or_else(|| "no open project".to_string())?;
    let session_id = Uuid::parse_str(&session_id).map_err(|e| e.to_string())?;
    ctx.sessions
        .attach_existing(session_id)
        .await
        .map_err(|e| e.to_string())?;

    append_event(
        &ctx.db,
        ctx.project_id,
        None,
        Some(session_id),
        "session",
        "SessionReattached",
        json!({"manual": true}),
    )
    .await;

    Ok(())
}

#[tauri::command]
pub async fn list_panes(state: State<'_, AppState>) -> Result<Vec<PaneRow>, String> {
    let current = state.current.lock().await;
    let ctx = current
        .as_ref()
        .ok_or_else(|| "no open project".to_string())?;
    ctx.db
        .list_panes(&ctx.project_id.to_string())
        .await
        .map_err(|e| e.to_string())
}

#[tauri::command]
pub async fn upsert_pane(input: PaneInput, state: State<'_, AppState>) -> Result<PaneRow, String> {
    let current = state.current.lock().await;
    let ctx = current
        .as_ref()
        .ok_or_else(|| "no open project".to_string())?;

    let row = PaneRow {
        id: input.id.unwrap_or_else(|| Uuid::new_v4().to_string()),
        project_id: ctx.project_id.to_string(),
        session_id: input.session_id,
        r#type: input.r#type,
        position: input.position,
        label: input.label,
        metadata_json: input.metadata_json,
    };

    ctx.db.upsert_pane(&row).await.map_err(|e| e.to_string())?;
    Ok(row)
}

#[tauri::command]
pub async fn remove_pane(pane_id: String, state: State<'_, AppState>) -> Result<(), String> {
    let current = state.current.lock().await;
    let ctx = current
        .as_ref()
        .ok_or_else(|| "no open project".to_string())?;
    ctx.db
        .remove_pane(&pane_id)
        .await
        .map_err(|e| e.to_string())
}

#[tauri::command]
pub async fn list_pane_layout_templates(
    state: State<'_, AppState>,
) -> Result<Vec<PaneLayoutTemplateView>, String> {
    let (db, project_id) = {
        let current = state.current.lock().await;
        let ctx = current
            .as_ref()
            .ok_or_else(|| "no open project".to_string())?;
        (ctx.db.clone(), ctx.project_id)
    };
    ensure_system_layout_templates(&db, project_id).await?;
    let rows = db
        .list_pane_layout_templates(&project_id.to_string())
        .await
        .map_err(|e| e.to_string())?;
    rows.into_iter()
        .map(pane_layout_template_view_from_row)
        .collect()
}

#[tauri::command]
pub async fn save_pane_layout_template(
    input: SavePaneLayoutTemplateInput,
    app: AppHandle,
    state: State<'_, AppState>,
) -> Result<PaneLayoutTemplateView, String> {
    let name = normalize_layout_template_name(&input.name);
    if name.is_empty() {
        return Err("template name cannot be empty".to_string());
    }
    let system_names = system_layout_templates()
        .into_iter()
        .map(|(id, _, _)| id)
        .collect::<HashSet<_>>();
    if system_names.contains(&name) {
        return Err(format!("template name is reserved: {name}"));
    }

    let display_name = input
        .display_name
        .as_deref()
        .map(str::trim)
        .filter(|v| !v.is_empty())
        .map(ToString::to_string)
        .unwrap_or_else(|| default_layout_template_display_name(&name));

    let (db, project_id) = {
        let current = state.current.lock().await;
        let ctx = current
            .as_ref()
            .ok_or_else(|| "no open project".to_string())?;
        (ctx.db.clone(), ctx.project_id)
    };
    ensure_system_layout_templates(&db, project_id).await?;

    let panes = db
        .list_panes(&project_id.to_string())
        .await
        .map_err(|e| e.to_string())?;
    if panes.is_empty() {
        return Err("cannot save an empty pane layout".to_string());
    }
    let template_panes = panes
        .into_iter()
        .map(|pane| PaneLayoutTemplatePane {
            id: pane.id,
            session_id: pane.session_id,
            r#type: pane.r#type,
            position: pane.position,
            label: pane.label,
            metadata_json: pane.metadata_json,
        })
        .collect::<Vec<_>>();

    let existing = db
        .get_pane_layout_template(&project_id.to_string(), &name)
        .await
        .map_err(|e| e.to_string())?;
    if existing.as_ref().is_some_and(|row| row.is_system) {
        return Err(format!("cannot overwrite system template: {name}"));
    }
    let now = Utc::now();
    let (id, created_at) = existing
        .map(|row| (row.id, row.created_at))
        .unwrap_or_else(|| (Uuid::new_v4().to_string(), now));

    let row = PaneLayoutTemplateRow {
        id,
        project_id: project_id.to_string(),
        name: name.clone(),
        display_name: display_name.clone(),
        pane_graph_json: panes_to_template_json(&template_panes)?,
        is_system: false,
        created_at,
        updated_at: now,
    };
    db.upsert_pane_layout_template(&row)
        .await
        .map_err(|e| e.to_string())?;

    append_event(
        &db,
        project_id,
        None,
        None,
        "ui",
        "PaneLayoutTemplateSaved",
        json!({"name": name, "display_name": display_name, "pane_count": template_panes.len()}),
    )
    .await;
    let _ = app.emit(
        "project_refreshed",
        json!({"reason": "layout_template_saved", "template_name": row.name}),
    );

    pane_layout_template_view_from_row(row)
}

#[tauri::command]
pub async fn apply_pane_layout_template(
    input: ApplyPaneLayoutTemplateInput,
    app: AppHandle,
    state: State<'_, AppState>,
) -> Result<ApplyPaneLayoutTemplateResult, String> {
    let template_name = normalize_layout_template_name(&input.name);
    if template_name.is_empty() {
        return Err("template name cannot be empty".to_string());
    }

    let (db, project_id) = {
        let current = state.current.lock().await;
        let ctx = current
            .as_ref()
            .ok_or_else(|| "no open project".to_string())?;
        (ctx.db.clone(), ctx.project_id)
    };
    ensure_system_layout_templates(&db, project_id).await?;

    let template = db
        .get_pane_layout_template(&project_id.to_string(), &template_name)
        .await
        .map_err(|e| e.to_string())?
        .ok_or_else(|| format!("template not found: {template_name}"))?;
    let template_panes = parse_template_panes(&template.pane_graph_json)?;
    if template_panes.is_empty() {
        return Err("template contains no panes".to_string());
    }
    let mut template_ids = HashSet::new();
    for pane in &template_panes {
        if pane.id.trim().is_empty() {
            return Err(format!(
                "template {template_name} has a pane with an empty id"
            ));
        }
        if !template_ids.insert(pane.id.clone()) {
            return Err(format!(
                "template {template_name} contains duplicate pane id: {}",
                pane.id
            ));
        }
    }

    let current_panes = db
        .list_panes(&project_id.to_string())
        .await
        .map_err(|e| e.to_string())?;
    let session_rows = db
        .list_sessions(&project_id.to_string())
        .await
        .map_err(|e| e.to_string())?;
    let sessions_by_id = session_rows
        .into_iter()
        .map(|row| (row.id.clone(), row))
        .collect::<HashMap<_, _>>();
    let desired_by_id = template_panes
        .iter()
        .map(|pane| (pane.id.clone(), pane))
        .collect::<HashMap<_, _>>();

    let mut replaced_panes = Vec::new();
    let mut unsaved_replacements = Vec::new();
    for pane in &current_panes {
        let changed = desired_by_id
            .get(&pane.id)
            .map(|target| {
                pane.session_id != target.session_id
                    || pane.r#type != target.r#type
                    || pane.position != target.position
                    || pane.label != target.label
                    || pane.metadata_json != target.metadata_json
            })
            .unwrap_or(true);
        if !changed {
            continue;
        }
        replaced_panes.push(pane.id.clone());

        if pane_contains_unsaved_metadata(pane.metadata_json.as_deref()) {
            unsaved_replacements.push(UnsavedPaneReplacementView {
                pane_id: pane.id.clone(),
                pane_label: pane.label.clone(),
                pane_type: pane.r#type.clone(),
                reason: "pane metadata is marked unsaved/dirty".to_string(),
            });
            continue;
        }
        if pane.r#type != "terminal" {
            continue;
        }
        let Some(session_id) = pane.session_id.as_deref() else {
            continue;
        };
        let Some(session) = sessions_by_id.get(session_id) else {
            continue;
        };
        if session_state_may_be_unsaved(&session.status) {
            unsaved_replacements.push(UnsavedPaneReplacementView {
                pane_id: pane.id.clone(),
                pane_label: pane.label.clone(),
                pane_type: pane.r#type.clone(),
                reason: format!(
                    "bound session \"{}\" is still {}",
                    session.name, session.status
                ),
            });
        }
    }

    if !input.force && !unsaved_replacements.is_empty() {
        return Ok(ApplyPaneLayoutTemplateResult {
            applied: false,
            template_name,
            replaced_panes,
            unsaved_replacements,
        });
    }

    let existing_sessions = sessions_by_id.keys().cloned().collect::<HashSet<_>>();
    for pane in &current_panes {
        db.remove_pane(&pane.id).await.map_err(|e| e.to_string())?;
        let _ = app.emit(
            "pane_updated",
            json!({
                "action": "removed",
                "pane_id": pane.id,
                "template_name": template.name,
            }),
        );
    }
    for pane in &template_panes {
        let mut session_id = pane.session_id.clone();
        if session_id
            .as_ref()
            .is_some_and(|id| !existing_sessions.contains(id))
        {
            session_id = None;
        }
        let row = PaneRow {
            id: pane.id.clone(),
            project_id: project_id.to_string(),
            session_id,
            r#type: pane.r#type.clone(),
            position: pane.position.clone(),
            label: pane.label.clone(),
            metadata_json: pane.metadata_json.clone(),
        };
        db.upsert_pane(&row).await.map_err(|e| e.to_string())?;
        let _ = app.emit(
            "pane_updated",
            json!({
                "action": "upserted",
                "pane_id": row.id,
                "pane_type": row.r#type,
                "template_name": template.name,
            }),
        );
    }

    append_event(
        &db,
        project_id,
        None,
        None,
        "ui",
        "PaneLayoutTemplateApplied",
        json!({
            "name": template.name,
            "force": input.force,
            "pane_count": template_panes.len(),
            "replaced_panes": replaced_panes.clone(),
            "unsaved_replacements": unsaved_replacements.clone(),
        }),
    )
    .await;
    let _ = app.emit(
        "project_refreshed",
        json!({"reason": "layout_template_applied", "template_name": template.name}),
    );

    Ok(ApplyPaneLayoutTemplateResult {
        applied: true,
        template_name,
        replaced_panes,
        unsaved_replacements,
    })
}

#[tauri::command]
pub async fn query_events(
    input: QueryEventsInput,
    state: State<'_, AppState>,
) -> Result<Vec<EventRow>, String> {
    let current = state.current.lock().await;
    let ctx = current
        .as_ref()
        .ok_or_else(|| "no open project".to_string())?;

    ctx.db
        .query_events(EventQueryFilter {
            project_id: ctx.project_id.to_string(),
            task_id: input.task_id,
            session_id: input.session_id,
            event_type: input.event_type,
            from: parse_dt(input.from),
            to: parse_dt(input.to),
            limit: input.limit,
        })
        .await
        .map_err(|e| e.to_string())
}

#[tauri::command]
pub async fn search_project(
    input: SearchProjectInput,
    state: State<'_, AppState>,
) -> Result<Vec<SearchResultView>, String> {
    let query = input.query.trim().to_string();
    if query.is_empty() {
        return Ok(Vec::new());
    }

    let (db, project_id, project_path, sessions) = {
        let current = state.current.lock().await;
        let ctx = current
            .as_ref()
            .ok_or_else(|| "no open project".to_string())?;
        (
            ctx.db.clone(),
            ctx.project_id,
            ctx.project_path.clone(),
            ctx.sessions.clone(),
        )
    };

    let limit = input.limit.unwrap_or(120).clamp(1, 500);
    let mut hits = Vec::new();

    let tasks = db
        .list_tasks(&project_id.to_string())
        .await
        .map_err(|e| e.to_string())?;
    for task in tasks {
        let body = format!(
            "{}\n{}\n{}\n{}\n{}",
            task.title, task.goal, task.scope_json, task.constraints_json, task.acceptance_json
        );
        if contains_case_insensitive(&body, &query) {
            hits.push(SearchResultView {
                id: format!("task:{}", task.id),
                source: "task".to_string(),
                title: task.title.clone(),
                snippet: summarize_match(&body, &query),
                path: None,
                task_id: Some(task.id),
                session_id: None,
                timestamp: Some(task.updated_at),
            });
        }
        if hits.len() >= limit {
            return Ok(hits);
        }
    }

    let events = db
        .list_recent_events(&project_id.to_string(), 4_000)
        .await
        .map_err(|e| e.to_string())?;
    for event in events {
        let body = format!(
            "{}\n{}\n{}",
            event.event_type, event.source, event.payload_json
        );
        if contains_case_insensitive(&body, &query) {
            hits.push(SearchResultView {
                id: format!("event:{}", event.id),
                source: "event".to_string(),
                title: event.event_type.clone(),
                snippet: summarize_match(&body, &query),
                path: None,
                task_id: event.task_id.clone(),
                session_id: event.session_id.clone(),
                timestamp: Some(event.timestamp),
            });
        }
        if hits.len() >= limit {
            return Ok(hits);
        }
    }

    let artifacts = db
        .list_artifacts(&project_id.to_string())
        .await
        .map_err(|e| e.to_string())?;
    for artifact in artifacts {
        let body = format!(
            "{}\n{}\n{}",
            artifact.r#type,
            artifact.path,
            artifact.description.clone().unwrap_or_default()
        );
        if contains_case_insensitive(&body, &query) {
            hits.push(SearchResultView {
                id: format!("artifact:{}", artifact.id),
                source: "artifact".to_string(),
                title: format!("{} · {}", artifact.r#type, artifact.path),
                snippet: summarize_match(&body, &query),
                path: Some(artifact.path.clone()),
                task_id: artifact.task_id.clone(),
                session_id: None,
                timestamp: Some(artifact.created_at),
            });
        }
        if hits.len() >= limit {
            return Ok(hits);
        }
    }

    let commit_log = git_output(
        &project_path,
        &["log", "--pretty=format:%H%x1f%ct%x1f%s", "-n", "300"],
    )
    .await
    .unwrap_or_default();
    for line in commit_log.lines() {
        let mut parts = line.split('\x1f');
        let hash = parts.next().unwrap_or_default();
        let ts = parts
            .next()
            .and_then(|v| v.parse::<i64>().ok())
            .and_then(|secs| DateTime::<Utc>::from_timestamp(secs, 0));
        let subject = parts.next().unwrap_or_default();
        if hash.is_empty() || subject.is_empty() {
            continue;
        }
        if contains_case_insensitive(subject, &query) {
            hits.push(SearchResultView {
                id: format!("commit:{hash}"),
                source: "commit".to_string(),
                title: format!("commit {}", hash.chars().take(8).collect::<String>()),
                snippet: subject.to_string(),
                path: None,
                task_id: None,
                session_id: None,
                timestamp: ts,
            });
        }
        if hits.len() >= limit {
            return Ok(hits);
        }
    }

    let metas = sessions.list().await;
    for meta in metas {
        let slice = sessions
            .read_scrollback(meta.id, 0, 128 * 1024)
            .await
            .unwrap_or(ScrollbackSlice {
                session_id: meta.id,
                start_offset: 0,
                end_offset: 0,
                total_bytes: 0,
                data: String::new(),
            });
        if slice.data.is_empty() || !contains_case_insensitive(&slice.data, &query) {
            continue;
        }
        hits.push(SearchResultView {
            id: format!("scrollback:{}", meta.id),
            source: "scrollback".to_string(),
            title: format!("session {}", meta.name),
            snippet: summarize_match(&slice.data, &query),
            path: Some(meta.scrollback_path.clone()),
            task_id: None,
            session_id: Some(meta.id.to_string()),
            timestamp: Some(meta.last_heartbeat),
        });
        if hits.len() >= limit {
            return Ok(hits);
        }
    }

    Ok(hits)
}

#[tauri::command]
pub async fn list_project_files(
    input: Option<ListProjectFilesInput>,
    state: State<'_, AppState>,
) -> Result<Vec<ProjectFileView>, String> {
    let (project_path, query) = {
        let current = state.current.lock().await;
        let ctx = current
            .as_ref()
            .ok_or_else(|| "no open project".to_string())?;
        (
            ctx.project_path.clone(),
            input
                .as_ref()
                .and_then(|v| v.query.clone())
                .unwrap_or_default(),
        )
    };

    let limit = input.and_then(|v| v.limit).unwrap_or(1_000).clamp(1, 5_000);
    let mut all_paths = HashSet::new();
    let tracked = git_output(&project_path, &["ls-files"])
        .await
        .unwrap_or_default();
    for line in tracked.lines().map(str::trim).filter(|v| !v.is_empty()) {
        all_paths.insert(line.to_string());
    }
    let untracked = git_output(
        &project_path,
        &["ls-files", "--others", "--exclude-standard"],
    )
    .await
    .unwrap_or_default();
    for line in untracked.lines().map(str::trim).filter(|v| !v.is_empty()) {
        all_paths.insert(line.to_string());
    }

    let mut statuses = HashMap::<String, String>::new();
    let porcelain = git_output(&project_path, &["status", "--porcelain"])
        .await
        .unwrap_or_default();
    for line in porcelain.lines() {
        if let Some((path, status)) = parse_porcelain_status_line(line) {
            statuses.insert(path, status);
        }
    }

    let query = query.trim().to_ascii_lowercase();
    let mut files = all_paths
        .into_iter()
        .filter(|path| query.is_empty() || path.to_ascii_lowercase().contains(&query))
        .map(|path| {
            let status = statuses
                .get(&path)
                .cloned()
                .unwrap_or_else(|| "  ".to_string());
            let staged = status.chars().next().is_some_and(|c| c != ' ' && c != '?');
            let modified = status.chars().nth(1).is_some_and(|c| c != ' ' && c != '?');
            let conflicted = status.contains('U');
            let untracked = status.starts_with("??");
            ProjectFileView {
                path,
                status,
                modified,
                staged,
                conflicted,
                untracked,
            }
        })
        .collect::<Vec<_>>();
    files.sort_by(|a, b| a.path.cmp(&b.path));
    if files.len() > limit {
        files.truncate(limit);
    }
    Ok(files)
}

#[tauri::command]
pub async fn open_file_target(
    input: OpenFileTargetInput,
    state: State<'_, AppState>,
) -> Result<FileOpenResultView, String> {
    let project_path = {
        let current = state.current.lock().await;
        let ctx = current
            .as_ref()
            .ok_or_else(|| "no open project".to_string())?;
        ctx.project_path.clone()
    };
    let rel = input.path.trim().trim_start_matches('/');
    if rel.is_empty() {
        return Err("invalid path".to_string());
    }
    let abs = project_path.join(rel);
    if !abs.exists() {
        return Err(format!("file not found: {}", input.path));
    }
    let canonical = abs.canonicalize().map_err(|e| e.to_string())?;
    let canonical_project = project_path.canonicalize().map_err(|e| e.to_string())?;
    if !canonical.starts_with(&canonical_project) {
        return Err("path escapes project directory".to_string());
    }
    if !canonical.is_file() {
        return Err("path is not a file".to_string());
    }

    let editor_mode = input.mode.as_deref().unwrap_or("preview") == "editor";
    let launched_editor = if editor_mode {
        if let Ok(editor) = std::env::var("EDITOR") {
            if !editor.trim().is_empty() {
                TokioCommand::new(editor)
                    .arg(&abs)
                    .current_dir(&project_path)
                    .spawn()
                    .is_ok()
            } else {
                false
            }
        } else {
            false
        }
    } else {
        false
    };

    let raw = tokio::fs::read_to_string(&abs).await.unwrap_or_default();
    let max_chars = 20_000usize;
    let truncated = raw.chars().count() > max_chars;
    let content = if truncated {
        raw.chars().take(max_chars).collect::<String>()
    } else {
        raw
    };

    Ok(FileOpenResultView {
        path: rel.to_string(),
        content,
        truncated,
        launched_editor,
    })
}

#[tauri::command]
pub async fn get_task_diff(
    input: TaskDiffInput,
    state: State<'_, AppState>,
) -> Result<Option<TaskDiffView>, String> {
    let db = {
        let current = state.current.lock().await;
        let ctx = current
            .as_ref()
            .ok_or_else(|| "no open project".to_string())?;
        ctx.db.clone()
    };
    let Some(review) = db
        .get_review_by_task(&input.task_id)
        .await
        .map_err(|e| e.to_string())?
    else {
        return Ok(None);
    };
    let review_text = tokio::fs::read_to_string(&review.review_pack_path)
        .await
        .map_err(|e| e.to_string())?;
    let pack =
        serde_json::from_str::<serde_json::Value>(&review_text).map_err(|e| e.to_string())?;
    let diff_path = pack
        .get("diff_path")
        .and_then(|v| v.as_str())
        .map(ToString::to_string)
        .unwrap_or_else(|| {
            PathBuf::from(&review.review_pack_path)
                .with_file_name("diff.patch")
                .to_string_lossy()
                .to_string()
        });
    let diff_text = tokio::fs::read_to_string(&diff_path)
        .await
        .map_err(|e| e.to_string())?;
    Ok(Some(TaskDiffView {
        task_id: input.task_id,
        diff_path,
        files: parse_diff_patch(&diff_text),
    }))
}

async fn rule_row_to_view(row: RuleRow, project_path: &Path) -> RuleView {
    let content = tokio::fs::read_to_string(project_path.join(&row.path))
        .await
        .unwrap_or_default();
    RuleView {
        id: row.id,
        name: row.name,
        path: row.path,
        scope: row.scope.unwrap_or_else(|| "rule".to_string()),
        active: row.active,
        content,
    }
}

async fn ensure_scope_rows_from_config(
    db: &Db,
    project_id: Uuid,
    project_path: &Path,
    config: &ProjectConfig,
    scope: &str,
) -> Result<(), String> {
    let patterns = if normalize_rule_scope(scope) == "convention" {
        &config.conventions.paths
    } else {
        &config.rules.paths
    };
    ensure_rule_rows(db, project_id, project_path, scope, patterns).await
}

#[tauri::command]
pub async fn list_rules(state: State<'_, AppState>) -> Result<Vec<RuleView>, String> {
    let (db, project_id, project_path, config) = {
        let current = state.current.lock().await;
        let ctx = current
            .as_ref()
            .ok_or_else(|| "no open project".to_string())?;
        (
            ctx.db.clone(),
            ctx.project_id,
            ctx.project_path.clone(),
            ctx.config.clone(),
        )
    };
    ensure_scope_rows_from_config(&db, project_id, &project_path, &config, "rule").await?;
    let rows = db
        .list_rules(&project_id.to_string(), Some("rule"))
        .await
        .map_err(|e| e.to_string())?;
    let mut out = Vec::with_capacity(rows.len());
    for row in rows {
        out.push(rule_row_to_view(row, &project_path).await);
    }
    Ok(out)
}

#[tauri::command]
pub async fn list_conventions(state: State<'_, AppState>) -> Result<Vec<RuleView>, String> {
    let (db, project_id, project_path, config) = {
        let current = state.current.lock().await;
        let ctx = current
            .as_ref()
            .ok_or_else(|| "no open project".to_string())?;
        (
            ctx.db.clone(),
            ctx.project_id,
            ctx.project_path.clone(),
            ctx.config.clone(),
        )
    };
    ensure_scope_rows_from_config(&db, project_id, &project_path, &config, "convention").await?;
    let rows = db
        .list_rules(&project_id.to_string(), Some("convention"))
        .await
        .map_err(|e| e.to_string())?;
    let mut out = Vec::with_capacity(rows.len());
    for row in rows {
        out.push(rule_row_to_view(row, &project_path).await);
    }
    Ok(out)
}

async fn upsert_scope_item(
    input: RuleUpsertInput,
    scope: &str,
    app: &AppHandle,
    state: &State<'_, AppState>,
) -> Result<RuleView, String> {
    let (db, project_id, project_path) = {
        let current = state.current.lock().await;
        let ctx = current
            .as_ref()
            .ok_or_else(|| "no open project".to_string())?;
        (ctx.db.clone(), ctx.project_id, ctx.project_path.clone())
    };
    let scope = normalize_rule_scope(scope);
    let mut row = if let Some(id) = input.id.clone() {
        db.get_rule(&id)
            .await
            .map_err(|e| e.to_string())?
            .unwrap_or(RuleRow {
                id,
                project_id: project_id.to_string(),
                name: input.name.clone(),
                path: String::new(),
                scope: Some(scope.to_string()),
                active: input.active.unwrap_or(true),
            })
    } else {
        RuleRow {
            id: Uuid::new_v4().to_string(),
            project_id: project_id.to_string(),
            name: input.name.clone(),
            path: String::new(),
            scope: Some(scope.to_string()),
            active: input.active.unwrap_or(true),
        }
    };

    row.name = input.name.trim().to_string();
    row.scope = Some(scope.to_string());
    row.active = input.active.unwrap_or(row.active);

    if row.path.trim().is_empty() {
        let dir = project_path.join(scope_default_dir(scope));
        tokio::fs::create_dir_all(&dir)
            .await
            .map_err(|e| e.to_string())?;
        let mut candidate = dir.join(format!("{}.md", sanitize_file_stem(&row.name)));
        if candidate.exists() {
            candidate = dir.join(format!(
                "{}-{}.md",
                sanitize_file_stem(&row.name),
                &row.id.chars().take(8).collect::<String>()
            ));
        }
        row.path = candidate
            .strip_prefix(&project_path)
            .unwrap_or(&candidate)
            .to_string_lossy()
            .to_string();
    }

    let absolute = project_path.join(&row.path);
    if let Some(parent) = absolute.parent() {
        tokio::fs::create_dir_all(parent)
            .await
            .map_err(|e| e.to_string())?;
    }
    tokio::fs::write(&absolute, input.content.as_bytes())
        .await
        .map_err(|e| e.to_string())?;
    db.upsert_rule(&row).await.map_err(|e| e.to_string())?;
    append_event(
        &db,
        project_id,
        None,
        None,
        "rules",
        "RuleUpdated",
        json!({"rule_id": row.id, "scope": scope, "active": row.active}),
    )
    .await;
    let _ = app.emit("project_refreshed", json!({"reason": "rules_updated"}));
    Ok(rule_row_to_view(row, &project_path).await)
}

#[tauri::command]
pub async fn upsert_rule(
    input: RuleUpsertInput,
    app: AppHandle,
    state: State<'_, AppState>,
) -> Result<RuleView, String> {
    upsert_scope_item(input, "rule", &app, &state).await
}

#[tauri::command]
pub async fn upsert_convention(
    input: RuleUpsertInput,
    app: AppHandle,
    state: State<'_, AppState>,
) -> Result<RuleView, String> {
    upsert_scope_item(input, "convention", &app, &state).await
}

async fn toggle_scope_item(
    input: RuleToggleInput,
    expected_scope: &str,
    app: &AppHandle,
    state: &State<'_, AppState>,
) -> Result<RuleView, String> {
    let (db, project_id, project_path) = {
        let current = state.current.lock().await;
        let ctx = current
            .as_ref()
            .ok_or_else(|| "no open project".to_string())?;
        (ctx.db.clone(), ctx.project_id, ctx.project_path.clone())
    };
    let mut row = db
        .get_rule(&input.id)
        .await
        .map_err(|e| e.to_string())?
        .ok_or_else(|| format!("rule not found: {}", input.id))?;
    let scope = row.scope.clone().unwrap_or_else(|| "rule".to_string());
    if normalize_rule_scope(&scope) != normalize_rule_scope(expected_scope) {
        return Err(format!("entry scope mismatch: expected {expected_scope}"));
    }
    row.active = input.active;
    db.upsert_rule(&row).await.map_err(|e| e.to_string())?;
    append_event(
        &db,
        project_id,
        None,
        None,
        "rules",
        "RuleToggled",
        json!({"rule_id": row.id, "active": row.active}),
    )
    .await;
    let _ = app.emit("project_refreshed", json!({"reason": "rules_updated"}));
    Ok(rule_row_to_view(row, &project_path).await)
}

#[tauri::command]
pub async fn toggle_rule(
    input: RuleToggleInput,
    app: AppHandle,
    state: State<'_, AppState>,
) -> Result<RuleView, String> {
    toggle_scope_item(input, "rule", &app, &state).await
}

#[tauri::command]
pub async fn toggle_convention(
    input: RuleToggleInput,
    app: AppHandle,
    state: State<'_, AppState>,
) -> Result<RuleView, String> {
    toggle_scope_item(input, "convention", &app, &state).await
}

async fn delete_scope_item(
    id: String,
    expected_scope: &str,
    app: &AppHandle,
    state: &State<'_, AppState>,
) -> Result<(), String> {
    let (db, project_id, project_path) = {
        let current = state.current.lock().await;
        let ctx = current
            .as_ref()
            .ok_or_else(|| "no open project".to_string())?;
        (ctx.db.clone(), ctx.project_id, ctx.project_path.clone())
    };
    let row = db
        .get_rule(&id)
        .await
        .map_err(|e| e.to_string())?
        .ok_or_else(|| format!("rule not found: {id}"))?;
    let scope = row.scope.clone().unwrap_or_else(|| "rule".to_string());
    if normalize_rule_scope(&scope) != normalize_rule_scope(expected_scope) {
        return Err(format!("entry scope mismatch: expected {expected_scope}"));
    }
    let path = project_path.join(&row.path);
    let _ = tokio::fs::remove_file(path).await;
    db.delete_rule(&id).await.map_err(|e| e.to_string())?;
    append_event(
        &db,
        project_id,
        None,
        None,
        "rules",
        "RuleDeleted",
        json!({"rule_id": id}),
    )
    .await;
    let _ = app.emit("project_refreshed", json!({"reason": "rules_updated"}));
    Ok(())
}

#[tauri::command]
pub async fn delete_rule(
    id: String,
    app: AppHandle,
    state: State<'_, AppState>,
) -> Result<(), String> {
    delete_scope_item(id, "rule", &app, &state).await
}

#[tauri::command]
pub async fn delete_convention(
    id: String,
    app: AppHandle,
    state: State<'_, AppState>,
) -> Result<(), String> {
    delete_scope_item(id, "convention", &app, &state).await
}

#[tauri::command]
pub async fn list_rule_usage(
    input: RuleUsageInput,
    state: State<'_, AppState>,
) -> Result<Vec<RuleUsageView>, String> {
    let (db, project_id) = {
        let current = state.current.lock().await;
        let ctx = current
            .as_ref()
            .ok_or_else(|| "no open project".to_string())?;
        (ctx.db.clone(), ctx.project_id)
    };
    let rows = db
        .list_context_rule_usage(
            &project_id.to_string(),
            &input.rule_id,
            input.limit.unwrap_or(100).max(1),
        )
        .await
        .map_err(|e| e.to_string())?;
    Ok(rows
        .into_iter()
        .map(|row| RuleUsageView {
            run_id: row.run_id,
            included: row.included,
            reason: row.reason,
            created_at: row.created_at,
        })
        .collect())
}

#[tauri::command]
pub async fn capture_knowledge(
    input: KnowledgeCaptureInput,
    app: AppHandle,
    state: State<'_, AppState>,
) -> Result<ArtifactView, String> {
    let (db, project_id, project_path, global_config) = {
        let current = state.current.lock().await;
        let ctx = current
            .as_ref()
            .ok_or_else(|| "no open project".to_string())?;
        (
            ctx.db.clone(),
            ctx.project_id,
            ctx.project_path.clone(),
            ctx.global_config.clone(),
        )
    };
    let kind = input.kind.trim().to_ascii_lowercase();
    if kind != "adr" && kind != "changelog" && kind != "convention-update" {
        return Err("kind must be one of: adr, changelog, convention-update".to_string());
    }
    let artifact_id = Uuid::new_v4().to_string();
    let now = Utc::now();
    let task_folder = input
        .task_id
        .clone()
        .unwrap_or_else(|| "general".to_string());
    let dir = project_path
        .join(".pnevma")
        .join("data")
        .join("artifacts")
        .join(task_folder);
    tokio::fs::create_dir_all(&dir)
        .await
        .map_err(|e| e.to_string())?;
    let filename = format!(
        "{}-{}.md",
        sanitize_file_stem(&kind),
        now.format("%Y%m%d-%H%M%S")
    );
    let file_path = dir.join(filename);
    let title = input
        .title
        .clone()
        .unwrap_or_else(|| format!("{} capture", kind));
    let body = format!(
        "# {title}\n\nkind: {kind}\ncreated_at: {}\n\n{}\n",
        now.to_rfc3339(),
        input.content
    );
    tokio::fs::write(&file_path, body.as_bytes())
        .await
        .map_err(|e| e.to_string())?;
    let rel = file_path
        .strip_prefix(&project_path)
        .unwrap_or(&file_path)
        .to_string_lossy()
        .to_string();
    let row = ArtifactRow {
        id: artifact_id,
        project_id: project_id.to_string(),
        task_id: input.task_id.clone(),
        r#type: kind.clone(),
        path: rel.clone(),
        description: Some(title.clone()),
        created_at: now,
    };
    db.create_artifact(&row).await.map_err(|e| e.to_string())?;
    append_event(
        &db,
        project_id,
        input
            .task_id
            .as_deref()
            .and_then(|raw| Uuid::parse_str(raw).ok()),
        None,
        "knowledge",
        "KnowledgeCaptured",
        json!({"artifact_id": row.id, "type": kind, "path": rel}),
    )
    .await;
    append_telemetry_event(
        &db,
        project_id,
        &global_config,
        "knowledge.capture",
        json!({"artifact_id": row.id, "kind": row.r#type}),
    )
    .await;
    let _ = app.emit(
        "knowledge_captured",
        json!({"artifact_id": row.id, "path": row.path, "type": row.r#type}),
    );
    Ok(ArtifactView {
        id: row.id,
        task_id: row.task_id,
        r#type: row.r#type,
        path: row.path,
        description: row.description,
        created_at: row.created_at,
    })
}

#[tauri::command]
pub async fn list_artifacts(state: State<'_, AppState>) -> Result<Vec<ArtifactView>, String> {
    let (db, project_id) = {
        let current = state.current.lock().await;
        let ctx = current
            .as_ref()
            .ok_or_else(|| "no open project".to_string())?;
        (ctx.db.clone(), ctx.project_id)
    };
    let rows = db
        .list_artifacts(&project_id.to_string())
        .await
        .map_err(|e| e.to_string())?;
    Ok(rows
        .into_iter()
        .map(|row| ArtifactView {
            id: row.id,
            task_id: row.task_id,
            r#type: row.r#type,
            path: row.path,
            description: row.description,
            created_at: row.created_at,
        })
        .collect())
}

fn keybinding_views_from_config(config: &GlobalConfig) -> Vec<KeybindingView> {
    let mut merged = default_keybindings();
    for (action, shortcut) in &config.keybindings {
        let action = action.trim();
        let shortcut = shortcut.trim();
        if !action.is_empty() && !shortcut.is_empty() && is_supported_keybinding_action(action) {
            merged.insert(action.to_string(), shortcut.to_string());
        }
    }
    let mut out = merged
        .into_iter()
        .map(|(action, shortcut)| KeybindingView { action, shortcut })
        .collect::<Vec<_>>();
    out.sort_by(|a, b| a.action.cmp(&b.action));
    out
}

#[tauri::command]
pub async fn get_environment_readiness(
    input: Option<EnvironmentReadinessInput>,
    state: State<'_, AppState>,
) -> Result<EnvironmentReadinessView, String> {
    let current_project_path = {
        let current = state.current.lock().await;
        current.as_ref().map(|ctx| ctx.project_path.clone())
    };
    let requested_path = match input.and_then(|value| value.path) {
        Some(path) => Some(normalize_scaffold_path(&path)?),
        None => current_project_path,
    };
    let git_available = is_git_available();
    let detected_adapters = pnevma_agents::AdapterRegistry::detect().available();
    let global_path = global_config_path();
    let global_config_exists = global_path.exists();
    let project_initialized = requested_path
        .as_deref()
        .map(project_is_initialized)
        .unwrap_or(false);

    let mut missing_steps = Vec::new();
    if !git_available {
        missing_steps.push("install_git".to_string());
    }
    if detected_adapters.is_empty() {
        missing_steps.push("install_agent_cli".to_string());
    }
    if !global_config_exists {
        missing_steps.push("initialize_global_config".to_string());
    }
    if requested_path.is_none() {
        missing_steps.push("select_project_path".to_string());
    } else if !project_initialized {
        missing_steps.push("initialize_project_scaffold".to_string());
    }

    Ok(EnvironmentReadinessView {
        git_available,
        detected_adapters,
        global_config_path: global_path.to_string_lossy().to_string(),
        global_config_exists,
        project_path: requested_path.map(|path| path.to_string_lossy().to_string()),
        project_initialized,
        missing_steps,
    })
}

#[tauri::command]
pub async fn initialize_global_config(
    input: Option<InitializeGlobalConfigInput>,
    state: State<'_, AppState>,
) -> Result<InitGlobalConfigResultView, String> {
    let path = global_config_path();
    let mut created = false;
    if !path.exists() {
        let mut config = GlobalConfig::default();
        if let Some(provider) = input
            .as_ref()
            .and_then(|value| value.default_provider.as_deref())
            .map(str::trim)
            .filter(|value| !value.is_empty())
        {
            config.default_provider = Some(provider.to_string());
        }
        save_global_config(&config).map_err(|e| e.to_string())?;
        created = true;
    }

    if let Ok(latest_config) = load_global_config() {
        let mut current = state.current.lock().await;
        if let Some(ctx) = current.as_mut() {
            ctx.global_config = latest_config;
        }
    }

    Ok(InitGlobalConfigResultView {
        created,
        path: path.to_string_lossy().to_string(),
    })
}

#[tauri::command]
pub async fn initialize_project_scaffold(
    input: InitializeProjectScaffoldInput,
    state: State<'_, AppState>,
) -> Result<InitProjectScaffoldResultView, String> {
    let root = normalize_scaffold_path(&input.path)?;
    let metadata = tokio::fs::metadata(&root)
        .await
        .map_err(|e| format!("project path is not accessible: {e}"))?;
    if !metadata.is_dir() {
        return Err("project path must be a directory".to_string());
    }

    let mut created_paths = Vec::new();
    for rel in [
        ".pnevma",
        ".pnevma/data",
        ".pnevma/rules",
        ".pnevma/conventions",
    ] {
        let path = root.join(rel);
        if !path.exists() {
            tokio::fs::create_dir_all(&path)
                .await
                .map_err(|e| e.to_string())?;
            created_paths.push(path.to_string_lossy().to_string());
        }
    }

    let global = load_global_config().unwrap_or_default();
    let default_provider = normalize_default_provider(
        input
            .default_provider
            .as_deref()
            .or(global.default_provider.as_deref()),
    );

    let config_path = root.join("pnevma.toml");
    if !config_path.exists() {
        let content = build_default_project_toml(
            &root,
            input.project_name.as_deref(),
            input.project_brief.as_deref(),
            &default_provider,
        );
        tokio::fs::write(&config_path, content.as_bytes())
            .await
            .map_err(|e| e.to_string())?;
        created_paths.push(config_path.to_string_lossy().to_string());
    }

    let rule_seed = root.join(".pnevma/rules/project-rules.md");
    if !rule_seed.exists() {
        let content = "\
# Project Rules

- Keep work scoped to the active task contract.
- Prefer deterministic checks before requesting review.
";
        tokio::fs::write(&rule_seed, content.as_bytes())
            .await
            .map_err(|e| e.to_string())?;
        created_paths.push(rule_seed.to_string_lossy().to_string());
    }

    let convention_seed = root.join(".pnevma/conventions/conventions.md");
    if !convention_seed.exists() {
        let content = "\
# Conventions

- Write concise commit messages in imperative mood.
- Capture reusable decisions in ADR knowledge artifacts.
";
        tokio::fs::write(&convention_seed, content.as_bytes())
            .await
            .map_err(|e| e.to_string())?;
        created_paths.push(convention_seed.to_string_lossy().to_string());
    }

    {
        let mut current = state.current.lock().await;
        if let Some(ctx) = current.as_mut() {
            if ctx.project_path == root {
                if let Ok(cfg) = load_project_config(&config_path) {
                    ctx.config = cfg;
                }
            }
        }
    }

    Ok(InitProjectScaffoldResultView {
        root_path: root.to_string_lossy().to_string(),
        already_initialized: created_paths.is_empty(),
        created_paths,
    })
}

#[tauri::command]
pub async fn list_keybindings(state: State<'_, AppState>) -> Result<Vec<KeybindingView>, String> {
    let current = state.current.lock().await;
    let ctx = current
        .as_ref()
        .ok_or_else(|| "no open project".to_string())?;
    Ok(keybinding_views_from_config(&ctx.global_config))
}

#[tauri::command]
pub async fn set_keybinding(
    input: SetKeybindingInput,
    state: State<'_, AppState>,
) -> Result<Vec<KeybindingView>, String> {
    let mut current = state.current.lock().await;
    let ctx = current
        .as_mut()
        .ok_or_else(|| "no open project".to_string())?;
    if input.action.trim().is_empty() || input.shortcut.trim().is_empty() {
        return Err("action and shortcut are required".to_string());
    }
    if !is_supported_keybinding_action(input.action.trim()) {
        return Err(format!(
            "unsupported keybinding action: {}",
            input.action.trim()
        ));
    }
    ctx.global_config.keybindings.insert(
        input.action.trim().to_string(),
        input.shortcut.trim().to_string(),
    );
    save_global_config(&ctx.global_config).map_err(|e| e.to_string())?;
    Ok(keybinding_views_from_config(&ctx.global_config))
}

#[tauri::command]
pub async fn reset_keybindings(state: State<'_, AppState>) -> Result<Vec<KeybindingView>, String> {
    let mut current = state.current.lock().await;
    let ctx = current
        .as_mut()
        .ok_or_else(|| "no open project".to_string())?;
    ctx.global_config.keybindings.clear();
    save_global_config(&ctx.global_config).map_err(|e| e.to_string())?;
    Ok(keybinding_views_from_config(&ctx.global_config))
}

#[tauri::command]
pub async fn get_onboarding_state(
    state: State<'_, AppState>,
) -> Result<OnboardingStateView, String> {
    let (db, project_id) = {
        let current = state.current.lock().await;
        let ctx = current
            .as_ref()
            .ok_or_else(|| "no open project".to_string())?;
        (ctx.db.clone(), ctx.project_id)
    };
    let row = db
        .get_onboarding_state(&project_id.to_string())
        .await
        .map_err(|e| e.to_string())?
        .unwrap_or(OnboardingStateRow {
            project_id: project_id.to_string(),
            step: "open_project".to_string(),
            completed: false,
            dismissed: false,
            updated_at: Utc::now(),
        });
    Ok(OnboardingStateView {
        step: row.step,
        completed: row.completed,
        dismissed: row.dismissed,
        updated_at: row.updated_at,
    })
}

#[tauri::command]
pub async fn advance_onboarding_step(
    input: AdvanceOnboardingInput,
    state: State<'_, AppState>,
) -> Result<OnboardingStateView, String> {
    let (db, project_id, global_config) = {
        let current = state.current.lock().await;
        let ctx = current
            .as_ref()
            .ok_or_else(|| "no open project".to_string())?;
        (ctx.db.clone(), ctx.project_id, ctx.global_config.clone())
    };
    let row = OnboardingStateRow {
        project_id: project_id.to_string(),
        step: input.step,
        completed: input.completed.unwrap_or(false),
        dismissed: input.dismissed.unwrap_or(false),
        updated_at: Utc::now(),
    };
    db.upsert_onboarding_state(&row)
        .await
        .map_err(|e| e.to_string())?;
    append_event(
        &db,
        project_id,
        None,
        None,
        "onboarding",
        "OnboardingStepAdvanced",
        json!({
            "step": row.step,
            "completed": row.completed,
            "dismissed": row.dismissed
        }),
    )
    .await;
    append_telemetry_event(
        &db,
        project_id,
        &global_config,
        "onboarding.advance",
        json!({
            "step": row.step,
            "completed": row.completed,
            "dismissed": row.dismissed
        }),
    )
    .await;
    Ok(OnboardingStateView {
        step: row.step,
        completed: row.completed,
        dismissed: row.dismissed,
        updated_at: row.updated_at,
    })
}

#[tauri::command]
pub async fn reset_onboarding(state: State<'_, AppState>) -> Result<OnboardingStateView, String> {
    let (db, project_id, global_config) = {
        let current = state.current.lock().await;
        let ctx = current
            .as_ref()
            .ok_or_else(|| "no open project".to_string())?;
        (ctx.db.clone(), ctx.project_id, ctx.global_config.clone())
    };
    let row = OnboardingStateRow {
        project_id: project_id.to_string(),
        step: "open_project".to_string(),
        completed: false,
        dismissed: false,
        updated_at: Utc::now(),
    };
    db.upsert_onboarding_state(&row)
        .await
        .map_err(|e| e.to_string())?;
    append_event(
        &db,
        project_id,
        None,
        None,
        "onboarding",
        "OnboardingReset",
        json!({}),
    )
    .await;
    append_telemetry_event(
        &db,
        project_id,
        &global_config,
        "onboarding.reset",
        json!({}),
    )
    .await;
    Ok(OnboardingStateView {
        step: row.step,
        completed: row.completed,
        dismissed: row.dismissed,
        updated_at: row.updated_at,
    })
}

#[tauri::command]
pub async fn get_telemetry_status(
    state: State<'_, AppState>,
) -> Result<TelemetryStatusView, String> {
    let (db, project_id, global_config) = {
        let current = state.current.lock().await;
        let ctx = current
            .as_ref()
            .ok_or_else(|| "no open project".to_string())?;
        (ctx.db.clone(), ctx.project_id, ctx.global_config.clone())
    };
    let queued_events = db
        .count_telemetry_events(&project_id.to_string())
        .await
        .map_err(|e| e.to_string())?;
    Ok(TelemetryStatusView {
        opted_in: global_config.telemetry_opt_in,
        queued_events,
    })
}

#[tauri::command]
pub async fn set_telemetry_opt_in(
    input: SetTelemetryInput,
    state: State<'_, AppState>,
) -> Result<TelemetryStatusView, String> {
    let (db, project_id, global_config) = {
        let mut current = state.current.lock().await;
        let ctx = current
            .as_mut()
            .ok_or_else(|| "no open project".to_string())?;
        ctx.global_config.telemetry_opt_in = input.opted_in;
        save_global_config(&ctx.global_config).map_err(|e| e.to_string())?;
        (ctx.db.clone(), ctx.project_id, ctx.global_config.clone())
    };
    let queued_events = db
        .count_telemetry_events(&project_id.to_string())
        .await
        .map_err(|e| e.to_string())?;
    Ok(TelemetryStatusView {
        opted_in: global_config.telemetry_opt_in,
        queued_events,
    })
}

#[tauri::command]
pub async fn export_telemetry_bundle(
    input: Option<ExportTelemetryInput>,
    state: State<'_, AppState>,
) -> Result<String, String> {
    let (db, project_id, project_path, opted_in) = {
        let current = state.current.lock().await;
        let ctx = current
            .as_ref()
            .ok_or_else(|| "no open project".to_string())?;
        (
            ctx.db.clone(),
            ctx.project_id,
            ctx.project_path.clone(),
            ctx.global_config.telemetry_opt_in,
        )
    };
    if !opted_in {
        return Err("telemetry is disabled; opt in first".to_string());
    }
    let limit = input
        .as_ref()
        .and_then(|v| v.limit)
        .unwrap_or(10_000)
        .max(1);
    let rows = db
        .list_telemetry_events(&project_id.to_string(), limit)
        .await
        .map_err(|e| e.to_string())?;
    let payload = rows
        .into_iter()
        .map(|row| {
            json!({
                "id": row.id,
                "event_type": row.event_type,
                "payload": serde_json::from_str::<serde_json::Value>(&row.payload_json).unwrap_or_else(|_| json!({})),
                "created_at": row.created_at,
            })
        })
        .collect::<Vec<_>>();

    let data_dir = project_path.join(".pnevma").join("data");
    let target = if let Some(path) = input.and_then(|v| v.path) {
        let requested = PathBuf::from(&path);
        let canonical_data = data_dir.canonicalize().unwrap_or_else(|_| data_dir.clone());
        let canonical_target = if requested.exists() {
            requested.canonicalize().map_err(|e| e.to_string())?
        } else if let Some(parent) = requested.parent() {
            let canon_parent = parent.canonicalize().map_err(|e| e.to_string())?;
            canon_parent.join(requested.file_name().unwrap_or_default())
        } else {
            return Err("invalid export path".to_string());
        };
        if !canonical_target.starts_with(&canonical_data) {
            return Err("export path must be within .pnevma/data/".to_string());
        }
        canonical_target
    } else {
        data_dir.join("telemetry").join(format!(
            "telemetry-export-{}.json",
            Utc::now().format("%Y%m%d-%H%M%S")
        ))
    };
    if let Some(parent) = target.parent() {
        tokio::fs::create_dir_all(parent)
            .await
            .map_err(|e| e.to_string())?;
    }
    tokio::fs::write(
        &target,
        serde_json::to_string_pretty(&payload).map_err(|e| e.to_string())?,
    )
    .await
    .map_err(|e| e.to_string())?;
    Ok(target.to_string_lossy().to_string())
}

#[tauri::command]
pub async fn clear_telemetry(state: State<'_, AppState>) -> Result<(), String> {
    let (db, project_id) = {
        let current = state.current.lock().await;
        let ctx = current
            .as_ref()
            .ok_or_else(|| "no open project".to_string())?;
        (ctx.db.clone(), ctx.project_id)
    };
    db.clear_telemetry_events(&project_id.to_string())
        .await
        .map_err(|e| e.to_string())
}

#[tauri::command]
pub async fn submit_feedback(
    input: FeedbackInput,
    state: State<'_, AppState>,
) -> Result<FeedbackView, String> {
    let (db, project_id, project_path, global_config) = {
        let current = state.current.lock().await;
        let ctx = current
            .as_ref()
            .ok_or_else(|| "no open project".to_string())?;
        (
            ctx.db.clone(),
            ctx.project_id,
            ctx.project_path.clone(),
            ctx.global_config.clone(),
        )
    };
    if input.category.trim().is_empty() || input.body.trim().is_empty() {
        return Err("category and body are required".to_string());
    }
    let now = Utc::now();
    let id = Uuid::new_v4().to_string();
    let dir = project_path.join(".pnevma").join("data").join("feedback");
    tokio::fs::create_dir_all(&dir)
        .await
        .map_err(|e| e.to_string())?;
    let artifact_path = dir.join(format!(
        "{}-{}.md",
        sanitize_file_stem(&input.category),
        now.format("%Y%m%d-%H%M%S")
    ));
    let artifact_content = format!(
        "# Feedback\n\ncategory: {}\ncreated_at: {}\ncontact: {}\n\n{}\n",
        input.category.trim(),
        now.to_rfc3339(),
        input.contact.clone().unwrap_or_default(),
        input.body.trim()
    );
    tokio::fs::write(&artifact_path, artifact_content)
        .await
        .map_err(|e| e.to_string())?;
    let rel = artifact_path
        .strip_prefix(&project_path)
        .unwrap_or(&artifact_path)
        .to_string_lossy()
        .to_string();
    let row = FeedbackRow {
        id: id.clone(),
        project_id: project_id.to_string(),
        category: input.category.trim().to_string(),
        body: input.body.trim().to_string(),
        contact: input.contact.clone(),
        artifact_path: Some(rel.clone()),
        created_at: now,
    };
    db.create_feedback(&row).await.map_err(|e| e.to_string())?;
    append_event(
        &db,
        project_id,
        None,
        None,
        "feedback",
        "FeedbackSubmitted",
        json!({"feedback_id": row.id, "category": row.category}),
    )
    .await;
    append_telemetry_event(
        &db,
        project_id,
        &global_config,
        "feedback.submit",
        json!({"category": row.category}),
    )
    .await;
    Ok(FeedbackView {
        id,
        category: row.category,
        body: row.body,
        contact: row.contact,
        artifact_path: row.artifact_path,
        created_at: row.created_at,
    })
}

#[tauri::command]
pub async fn partner_metrics_report(
    input: Option<PartnerMetricsInput>,
    state: State<'_, AppState>,
) -> Result<PartnerMetricsReportView, String> {
    let (db, project_id, onboarding_completed) = {
        let current = state.current.lock().await;
        let ctx = current
            .as_ref()
            .ok_or_else(|| "no open project".to_string())?;
        let db = ctx.db.clone();
        let onboarding_completed = db
            .get_onboarding_state(&ctx.project_id.to_string())
            .await
            .ok()
            .flatten()
            .map(|row| row.completed)
            .unwrap_or(false);
        (db, ctx.project_id, onboarding_completed)
    };
    let window_days = input.and_then(|v| v.days).unwrap_or(14).max(1);
    let from = Utc::now() - chrono::Duration::days(window_days);
    let events = db
        .query_events(EventQueryFilter {
            project_id: project_id.to_string(),
            from: Some(from),
            ..EventQueryFilter::default()
        })
        .await
        .map_err(|e| e.to_string())?;
    let sessions_started = events
        .iter()
        .filter(|e| e.event_type == "SessionSpawned")
        .count() as i64;
    let merges_completed = events
        .iter()
        .filter(|e| e.event_type == "MergeCompleted")
        .count() as i64;
    let knowledge_captures = events
        .iter()
        .filter(|e| e.event_type == "KnowledgeCaptured")
        .count() as i64;
    let tasks = db
        .list_tasks(&project_id.to_string())
        .await
        .map_err(|e| e.to_string())?;
    let tasks_created = tasks.iter().filter(|t| t.created_at >= from).count() as i64;
    let tasks_done = tasks
        .iter()
        .filter(|t| t.status == "Done" && t.updated_at >= from)
        .count() as i64;
    let feedback_rows = db
        .list_feedback(&project_id.to_string(), 10_000)
        .await
        .map_err(|e| e.to_string())?;
    let feedback_count = feedback_rows
        .iter()
        .filter(|f| f.created_at >= from)
        .count() as i64;
    let feedback_with_contact = feedback_rows
        .iter()
        .filter(|f| f.created_at >= from)
        .filter(|f| {
            f.contact
                .as_deref()
                .map(|v| !v.trim().is_empty())
                .unwrap_or(false)
        })
        .count() as i64;
    let cycle_hours = tasks
        .iter()
        .filter(|t| t.status == "Done" && t.updated_at >= from)
        .map(|t| (t.updated_at - t.created_at).num_seconds() as f64 / 3600.0)
        .collect::<Vec<_>>();
    let avg_task_cycle_hours = if cycle_hours.is_empty() {
        None
    } else {
        Some(cycle_hours.iter().sum::<f64>() / cycle_hours.len() as f64)
    };
    let telemetry_events = db
        .count_telemetry_events(&project_id.to_string())
        .await
        .unwrap_or(0);
    Ok(PartnerMetricsReportView {
        generated_at: Utc::now(),
        window_days,
        sessions_started,
        tasks_created,
        tasks_done,
        merges_completed,
        knowledge_captures,
        feedback_count,
        feedback_with_contact,
        telemetry_events,
        onboarding_completed,
        avg_task_cycle_hours,
    })
}

fn timeline_view_from_event(row: EventRow) -> TimelineEventView {
    let payload =
        serde_json::from_str::<serde_json::Value>(&row.payload_json).unwrap_or_else(|_| {
            json!({
                "raw": row.payload_json
            })
        });
    let summary = payload
        .get("summary")
        .and_then(|v| v.as_str())
        .or_else(|| payload.get("message").and_then(|v| v.as_str()))
        .or_else(|| payload.get("chunk").and_then(|v| v.as_str()))
        .map(|v| v.chars().take(160).collect::<String>())
        .unwrap_or_else(|| row.event_type.clone());
    TimelineEventView {
        timestamp: row.timestamp,
        kind: row.event_type,
        summary,
        payload,
    }
}

#[tauri::command]
pub async fn get_session_timeline(
    input: SessionTimelineInput,
    state: State<'_, AppState>,
) -> Result<Vec<TimelineEventView>, String> {
    let (db, project_id, sessions) = {
        let current = state.current.lock().await;
        let ctx = current
            .as_ref()
            .ok_or_else(|| "no open project".to_string())?;
        (ctx.db.clone(), ctx.project_id, ctx.sessions.clone())
    };
    let session_uuid = Uuid::parse_str(&input.session_id).map_err(|e| e.to_string())?;
    let events = db
        .query_events(EventQueryFilter {
            project_id: project_id.to_string(),
            task_id: None,
            session_id: Some(input.session_id.clone()),
            event_type: None,
            from: None,
            to: None,
            limit: input.limit.or(Some(500)),
        })
        .await
        .map_err(|e| e.to_string())?;
    let mut timeline = events
        .into_iter()
        .map(timeline_view_from_event)
        .collect::<Vec<_>>();

    if let Ok(slice) = sessions.read_scrollback(session_uuid, 0, 128 * 1024).await {
        if !slice.data.trim().is_empty() {
            timeline.push(TimelineEventView {
                timestamp: Utc::now(),
                kind: "ScrollbackSnapshot".to_string(),
                summary: "latest scrollback snapshot".to_string(),
                payload: json!({
                    "session_id": input.session_id,
                    "start_offset": slice.start_offset,
                    "end_offset": slice.end_offset,
                    "total_bytes": slice.total_bytes,
                    "data": slice.data
                }),
            });
        }
    }

    Ok(timeline)
}

#[tauri::command]
pub async fn get_session_recovery_options(
    session_id: String,
    state: State<'_, AppState>,
) -> Result<Vec<RecoveryOptionView>, String> {
    let current = state.current.lock().await;
    let ctx = current
        .as_ref()
        .ok_or_else(|| "no open project".to_string())?;
    let session_uuid = Uuid::parse_str(&session_id).map_err(|e| e.to_string())?;
    let Some(meta) = ctx.sessions.get(session_uuid).await else {
        return Err(format!("session not found: {session_id}"));
    };
    let can_interrupt = matches!(meta.status, SessionStatus::Running | SessionStatus::Waiting);
    let can_restart = true;
    let can_reattach = meta.status == SessionStatus::Waiting;
    Ok(vec![
        RecoveryOptionView {
            id: "interrupt".to_string(),
            label: "Interrupt".to_string(),
            description: "Send Ctrl+C to the session process.".to_string(),
            enabled: can_interrupt,
        },
        RecoveryOptionView {
            id: "restart".to_string(),
            label: "Restart Session".to_string(),
            description: "Restart backend process and rebind panes.".to_string(),
            enabled: can_restart,
        },
        RecoveryOptionView {
            id: "reattach".to_string(),
            label: "Reattach Backend".to_string(),
            description: "Attach to an existing waiting backend.".to_string(),
            enabled: can_reattach,
        },
    ])
}

#[tauri::command]
pub async fn recover_session(
    input: SessionRecoveryInput,
    app: AppHandle,
    state: State<'_, AppState>,
) -> Result<serde_json::Value, String> {
    let (project_id, db, sessions, project_path) = {
        let current = state.current.lock().await;
        let ctx = current
            .as_ref()
            .ok_or_else(|| "no open project".to_string())?;
        (
            ctx.project_id,
            ctx.db.clone(),
            ctx.sessions.clone(),
            ctx.project_path.clone(),
        )
    };
    let action = input.action.trim().to_ascii_lowercase();
    let session_uuid = Uuid::parse_str(&input.session_id).map_err(|e| e.to_string())?;
    match action.as_str() {
        "interrupt" => {
            sessions
                .send_input(session_uuid, "\u{3}")
                .await
                .map_err(|e| e.to_string())?;
            append_event(
                &db,
                project_id,
                None,
                Some(session_uuid),
                "session",
                "SessionRecoveryAction",
                json!({"action": "interrupt"}),
            )
            .await;
            Ok(json!({"ok": true, "action": "interrupt"}))
        }
        "restart" => {
            let new_id = restart_session(input.session_id.clone(), state).await?;
            append_event(
                &db,
                project_id,
                None,
                Some(session_uuid),
                "session",
                "SessionRecoveryAction",
                json!({"action": "restart", "new_session_id": new_id}),
            )
            .await;
            Ok(json!({"ok": true, "action": "restart", "new_session_id": new_id}))
        }
        "reattach" => {
            sessions
                .attach_existing(session_uuid)
                .await
                .map_err(|e| e.to_string())?;
            append_event(
                &db,
                project_id,
                None,
                Some(session_uuid),
                "session",
                "SessionRecoveryAction",
                json!({"action": "reattach"}),
            )
            .await;
            Ok(json!({"ok": true, "action": "reattach"}))
        }
        "checkpoint_restore" => {
            let checkpoints = db
                .list_checkpoints(&project_id.to_string())
                .await
                .map_err(|e| e.to_string())?;
            let Some(last) = checkpoints.last() else {
                return Err("no checkpoints available".to_string());
            };
            let _ = git_output(&project_path, &["reset", "--hard", &last.git_ref]).await?;
            append_event(
                &db,
                project_id,
                None,
                Some(session_uuid),
                "session",
                "SessionRecoveryAction",
                json!({"action": "checkpoint_restore", "checkpoint_id": last.id, "git_ref": last.git_ref}),
            )
            .await;
            let _ = app.emit("project_refreshed", json!({"reason": "checkpoint_restore"}));
            Ok(
                json!({"ok": true, "action": "checkpoint_restore", "checkpoint_id": last.id, "git_ref": last.git_ref}),
            )
        }
        _ => Err(
            "unsupported action; expected interrupt|restart|reattach|checkpoint_restore"
                .to_string(),
        ),
    }
}

#[tauri::command]
pub async fn project_status(state: State<'_, AppState>) -> Result<ProjectStatusView, String> {
    let current = state.current.lock().await;
    let ctx = current
        .as_ref()
        .ok_or_else(|| "no open project".to_string())?;
    let sessions = ctx
        .db
        .list_sessions(&ctx.project_id.to_string())
        .await
        .map_err(|e| e.to_string())?;
    let tasks = ctx
        .db
        .list_tasks(&ctx.project_id.to_string())
        .await
        .map_err(|e| e.to_string())?;
    let worktrees = ctx
        .db
        .list_worktrees(&ctx.project_id.to_string())
        .await
        .map_err(|e| e.to_string())?;
    Ok(ProjectStatusView {
        project_id: ctx.project_id.to_string(),
        project_name: ctx.config.project.name.clone(),
        project_path: ctx.project_path.to_string_lossy().to_string(),
        sessions: sessions.len(),
        tasks: tasks.len(),
        worktrees: worktrees.len(),
    })
}

#[tauri::command]
pub async fn get_daily_brief(state: State<'_, AppState>) -> Result<DailyBriefView, String> {
    let (db, project_id) = {
        let current = state.current.lock().await;
        let ctx = current
            .as_ref()
            .ok_or_else(|| "no open project".to_string())?;
        (ctx.db.clone(), ctx.project_id)
    };
    let tasks = db
        .list_tasks(&project_id.to_string())
        .await
        .map_err(|e| e.to_string())?;
    let recent = db
        .list_recent_events(&project_id.to_string(), 20)
        .await
        .map_err(|e| e.to_string())?;
    let ready_tasks = tasks.iter().filter(|task| task.status == "Ready").count();
    let review_tasks = tasks.iter().filter(|task| task.status == "Review").count();
    let blocked_tasks = tasks.iter().filter(|task| task.status == "Blocked").count();
    let failed_tasks = tasks.iter().filter(|task| task.status == "Failed").count();
    let mut actions = Vec::new();
    if review_tasks > 0 {
        actions.push(format!(
            "{review_tasks} task(s) waiting for review decisions"
        ));
    }
    if ready_tasks > 0 {
        actions.push(format!("{ready_tasks} task(s) ready for dispatch"));
    }
    if blocked_tasks > 0 {
        actions.push(format!("{blocked_tasks} task(s) blocked by dependencies"));
    }
    if failed_tasks > 0 {
        actions.push(format!(
            "{failed_tasks} task(s) failed and need handoff/recovery"
        ));
    }
    if actions.is_empty() {
        actions.push("No urgent actions. Continue highest-priority in-progress work.".to_string());
    }

    let recent_events = recent
        .into_iter()
        .map(timeline_view_from_event)
        .collect::<Vec<_>>();
    let brief = DailyBriefView {
        generated_at: Utc::now(),
        total_tasks: tasks.len(),
        ready_tasks,
        review_tasks,
        blocked_tasks,
        failed_tasks,
        total_cost_usd: db
            .project_cost_total(&project_id.to_string())
            .await
            .unwrap_or(0.0),
        recent_events,
        recommended_actions: actions,
    };
    append_event(
        &db,
        project_id,
        None,
        None,
        "system",
        "DailyBriefGenerated",
        json!({
            "total_tasks": brief.total_tasks,
            "ready_tasks": brief.ready_tasks,
            "review_tasks": brief.review_tasks,
            "blocked_tasks": brief.blocked_tasks,
            "failed_tasks": brief.failed_tasks
        }),
    )
    .await;
    Ok(brief)
}

fn infer_scope_paths(input: &str) -> Vec<String> {
    let mut paths = Vec::new();
    for token in input.split_whitespace() {
        let trimmed = token.trim_matches(|c: char| {
            matches!(
                c,
                ',' | '.' | ':' | ';' | '"' | '\'' | '(' | ')' | '[' | ']' | '{' | '}'
            )
        });
        let looks_like_path = trimmed.contains('/')
            || trimmed.ends_with(".rs")
            || trimmed.ends_with(".ts")
            || trimmed.ends_with(".tsx")
            || trimmed.ends_with(".js")
            || trimmed.ends_with(".json")
            || trimmed.ends_with(".toml")
            || trimmed.ends_with(".md");
        if looks_like_path && !trimmed.is_empty() && !paths.iter().any(|p| p == trimmed) {
            paths.push(trimmed.to_string());
        }
    }
    paths
}

fn normalize_priority(input: Option<&str>) -> String {
    match input.unwrap_or("P1").trim().to_ascii_uppercase().as_str() {
        "P0" => "P0".to_string(),
        "P1" => "P1".to_string(),
        "P2" => "P2".to_string(),
        _ => "P3".to_string(),
    }
}

fn fallback_draft(text: &str, warning: Option<String>) -> DraftTaskView {
    let title = text
        .split(['.', '\n'])
        .next()
        .map(str::trim)
        .filter(|line| !line.is_empty())
        .map(|line| {
            if line.chars().count() > 72 {
                line.chars().take(72).collect::<String>()
            } else {
                line.to_string()
            }
        })
        .unwrap_or_else(|| "Draft Task".to_string());
    let mut warnings = Vec::new();
    if let Some(message) = warning {
        warnings.push(message);
    }
    DraftTaskView {
        title,
        goal: text.to_string(),
        scope: infer_scope_paths(text),
        acceptance_criteria: vec![
            "Relevant tests pass".to_string(),
            "Manual review confirms expected behavior".to_string(),
        ],
        constraints: vec!["Keep changes scoped to requested behavior".to_string()],
        dependencies: Vec::new(),
        priority: "P1".to_string(),
        source: "fallback".to_string(),
        warnings,
    }
}

fn extract_first_json_object(raw: &str) -> Option<serde_json::Value> {
    let starts = raw
        .match_indices('{')
        .map(|(idx, _)| idx)
        .collect::<Vec<_>>();
    for start in starts {
        let mut ends = raw[start..]
            .match_indices('}')
            .map(|(idx, _)| start + idx + 1)
            .collect::<Vec<_>>();
        ends.reverse();
        for end in ends {
            if let Ok(parsed) = serde_json::from_str::<serde_json::Value>(&raw[start..end]) {
                if parsed.is_object() {
                    return Some(parsed);
                }
            }
        }
    }
    None
}

fn strings_from_array(value: Option<&serde_json::Value>) -> Vec<String> {
    value
        .and_then(|item| item.as_array())
        .map(|items| {
            items
                .iter()
                .filter_map(|item| item.as_str())
                .map(ToString::to_string)
                .filter(|item| !item.trim().is_empty())
                .collect::<Vec<_>>()
        })
        .unwrap_or_default()
}

fn parse_provider_draft(
    value: serde_json::Value,
    user_text: &str,
) -> Result<DraftTaskView, String> {
    let obj = value
        .as_object()
        .ok_or_else(|| "provider draft response must be a JSON object".to_string())?;
    let title = obj
        .get("title")
        .and_then(|v| v.as_str())
        .map(str::trim)
        .filter(|v| !v.is_empty())
        .ok_or_else(|| "provider draft missing title".to_string())?
        .to_string();
    let goal = obj
        .get("goal")
        .and_then(|v| v.as_str())
        .map(str::trim)
        .filter(|v| !v.is_empty())
        .map(ToString::to_string)
        .unwrap_or_else(|| user_text.to_string());
    let mut acceptance = strings_from_array(obj.get("acceptance_criteria"));
    if acceptance.is_empty() {
        acceptance.push("Relevant tests pass".to_string());
    }

    Ok(DraftTaskView {
        title,
        goal,
        scope: strings_from_array(obj.get("scope")),
        acceptance_criteria: acceptance,
        constraints: strings_from_array(obj.get("constraints")),
        dependencies: strings_from_array(obj.get("dependencies")),
        priority: normalize_priority(obj.get("priority").and_then(|v| v.as_str())),
        source: "provider".to_string(),
        warnings: Vec::new(),
    })
}

#[allow(clippy::too_many_arguments)]
async fn try_provider_task_draft(
    adapter: Arc<dyn pnevma_agents::AgentAdapter>,
    provider: &str,
    model: Option<String>,
    timeout_minutes: u64,
    env: Vec<(String, String)>,
    project_path: &Path,
    text: &str,
) -> Result<DraftTaskView, String> {
    let handle = adapter
        .spawn(AgentConfig {
            provider: provider.to_string(),
            model,
            env,
            working_dir: project_path.to_string_lossy().to_string(),
            timeout_minutes,
            auto_approve: false,
            output_format: "stream-json".to_string(),
            context_file: None,
        })
        .await
        .map_err(|e| e.to_string())?;
    let mut rx = adapter.events(&handle);
    let objective = format!(
        "Draft a software task contract from this request.\n\
Return JSON only (no markdown, no prose) with keys:\n\
title, goal, scope[], acceptance_criteria[], constraints[], dependencies[], priority.\n\
Priority must be one of P0/P1/P2/P3.\n\
User request:\n{}",
        text
    );
    adapter
        .send(
            &handle,
            TaskPayload {
                task_id: Uuid::new_v4(),
                objective,
                constraints: vec!["Return strict JSON object only".to_string()],
                project_rules: Vec::new(),
                worktree_path: project_path.to_string_lossy().to_string(),
                branch_name: "draft-only".to_string(),
                acceptance_checks: Vec::new(),
                relevant_file_paths: Vec::new(),
                prior_context_summary: None,
            },
        )
        .await
        .map_err(|e| e.to_string())?;

    let mut combined_output = String::new();
    let timeout_window = Duration::from_secs((timeout_minutes.max(1) * 60).min(45));
    loop {
        let event = timeout(timeout_window, rx.recv())
            .await
            .map_err(|_| "provider draft timed out".to_string())?
            .map_err(|e| e.to_string())?;
        match event {
            AgentEvent::OutputChunk(chunk) => {
                combined_output.push_str(&chunk);
                if combined_output.len() > 128_000 {
                    let keep_from = combined_output.len().saturating_sub(96_000);
                    combined_output = combined_output[keep_from..].to_string();
                }
            }
            AgentEvent::Complete { summary } => {
                combined_output.push('\n');
                combined_output.push_str(&summary);
                break;
            }
            AgentEvent::Error(err) => {
                return Err(format!("provider draft failed: {err}"));
            }
            AgentEvent::ToolUse { .. }
            | AgentEvent::StatusChange(_)
            | AgentEvent::UsageUpdate { .. } => {}
        }
    }

    let parsed = extract_first_json_object(&combined_output)
        .ok_or_else(|| "provider output did not contain parseable JSON object".to_string())?;
    parse_provider_draft(parsed, text)
}

#[tauri::command]
pub async fn draft_task_contract(
    input: DraftTaskInput,
    state: State<'_, AppState>,
) -> Result<DraftTaskView, String> {
    let (db, project_id, adapters, config, global_config, project_path) = {
        let current = state.current.lock().await;
        let ctx = current
            .as_ref()
            .ok_or_else(|| "no open project".to_string())?;
        (
            ctx.db.clone(),
            ctx.project_id,
            ctx.adapters.clone(),
            ctx.config.clone(),
            ctx.global_config.clone(),
            ctx.project_path.clone(),
        )
    };
    let text = input.text.trim();
    if text.is_empty() {
        return Err("draft input text is required".to_string());
    }
    let preferred_provider = global_config
        .default_provider
        .clone()
        .unwrap_or_else(|| config.agents.default_provider.clone());
    let provider = if adapters.get(&preferred_provider).is_some() {
        preferred_provider
    } else if adapters.get("claude-code").is_some() {
        "claude-code".to_string()
    } else {
        "codex".to_string()
    };
    let model = match provider.as_str() {
        "codex" => config
            .agents
            .codex
            .as_ref()
            .and_then(|cfg| cfg.model.clone()),
        _ => config
            .agents
            .claude_code
            .as_ref()
            .and_then(|cfg| cfg.model.clone()),
    };
    let timeout_minutes = match provider.as_str() {
        "codex" => config
            .agents
            .codex
            .as_ref()
            .map(|cfg| cfg.timeout_minutes)
            .unwrap_or(20),
        _ => config
            .agents
            .claude_code
            .as_ref()
            .map(|cfg| cfg.timeout_minutes)
            .unwrap_or(30),
    };
    let (secret_env, _) = resolve_secret_env(&db, project_id)
        .await
        .unwrap_or_else(|_| (Vec::new(), Vec::new()));

    let draft = if let Some(adapter) = adapters.get(&provider) {
        match try_provider_task_draft(
            adapter,
            &provider,
            model,
            timeout_minutes,
            secret_env,
            project_path.as_path(),
            text,
        )
        .await
        {
            Ok(provider_draft) => provider_draft,
            Err(err) => fallback_draft(text, Some(err)),
        }
    } else {
        fallback_draft(
            text,
            Some(format!(
                "provider '{}' unavailable; used deterministic fallback",
                provider
            )),
        )
    };
    append_event(
        &db,
        project_id,
        None,
        None,
        "core",
        "TaskDraftGenerated",
        json!({
            "title": draft.title,
            "scope_items": draft.scope.len(),
            "source": draft.source,
            "warnings": draft.warnings
        }),
    )
    .await;
    Ok(draft)
}

#[tauri::command]
pub async fn create_notification(
    input: NotificationInput,
    app: AppHandle,
    state: State<'_, AppState>,
) -> Result<NotificationView, String> {
    let (db, project_id) = {
        let current = state.current.lock().await;
        let ctx = current
            .as_ref()
            .ok_or_else(|| "no open project".to_string())?;
        (ctx.db.clone(), ctx.project_id)
    };
    let (_, secret_values) = resolve_secret_env(&db, project_id)
        .await
        .unwrap_or_else(|_| (Vec::new(), Vec::new()));
    create_notification_row(
        &db,
        &app,
        project_id,
        input
            .task_id
            .as_deref()
            .and_then(|v| Uuid::parse_str(v).ok()),
        input
            .session_id
            .as_deref()
            .and_then(|v| Uuid::parse_str(v).ok()),
        &input.title,
        &input.body,
        input.level.as_deref(),
        "manual",
        &secret_values,
    )
    .await
}

#[tauri::command]
pub async fn list_notifications(
    input: Option<NotificationListInput>,
    state: State<'_, AppState>,
) -> Result<Vec<NotificationView>, String> {
    let (db, project_id) = {
        let current = state.current.lock().await;
        let ctx = current
            .as_ref()
            .ok_or_else(|| "no open project".to_string())?;
        (ctx.db.clone(), ctx.project_id)
    };
    let unread_only = input.map(|v| v.unread_only).unwrap_or(false);
    let rows = db
        .list_notifications(&project_id.to_string(), unread_only)
        .await
        .map_err(|e| e.to_string())?;
    Ok(rows
        .into_iter()
        .map(|row| NotificationView {
            id: row.id,
            task_id: row.task_id,
            session_id: row.session_id,
            title: row.title,
            body: row.body,
            level: row.level,
            unread: row.unread,
            created_at: row.created_at,
        })
        .collect())
}

#[tauri::command]
pub async fn mark_notification_read(
    notification_id: String,
    app: AppHandle,
    state: State<'_, AppState>,
) -> Result<(), String> {
    let (db, project_id) = {
        let current = state.current.lock().await;
        let ctx = current
            .as_ref()
            .ok_or_else(|| "no open project".to_string())?;
        (ctx.db.clone(), ctx.project_id)
    };
    db.mark_notification_read(&notification_id)
        .await
        .map_err(|e| e.to_string())?;
    append_event(
        &db,
        project_id,
        None,
        None,
        "system",
        "NotificationMarkedRead",
        json!({"notification_id": notification_id}),
    )
    .await;
    let _ = app.emit(
        "notification_updated",
        json!({"id": notification_id, "unread": false}),
    );
    Ok(())
}

#[tauri::command]
pub async fn clear_notifications(app: AppHandle, state: State<'_, AppState>) -> Result<(), String> {
    let (db, project_id) = {
        let current = state.current.lock().await;
        let ctx = current
            .as_ref()
            .ok_or_else(|| "no open project".to_string())?;
        (ctx.db.clone(), ctx.project_id)
    };
    db.clear_notifications(&project_id.to_string())
        .await
        .map_err(|e| e.to_string())?;
    append_event(
        &db,
        project_id,
        None,
        None,
        "system",
        "NotificationsCleared",
        json!({}),
    )
    .await;
    let _ = app.emit(
        "notification_cleared",
        json!({"project_id": project_id.to_string()}),
    );
    Ok(())
}

#[tauri::command]
pub async fn run_task_checks(
    task_id: String,
    state: State<'_, AppState>,
) -> Result<TaskCheckRunView, String> {
    let (db, project_id, project_path) = {
        let current = state.current.lock().await;
        let ctx = current
            .as_ref()
            .ok_or_else(|| "no open project".to_string())?;
        (ctx.db.clone(), ctx.project_id, ctx.project_path.clone())
    };
    let row = db
        .get_task(&task_id)
        .await
        .map_err(|e| e.to_string())?
        .ok_or_else(|| format!("task not found: {task_id}"))?;
    let task = task_row_to_contract(&row)?;
    let (run, results, _) =
        run_acceptance_checks_for_task(&db, project_id, &project_path, &task).await?;
    Ok(TaskCheckRunView {
        id: run.id,
        task_id: run.task_id,
        status: run.status,
        summary: run.summary,
        created_at: run.created_at,
        results: results
            .into_iter()
            .map(|row| TaskCheckResultView {
                id: row.id,
                description: row.description,
                check_type: row.check_type,
                command: row.command,
                passed: row.passed,
                output: row.output,
                created_at: row.created_at,
            })
            .collect(),
    })
}

#[tauri::command]
pub async fn get_task_check_results(
    task_id: String,
    state: State<'_, AppState>,
) -> Result<Option<TaskCheckRunView>, String> {
    let db = {
        let current = state.current.lock().await;
        let ctx = current
            .as_ref()
            .ok_or_else(|| "no open project".to_string())?;
        ctx.db.clone()
    };
    let Some(run) = db
        .latest_check_run_for_task(&task_id)
        .await
        .map_err(|e| e.to_string())?
    else {
        return Ok(None);
    };
    let results = db
        .list_check_results_for_run(&run.id)
        .await
        .map_err(|e| e.to_string())?;
    Ok(Some(TaskCheckRunView {
        id: run.id,
        task_id: run.task_id,
        status: run.status,
        summary: run.summary,
        created_at: run.created_at,
        results: results
            .into_iter()
            .map(|row| TaskCheckResultView {
                id: row.id,
                description: row.description,
                check_type: row.check_type,
                command: row.command,
                passed: row.passed,
                output: row.output,
                created_at: row.created_at,
            })
            .collect(),
    }))
}

#[tauri::command]
pub async fn get_review_pack(
    task_id: String,
    state: State<'_, AppState>,
) -> Result<Option<ReviewPackView>, String> {
    let db = {
        let current = state.current.lock().await;
        let ctx = current
            .as_ref()
            .ok_or_else(|| "no open project".to_string())?;
        ctx.db.clone()
    };
    let Some(review) = db
        .get_review_by_task(&task_id)
        .await
        .map_err(|e| e.to_string())?
    else {
        return Ok(None);
    };
    let pack_text = tokio::fs::read_to_string(&review.review_pack_path)
        .await
        .map_err(|e| e.to_string())?;
    let pack = serde_json::from_str::<serde_json::Value>(&pack_text).map_err(|e| e.to_string())?;
    Ok(Some(ReviewPackView {
        task_id: review.task_id,
        status: review.status,
        review_pack_path: review.review_pack_path,
        reviewer_notes: review.reviewer_notes,
        approved_at: review.approved_at,
        pack,
    }))
}

#[tauri::command]
pub async fn approve_review(
    input: ReviewDecisionInput,
    app: AppHandle,
    state: State<'_, AppState>,
) -> Result<(), String> {
    let (db, project_id) = {
        let current = state.current.lock().await;
        let ctx = current
            .as_ref()
            .ok_or_else(|| "no open project".to_string())?;
        (ctx.db.clone(), ctx.project_id)
    };
    let task_id = Uuid::parse_str(&input.task_id).map_err(|e| e.to_string())?;
    let Some(mut review) = db
        .get_review_by_task(&input.task_id)
        .await
        .map_err(|e| e.to_string())?
    else {
        return Err(format!("review pack not found for task {}", input.task_id));
    };
    review.status = "Approved".to_string();
    review.reviewer_notes = input.note.clone();
    review.approved_at = Some(Utc::now());
    db.upsert_review(&review).await.map_err(|e| e.to_string())?;

    db.upsert_merge_queue_item(&MergeQueueRow {
        id: Uuid::new_v4().to_string(),
        project_id: project_id.to_string(),
        task_id: input.task_id.clone(),
        status: "Queued".to_string(),
        blocked_reason: None,
        approved_at: review.approved_at.unwrap_or_else(Utc::now),
        started_at: None,
        completed_at: None,
    })
    .await
    .map_err(|e| e.to_string())?;

    append_event(
        &db,
        project_id,
        Some(task_id),
        None,
        "review",
        "ReviewApproved",
        json!({"task_id": input.task_id, "note": input.note}),
    )
    .await;
    emit_enriched_task_event(&app, &db, &input.task_id).await;
    let _ = app.emit("merge_queue_updated", json!({"task_id": input.task_id}));
    Ok(())
}

#[tauri::command]
pub async fn reject_review(
    input: ReviewDecisionInput,
    app: AppHandle,
    state: State<'_, AppState>,
) -> Result<(), String> {
    let (db, project_id) = {
        let current = state.current.lock().await;
        let ctx = current
            .as_ref()
            .ok_or_else(|| "no open project".to_string())?;
        (ctx.db.clone(), ctx.project_id)
    };
    let task_id = Uuid::parse_str(&input.task_id).map_err(|e| e.to_string())?;
    if let Some(mut review) = db
        .get_review_by_task(&input.task_id)
        .await
        .map_err(|e| e.to_string())?
    {
        review.status = "Rejected".to_string();
        review.reviewer_notes = input.note.clone();
        db.upsert_review(&review).await.map_err(|e| e.to_string())?;
    }
    if let Some(mut task_row) = db
        .get_task(&input.task_id)
        .await
        .map_err(|e| e.to_string())?
    {
        task_row.status = "InProgress".to_string();
        task_row.updated_at = Utc::now();
        db.update_task(&task_row).await.map_err(|e| e.to_string())?;
    }
    append_event(
        &db,
        project_id,
        Some(task_id),
        None,
        "review",
        "ReviewRejected",
        json!({"task_id": input.task_id, "note": input.note}),
    )
    .await;
    emit_enriched_task_event(&app, &db, &input.task_id).await;
    Ok(())
}

#[tauri::command]
pub async fn list_merge_queue(
    state: State<'_, AppState>,
) -> Result<Vec<MergeQueueItemView>, String> {
    let (db, project_id) = {
        let current = state.current.lock().await;
        let ctx = current
            .as_ref()
            .ok_or_else(|| "no open project".to_string())?;
        (ctx.db.clone(), ctx.project_id)
    };
    merge_queue_views(&db, project_id).await
}

async fn merge_queue_views(db: &Db, project_id: Uuid) -> Result<Vec<MergeQueueItemView>, String> {
    let rows = db
        .list_merge_queue(&project_id.to_string())
        .await
        .map_err(|e| e.to_string())?;
    let mut views = Vec::with_capacity(rows.len());
    for row in rows {
        let task_title = db
            .get_task(&row.task_id)
            .await
            .ok()
            .flatten()
            .map(|task| task.title)
            .unwrap_or_else(|| row.task_id.clone());
        views.push(MergeQueueItemView {
            id: row.id,
            task_id: row.task_id,
            task_title,
            status: row.status,
            blocked_reason: row.blocked_reason,
            approved_at: row.approved_at,
            started_at: row.started_at,
            completed_at: row.completed_at,
        });
    }
    Ok(views)
}

#[tauri::command]
pub async fn move_merge_queue_item(
    input: MoveMergeQueueInput,
    app: AppHandle,
    state: State<'_, AppState>,
) -> Result<Vec<MergeQueueItemView>, String> {
    let (db, project_id) = {
        let current = state.current.lock().await;
        let ctx = current
            .as_ref()
            .ok_or_else(|| "no open project".to_string())?;
        (ctx.db.clone(), ctx.project_id)
    };
    let mut rows = db
        .list_merge_queue(&project_id.to_string())
        .await
        .map_err(|e| e.to_string())?;
    let Some(index) = rows.iter().position(|row| row.task_id == input.task_id) else {
        return Err(format!("task not in merge queue: {}", input.task_id));
    };
    let target = input.direction.trim().to_ascii_lowercase();
    let swap_with = match target.as_str() {
        "up" if index > 0 => Some(index - 1),
        "down" if index + 1 < rows.len() => Some(index + 1),
        "up" | "down" => None,
        _ => return Err("direction must be 'up' or 'down'".to_string()),
    };
    if let Some(other_index) = swap_with {
        let first_time = rows[index].approved_at;
        let second_time = rows[other_index].approved_at;
        rows[index].approved_at = second_time;
        rows[other_index].approved_at = first_time;
        db.upsert_merge_queue_item(&rows[index])
            .await
            .map_err(|e| e.to_string())?;
        db.upsert_merge_queue_item(&rows[other_index])
            .await
            .map_err(|e| e.to_string())?;
        append_event(
            &db,
            project_id,
            Uuid::parse_str(&input.task_id).ok(),
            None,
            "review",
            "MergeQueueReordered",
            json!({"task_id": input.task_id, "direction": target}),
        )
        .await;
        let _ = app.emit("merge_queue_updated", json!({"ok": true}));
    }
    merge_queue_views(&db, project_id).await
}

#[tauri::command]
pub async fn merge_queue_execute(
    task_id: String,
    app: AppHandle,
    state: State<'_, AppState>,
) -> Result<(), String> {
    let (project_id, db, project_path, git, config, global_config) = {
        let current = state.current.lock().await;
        let ctx = current
            .as_ref()
            .ok_or_else(|| "no open project".to_string())?;
        (
            ctx.project_id,
            ctx.db.clone(),
            ctx.project_path.clone(),
            ctx.git.clone(),
            ctx.config.clone(),
            ctx.global_config.clone(),
        )
    };
    let target_branch = config.branches.target.clone();
    let Some(mut queue_item) = db
        .get_merge_queue_item_by_task(&task_id)
        .await
        .map_err(|e| e.to_string())?
    else {
        return Err(format!("task not in merge queue: {task_id}"));
    };
    queue_item.status = "Running".to_string();
    queue_item.started_at = Some(Utc::now());
    queue_item.blocked_reason = None;
    db.upsert_merge_queue_item(&queue_item)
        .await
        .map_err(|e| e.to_string())?;
    let _ = app.emit(
        "merge_queue_updated",
        json!({"task_id": task_id, "status": "Running"}),
    );

    let task_uuid = Uuid::parse_str(&task_id).map_err(|e| e.to_string())?;
    let mut task_row = db
        .get_task(&task_id)
        .await
        .map_err(|e| e.to_string())?
        .ok_or_else(|| format!("task not found: {task_id}"))?;
    let task = task_row_to_contract(&task_row)?;
    let worktree = db
        .find_worktree_by_task(&task_id)
        .await
        .map_err(|e| e.to_string())?
        .ok_or_else(|| "task worktree not found".to_string())?;
    let worktree_path = PathBuf::from(&worktree.path);

    let checkpoint_id = Uuid::new_v4().to_string();
    let checkpoint_ref = format!("pnevma/checkpoint/{checkpoint_id}");
    let _ = git_output(&project_path, &["tag", &checkpoint_ref]).await?;
    db.create_checkpoint(&CheckpointRow {
        id: checkpoint_id.clone(),
        project_id: project_id.to_string(),
        task_id: Some(task_id.clone()),
        git_ref: checkpoint_ref.clone(),
        session_metadata_json: "{}".to_string(),
        created_at: Utc::now(),
        description: Some("auto-checkpoint before merge queue execution".to_string()),
    })
    .await
    .map_err(|e| e.to_string())?;
    append_event(
        &db,
        project_id,
        Some(task_uuid),
        None,
        "core",
        "CheckpointCreated",
        json!({"checkpoint_id": checkpoint_id, "git_ref": checkpoint_ref}),
    )
    .await;

    let dirty = git_output_in(&worktree_path, &["status", "--porcelain"]).await?;
    if !dirty.trim().is_empty() {
        queue_item.status = "Blocked".to_string();
        queue_item.blocked_reason = Some("worktree has uncommitted changes".to_string());
        db.upsert_merge_queue_item(&queue_item)
            .await
            .map_err(|e| e.to_string())?;
        let _ = app.emit(
            "merge_queue_updated",
            json!({"task_id": task_id, "status": "Blocked"}),
        );
        return Err("merge blocked: worktree has uncommitted changes".to_string());
    }

    if let Err(err) = git_output_in(&worktree_path, &["rebase", &target_branch]).await {
        let conflicts = git_output_in(&worktree_path, &["diff", "--name-only", "--diff-filter=U"])
            .await
            .unwrap_or_default();
        queue_item.status = "Blocked".to_string();
        queue_item.blocked_reason = Some(format!(
            "rebase conflict: {}",
            conflicts.lines().collect::<Vec<_>>().join(", ")
        ));
        db.upsert_merge_queue_item(&queue_item)
            .await
            .map_err(|e| e.to_string())?;
        let _ = app.emit(
            "merge_queue_updated",
            json!({"task_id": task_id, "status": "Blocked"}),
        );
        append_event(
            &db,
            project_id,
            Some(task_uuid),
            None,
            "git",
            "ConflictDetected",
            json!({"task_id": task_id, "error": err, "conflicts": conflicts}),
        )
        .await;
        return Err("merge blocked by rebase conflicts".to_string());
    }

    let (_, _, checks_ok) =
        run_acceptance_checks_for_task(&db, project_id, &project_path, &task).await?;
    if !checks_ok {
        queue_item.status = "Blocked".to_string();
        queue_item.blocked_reason = Some("automated checks failed after rebase".to_string());
        db.upsert_merge_queue_item(&queue_item)
            .await
            .map_err(|e| e.to_string())?;
        let _ = app.emit(
            "merge_queue_updated",
            json!({"task_id": task_id, "status": "Blocked"}),
        );
        return Err("merge blocked: checks failed".to_string());
    }

    let _ = git_output(&project_path, &["checkout", &target_branch]).await?;
    if let Err(ff_err) = git_output(&project_path, &["merge", "--ff-only", &worktree.branch]).await
    {
        let _ = git_output(
            &project_path,
            &[
                "merge",
                "--no-ff",
                "-m",
                &format!("Merge task {}", task_id),
                &worktree.branch,
            ],
        )
        .await
        .map_err(|merge_err| {
            format!("ff merge failed: {ff_err}; merge commit failed: {merge_err}")
        })?;
    }

    task_row.status = "Done".to_string();
    task_row.updated_at = Utc::now();
    db.update_task(&task_row).await.map_err(|e| e.to_string())?;
    cleanup_task_worktree(&db, &git, project_id, task_uuid, Some(&app)).await?;

    queue_item.status = "Merged".to_string();
    queue_item.completed_at = Some(Utc::now());
    queue_item.blocked_reason = None;
    db.upsert_merge_queue_item(&queue_item)
        .await
        .map_err(|e| e.to_string())?;
    let _ = app.emit(
        "merge_queue_updated",
        json!({"task_id": task_id, "status": "Completed"}),
    );
    append_event(
        &db,
        project_id,
        Some(task_uuid),
        None,
        "git",
        "MergeCompleted",
        json!({"task_id": task_id, "target_branch": target_branch}),
    )
    .await;
    append_telemetry_event(
        &db,
        project_id,
        &global_config,
        "merge.completed",
        json!({"task_id": task_id, "target_branch": target_branch}),
    )
    .await;
    emit_enriched_task_event(&app, &db, &task_id).await;
    let _ = app.emit(
        "knowledge_capture_requested",
        json!({"task_id": task_id, "kinds": ["adr", "changelog", "convention-update"]}),
    );
    Ok(())
}

#[tauri::command]
pub async fn list_conflicts(
    task_id: String,
    state: State<'_, AppState>,
) -> Result<Vec<String>, String> {
    let db = {
        let current = state.current.lock().await;
        let ctx = current
            .as_ref()
            .ok_or_else(|| "no open project".to_string())?;
        ctx.db.clone()
    };
    let Some(worktree) = db
        .find_worktree_by_task(&task_id)
        .await
        .map_err(|e| e.to_string())?
    else {
        return Ok(Vec::new());
    };
    let out = git_output_in(
        Path::new(&worktree.path),
        &["diff", "--name-only", "--diff-filter=U"],
    )
    .await?;
    Ok(out
        .lines()
        .map(str::trim)
        .filter(|line| !line.is_empty())
        .map(ToString::to_string)
        .collect())
}

#[tauri::command]
pub async fn resolve_conflicts_manual(
    task_id: String,
    state: State<'_, AppState>,
) -> Result<String, String> {
    let db = {
        let current = state.current.lock().await;
        let ctx = current
            .as_ref()
            .ok_or_else(|| "no open project".to_string())?;
        ctx.db.clone()
    };
    let worktree = db
        .find_worktree_by_task(&task_id)
        .await
        .map_err(|e| e.to_string())?
        .ok_or_else(|| format!("worktree not found for task {task_id}"))?;
    Ok(worktree.path)
}

#[tauri::command]
pub async fn redispatch_with_conflict_context(
    task_id: String,
    app: AppHandle,
    state: State<'_, AppState>,
) -> Result<String, String> {
    let (db, project_id) = {
        let current = state.current.lock().await;
        let ctx = current
            .as_ref()
            .ok_or_else(|| "no open project".to_string())?;
        (ctx.db.clone(), ctx.project_id)
    };
    let conflicts = list_conflicts(task_id.clone(), state.clone())
        .await
        .unwrap_or_default();
    if let Some(mut row) = db.get_task(&task_id).await.map_err(|e| e.to_string())? {
        let prior = row.handoff_summary.unwrap_or_default();
        row.handoff_summary = Some(format!(
            "{prior}\nConflict files:\n{}",
            conflicts
                .iter()
                .map(|v| format!("- {v}"))
                .collect::<Vec<_>>()
                .join("\n")
        ));
        row.status = "Ready".to_string();
        row.updated_at = Utc::now();
        db.update_task(&row).await.map_err(|e| e.to_string())?;
    }
    append_event(
        &db,
        project_id,
        Uuid::parse_str(&task_id).ok(),
        None,
        "git",
        "ConflictRedispatchRequested",
        json!({"task_id": task_id, "conflicts": conflicts}),
    )
    .await;
    dispatch_task(task_id, app, state).await
}

#[tauri::command]
pub async fn secrets_set_ref(
    input: SecretRefInput,
    state: State<'_, AppState>,
) -> Result<SecretRefView, String> {
    let (db, project_id) = {
        let current = state.current.lock().await;
        let ctx = current
            .as_ref()
            .ok_or_else(|| "no open project".to_string())?;
        (ctx.db.clone(), ctx.project_id)
    };
    let scope = if input.scope.eq_ignore_ascii_case("global") {
        "global".to_string()
    } else {
        "project".to_string()
    };
    let project_scope_id = if scope == "project" {
        Some(project_id.to_string())
    } else {
        None
    };
    let service = if let Some(project_scope_id) = &project_scope_id {
        format!("pnevma.{scope}.{project_scope_id}")
    } else {
        format!("pnevma.{scope}")
    };
    let account = input.name.clone();
    store_keychain_secret(&service, &account, &input.value).await?;

    let now = Utc::now();
    let row = SecretRefRow {
        id: Uuid::new_v4().to_string(),
        project_id: project_scope_id.clone(),
        scope: scope.clone(),
        name: input.name.clone(),
        keychain_service: service.clone(),
        keychain_account: account.clone(),
        created_at: now,
        updated_at: now,
    };
    db.upsert_secret_ref(&row)
        .await
        .map_err(|e| e.to_string())?;
    Ok(SecretRefView {
        id: row.id,
        project_id: row.project_id,
        scope: row.scope,
        name: row.name,
        keychain_service: row.keychain_service,
        keychain_account: row.keychain_account,
        created_at: row.created_at,
        updated_at: row.updated_at,
    })
}

#[tauri::command]
pub async fn secrets_list(
    scope: Option<String>,
    state: State<'_, AppState>,
) -> Result<Vec<SecretRefView>, String> {
    let (db, project_id) = {
        let current = state.current.lock().await;
        let ctx = current
            .as_ref()
            .ok_or_else(|| "no open project".to_string())?;
        (ctx.db.clone(), ctx.project_id)
    };
    let rows = db
        .list_secret_refs(&project_id.to_string(), scope.as_deref())
        .await
        .map_err(|e| e.to_string())?;
    Ok(rows
        .into_iter()
        .map(|row| SecretRefView {
            id: row.id,
            project_id: row.project_id,
            scope: row.scope,
            name: row.name,
            keychain_service: row.keychain_service,
            keychain_account: row.keychain_account,
            created_at: row.created_at,
            updated_at: row.updated_at,
        })
        .collect())
}

#[tauri::command]
pub async fn checkpoint_create(
    input: CheckpointInput,
    state: State<'_, AppState>,
) -> Result<CheckpointView, String> {
    let (db, project_id, project_path) = {
        let current = state.current.lock().await;
        let ctx = current
            .as_ref()
            .ok_or_else(|| "no open project".to_string())?;
        (ctx.db.clone(), ctx.project_id, ctx.project_path.clone())
    };
    let checkpoint_id = Uuid::new_v4().to_string();
    let git_ref = format!("pnevma/checkpoint/{checkpoint_id}");
    let _ = git_output(&project_path, &["tag", &git_ref]).await?;
    let sessions = db
        .list_sessions(&project_id.to_string())
        .await
        .map_err(|e| e.to_string())?;
    let session_json = serde_json::to_string(&sessions).map_err(|e| e.to_string())?;
    let row = CheckpointRow {
        id: checkpoint_id.clone(),
        project_id: project_id.to_string(),
        task_id: input.task_id.clone(),
        git_ref: git_ref.clone(),
        session_metadata_json: session_json,
        created_at: Utc::now(),
        description: input.description.clone(),
    };
    db.create_checkpoint(&row)
        .await
        .map_err(|e| e.to_string())?;
    Ok(CheckpointView {
        id: row.id,
        task_id: row.task_id,
        git_ref: row.git_ref,
        created_at: row.created_at,
        description: row.description,
    })
}

#[tauri::command]
pub async fn checkpoint_list(state: State<'_, AppState>) -> Result<Vec<CheckpointView>, String> {
    let (db, project_id) = {
        let current = state.current.lock().await;
        let ctx = current
            .as_ref()
            .ok_or_else(|| "no open project".to_string())?;
        (ctx.db.clone(), ctx.project_id)
    };
    let rows = db
        .list_checkpoints(&project_id.to_string())
        .await
        .map_err(|e| e.to_string())?;
    Ok(rows
        .into_iter()
        .map(|row| CheckpointView {
            id: row.id,
            task_id: row.task_id,
            git_ref: row.git_ref,
            created_at: row.created_at,
            description: row.description,
        })
        .collect())
}

#[tauri::command]
pub async fn checkpoint_restore(
    checkpoint_id: String,
    app: AppHandle,
    state: State<'_, AppState>,
) -> Result<(), String> {
    let (db, project_id, project_path) = {
        let current = state.current.lock().await;
        let ctx = current
            .as_ref()
            .ok_or_else(|| "no open project".to_string())?;
        (ctx.db.clone(), ctx.project_id, ctx.project_path.clone())
    };
    let row = db
        .get_checkpoint(&checkpoint_id)
        .await
        .map_err(|e| e.to_string())?
        .ok_or_else(|| format!("checkpoint not found: {checkpoint_id}"))?;
    let _ = git_output(&project_path, &["reset", "--hard", &row.git_ref]).await?;
    append_event(
        &db,
        project_id,
        row.task_id.as_deref().and_then(|v| Uuid::parse_str(v).ok()),
        None,
        "core",
        "CheckpointRestored",
        json!({"checkpoint_id": checkpoint_id, "git_ref": row.git_ref}),
    )
    .await;
    let _ = app.emit("project_refreshed", json!({"checkpoint_id": checkpoint_id}));
    Ok(())
}

#[tauri::command]
pub async fn list_registered_commands() -> Result<Vec<RegisteredCommand>, String> {
    Ok(default_registry().list())
}

#[tauri::command]
pub async fn execute_registered_command(
    input: ExecuteRegisteredCommandInput,
    app: AppHandle,
    _state: State<'_, AppState>,
) -> Result<serde_json::Value, String> {
    if !default_registry().contains(&input.id) {
        return Err(format!("unknown command id: {}", input.id));
    }

    let command_id = input.id.clone();
    let result = match input.id.as_str() {
        "environment.readiness" => {
            let path = optional_arg(&input.args, "path");
            let readiness = get_environment_readiness(
                Some(EnvironmentReadinessInput { path }),
                app.state::<AppState>(),
            )
            .await?;
            Ok(json!(readiness))
        }
        "environment.init_global_config" => {
            let default_provider = optional_arg(&input.args, "default_provider");
            let result = initialize_global_config(
                Some(InitializeGlobalConfigInput { default_provider }),
                app.state::<AppState>(),
            )
            .await?;
            Ok(json!(result))
        }
        "project.initialize_scaffold" => {
            let path = required_arg(&input.args, "path")?;
            let result = initialize_project_scaffold(
                InitializeProjectScaffoldInput {
                    path,
                    project_name: optional_arg(&input.args, "project_name"),
                    project_brief: optional_arg(&input.args, "project_brief"),
                    default_provider: optional_arg(&input.args, "default_provider"),
                },
                app.state::<AppState>(),
            )
            .await?;
            Ok(json!(result))
        }
        "project.open" => {
            let path = required_arg(&input.args, "path")?;
            let project_id = open_project(path, app.clone(), app.state::<AppState>()).await?;
            let status = project_status(app.state::<AppState>()).await?;
            Ok(json!({"project_id": project_id, "status": status}))
        }
        "session.new" => {
            let name = optional_arg(&input.args, "name").unwrap_or_else(|| "session".to_string());
            let cwd = optional_arg(&input.args, "cwd").unwrap_or_else(|| ".".to_string());
            let command = optional_arg(&input.args, "command").unwrap_or_else(|| "zsh".to_string());
            let active_pane_id = optional_arg(&input.args, "active_pane_id");
            let session_id = create_session(
                SessionInput {
                    name: name.clone(),
                    cwd,
                    command,
                },
                app.state::<AppState>(),
            )
            .await?;
            let position = active_pane_id
                .map(|id| format!("after:{id}"))
                .unwrap_or_else(|| "after:root".to_string());
            let pane = upsert_pane(
                PaneInput {
                    id: None,
                    session_id: Some(session_id.clone()),
                    r#type: "terminal".to_string(),
                    position,
                    label: name,
                    metadata_json: None,
                },
                app.state::<AppState>(),
            )
            .await?;
            Ok(json!({"session_id": session_id, "pane_id": pane.id}))
        }
        "session.reattach_active" => {
            let active_session_id = required_arg(&input.args, "active_session_id")?;
            reattach_session(active_session_id.clone(), app.state::<AppState>()).await?;
            Ok(json!({"session_id": active_session_id}))
        }
        "session.restart_active" => {
            let active_session_id = required_arg(&input.args, "active_session_id")?;
            let active_pane_id = required_arg(&input.args, "active_pane_id")?;
            let new_session_id =
                restart_session(active_session_id.clone(), app.state::<AppState>()).await?;
            if let Some(active) = list_panes(app.state::<AppState>())
                .await?
                .into_iter()
                .find(|pane| pane.id == active_pane_id)
            {
                let _ = upsert_pane(
                    PaneInput {
                        id: Some(active.id.clone()),
                        session_id: Some(new_session_id.clone()),
                        r#type: active.r#type,
                        position: active.position,
                        label: active.label,
                        metadata_json: active.metadata_json,
                    },
                    app.state::<AppState>(),
                )
                .await?;
            }
            Ok(json!({"old_session_id": active_session_id, "new_session_id": new_session_id}))
        }
        "pane.split_horizontal" | "pane.split_vertical" => {
            let suffix = if input.id.ends_with("horizontal") {
                ":h"
            } else {
                ":v"
            };
            let active_pane_id = optional_arg(&input.args, "active_pane_id");
            let panes = list_panes(app.state::<AppState>()).await?;
            let active = active_pane_id
                .as_ref()
                .and_then(|id| panes.iter().find(|pane| &pane.id == id))
                .cloned()
                .or_else(|| panes.first().cloned())
                .ok_or_else(|| "no panes found".to_string())?;
            let new_pane = upsert_pane(
                PaneInput {
                    id: None,
                    session_id: active.session_id,
                    r#type: active.r#type,
                    position: format!("{}{}", active.id, suffix),
                    label: format!("{} Copy", active.label),
                    metadata_json: active.metadata_json,
                },
                app.state::<AppState>(),
            )
            .await?;
            Ok(json!({"pane_id": new_pane.id}))
        }
        "pane.close" => {
            let active_pane_id = required_arg(&input.args, "active_pane_id")?;
            let panes = list_panes(app.state::<AppState>()).await?;
            let active = panes
                .into_iter()
                .find(|pane| pane.id == active_pane_id)
                .ok_or_else(|| format!("pane not found: {active_pane_id}"))?;
            if active.r#type == "task-board" {
                return Ok(json!({"closed": false, "reason": "task-board"}));
            }
            remove_pane(active.id.clone(), app.state::<AppState>()).await?;
            Ok(json!({"closed": true, "pane_id": active.id}))
        }
        "pane.open_review" => {
            let active_pane_id = optional_arg(&input.args, "active_pane_id");
            let position = active_pane_id
                .map(|id| format!("after:{id}"))
                .unwrap_or_else(|| "after:root".to_string());
            let pane = upsert_pane(
                PaneInput {
                    id: None,
                    session_id: None,
                    r#type: "review".to_string(),
                    position,
                    label: "Review".to_string(),
                    metadata_json: None,
                },
                app.state::<AppState>(),
            )
            .await?;
            Ok(json!({"pane_id": pane.id}))
        }
        "pane.open_notifications" => {
            let active_pane_id = optional_arg(&input.args, "active_pane_id");
            let position = active_pane_id
                .map(|id| format!("after:{id}"))
                .unwrap_or_else(|| "after:root".to_string());
            let pane = upsert_pane(
                PaneInput {
                    id: None,
                    session_id: None,
                    r#type: "notifications".to_string(),
                    position,
                    label: "Notifications".to_string(),
                    metadata_json: None,
                },
                app.state::<AppState>(),
            )
            .await?;
            Ok(json!({"pane_id": pane.id}))
        }
        "pane.open_merge_queue" => {
            let active_pane_id = optional_arg(&input.args, "active_pane_id");
            let position = active_pane_id
                .map(|id| format!("after:{id}"))
                .unwrap_or_else(|| "after:root".to_string());
            let pane = upsert_pane(
                PaneInput {
                    id: None,
                    session_id: None,
                    r#type: "merge-queue".to_string(),
                    position,
                    label: "Merge Queue".to_string(),
                    metadata_json: None,
                },
                app.state::<AppState>(),
            )
            .await?;
            Ok(json!({"pane_id": pane.id}))
        }
        "pane.open_replay" => {
            let active_pane_id = optional_arg(&input.args, "active_pane_id");
            let position = active_pane_id
                .map(|id| format!("after:{id}"))
                .unwrap_or_else(|| "after:root".to_string());
            let pane = upsert_pane(
                PaneInput {
                    id: None,
                    session_id: None,
                    r#type: "replay".to_string(),
                    position,
                    label: "Replay".to_string(),
                    metadata_json: None,
                },
                app.state::<AppState>(),
            )
            .await?;
            Ok(json!({"pane_id": pane.id}))
        }
        "pane.open_daily_brief" => {
            let active_pane_id = optional_arg(&input.args, "active_pane_id");
            let position = active_pane_id
                .map(|id| format!("after:{id}"))
                .unwrap_or_else(|| "after:root".to_string());
            let pane = upsert_pane(
                PaneInput {
                    id: None,
                    session_id: None,
                    r#type: "daily-brief".to_string(),
                    position,
                    label: "Daily Brief".to_string(),
                    metadata_json: None,
                },
                app.state::<AppState>(),
            )
            .await?;
            Ok(json!({"pane_id": pane.id}))
        }
        "pane.open_search" => {
            let active_pane_id = optional_arg(&input.args, "active_pane_id");
            let position = active_pane_id
                .map(|id| format!("after:{id}"))
                .unwrap_or_else(|| "after:root".to_string());
            let pane = upsert_pane(
                PaneInput {
                    id: None,
                    session_id: None,
                    r#type: "search".to_string(),
                    position,
                    label: "Search".to_string(),
                    metadata_json: None,
                },
                app.state::<AppState>(),
            )
            .await?;
            Ok(json!({"pane_id": pane.id}))
        }
        "pane.open_diff" => {
            let active_pane_id = optional_arg(&input.args, "active_pane_id");
            let position = active_pane_id
                .map(|id| format!("after:{id}"))
                .unwrap_or_else(|| "after:root".to_string());
            let pane = upsert_pane(
                PaneInput {
                    id: None,
                    session_id: None,
                    r#type: "diff".to_string(),
                    position,
                    label: "Diff".to_string(),
                    metadata_json: None,
                },
                app.state::<AppState>(),
            )
            .await?;
            Ok(json!({"pane_id": pane.id}))
        }
        "pane.open_file_browser" => {
            let active_pane_id = optional_arg(&input.args, "active_pane_id");
            let position = active_pane_id
                .map(|id| format!("after:{id}"))
                .unwrap_or_else(|| "after:root".to_string());
            let pane = upsert_pane(
                PaneInput {
                    id: None,
                    session_id: None,
                    r#type: "file-browser".to_string(),
                    position,
                    label: "Files".to_string(),
                    metadata_json: None,
                },
                app.state::<AppState>(),
            )
            .await?;
            Ok(json!({"pane_id": pane.id}))
        }
        "pane.open_rules_manager" => {
            let active_pane_id = optional_arg(&input.args, "active_pane_id");
            let position = active_pane_id
                .map(|id| format!("after:{id}"))
                .unwrap_or_else(|| "after:root".to_string());
            let pane = upsert_pane(
                PaneInput {
                    id: None,
                    session_id: None,
                    r#type: "rules-manager".to_string(),
                    position,
                    label: "Rules".to_string(),
                    metadata_json: None,
                },
                app.state::<AppState>(),
            )
            .await?;
            Ok(json!({"pane_id": pane.id}))
        }
        "pane.open_settings" => {
            let active_pane_id = optional_arg(&input.args, "active_pane_id");
            let position = active_pane_id
                .map(|id| format!("after:{id}"))
                .unwrap_or_else(|| "after:root".to_string());
            let pane = upsert_pane(
                PaneInput {
                    id: None,
                    session_id: None,
                    r#type: "settings".to_string(),
                    position,
                    label: "Settings".to_string(),
                    metadata_json: None,
                },
                app.state::<AppState>(),
            )
            .await?;
            Ok(json!({"pane_id": pane.id}))
        }
        "task.new" => {
            let title = optional_arg(&input.args, "title").unwrap_or_else(|| "Task".to_string());
            let goal =
                optional_arg(&input.args, "goal").unwrap_or_else(|| "Ship value".to_string());
            let priority =
                optional_arg(&input.args, "priority").unwrap_or_else(|| "P1".to_string());
            let id = create_task(
                CreateTaskInput {
                    title,
                    goal,
                    scope: Vec::new(),
                    acceptance_criteria: vec!["manual review".to_string()],
                    constraints: Vec::new(),
                    dependencies: Vec::new(),
                    priority,
                },
                app.clone(),
                app.state::<AppState>(),
            )
            .await?;
            Ok(json!({"task_id": id}))
        }
        "task.dispatch_next_ready" => {
            let next = list_tasks(app.state::<AppState>())
                .await?
                .into_iter()
                .filter(|task| task.status == "Ready")
                .min_by(|a, b| a.created_at.cmp(&b.created_at))
                .map(|task| task.id);
            let Some(task_id) = next else {
                return Ok(json!({"dispatched": false}));
            };
            let status =
                dispatch_task(task_id.clone(), app.clone(), app.state::<AppState>()).await?;
            Ok(json!({"dispatched": true, "task_id": task_id, "status": status}))
        }
        "task.delete_ready" => {
            let ready = list_tasks(app.state::<AppState>())
                .await?
                .into_iter()
                .find(|task| task.status == "Ready");
            let Some(ready) = ready else {
                return Ok(json!({"deleted": false}));
            };
            delete_task(ready.id.clone(), app.clone(), app.state::<AppState>()).await?;
            Ok(json!({"deleted": true, "task_id": ready.id}))
        }
        "review.approve_next" => {
            let next = list_tasks(app.state::<AppState>())
                .await?
                .into_iter()
                .filter(|task| task.status == "Review")
                .min_by(|a, b| a.created_at.cmp(&b.created_at))
                .map(|task| task.id);
            let Some(task_id) = next else {
                return Ok(json!({"approved": false}));
            };
            approve_review(
                ReviewDecisionInput {
                    task_id: task_id.clone(),
                    note: Some("approved via quick action".to_string()),
                },
                app.clone(),
                app.state::<AppState>(),
            )
            .await?;
            Ok(json!({"approved": true, "task_id": task_id}))
        }
        "review.approve_task" => {
            let task_id = required_arg(&input.args, "task_id")?;
            let note = optional_arg(&input.args, "note");
            approve_review(
                ReviewDecisionInput { task_id, note },
                app.clone(),
                app.state::<AppState>(),
            )
            .await?;
            Ok(json!({"ok": true}))
        }
        "review.reject_task" => {
            let task_id = required_arg(&input.args, "task_id")?;
            let note = optional_arg(&input.args, "note");
            reject_review(
                ReviewDecisionInput { task_id, note },
                app.clone(),
                app.state::<AppState>(),
            )
            .await?;
            Ok(json!({"ok": true}))
        }
        "merge.execute_task" => {
            let task_id = required_arg(&input.args, "task_id")?;
            merge_queue_execute(task_id, app.clone(), app.state::<AppState>()).await?;
            Ok(json!({"ok": true}))
        }
        "checkpoint.create" => {
            let description = optional_arg(&input.args, "description");
            let task_id = optional_arg(&input.args, "task_id");
            let checkpoint = checkpoint_create(
                CheckpointInput {
                    description,
                    task_id,
                },
                app.state::<AppState>(),
            )
            .await?;
            Ok(json!({"checkpoint_id": checkpoint.id}))
        }
        _ => Err(format!("command not implemented: {}", input.id)),
    };

    if result.is_ok() {
        let state = app.state::<AppState>();
        let current = state.current.lock().await;
        if let Some(ctx) = current.as_ref() {
            append_telemetry_event(
                &ctx.db,
                ctx.project_id,
                &ctx.global_config,
                "command.execute",
                json!({"id": command_id}),
            )
            .await;
        }
    }
    result
}

#[tauri::command]
pub async fn create_task(
    input: CreateTaskInput,
    app: AppHandle,
    state: State<'_, AppState>,
) -> Result<String, String> {
    let (project_id, db, project_path, global_config) = {
        let current = state.current.lock().await;
        let ctx = current
            .as_ref()
            .ok_or_else(|| "no open project".to_string())?;
        (
            ctx.project_id,
            ctx.db.clone(),
            ctx.project_path.clone(),
            ctx.global_config.clone(),
        )
    };

    let id = Uuid::new_v4();
    let now = Utc::now();
    let deps = parse_dependency_ids(&input.dependencies)?;
    validate_task_dependencies(&db, project_id, id, &deps).await?;

    let mut task = TaskContract {
        id,
        title: input.title.clone(),
        goal: input.goal.clone(),
        scope: input.scope.clone(),
        out_of_scope: Vec::new(),
        dependencies: deps,
        acceptance_criteria: input
            .acceptance_criteria
            .iter()
            .map(|description| Check {
                description: description.clone(),
                check_type: CheckType::ManualApproval,
                command: None,
            })
            .collect(),
        constraints: input.constraints.clone(),
        priority: map_priority(&input.priority),
        status: TaskStatus::Planned,
        assigned_session: None,
        branch: None,
        worktree: None,
        prompt_pack: None,
        handoff_summary: None,
        created_at: now,
        updated_at: now,
    };

    task.validate_new().map_err(|e| e.to_string())?;
    let existing = db
        .list_tasks(&project_id.to_string())
        .await
        .map_err(|e| e.to_string())?;
    let completed = existing
        .iter()
        .filter(|row| row.status == "Done")
        .filter_map(|row| Uuid::parse_str(&row.id).ok())
        .collect::<HashSet<_>>();
    task.refresh_blocked_status(&completed);

    if task.status == TaskStatus::Ready {
        if task.acceptance_criteria.is_empty() {
            return Err("task must include at least one acceptance criterion".to_string());
        }
        for rel in &task.scope {
            if !project_path.join(rel).exists() {
                return Err(format!("scope file does not exist: {rel}"));
            }
        }
    }

    let row = task_contract_to_row(&task, &project_id.to_string())?;
    db.create_task(&row).await.map_err(|e| e.to_string())?;
    db.replace_task_dependencies(
        &row.id,
        &task
            .dependencies
            .iter()
            .map(ToString::to_string)
            .collect::<Vec<_>>(),
    )
    .await
    .map_err(|e| e.to_string())?;
    append_event(
        &db,
        project_id,
        Some(id),
        None,
        "core",
        "TaskCreated",
        json!({"title": row.title}),
    )
    .await;
    append_telemetry_event(
        &db,
        project_id,
        &global_config,
        "task.create",
        json!({"task_id": id.to_string(), "priority": row.priority}),
    )
    .await;
    refresh_dependency_states(&db, project_id, Some(&app)).await?;
    emit_enriched_task_event(&app, &db, &id.to_string()).await;

    Ok(id.to_string())
}

#[tauri::command]
pub async fn list_tasks(state: State<'_, AppState>) -> Result<Vec<TaskView>, String> {
    let (project_id, db) = {
        let current = state.current.lock().await;
        let ctx = current
            .as_ref()
            .ok_or_else(|| "no open project".to_string())?;
        (ctx.project_id, ctx.db.clone())
    };

    let rows = db
        .list_tasks(&project_id.to_string())
        .await
        .map_err(|e| e.to_string())?;
    let mut out = Vec::with_capacity(rows.len());
    for row in rows {
        let cost = db.task_cost_total(&row.id).await.ok();
        out.push(task_row_to_view(row, cost)?);
    }
    Ok(out)
}

#[tauri::command]
pub async fn get_task(task_id: String, state: State<'_, AppState>) -> Result<TaskView, String> {
    let db = {
        let current = state.current.lock().await;
        let ctx = current
            .as_ref()
            .ok_or_else(|| "no open project".to_string())?;
        ctx.db.clone()
    };
    let row = db
        .get_task(&task_id)
        .await
        .map_err(|e| e.to_string())?
        .ok_or_else(|| format!("task not found: {task_id}"))?;
    let cost = db.task_cost_total(&task_id).await.ok();
    task_row_to_view(row, cost)
}

#[tauri::command]
pub async fn update_task(
    input: UpdateTaskInput,
    app: AppHandle,
    state: State<'_, AppState>,
) -> Result<TaskView, String> {
    let (project_id, db, project_path, git) = {
        let current = state.current.lock().await;
        let ctx = current
            .as_ref()
            .ok_or_else(|| "no open project".to_string())?;
        (
            ctx.project_id,
            ctx.db.clone(),
            ctx.project_path.clone(),
            ctx.git.clone(),
        )
    };

    let existing = db
        .get_task(&input.id)
        .await
        .map_err(|e| e.to_string())?
        .ok_or_else(|| format!("task not found: {}", input.id))?;
    let mut task = task_row_to_contract(&existing)?;
    let previous_status = task.status.clone();

    if let Some(title) = input.title {
        task.title = title;
    }
    if let Some(goal) = input.goal {
        task.goal = goal;
    }
    if let Some(scope) = input.scope {
        task.scope = scope;
    }
    if let Some(criteria) = input.acceptance_criteria {
        task.acceptance_criteria = criteria
            .into_iter()
            .map(|description| Check {
                description,
                check_type: CheckType::ManualApproval,
                command: None,
            })
            .collect();
    }
    if let Some(constraints) = input.constraints {
        task.constraints = constraints;
    }
    if let Some(priority) = input.priority {
        task.priority = map_priority(&priority);
    }
    if let Some(handoff) = input.handoff_summary {
        task.handoff_summary = Some(handoff);
    }
    if let Some(dependencies) = input.dependencies {
        task.dependencies = parse_dependency_ids(&dependencies)?;
        validate_task_dependencies(&db, project_id, task.id, &task.dependencies).await?;
    }
    if let Some(status) = input.status {
        let target = parse_status(&status);
        if target != task.status {
            task.transition(target).map_err(|e| e.to_string())?;
        }
    }

    if task.status == TaskStatus::Ready {
        if task.acceptance_criteria.is_empty() {
            return Err("acceptance_criteria is required before Ready".to_string());
        }
        for rel in &task.scope {
            if !project_path.join(rel).exists() {
                return Err(format!("scope file does not exist: {rel}"));
            }
        }
    }

    let all = db
        .list_tasks(&project_id.to_string())
        .await
        .map_err(|e| e.to_string())?;
    let completed = all
        .iter()
        .filter(|row| row.status == "Done")
        .filter_map(|row| Uuid::parse_str(&row.id).ok())
        .collect::<HashSet<_>>();
    task.refresh_blocked_status(&completed);
    validate_task_dependencies(&db, project_id, task.id, &task.dependencies).await?;
    task.validate_new().map_err(|e| e.to_string())?;
    task.updated_at = Utc::now();

    let row = task_contract_to_row(&task, &project_id.to_string())?;
    db.update_task(&row).await.map_err(|e| e.to_string())?;
    db.replace_task_dependencies(
        &row.id,
        &task
            .dependencies
            .iter()
            .map(ToString::to_string)
            .collect::<Vec<_>>(),
    )
    .await
    .map_err(|e| e.to_string())?;
    refresh_dependency_states(&db, project_id, Some(&app)).await?;
    emit_task_updated(&db, project_id, task.id).await;
    emit_enriched_task_event(&app, &db, &row.id).await;
    if previous_status != task.status && is_terminal_task_status(&task.status) {
        cleanup_task_worktree(&db, &git, project_id, task.id, Some(&app)).await?;
    }
    task_row_to_view(row.clone(), db.task_cost_total(&row.id).await.ok())
}

#[tauri::command]
pub async fn delete_task(
    task_id: String,
    app: AppHandle,
    state: State<'_, AppState>,
) -> Result<(), String> {
    let (project_id, db, git) = {
        let current = state.current.lock().await;
        let ctx = current
            .as_ref()
            .ok_or_else(|| "no open project".to_string())?;
        (ctx.project_id, ctx.db.clone(), ctx.git.clone())
    };

    if let Ok(task_uuid) = Uuid::parse_str(&task_id) {
        let _ = cleanup_task_worktree(&db, &git, project_id, task_uuid, Some(&app)).await;
    }
    db.delete_task(&task_id).await.map_err(|e| e.to_string())?;
    append_event(
        &db,
        project_id,
        Uuid::parse_str(&task_id).ok(),
        None,
        "core",
        "TaskDeleted",
        json!({"task_id": task_id}),
    )
    .await;
    refresh_dependency_states(&db, project_id, Some(&app)).await?;
    let _ = app.emit("task_updated", json!({"task_id": task_id, "deleted": true}));
    Ok(())
}

#[tauri::command]
pub async fn dispatch_task(
    task_id: String,
    app: AppHandle,
    state: State<'_, AppState>,
) -> Result<String, String> {
    let (project_id, db, project_path, config, global_config, pool, adapters, git) = {
        let current = state.current.lock().await;
        let ctx = current
            .as_ref()
            .ok_or_else(|| "no open project".to_string())?;
        (
            ctx.project_id,
            ctx.db.clone(),
            ctx.project_path.clone(),
            ctx.config.clone(),
            ctx.global_config.clone(),
            ctx.pool.clone(),
            ctx.adapters.clone(),
            ctx.git.clone(),
        )
    };

    let task_id_uuid = Uuid::parse_str(&task_id).map_err(|e| e.to_string())?;
    let row = db
        .get_task(&task_id)
        .await
        .map_err(|e| e.to_string())?
        .ok_or_else(|| format!("task not found: {task_id}"))?;
    let mut task = task_row_to_contract(&row)?;
    if task.status != TaskStatus::Ready {
        return Err(format!(
            "task must be Ready before dispatch (current: {})",
            status_to_str(&task.status)
        ));
    }

    let queued = QueuedDispatch {
        task_id: task_id_uuid,
        priority: task.priority.clone(),
    };

    let permit = match pool.try_acquire(queued).await {
        Ok(permit) => permit,
        Err(position) => {
            let _ = app.emit(
                "task_queue_updated",
                json!({"task_id": task_id, "queued_position": position}),
            );
            return Ok(format!("queued:{position}"));
        }
    };

    let preferred_provider = global_config
        .default_provider
        .clone()
        .unwrap_or_else(|| config.agents.default_provider.clone());
    let provider = if adapters.get(&preferred_provider).is_some() {
        preferred_provider
    } else if adapters.get("claude-code").is_some() {
        "claude-code".to_string()
    } else {
        "codex".to_string()
    };

    let adapter = adapters
        .get(&provider)
        .ok_or_else(|| "no available agent adapters found".to_string())?;

    let slug = slugify(&task.title);
    let lease = git
        .create_worktree(task_id_uuid, &config.branches.target, &slug)
        .await
        .map_err(|e| e.to_string())?;
    let worktree_row = WorktreeRow {
        id: lease.id.to_string(),
        project_id: project_id.to_string(),
        task_id: task_id.clone(),
        path: lease.path.clone(),
        branch: lease.branch.clone(),
        lease_status: "Active".to_string(),
        lease_started: lease.started_at,
        last_active: lease.last_active,
    };
    db.upsert_worktree(&worktree_row)
        .await
        .map_err(|e| e.to_string())?;

    task.transition(TaskStatus::InProgress)
        .map_err(|e| e.to_string())?;
    task.branch = Some(lease.branch.clone());
    task.worktree = Some(worktree_row.id.clone());
    let task_row = task_contract_to_row(&task, &project_id.to_string())?;
    db.update_task(&task_row).await.map_err(|e| e.to_string())?;
    emit_task_updated(&db, project_id, task.id).await;
    emit_enriched_task_event(&app, &db, &task.id.to_string()).await;
    append_telemetry_event(
        &db,
        project_id,
        &global_config,
        "task.dispatch",
        json!({"task_id": task.id.to_string(), "provider": provider}),
    )
    .await;

    ensure_scope_rows_from_config(&db, project_id, &project_path, &config, "rule").await?;
    ensure_scope_rows_from_config(&db, project_id, &project_path, &config, "convention").await?;
    let mut rules = load_active_scope_texts(&db, project_id, &project_path, "rule").await?;
    if rules.is_empty() {
        rules = load_rule_texts(&config, &project_path).await;
    }
    let mut conventions =
        load_active_scope_texts(&db, project_id, &project_path, "convention").await?;
    if conventions.is_empty() {
        conventions = load_convention_texts(&config, &project_path).await;
    }
    let token_budget = match provider.as_str() {
        "codex" => config
            .agents
            .codex
            .as_ref()
            .map(|c| c.token_budget)
            .unwrap_or(60_000),
        _ => config
            .agents
            .claude_code
            .as_ref()
            .map(|c| c.token_budget)
            .unwrap_or(80_000),
    };
    let (secret_env, secret_values) = resolve_secret_env(&db, project_id)
        .await
        .unwrap_or_else(|_| (Vec::new(), Vec::new()));
    let compiler = ContextCompiler::new(ContextCompilerConfig {
        mode: ContextCompileMode::V2,
        token_budget,
    });
    let discovery = FileDiscovery::new(DiscoveryConfig::default());
    let relevant_file_contents = discovery
        .discover(&task, &project_path, token_budget)
        .await
        .unwrap_or_default();
    let prior_task_summaries =
        load_recent_knowledge_summaries(&db, project_id, &project_path, 8).await;
    let ctx_result = compiler
        .compile(ContextCompileInput {
            task: task.clone(),
            project_brief: config.project.brief.clone(),
            architecture_notes: String::new(),
            conventions,
            rules: rules.clone(),
            relevant_file_contents,
            prior_task_summaries,
        })
        .map_err(|e| e.to_string())?;
    let context_path = PathBuf::from(&lease.path)
        .join(".pnevma")
        .join("task-context.md");
    let redacted_context_markdown = redact_text(&ctx_result.markdown, &secret_values);
    compiler
        .write_markdown(&redacted_context_markdown, &context_path)
        .map_err(|e| e.to_string())?;
    let manifest_path = PathBuf::from(&lease.path)
        .join(".pnevma")
        .join("task-context.manifest.json");
    let redacted_manifest = redact_json_value(
        serde_json::to_value(&ctx_result.pack.manifest).map_err(|e| e.to_string())?,
        &secret_values,
    );
    tokio::fs::write(
        &manifest_path,
        serde_json::to_string_pretty(&redacted_manifest).map_err(|e| e.to_string())?,
    )
    .await
    .map_err(|e| e.to_string())?;
    let context_run_id = format!("{}:{}", task.id, Utc::now().timestamp_millis());
    let scoped_rows = db
        .list_rules(&project_id.to_string(), None)
        .await
        .map_err(|e| e.to_string())?;
    for row in scoped_rows {
        let included = row.active;
        let reason = if included { "active" } else { "disabled" };
        let _ = db
            .create_context_rule_usage(&ContextRuleUsageRow {
                id: Uuid::new_v4().to_string(),
                project_id: project_id.to_string(),
                run_id: context_run_id.clone(),
                rule_id: row.id,
                included,
                reason: reason.to_string(),
                created_at: Utc::now(),
            })
            .await;
    }

    let timeout_minutes = match provider.as_str() {
        "codex" => config
            .agents
            .codex
            .as_ref()
            .map(|c| c.timeout_minutes)
            .unwrap_or(20),
        _ => config
            .agents
            .claude_code
            .as_ref()
            .map(|c| c.timeout_minutes)
            .unwrap_or(30),
    };
    let model = match provider.as_str() {
        "codex" => config.agents.codex.as_ref().and_then(|c| c.model.clone()),
        _ => config
            .agents
            .claude_code
            .as_ref()
            .and_then(|c| c.model.clone()),
    };

    let handle = adapter
        .spawn(AgentConfig {
            provider: provider.clone(),
            model,
            env: secret_env,
            working_dir: lease.path.clone(),
            timeout_minutes,
            auto_approve: true, // worktree isolation is the safety boundary
            output_format: "stream-json".to_string(),
            context_file: Some(context_path.to_string_lossy().to_string()),
        })
        .await
        .map_err(|e| e.to_string())?;

    let agent_session_row = SessionRow {
        id: handle.id.to_string(),
        project_id: project_id.to_string(),
        name: format!("agent-{}", task.title),
        r#type: Some("agent".to_string()),
        status: "running".to_string(),
        pid: None,
        cwd: lease.path.clone(),
        command: provider.clone(),
        branch: Some(lease.branch.clone()),
        worktree_id: Some(worktree_row.id.clone()),
        started_at: Utc::now(),
        last_heartbeat: Utc::now(),
    };
    db.upsert_session(&agent_session_row)
        .await
        .map_err(|e| e.to_string())?;
    let pane = PaneRow {
        id: Uuid::new_v4().to_string(),
        project_id: project_id.to_string(),
        session_id: Some(handle.id.to_string()),
        r#type: "terminal".to_string(),
        position: "after:pane-board".to_string(),
        label: format!("Agent {}", task.title),
        metadata_json: Some("{\"read_only\":true}".to_string()),
    };
    db.upsert_pane(&pane).await.map_err(|e| e.to_string())?;
    let _ = app.emit(
        "session_spawned",
        json!({"session_id": handle.id.to_string(), "name": agent_session_row.name, "session": session_row_to_event_payload(&agent_session_row)}),
    );

    adapter
        .send(
            &handle,
            TaskPayload {
                task_id: task_id_uuid,
                objective: task.goal.clone(),
                constraints: task.constraints.clone(),
                project_rules: rules.clone(),
                worktree_path: lease.path.clone(),
                branch_name: lease.branch.clone(),
                acceptance_checks: task
                    .acceptance_criteria
                    .iter()
                    .map(|check| check.description.clone())
                    .collect(),
                relevant_file_paths: task.scope.clone(),
                prior_context_summary: None,
            },
        )
        .await
        .map_err(|e| e.to_string())?;

    let mut rx = adapter.events(&handle);
    let db_for_task = db.clone();
    let app_for_task = app.clone();
    let git_for_task = git.clone();
    let lease_task_id = task_id_uuid;
    let provider_for_task = provider.clone();
    let session_id = handle.id.to_string();
    let session_uuid_for_task = handle.id;
    let project_path_for_task = project_path.clone();
    let target_branch_for_task = config.branches.target.clone();
    let secret_values_for_task = secret_values.clone();

    tauri::async_runtime::spawn(async move {
        let mut last_summary: Option<String> = None;
        let mut failed = false;

        while let Ok(event) = rx.recv().await {
            match event {
                AgentEvent::OutputChunk(chunk) => {
                    let safe_chunk = redact_text(&chunk, &secret_values_for_task);
                    let _ = app_for_task.emit(
                        "session_output",
                        json!({"session_id": session_id, "chunk": safe_chunk.clone()}),
                    );
                    append_event(
                        &db_for_task,
                        project_id,
                        Some(lease_task_id),
                        None,
                        "agent",
                        "AgentOutputChunk",
                        json!({"chunk": safe_chunk.clone()}),
                    )
                    .await;
                    for attention in parse_osc_attention(&safe_chunk) {
                        let body = if attention.body.trim().is_empty() {
                            format!("OSC {} attention sequence received", attention.code)
                        } else {
                            attention.body
                        };
                        let _ = create_notification_row(
                            &db_for_task,
                            &app_for_task,
                            project_id,
                            Some(lease_task_id),
                            Some(session_uuid_for_task),
                            osc_title(&attention.code),
                            &body,
                            Some(osc_level(&attention.code)),
                            "osc",
                            &secret_values_for_task,
                        )
                        .await;
                    }
                }
                AgentEvent::ToolUse {
                    name,
                    input,
                    output,
                } => {
                    append_event(
                        &db_for_task,
                        project_id,
                        Some(lease_task_id),
                        None,
                        "agent",
                        "AgentToolUse",
                        json!({
                            "name": name,
                            "input": redact_text(&input, &secret_values_for_task),
                            "output": redact_text(&output, &secret_values_for_task)
                        }),
                    )
                    .await;
                }
                AgentEvent::UsageUpdate {
                    tokens_in,
                    tokens_out,
                    cost_usd,
                } => {
                    let _ = db_for_task
                        .append_cost(&CostRow {
                            id: Uuid::new_v4().to_string(),
                            agent_run_id: None,
                            task_id: lease_task_id.to_string(),
                            session_id: session_id.clone(),
                            provider: provider_for_task.clone(),
                            model: None,
                            tokens_in: tokens_in as i64,
                            tokens_out: tokens_out as i64,
                            estimated_usd: cost_usd,
                            tracked: true,
                            timestamp: Utc::now(),
                        })
                        .await;
                    let _ = app_for_task.emit(
                        "cost_updated",
                        json!({"task_id": lease_task_id.to_string(), "cost_usd": cost_usd}),
                    );
                }
                AgentEvent::Error(message) => {
                    failed = true;
                    last_summary = Some(redact_text(&message, &secret_values_for_task));
                    break;
                }
                AgentEvent::Complete { summary } => {
                    last_summary = Some(redact_text(&summary, &secret_values_for_task));
                    break;
                }
                AgentEvent::StatusChange(_) => {}
            }
        }
        drop(permit);
        if let Ok(Some(mut row)) = db_for_task.get_task(&lease_task_id.to_string()).await {
            let prev_status = parse_status(&row.status);
            row.handoff_summary = last_summary.clone();
            let mut next_status = if failed {
                TaskStatus::Failed
            } else {
                TaskStatus::InProgress
            };

            if !failed {
                if let Ok(task_contract) = task_row_to_contract(&row) {
                    match run_acceptance_checks_for_task(
                        &db_for_task,
                        project_id,
                        &project_path_for_task,
                        &task_contract,
                    )
                    .await
                    {
                        Ok((check_run, check_results, all_automated_passed)) => {
                            if all_automated_passed {
                                let cost = db_for_task
                                    .task_cost_total(&lease_task_id.to_string())
                                    .await
                                    .unwrap_or(0.0);
                                if generate_review_pack(
                                    &db_for_task,
                                    project_id,
                                    &project_path_for_task,
                                    &target_branch_for_task,
                                    &task_contract,
                                    &check_run,
                                    &check_results,
                                    cost,
                                    last_summary.as_deref(),
                                    &secret_values_for_task,
                                )
                                .await
                                .is_ok()
                                {
                                    next_status = TaskStatus::Review;
                                }
                            }
                        }
                        Err(err) => {
                            append_event(
                                &db_for_task,
                                project_id,
                                Some(lease_task_id),
                                None,
                                "core",
                                "AcceptanceCheckRunFailed",
                                json!({
                                    "task_id": lease_task_id,
                                    "error": redact_text(&err, &secret_values_for_task)
                                }),
                            )
                            .await;
                        }
                    }
                }
            }

            row.status = status_to_str(&next_status).to_string();
            row.updated_at = Utc::now();
            let _ = db_for_task.update_task(&row).await;
            if prev_status != next_status {
                append_event(
                    &db_for_task,
                    project_id,
                    Some(lease_task_id),
                    None,
                    "core",
                    "TaskStatusChanged",
                    json!({
                        "task_id": lease_task_id,
                        "from": status_to_str(&prev_status),
                        "to": status_to_str(&next_status),
                        "reason": "agent_completion"
                    }),
                )
                .await;
            }
            emit_enriched_task_event(&app_for_task, &db_for_task, &row.id).await;
        }
        if failed {
            let _ = cleanup_task_worktree(
                &db_for_task,
                &git_for_task,
                project_id,
                lease_task_id,
                Some(&app_for_task),
            )
            .await;
        }
        let _ = app_for_task.emit(
            "pool_updated",
            json!({"state": db_for_task.path().to_string_lossy()}),
        );
        append_event(
            &db_for_task,
            project_id,
            Some(lease_task_id),
            None,
            "agent",
            "AgentComplete",
            json!({
                "task_id": lease_task_id,
                "failed": failed,
                "handoff_summary": last_summary
            }),
        )
        .await;
    });

    Ok("started".to_string())
}

#[tauri::command]
pub async fn list_worktrees(state: State<'_, AppState>) -> Result<Vec<WorktreeView>, String> {
    let (project_id, db) = {
        let current = state.current.lock().await;
        let ctx = current
            .as_ref()
            .ok_or_else(|| "no open project".to_string())?;
        (ctx.project_id, ctx.db.clone())
    };

    let rows = db
        .list_worktrees(&project_id.to_string())
        .await
        .map_err(|e| e.to_string())?;
    Ok(rows
        .into_iter()
        .map(|row| WorktreeView {
            id: row.id,
            task_id: row.task_id,
            path: row.path,
            branch: row.branch,
            lease_status: row.lease_status,
            lease_started: row.lease_started,
            last_active: row.last_active,
        })
        .collect())
}

#[tauri::command]
pub async fn cleanup_worktree(
    task_id: String,
    app: AppHandle,
    state: State<'_, AppState>,
) -> Result<(), String> {
    let (project_id, db, git) = {
        let current = state.current.lock().await;
        let ctx = current
            .as_ref()
            .ok_or_else(|| "no open project".to_string())?;
        (ctx.project_id, ctx.db.clone(), ctx.git.clone())
    };

    let task_uuid = Uuid::parse_str(&task_id).map_err(|e| e.to_string())?;
    cleanup_task_worktree(&db, &git, project_id, task_uuid, Some(&app)).await
}

#[tauri::command]
pub async fn get_task_cost(task_id: String, state: State<'_, AppState>) -> Result<f64, String> {
    let current = state.current.lock().await;
    let ctx = current
        .as_ref()
        .ok_or_else(|| "no open project".to_string())?;
    ctx.db
        .task_cost_total(&task_id)
        .await
        .map_err(|e| e.to_string())
}

#[tauri::command]
pub async fn get_project_cost(
    project_id: String,
    state: State<'_, AppState>,
) -> Result<f64, String> {
    let current = state.current.lock().await;
    let ctx = current
        .as_ref()
        .ok_or_else(|| "no open project".to_string())?;

    let id = if project_id.is_empty() {
        ctx.project_id.to_string()
    } else {
        project_id
    };

    ctx.db
        .project_cost_total(&id)
        .await
        .map_err(|e| e.to_string())
}

// ─── Workflow commands ──────────────────────────────────────────

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct WorkflowDefView {
    pub name: String,
    pub description: Option<String>,
    pub steps: Vec<WorkflowStepView>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct WorkflowStepView {
    pub title: String,
    pub goal: String,
    pub scope: Vec<String>,
    pub priority: String,
    pub depends_on: Vec<usize>,
    pub auto_dispatch: bool,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct WorkflowInstanceView {
    pub id: String,
    pub workflow_name: String,
    pub description: Option<String>,
    pub status: String,
    pub task_ids: Vec<String>,
    pub created_at: DateTime<Utc>,
    pub updated_at: DateTime<Utc>,
}

#[tauri::command]
pub async fn list_workflow_defs(
    state: State<'_, AppState>,
) -> Result<Vec<WorkflowDefView>, String> {
    let current = state.current.lock().await;
    let ctx = current
        .as_ref()
        .ok_or_else(|| "no open project".to_string())?;
    let workflows_dir = ctx.project_path.join(".pnevma").join("workflows");
    let defs = WorkflowDef::load_all(&workflows_dir).map_err(|e| e.to_string())?;
    Ok(defs
        .into_iter()
        .map(|d| WorkflowDefView {
            name: d.name,
            description: d.description,
            steps: d
                .steps
                .into_iter()
                .map(|s| WorkflowStepView {
                    title: s.title,
                    goal: s.goal,
                    scope: s.scope,
                    priority: s.priority,
                    depends_on: s.depends_on,
                    auto_dispatch: s.auto_dispatch,
                })
                .collect(),
        })
        .collect())
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct InstantiateWorkflowInput {
    pub workflow_name: String,
}

#[tauri::command]
pub async fn instantiate_workflow(
    input: InstantiateWorkflowInput,
    app: AppHandle,
    state: State<'_, AppState>,
) -> Result<WorkflowInstanceView, String> {
    let (project_id, db, project_path) = {
        let current = state.current.lock().await;
        let ctx = current
            .as_ref()
            .ok_or_else(|| "no open project".to_string())?;
        (ctx.project_id, ctx.db.clone(), ctx.project_path.clone())
    };

    let workflows_dir = project_path.join(".pnevma").join("workflows");
    let defs = WorkflowDef::load_all(&workflows_dir).map_err(|e| e.to_string())?;
    let def = defs
        .into_iter()
        .find(|d| d.name == input.workflow_name)
        .ok_or_else(|| format!("workflow '{}' not found", input.workflow_name))?;

    let workflow_id = Uuid::new_v4();
    let now = Utc::now();

    // Create the workflow instance row.
    db.create_workflow_instance(&WorkflowInstanceRow {
        id: workflow_id.to_string(),
        project_id: project_id.to_string(),
        workflow_name: def.name.clone(),
        description: def.description.clone(),
        status: "Running".to_string(),
        created_at: now,
        updated_at: now,
    })
    .await
    .map_err(|e| e.to_string())?;

    // Create a task for each step, collecting IDs.
    let mut task_ids: Vec<Uuid> = Vec::with_capacity(def.steps.len());

    for (i, step) in def.steps.iter().enumerate() {
        let task_id = Uuid::new_v4();
        let deps_json: Vec<String> = step
            .depends_on
            .iter()
            .filter_map(|&idx| task_ids.get(idx).map(|id| id.to_string()))
            .collect();
        let checks: Vec<serde_json::Value> = step
            .acceptance_criteria
            .iter()
            .map(|desc| {
                serde_json::json!({
                    "description": desc,
                    "check_type": "ManualApproval",
                })
            })
            .collect();
        let has_deps = !step.depends_on.is_empty();
        let initial_status = if has_deps { "Blocked" } else { "Ready" };

        db.create_task(&TaskRow {
            id: task_id.to_string(),
            project_id: project_id.to_string(),
            title: step.title.clone(),
            goal: step.goal.clone(),
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
        })
        .await
        .map_err(|e| e.to_string())?;

        // Set task dependencies in the join table.
        if !deps_json.is_empty() {
            db.replace_task_dependencies(&task_id.to_string(), &deps_json)
                .await
                .map_err(|e| e.to_string())?;
        }

        // Link task to workflow instance.
        db.add_workflow_task(&workflow_id.to_string(), i as i64, &task_id.to_string())
            .await
            .map_err(|e| e.to_string())?;

        task_ids.push(task_id);
    }

    let _ = app.emit(
        "task_updated",
        serde_json::json!({"workflow_id": workflow_id.to_string()}),
    );

    Ok(WorkflowInstanceView {
        id: workflow_id.to_string(),
        workflow_name: def.name,
        description: def.description,
        status: "Running".to_string(),
        task_ids: task_ids.iter().map(|id| id.to_string()).collect(),
        created_at: now,
        updated_at: now,
    })
}

#[tauri::command]
pub async fn list_workflow_instances(
    state: State<'_, AppState>,
) -> Result<Vec<WorkflowInstanceView>, String> {
    let (project_id, db) = {
        let current = state.current.lock().await;
        let ctx = current
            .as_ref()
            .ok_or_else(|| "no open project".to_string())?;
        (ctx.project_id, ctx.db.clone())
    };

    let instances = db
        .list_workflow_instances(&project_id.to_string())
        .await
        .map_err(|e| e.to_string())?;

    let mut views = Vec::new();
    for inst in instances {
        let tasks = db
            .list_workflow_tasks(&inst.id)
            .await
            .map_err(|e| e.to_string())?;
        views.push(WorkflowInstanceView {
            id: inst.id,
            workflow_name: inst.workflow_name,
            description: inst.description,
            status: inst.status,
            task_ids: tasks.into_iter().map(|t| t.task_id).collect(),
            created_at: inst.created_at,
            updated_at: inst.updated_at,
        });
    }

    Ok(views)
}

#[tauri::command]
pub async fn pool_state(state: State<'_, AppState>) -> Result<(usize, usize, usize), String> {
    let current = state.current.lock().await;
    let ctx = current
        .as_ref()
        .ok_or_else(|| "no open project".to_string())?;
    Ok(ctx.pool.state().await)
}

// ─── SSH ─────────────────────────────────────────────────────────────────────

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct SshProfileInput {
    pub id: Option<String>,
    pub name: String,
    pub host: String,
    #[serde(default = "default_ssh_port")]
    pub port: u16,
    pub user: Option<String>,
    pub identity_file: Option<String>,
    pub proxy_jump: Option<String>,
    #[serde(default)]
    pub tags: Vec<String>,
    pub source: Option<String>,
}

fn default_ssh_port() -> u16 {
    22
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct SshProfileView {
    pub id: String,
    pub name: String,
    pub host: String,
    pub port: u16,
    pub user: Option<String>,
    pub identity_file: Option<String>,
    pub proxy_jump: Option<String>,
    pub tags: Vec<String>,
    pub source: String,
    pub created_at: DateTime<Utc>,
    pub updated_at: DateTime<Utc>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct SshKeyInfoView {
    pub name: String,
    pub path: String,
    pub key_type: String,
    pub fingerprint: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct GenerateSshKeyInput {
    pub name: String,
    pub key_type: Option<String>,
    pub comment: Option<String>,
}

fn ssh_profile_row_to_view(row: SshProfileRow) -> SshProfileView {
    let tags: Vec<String> = serde_json::from_str(&row.tags_json).unwrap_or_default();
    SshProfileView {
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
    }
}

fn ssh_profile_to_row(profile: &pnevma_ssh::SshProfile, project_id: &str) -> SshProfileRow {
    SshProfileRow {
        id: profile.id.clone(),
        project_id: project_id.to_string(),
        name: profile.name.clone(),
        host: profile.host.clone(),
        port: profile.port as i64,
        user: profile.user.clone(),
        identity_file: profile.identity_file.clone(),
        proxy_jump: profile.proxy_jump.clone(),
        tags_json: serde_json::to_string(&profile.tags).unwrap_or_else(|_| "[]".to_string()),
        source: profile.source.clone(),
        created_at: profile.created_at,
        updated_at: profile.updated_at,
    }
}

#[tauri::command]
pub async fn list_ssh_profiles(state: State<'_, AppState>) -> Result<Vec<SshProfileView>, String> {
    let current = state.current.lock().await;
    let ctx = current
        .as_ref()
        .ok_or_else(|| "no open project".to_string())?;
    let rows = ctx
        .db
        .list_ssh_profiles(&ctx.project_id.to_string())
        .await
        .map_err(|e| e.to_string())?;
    Ok(rows.into_iter().map(ssh_profile_row_to_view).collect())
}

#[tauri::command]
pub async fn upsert_ssh_profile(
    input: SshProfileInput,
    state: State<'_, AppState>,
) -> Result<String, String> {
    let current = state.current.lock().await;
    let ctx = current
        .as_ref()
        .ok_or_else(|| "no open project".to_string())?;
    let now = Utc::now();
    let id = input.id.unwrap_or_else(|| Uuid::new_v4().to_string());
    let tags_json = serde_json::to_string(&input.tags).unwrap_or_else(|_| "[]".to_string());
    let row = SshProfileRow {
        id: id.clone(),
        project_id: ctx.project_id.to_string(),
        name: input.name,
        host: input.host,
        port: input.port as i64,
        user: input.user,
        identity_file: input.identity_file,
        proxy_jump: input.proxy_jump,
        tags_json,
        source: input.source.unwrap_or_else(|| "manual".to_string()),
        created_at: now,
        updated_at: now,
    };
    ctx.db
        .upsert_ssh_profile(&row)
        .await
        .map_err(|e| e.to_string())?;
    Ok(id)
}

#[tauri::command]
pub async fn delete_ssh_profile(id: String, state: State<'_, AppState>) -> Result<(), String> {
    let current = state.current.lock().await;
    let ctx = current
        .as_ref()
        .ok_or_else(|| "no open project".to_string())?;
    ctx.db
        .delete_ssh_profile(&id)
        .await
        .map_err(|e| e.to_string())?;
    Ok(())
}

#[tauri::command]
pub async fn import_ssh_config(state: State<'_, AppState>) -> Result<Vec<SshProfileView>, String> {
    let current = state.current.lock().await;
    let ctx = current
        .as_ref()
        .ok_or_else(|| "no open project".to_string())?;
    let home = std::env::var("HOME").unwrap_or_else(|_| ".".to_string());
    let ssh_config_path = PathBuf::from(&home).join(".ssh/config");
    let profiles = pnevma_ssh::parse_ssh_config(&ssh_config_path).map_err(|e| e.to_string())?;
    let project_id = ctx.project_id.to_string();
    let mut views = Vec::new();
    for profile in &profiles {
        let row = ssh_profile_to_row(profile, &project_id);
        ctx.db
            .upsert_ssh_profile(&row)
            .await
            .map_err(|e| e.to_string())?;
        views.push(ssh_profile_row_to_view(row));
    }
    Ok(views)
}

#[tauri::command]
pub async fn discover_tailscale(state: State<'_, AppState>) -> Result<Vec<SshProfileView>, String> {
    let current = state.current.lock().await;
    let ctx = current
        .as_ref()
        .ok_or_else(|| "no open project".to_string())?;
    let profiles = pnevma_ssh::discover_tailscale_devices()
        .await
        .map_err(|e| e.to_string())?;
    let project_id = ctx.project_id.to_string();
    let mut views = Vec::new();
    for profile in &profiles {
        let row = ssh_profile_to_row(profile, &project_id);
        ctx.db
            .upsert_ssh_profile(&row)
            .await
            .map_err(|e| e.to_string())?;
        views.push(ssh_profile_row_to_view(row));
    }
    Ok(views)
}

#[tauri::command]
pub async fn connect_ssh(profile_id: String, state: State<'_, AppState>) -> Result<String, String> {
    let current = state.current.lock().await;
    let ctx = current
        .as_ref()
        .ok_or_else(|| "no open project".to_string())?;
    let row = ctx
        .db
        .get_ssh_profile(&profile_id)
        .await
        .map_err(|e| e.to_string())?;

    let tags: Vec<String> = serde_json::from_str(&row.tags_json).unwrap_or_default();
    let ssh_profile = pnevma_ssh::SshProfile {
        id: row.id.clone(),
        name: row.name.clone(),
        host: row.host.clone(),
        port: row.port as u16,
        user: row.user.clone(),
        identity_file: row.identity_file.clone(),
        proxy_jump: row.proxy_jump.clone(),
        tags,
        source: row.source.clone(),
        created_at: row.created_at,
        updated_at: row.updated_at,
    };

    let ssh_args = pnevma_ssh::build_ssh_command(&ssh_profile);
    let command = ssh_args.join(" ");

    let session = ctx
        .sessions
        .spawn_shell(
            ctx.project_id,
            format!("ssh-{}", row.name),
            ".".to_string(),
            command,
        )
        .await
        .map_err(|e| e.to_string())?;

    let mut session_row = session_row_from_meta(&session);
    session_row.r#type = Some("ssh".to_string());
    ctx.db
        .upsert_session(&session_row)
        .await
        .map_err(|e| e.to_string())?;

    let pane_row = PaneRow {
        id: Uuid::new_v4().to_string(),
        project_id: ctx.project_id.to_string(),
        session_id: Some(session.id.to_string()),
        r#type: "terminal".to_string(),
        position: "root".to_string(),
        label: row.name.clone(),
        metadata_json: None,
    };
    ctx.db
        .upsert_pane(&pane_row)
        .await
        .map_err(|e| e.to_string())?;

    Ok(session.id.to_string())
}

#[tauri::command]
pub async fn list_ssh_keys(state: State<'_, AppState>) -> Result<Vec<SshKeyInfoView>, String> {
    let _current = state.current.lock().await;
    let home = std::env::var("HOME").unwrap_or_else(|_| ".".to_string());
    let ssh_dir = PathBuf::from(&home).join(".ssh");
    let keys = pnevma_ssh::list_ssh_keys(&ssh_dir).map_err(|e| e.to_string())?;
    Ok(keys
        .into_iter()
        .map(|k| SshKeyInfoView {
            name: k.name,
            path: k.path,
            key_type: k.key_type,
            fingerprint: k.fingerprint,
        })
        .collect())
}

#[tauri::command]
pub async fn generate_ssh_key(
    input: GenerateSshKeyInput,
    state: State<'_, AppState>,
) -> Result<SshKeyInfoView, String> {
    let _current = state.current.lock().await;
    let home = std::env::var("HOME").unwrap_or_else(|_| ".".to_string());
    let ssh_dir = PathBuf::from(&home).join(".ssh");
    let key_type = input.key_type.as_deref().unwrap_or("ed25519");
    let comment = input.comment.as_deref().unwrap_or("");
    let key = pnevma_ssh::generate_key(&ssh_dir, &input.name, key_type, comment)
        .map_err(|e| e.to_string())?;
    Ok(SshKeyInfoView {
        name: key.name,
        path: key.path,
        key_type: key.key_type,
        fingerprint: key.fingerprint,
    })
}

#[cfg(test)]
mod tests {
    use super::{
        build_default_project_toml, is_supported_keybinding_action, normalize_layout_template_name,
        pane_contains_unsaved_metadata, parse_osc_attention, project_is_initialized, redact_text,
        session_state_may_be_unsaved,
    };
    use std::path::PathBuf;
    use uuid::Uuid;

    #[test]
    fn parses_osc_attention_sequences() {
        let chunk = "pre\x1b]9;build done\x07mid\x1b]99;needs input\x1b\\post";
        let items = parse_osc_attention(chunk);
        assert_eq!(items.len(), 2);
        assert_eq!(items[0].code, "9");
        assert_eq!(items[0].body, "build done");
        assert_eq!(items[1].code, "99");
        assert_eq!(items[1].body, "needs input");
    }

    #[test]
    fn redacts_known_secret_values_and_patterns() {
        let input = "Authorization: Bearer abc123 password=hunter2 token:xyz";
        let redacted = redact_text(input, &["abc123".to_string(), "hunter2".to_string()]);
        assert!(!redacted.contains("abc123"));
        assert!(!redacted.contains("hunter2"));
        assert!(!redacted.contains("xyz"));
        assert!(redacted.contains("[REDACTED]"));
    }

    #[test]
    fn normalizes_layout_template_names() {
        assert_eq!(
            normalize_layout_template_name("  Review Mode / Team A "),
            "review-mode-team-a"
        );
        assert_eq!(normalize_layout_template_name(""), "");
    }

    #[test]
    fn detects_unsaved_metadata_flags() {
        assert!(pane_contains_unsaved_metadata(Some(r#"{"unsaved":true}"#)));
        assert!(pane_contains_unsaved_metadata(Some(r#"{"dirty":true}"#)));
        assert!(!pane_contains_unsaved_metadata(Some(r#"{"dirty":false}"#)));
        assert!(!pane_contains_unsaved_metadata(Some("not-json")));
    }

    #[test]
    fn recognizes_running_session_states_as_unsaved() {
        assert!(session_state_may_be_unsaved("Running"));
        assert!(!session_state_may_be_unsaved("Exited"));
        assert!(!session_state_may_be_unsaved("Completed"));
    }

    #[test]
    fn default_project_toml_contains_required_sections() {
        let content = build_default_project_toml(
            PathBuf::from("/tmp/sample").as_path(),
            Some("Sample"),
            Some("Brief"),
            "claude-code",
        );
        assert!(content.contains("[project]"));
        assert!(content.contains("[agents]"));
        assert!(content.contains("[automation]"));
        assert!(content.contains("default_provider = \"claude-code\""));
    }

    #[test]
    fn project_initialized_requires_config_and_data_dir() {
        let root = std::env::temp_dir().join(format!("pnevma-init-test-{}", Uuid::new_v4()));
        let _ = std::fs::remove_dir_all(&root);
        std::fs::create_dir_all(root.join(".pnevma")).expect("create .pnevma");
        assert!(!project_is_initialized(&root));
        std::fs::write(
            root.join("pnevma.toml"),
            "[project]\nname=\"x\"\nbrief=\"y\"\n",
        )
        .expect("write config");
        assert!(project_is_initialized(&root));
        let _ = std::fs::remove_dir_all(&root);
    }

    #[test]
    fn keybinding_actions_are_allowlisted() {
        assert!(is_supported_keybinding_action("command_palette.toggle"));
        assert!(is_supported_keybinding_action("task.dispatch_next_ready"));
        assert!(is_supported_keybinding_action("review.approve_next"));
        assert!(!is_supported_keybinding_action("custom.unknown"));
    }
}
