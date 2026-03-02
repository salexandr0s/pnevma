CREATE TABLE IF NOT EXISTS context_rule_usage (
  id TEXT PRIMARY KEY,
  project_id TEXT NOT NULL,
  run_id TEXT NOT NULL,
  rule_id TEXT NOT NULL,
  included INTEGER NOT NULL,
  reason TEXT NOT NULL,
  created_at TEXT NOT NULL,
  FOREIGN KEY (project_id) REFERENCES projects(id) ON DELETE CASCADE,
  FOREIGN KEY (rule_id) REFERENCES rules(id) ON DELETE CASCADE
);

CREATE INDEX IF NOT EXISTS idx_context_rule_usage_rule
ON context_rule_usage(project_id, rule_id, created_at DESC);

CREATE TABLE IF NOT EXISTS onboarding_state (
  project_id TEXT PRIMARY KEY,
  step TEXT NOT NULL,
  completed INTEGER NOT NULL,
  dismissed INTEGER NOT NULL,
  updated_at TEXT NOT NULL,
  FOREIGN KEY (project_id) REFERENCES projects(id) ON DELETE CASCADE
);

CREATE TABLE IF NOT EXISTS telemetry_events (
  id TEXT PRIMARY KEY,
  project_id TEXT NOT NULL,
  event_type TEXT NOT NULL,
  payload_json TEXT NOT NULL,
  anonymized INTEGER NOT NULL,
  created_at TEXT NOT NULL,
  FOREIGN KEY (project_id) REFERENCES projects(id) ON DELETE CASCADE
);

CREATE INDEX IF NOT EXISTS idx_telemetry_events_project_time
ON telemetry_events(project_id, created_at DESC);

CREATE TABLE IF NOT EXISTS feedback_entries (
  id TEXT PRIMARY KEY,
  project_id TEXT NOT NULL,
  category TEXT NOT NULL,
  body TEXT NOT NULL,
  contact TEXT,
  artifact_path TEXT,
  created_at TEXT NOT NULL,
  FOREIGN KEY (project_id) REFERENCES projects(id) ON DELETE CASCADE
);

CREATE INDEX IF NOT EXISTS idx_feedback_entries_project_time
ON feedback_entries(project_id, created_at DESC);
