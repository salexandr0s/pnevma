import { invoke } from "@tauri-apps/api/core";
import type {
  ApplyPaneLayoutResult,
  Artifact,
  DailyBrief,
  EnvironmentReadiness,
  Feedback,
  FileOpenResult,
  InitGlobalConfigResult,
  InitProjectScaffoldResult,
  Keybinding,
  OnboardingState,
  PartnerMetricsReport,
  ProjectFile,
  DraftTask,
  MergeQueueItem,
  Notification,
  PaneLayoutTemplate,
  Pane,
  ProjectStatus,
  RecentProject,
  RegisteredCommand,
  RecoveryOption,
  ReviewPack,
  RuleEntry,
  RuleUsage,
  SearchResult,
  Session,
  SshKeyInfo,
  SshProfile,
  Task,
  TaskDiff,
  TaskCheckRun,
  TrustRecord,
  UsageBreakdown,
  UsageByModel,
  UsageDailyTrend,
  ErrorSignature,
  ErrorTrendPoint,
  WorkflowDef,
  WorkflowInstance,
  Workflow,
  TelemetryStatus,
  TimelineEvent,
  ActionRiskInfo,
  TaskStory,
  StoryProgress,
  AgentProfile,
  DispatchRecommendation,
} from "../lib/types";

type ScrollbackSlice = {
  session_id: string;
  start_offset: number;
  end_offset: number;
  total_bytes: number;
  data: string;
};

export async function openProject(path: string): Promise<string> {
  return invoke("open_project", { path });
}

export async function listRecentProjects(): Promise<RecentProject[]> {
  return invoke("list_recent_projects");
}

export async function closeProject(): Promise<void> {
  return invoke("close_project");
}

export async function trustWorkspace(path: string): Promise<void> {
  return invoke("trust_workspace", { path });
}

export async function revokeWorkspaceTrust(path: string): Promise<void> {
  return invoke("revoke_workspace_trust", { path });
}

export async function listTrustedWorkspaces(): Promise<TrustRecord[]> {
  return invoke("list_trusted_workspaces");
}

export async function getEnvironmentReadiness(
  path?: string
): Promise<EnvironmentReadiness> {
  return invoke("get_environment_readiness", { input: { path } });
}

export async function initializeGlobalConfig(
  defaultProvider?: string
): Promise<InitGlobalConfigResult> {
  return invoke("initialize_global_config", {
    input: { default_provider: defaultProvider },
  });
}

export async function initializeProjectScaffold(input: {
  path: string;
  project_name?: string;
  project_brief?: string;
  default_provider?: string;
}): Promise<InitProjectScaffoldResult> {
  return invoke("initialize_project_scaffold", { input });
}

export async function createSession(name: string, cwd: string, command: string): Promise<string> {
  return invoke("create_session", {
    input: { name, cwd, command },
  });
}

export async function listSessions(): Promise<Session[]> {
  return invoke("list_sessions");
}

export async function reattachSession(sessionId: string): Promise<void> {
  return invoke("reattach_session", { session_id: sessionId });
}

export async function restartSession(sessionId: string): Promise<string> {
  return invoke("restart_session", { session_id: sessionId });
}

export async function sendSessionInput(sessionId: string, input: string): Promise<void> {
  return invoke("send_session_input", { session_id: sessionId, input });
}

export async function resizeSession(sessionId: string, cols: number, rows: number): Promise<void> {
  return invoke("resize_session", { session_id: sessionId, cols, rows });
}

export async function getScrollback(
  sessionId: string,
  offset = 0,
  limit = 64 * 1024
): Promise<ScrollbackSlice> {
  return invoke("get_scrollback", {
    input: { session_id: sessionId, offset, limit },
  });
}

export async function restoreSessions() {
  return invoke("restore_sessions");
}

export async function listPanes(): Promise<Pane[]> {
  return invoke("list_panes");
}

export async function upsertPane(input: {
  id?: string;
  session_id?: string;
  type: string;
  position: string;
  label: string;
  metadata_json?: string;
}) {
  return invoke("upsert_pane", { input });
}

export async function removePane(paneId: string): Promise<void> {
  return invoke("remove_pane", { pane_id: paneId });
}

export async function listPaneLayoutTemplates(): Promise<PaneLayoutTemplate[]> {
  return invoke("list_pane_layout_templates");
}

export async function savePaneLayoutTemplate(
  name: string,
  displayName?: string
): Promise<PaneLayoutTemplate> {
  return invoke("save_pane_layout_template", {
    input: { name, display_name: displayName },
  });
}

export async function applyPaneLayoutTemplate(
  name: string,
  force = false
): Promise<ApplyPaneLayoutResult> {
  return invoke("apply_pane_layout_template", { input: { name, force } });
}

export async function queryEvents(input: {
  event_type?: string;
  session_id?: string;
  task_id?: string;
  from?: string;
  to?: string;
  limit?: number;
}) {
  return invoke("query_events", { input });
}

export async function searchProject(query: string, limit = 120): Promise<SearchResult[]> {
  return invoke("search_project", { input: { query, limit } });
}

export async function listRules(): Promise<RuleEntry[]> {
  return invoke("list_rules");
}

export async function listConventions(): Promise<RuleEntry[]> {
  return invoke("list_conventions");
}

export async function upsertRule(input: {
  id?: string;
  name: string;
  content: string;
  active?: boolean;
}): Promise<RuleEntry> {
  return invoke("upsert_rule", { input: { ...input, scope: "rule" } });
}

export async function upsertConvention(input: {
  id?: string;
  name: string;
  content: string;
  active?: boolean;
}): Promise<RuleEntry> {
  return invoke("upsert_convention", { input: { ...input, scope: "convention" } });
}

export async function toggleRule(id: string, active: boolean): Promise<RuleEntry> {
  return invoke("toggle_rule", { input: { id, active } });
}

export async function toggleConvention(id: string, active: boolean): Promise<RuleEntry> {
  return invoke("toggle_convention", { input: { id, active } });
}

export async function deleteRule(id: string): Promise<void> {
  return invoke("delete_rule", { id });
}

export async function deleteConvention(id: string): Promise<void> {
  return invoke("delete_convention", { id });
}

export async function listRuleUsage(ruleId: string, limit = 100): Promise<RuleUsage[]> {
  return invoke("list_rule_usage", { input: { rule_id: ruleId, limit } });
}

export async function getSessionTimeline(
  sessionId: string,
  limit = 500
): Promise<TimelineEvent[]> {
  return invoke("get_session_timeline", { input: { session_id: sessionId, limit } });
}

export async function listProjectFiles(
  query = "",
  limit = 1000
): Promise<ProjectFile[]> {
  return invoke("list_project_files", { input: { query, limit } });
}

export async function openFileTarget(
  path: string,
  mode: "preview" | "editor" = "preview"
): Promise<FileOpenResult> {
  return invoke("open_file_target", { input: { path, mode } });
}

export async function getSessionRecoveryOptions(sessionId: string): Promise<RecoveryOption[]> {
  return invoke("get_session_recovery_options", { session_id: sessionId });
}

export async function recoverSession(
  sessionId: string,
  action: string
): Promise<Record<string, unknown>> {
  return invoke("recover_session", { input: { session_id: sessionId, action } });
}

export async function createTask(input: {
  title: string;
  goal: string;
  scope: string[];
  acceptance_criteria: string[];
  constraints?: string[];
  dependencies?: string[];
  priority: string;
}) {
  return invoke("create_task", { input });
}

export async function listTasks(): Promise<Task[]> {
  return invoke("list_tasks");
}

export async function getTask(taskId: string): Promise<Task> {
  return invoke("get_task", { task_id: taskId });
}

export async function updateTask(input: {
  id: string;
  title?: string;
  goal?: string;
  scope?: string[];
  acceptance_criteria?: string[];
  constraints?: string[];
  dependencies?: string[];
  priority?: string;
  status?: string;
  handoff_summary?: string;
}): Promise<Task> {
  return invoke("update_task", { input });
}

export async function deleteTask(taskId: string): Promise<void> {
  return invoke("delete_task", { task_id: taskId });
}

export async function dispatchTask(taskId: string): Promise<string> {
  return invoke("dispatch_task", { task_id: taskId });
}

export async function runTaskChecks(taskId: string): Promise<TaskCheckRun> {
  return invoke("run_task_checks", { task_id: taskId });
}

export async function getTaskCheckResults(taskId: string): Promise<TaskCheckRun | null> {
  return invoke("get_task_check_results", { task_id: taskId });
}

export async function getReviewPack(taskId: string): Promise<ReviewPack | null> {
  return invoke("get_review_pack", { task_id: taskId });
}

export async function getTaskDiff(taskId: string): Promise<TaskDiff | null> {
  return invoke("get_task_diff", { input: { task_id: taskId } });
}

export async function captureKnowledge(input: {
  task_id?: string;
  kind: "adr" | "changelog" | "convention-update";
  title?: string;
  content: string;
}): Promise<Artifact> {
  return invoke("capture_knowledge", { input });
}

export async function listArtifacts(): Promise<Artifact[]> {
  return invoke("list_artifacts");
}

export async function approveReview(taskId: string, note?: string): Promise<void> {
  return invoke("approve_review", { input: { task_id: taskId, note } });
}

export async function rejectReview(taskId: string, note?: string): Promise<void> {
  return invoke("reject_review", { input: { task_id: taskId, note } });
}

export async function listMergeQueue(): Promise<MergeQueueItem[]> {
  return invoke("list_merge_queue");
}

export async function executeMergeQueue(taskId: string): Promise<void> {
  return invoke("merge_queue_execute", { task_id: taskId });
}

export async function moveMergeQueueItem(
  taskId: string,
  direction: "up" | "down"
): Promise<MergeQueueItem[]> {
  return invoke("move_merge_queue_item", { input: { task_id: taskId, direction } });
}

export async function listNotifications(unreadOnly = false): Promise<Notification[]> {
  return invoke("list_notifications", { input: { unread_only: unreadOnly } });
}

export async function markNotificationRead(notificationId: string): Promise<void> {
  return invoke("mark_notification_read", { notification_id: notificationId });
}

export async function clearNotifications(): Promise<void> {
  return invoke("clear_notifications");
}

export async function getProjectCost(projectId = ""): Promise<number> {
  return invoke("get_project_cost", { project_id: projectId });
}

export async function projectStatus(): Promise<ProjectStatus> {
  return invoke("project_status");
}

export async function getDailyBrief(): Promise<DailyBrief> {
  return invoke("get_daily_brief");
}

export async function draftTaskContract(text: string): Promise<DraftTask> {
  return invoke("draft_task_contract", { input: { text } });
}

export async function listKeybindings(): Promise<Keybinding[]> {
  return invoke("list_keybindings");
}

export async function setKeybinding(action: string, shortcut: string): Promise<Keybinding[]> {
  return invoke("set_keybinding", { input: { action, shortcut } });
}

export async function resetKeybindings(): Promise<Keybinding[]> {
  return invoke("reset_keybindings");
}

export async function getOnboardingState(): Promise<OnboardingState> {
  return invoke("get_onboarding_state");
}

export async function advanceOnboardingStep(input: {
  step: string;
  completed?: boolean;
  dismissed?: boolean;
}): Promise<OnboardingState> {
  return invoke("advance_onboarding_step", { input });
}

export async function resetOnboarding(): Promise<OnboardingState> {
  return invoke("reset_onboarding");
}

export async function getTelemetryStatus(): Promise<TelemetryStatus> {
  return invoke("get_telemetry_status");
}

export async function setTelemetryOptIn(optedIn: boolean): Promise<TelemetryStatus> {
  return invoke("set_telemetry_opt_in", { input: { opted_in: optedIn } });
}

export async function exportTelemetryBundle(path?: string, limit = 10000): Promise<string> {
  return invoke("export_telemetry_bundle", { input: { path, limit } });
}

export async function clearTelemetry(): Promise<void> {
  return invoke("clear_telemetry");
}

export async function submitFeedback(input: {
  category: string;
  body: string;
  contact?: string;
}): Promise<Feedback> {
  return invoke("submit_feedback", { input });
}

export async function partnerMetricsReport(days = 14): Promise<PartnerMetricsReport> {
  return invoke("partner_metrics_report", { input: { days } });
}

export async function listRegisteredCommands(): Promise<RegisteredCommand[]> {
  return invoke("list_registered_commands");
}

export async function executeRegisteredCommand(
  id: string,
  args: Record<string, string>
): Promise<Record<string, unknown>> {
  return invoke("execute_registered_command", { input: { id, args } });
}

// ─── Workflows ──────────────────────────────────────────────────

export async function listWorkflowDefs(): Promise<WorkflowDef[]> {
  return invoke("list_workflow_defs");
}

export async function instantiateWorkflow(
  workflowName: string
): Promise<WorkflowInstance> {
  return invoke("instantiate_workflow", {
    input: { workflow_name: workflowName },
  });
}

export async function listWorkflowInstances(): Promise<WorkflowInstance[]> {
  return invoke("list_workflow_instances");
}

export async function listWorkflows(): Promise<Workflow[]> {
  return invoke("list_workflows");
}

export async function getWorkflow(id: string): Promise<Workflow> {
  return invoke("get_workflow", { id });
}

export async function createWorkflow(input: {
  name: string;
  description?: string;
  definition_yaml: string;
}): Promise<Workflow> {
  return invoke("create_workflow", { input });
}

export async function updateWorkflow(input: {
  id: string;
  name?: string;
  description?: string;
  definition_yaml?: string;
}): Promise<Workflow> {
  return invoke("update_workflow", { input });
}

export async function deleteWorkflow(id: string): Promise<void> {
  return invoke("delete_workflow", { id });
}

export async function dispatchWorkflow(
  workflowName: string,
  params?: Record<string, unknown>
): Promise<WorkflowInstance> {
  return invoke("dispatch_workflow", {
    input: { workflow_name: workflowName, params },
  });
}

// ─── SSH ──────────────────────────────────────────────────

export async function listSshProfiles(): Promise<SshProfile[]> {
  return invoke("list_ssh_profiles");
}

export async function upsertSshProfile(input: {
  id?: string;
  name: string;
  host: string;
  port?: number;
  user?: string;
  identity_file?: string;
  proxy_jump?: string;
  tags?: string[];
  source?: string;
}): Promise<string> {
  return invoke("upsert_ssh_profile", { input });
}

export async function deleteSshProfile(id: string): Promise<void> {
  return invoke("delete_ssh_profile", { id });
}

export async function importSshConfig(): Promise<SshProfile[]> {
  return invoke("import_ssh_config");
}

export async function discoverTailscale(): Promise<SshProfile[]> {
  return invoke("discover_tailscale");
}

export async function connectSsh(profileId: string): Promise<string> {
  return invoke("connect_ssh", { profile_id: profileId });
}

export async function listSshKeys(): Promise<SshKeyInfo[]> {
  return invoke("list_ssh_keys");
}

export async function generateSshKey(input: {
  name: string;
  key_type?: string;
  comment?: string;
}): Promise<SshKeyInfo> {
  return invoke("generate_ssh_key", { input });
}

// ─── Analytics / Cost Aggregation ──────────────────────────────────────────

export async function getUsageBreakdown(days = 30): Promise<UsageBreakdown[]> {
  return invoke("get_usage_breakdown", { days });
}

export async function getUsageByModel(): Promise<UsageByModel[]> {
  return invoke("get_usage_by_model");
}

export async function getUsageDailyTrend(days = 30): Promise<UsageDailyTrend[]> {
  return invoke("get_usage_daily_trend", { days });
}

export async function checkActionRisk(actionKind: string): Promise<ActionRiskInfo> {
  return invoke("check_action_risk", { action_kind: actionKind });
}

export async function listErrorSignatures(
  limit = 50,
): Promise<ErrorSignature[]> {
  return invoke("list_error_signatures", { limit });
}

export async function getErrorSignature(
  id: string,
): Promise<ErrorSignature | null> {
  return invoke("get_error_signature", { id });
}

export async function getErrorTrend(days = 30): Promise<ErrorTrendPoint[]> {
  return invoke("get_error_trend", { days });
}

export async function listTaskStories(taskId: string): Promise<TaskStory[]> {
  return invoke("list_task_stories", { task_id: taskId });
}

export async function createStoriesForTask(taskId: string, stories: Array<{ title: string }>): Promise<TaskStory[]> {
  return invoke("create_stories_for_task", { input: { task_id: taskId, stories } });
}

export async function updateStoryStatus(id: string, status: string, outputSummary?: string): Promise<void> {
  return invoke("update_story_status", { input: { id, status, output_summary: outputSummary } });
}

export async function getTaskStoryProgress(taskId: string): Promise<StoryProgress> {
  return invoke("get_task_story_progress", { task_id: taskId });
}

export async function listAgentProfiles(): Promise<AgentProfile[]> {
  return invoke("list_agent_profiles");
}

export async function getDispatchRecommendation(taskId: string): Promise<DispatchRecommendation[]> {
  return invoke("get_dispatch_recommendation", { task_id: taskId });
}

export async function overrideTaskProfile(taskId: string, profileName: string): Promise<string> {
  return invoke("override_task_profile", { task_id: taskId, profile_name: profileName });
}

export async function getAgentTeam(): Promise<AgentProfile[]> {
  return invoke("get_agent_team");
}
