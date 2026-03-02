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
  | "notifications";

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
