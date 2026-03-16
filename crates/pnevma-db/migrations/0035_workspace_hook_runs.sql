-- Workspace hook execution log
CREATE TABLE IF NOT EXISTS workspace_hook_runs (
    id              TEXT PRIMARY KEY NOT NULL,
    project_id      TEXT NOT NULL REFERENCES projects(id),
    hook_name       TEXT NOT NULL,
    phase           TEXT NOT NULL,
    trigger_event   TEXT,
    status          TEXT NOT NULL DEFAULT 'running',
    exit_code       INTEGER,
    stdout          TEXT,
    stderr          TEXT,
    duration_ms     INTEGER,
    started_at      TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
    completed_at    TEXT
);

CREATE INDEX IF NOT EXISTS idx_workspace_hook_runs_project ON workspace_hook_runs(project_id, hook_name);
