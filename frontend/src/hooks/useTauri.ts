import { invoke } from "@tauri-apps/api/core";
import type { Pane, ProjectStatus, RegisteredCommand, Session, Task } from "../lib/types";

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

export async function getProjectCost(projectId = ""): Promise<number> {
  return invoke("get_project_cost", { project_id: projectId });
}

export async function projectStatus(): Promise<ProjectStatus> {
  return invoke("project_status");
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
