-- Port allocation tracking for dev servers
CREATE TABLE IF NOT EXISTS port_allocations (
    id              TEXT PRIMARY KEY NOT NULL,
    project_id      TEXT NOT NULL REFERENCES projects(id),
    task_id         TEXT REFERENCES tasks(id),
    session_id      TEXT REFERENCES sessions(id),
    port            INTEGER NOT NULL,
    protocol        TEXT NOT NULL DEFAULT 'tcp',
    label           TEXT,
    allocated_at    TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
    released_at     TEXT,
    UNIQUE(project_id, port)
);

CREATE INDEX IF NOT EXISTS idx_port_allocations_project ON port_allocations(project_id);
