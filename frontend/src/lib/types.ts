export type Task = {
  id: string;
  project_id: string;
  title: string;
  goal: string;
  scope: string[];
  dependencies: string[];
  acceptance_criteria: Array<{
    description: string;
    check_type: "TestCommand" | "FileExists" | "ManualApproval";
    command?: string | null;
  }>;
  constraints: string[];
  priority: string;
  status: string;
  branch?: string | null;
  worktree_id?: string | null;
  handoff_summary?: string | null;
  auto_dispatch: boolean;
  agent_profile_override?: string | null;
  created_at: string;
  updated_at: string;
  queued_position?: number | null;
  cost_usd?: number | null;
};

export type Session = {
  id: string;
  project_id: string;
  name: string;
  status: string;
  pid?: number | null;
  cwd: string;
  command: string;
  started_at: string;
  last_heartbeat: string;
};

export type PaneType =
  | "terminal"
  | "task-board"
  | "review"
  | "merge-queue"
  | "replay"
  | "daily-brief"
  | "diff"
  | "search"
  | "file-browser"
  | "rules-manager"
  | "settings"
  | "notifications"
  | "ssh-manager"
  | "workflow"
  | "analytics";

export type Pane = {
  id: string;
  project_id?: string;
  type: PaneType;
  position?: string;
  label: string;
  session_id?: string | null;
  metadata_json?: string | null;
};

export type PaneLayoutTemplatePane = {
  id: string;
  session_id?: string | null;
  type: PaneType;
  position: string;
  label: string;
  metadata_json?: string | null;
};

export type PaneLayoutTemplate = {
  id: string;
  name: string;
  display_name: string;
  is_system: boolean;
  panes: PaneLayoutTemplatePane[];
  created_at: string;
  updated_at: string;
};

export type UnsavedPaneReplacement = {
  pane_id: string;
  pane_label: string;
  pane_type: string;
  reason: string;
};

export type ApplyPaneLayoutResult = {
  applied: boolean;
  template_name: string;
  replaced_panes: string[];
  unsaved_replacements: UnsavedPaneReplacement[];
};

export type ProjectStatus = {
  project_id: string;
  project_name: string;
  project_path: string;
  sessions: number;
  tasks: number;
  worktrees: number;
};

export type EnvironmentReadiness = {
  git_available: boolean;
  detected_adapters: string[];
  global_config_path: string;
  global_config_exists: boolean;
  project_path?: string | null;
  project_initialized: boolean;
  missing_steps: string[];
};

export type RecentProject = {
  id: string;
  name: string;
  path: string;
};

export type InitGlobalConfigResult = {
  created: boolean;
  path: string;
};

export type InitProjectScaffoldResult = {
  root_path: string;
  created_paths: string[];
  already_initialized: boolean;
};

export type CommandArgDescriptor = {
  name: string;
  label: string;
  required: boolean;
  default_value?: string | null;
  source?: string | null;
  description?: string | null;
};

export type RegisteredCommand = {
  id: string;
  label: string;
  description: string;
  args: CommandArgDescriptor[];
};

export type TaskCheckResult = {
  id: string;
  description: string;
  check_type: string;
  command?: string | null;
  passed: boolean;
  output?: string | null;
  created_at: string;
};

export type TaskCheckRun = {
  id: string;
  task_id: string;
  status: string;
  summary?: string | null;
  created_at: string;
  results: TaskCheckResult[];
};

export type ReviewPack = {
  task_id: string;
  status: string;
  review_pack_path: string;
  reviewer_notes?: string | null;
  approved_at?: string | null;
  pack: Record<string, unknown>;
};

export type MergeQueueItem = {
  id: string;
  task_id: string;
  task_title: string;
  status: string;
  blocked_reason?: string | null;
  approved_at: string;
  started_at?: string | null;
  completed_at?: string | null;
};

export type Notification = {
  id: string;
  task_id?: string | null;
  session_id?: string | null;
  title: string;
  body: string;
  level: string;
  unread: boolean;
  created_at: string;
};

export type TimelineEvent = {
  timestamp: string;
  kind: string;
  summary: string;
  payload: Record<string, unknown>;
};

export type SearchResult = {
  id: string;
  source: string;
  title: string;
  snippet: string;
  path?: string | null;
  task_id?: string | null;
  session_id?: string | null;
  timestamp?: string | null;
};

export type ProjectFile = {
  path: string;
  status: string;
  modified: boolean;
  staged: boolean;
  conflicted: boolean;
  untracked: boolean;
};

export type FileOpenResult = {
  path: string;
  content: string;
  truncated: boolean;
  launched_editor: boolean;
};

export type DiffHunk = {
  header: string;
  lines: string[];
};

export type DiffFile = {
  path: string;
  hunks: DiffHunk[];
};

export type TaskDiff = {
  task_id: string;
  diff_path: string;
  files: DiffFile[];
};

export type RuleEntry = {
  id: string;
  name: string;
  path: string;
  scope: string;
  active: boolean;
  content: string;
};

export type RuleUsage = {
  run_id: string;
  included: boolean;
  reason: string;
  created_at: string;
};

export type Artifact = {
  id: string;
  task_id?: string | null;
  type: string;
  path: string;
  description?: string | null;
  created_at: string;
};

export type Keybinding = {
  action: string;
  shortcut: string;
};

export type OnboardingState = {
  step: string;
  completed: boolean;
  dismissed: boolean;
  updated_at: string;
};

export type TelemetryStatus = {
  opted_in: boolean;
  queued_events: number;
};

export type Feedback = {
  id: string;
  category: string;
  body: string;
  contact?: string | null;
  artifact_path?: string | null;
  created_at: string;
};

export type PartnerMetricsReport = {
  generated_at: string;
  window_days: number;
  sessions_started: number;
  tasks_created: number;
  tasks_done: number;
  merges_completed: number;
  knowledge_captures: number;
  feedback_count: number;
  feedback_with_contact: number;
  telemetry_events: number;
  onboarding_completed: boolean;
  avg_task_cycle_hours?: number | null;
};

export type RecoveryOption = {
  id: string;
  label: string;
  description: string;
  enabled: boolean;
};

export type TaskCostEntry = {
  task_id: string;
  title: string;
  cost_usd: number;
};

export type DailyBrief = {
  generated_at: string;
  total_tasks: number;
  ready_tasks: number;
  review_tasks: number;
  blocked_tasks: number;
  failed_tasks: number;
  total_cost_usd: number;
  recent_events: TimelineEvent[];
  recommended_actions: string[];
  // Extended intelligence (optional for backward compat)
  active_sessions?: number;
  cost_last_24h_usd?: number;
  tasks_completed_last_24h?: number;
  tasks_failed_last_24h?: number;
  stale_ready_count?: number;
  longest_running_task?: string | null;
  top_cost_tasks?: TaskCostEntry[];
};

export type DraftTask = {
  title: string;
  goal: string;
  scope: string[];
  acceptance_criteria: string[];
  constraints: string[];
  dependencies: string[];
  priority: string;
  source: "provider" | "fallback";
  warnings: string[];
};

export type WorkflowDef = {
  name: string;
  description?: string | null;
  steps: WorkflowStep[];
};

export type WorkflowStep = {
  title: string;
  goal: string;
  scope: string[];
  priority: string;
  depends_on: number[];
  auto_dispatch: boolean;
};

export type WorkflowInstance = {
  id: string;
  workflow_name: string;
  description?: string | null;
  status: string;
  task_ids: string[];
  created_at: string;
  updated_at: string;
};

export type Workflow = {
  id: string;
  name: string;
  description?: string | null;
  source: string;
  created_at: string;
  updated_at: string;
};

export type FailurePolicy = "pause" | "retry_once" | "skip";

export type StageResult = {
  step_index: number;
  task_id: string;
  status: string;
  completed_at?: string | null;
};

export type SshProfile = {
  id: string;
  name: string;
  host: string;
  port: number;
  user?: string | null;
  identity_file?: string | null;
  proxy_jump?: string | null;
  tags: string[];
  source: string;
  created_at: string;
  updated_at: string;
};

export type SshKeyInfo = {
  name: string;
  path: string;
  key_type: string;
  fingerprint: string;
};

export type TrustRecord = {
  path: string;
  trusted_at: string;
  fingerprint: string;
};

export type UsageBreakdown = {
  provider: string;
  tokens_in: number;
  tokens_out: number;
  estimated_usd: number;
  record_count: number;
};

export type UsageByModel = {
  provider: string;
  model: string;
  tokens_in: number;
  tokens_out: number;
  estimated_usd: number;
};

export type UsageDailyTrend = {
  date: string;
  tokens_in: number;
  tokens_out: number;
  estimated_usd: number;
};

export type RiskLevel = "safe" | "caution" | "danger";

export type ActionKind =
  | "merge_to_target"
  | "delete_worktree_with_changes"
  | "force_push"
  | "delete_task_with_active_session"
  | "purge_scrollback"
  | "restart_stuck_agent"
  | "discard_review"
  | "redispatch_failed_task"
  | "bulk_delete_completed_tasks"
  | "create_task"
  | "dispatch_ready_task"
  | "open_pane"
  | "create_checkpoint";

export type ActionRiskInfo = {
  kind: ActionKind;
  risk_level: RiskLevel;
  description: string;
  consequences: string[];
  confirmation_phrase?: string | null;
};

export type ErrorSignature = {
  id: string;
  signature_hash: string;
  canonical_message: string;
  category: string;
  first_seen: string;
  last_seen: string;
  total_count: number;
  sample_output?: string | null;
  remediation_hint?: string | null;
};

export type ErrorTrendPoint = {
  date: string;
  count: number;
  signature_hash: string;
  category: string;
};

export type TaskStory = {
  id: string;
  task_id: string;
  sequence_number: number;
  title: string;
  status: string;
  started_at?: string | null;
  completed_at?: string | null;
  output_summary?: string | null;
};

export type StoryProgress = {
  total: number;
  completed: number;
  failed: number;
  in_progress: number;
};

export type AgentProfile = {
  id: string;
  name: string;
  provider: string;
  model: string;
  token_budget: number;
  timeout_minutes: number;
  max_concurrent: number;
  stations: string[];
  active: boolean;
  created_at: string;
  updated_at: string;
};

export type DispatchRecommendation = {
  profile_name: string;
  score: number;
  reason: string;
};
