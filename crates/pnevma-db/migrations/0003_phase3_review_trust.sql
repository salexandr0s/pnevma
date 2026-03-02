CREATE TABLE IF NOT EXISTS check_runs (
  id TEXT PRIMARY KEY,
  project_id TEXT NOT NULL,
  task_id TEXT NOT NULL,
  status TEXT NOT NULL,
  summary TEXT,
  created_at TEXT NOT NULL,
  FOREIGN KEY (project_id) REFERENCES projects(id) ON DELETE CASCADE,
  FOREIGN KEY (task_id) REFERENCES tasks(id) ON DELETE CASCADE
);

CREATE TABLE IF NOT EXISTS check_results (
  id TEXT PRIMARY KEY,
  check_run_id TEXT NOT NULL,
  project_id TEXT NOT NULL,
  task_id TEXT NOT NULL,
  description TEXT NOT NULL,
  check_type TEXT NOT NULL,
  command TEXT,
  passed INTEGER NOT NULL,
  output TEXT,
  created_at TEXT NOT NULL,
  FOREIGN KEY (check_run_id) REFERENCES check_runs(id) ON DELETE CASCADE,
  FOREIGN KEY (project_id) REFERENCES projects(id) ON DELETE CASCADE,
  FOREIGN KEY (task_id) REFERENCES tasks(id) ON DELETE CASCADE
);

CREATE TABLE IF NOT EXISTS merge_queue (
  id TEXT PRIMARY KEY,
  project_id TEXT NOT NULL,
  task_id TEXT NOT NULL UNIQUE,
  status TEXT NOT NULL,
  blocked_reason TEXT,
  approved_at TEXT NOT NULL,
  started_at TEXT,
  completed_at TEXT,
  FOREIGN KEY (project_id) REFERENCES projects(id) ON DELETE CASCADE,
  FOREIGN KEY (task_id) REFERENCES tasks(id) ON DELETE CASCADE
);

CREATE TABLE IF NOT EXISTS notifications (
  id TEXT PRIMARY KEY,
  project_id TEXT NOT NULL,
  task_id TEXT,
  session_id TEXT,
  title TEXT NOT NULL,
  body TEXT NOT NULL,
  level TEXT NOT NULL,
  unread INTEGER NOT NULL,
  created_at TEXT NOT NULL,
  FOREIGN KEY (project_id) REFERENCES projects(id) ON DELETE CASCADE,
  FOREIGN KEY (task_id) REFERENCES tasks(id) ON DELETE SET NULL,
  FOREIGN KEY (session_id) REFERENCES sessions(id) ON DELETE SET NULL
);

CREATE TABLE IF NOT EXISTS secret_refs (
  id TEXT PRIMARY KEY,
  project_id TEXT,
  scope TEXT NOT NULL,
  name TEXT NOT NULL,
  keychain_service TEXT NOT NULL,
  keychain_account TEXT NOT NULL,
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL,
  UNIQUE (project_id, scope, name)
);

CREATE INDEX IF NOT EXISTS idx_check_runs_project_task
ON check_runs(project_id, task_id, created_at DESC);

CREATE INDEX IF NOT EXISTS idx_check_results_task
ON check_results(task_id, created_at DESC);

CREATE INDEX IF NOT EXISTS idx_merge_queue_project_status
ON merge_queue(project_id, status, approved_at ASC);

CREATE INDEX IF NOT EXISTS idx_notifications_project_unread
ON notifications(project_id, unread, created_at DESC);
