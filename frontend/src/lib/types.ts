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

export type PaneType = "terminal" | "task-board" | "review" | "diff" | "search" | "settings";

export type Pane = {
  id: string;
  project_id?: string;
  type: PaneType;
  position?: string;
  label: string;
  session_id?: string | null;
  metadata_json?: string | null;
};

export type ProjectStatus = {
  project_id: string;
  project_name: string;
  project_path: string;
  sessions: number;
  tasks: number;
  worktrees: number;
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
