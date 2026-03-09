CREATE TABLE automation_runs (
    id TEXT PRIMARY KEY,
    project_id TEXT NOT NULL REFERENCES projects(id) ON DELETE CASCADE,
    task_id TEXT NOT NULL REFERENCES tasks(id) ON DELETE CASCADE,
    run_id TEXT NOT NULL,
    origin TEXT NOT NULL,
    provider TEXT NOT NULL,
    model TEXT,
    status TEXT NOT NULL,
    attempt INTEGER NOT NULL DEFAULT 1,
    started_at TEXT NOT NULL,
    finished_at TEXT,
    duration_seconds REAL,
    tokens_in INTEGER DEFAULT 0,
    tokens_out INTEGER DEFAULT 0,
    cost_usd REAL DEFAULT 0.0,
    summary TEXT,
    error_message TEXT,
    created_at TEXT NOT NULL
);

CREATE TABLE automation_retries (
    id TEXT PRIMARY KEY,
    project_id TEXT NOT NULL REFERENCES projects(id) ON DELETE CASCADE,
    run_id TEXT NOT NULL REFERENCES automation_runs(id) ON DELETE CASCADE,
    task_id TEXT NOT NULL REFERENCES tasks(id) ON DELETE CASCADE,
    attempt INTEGER NOT NULL,
    reason TEXT NOT NULL,
    retry_after TEXT NOT NULL,
    retried_at TEXT,
    outcome TEXT,
    created_at TEXT NOT NULL
);

CREATE INDEX idx_automation_runs_project ON automation_runs(project_id);
CREATE INDEX idx_automation_runs_task ON automation_runs(task_id);
CREATE INDEX idx_automation_runs_status ON automation_runs(status);
CREATE INDEX idx_automation_retries_run ON automation_retries(run_id);
CREATE INDEX idx_automation_retries_task ON automation_retries(task_id);
