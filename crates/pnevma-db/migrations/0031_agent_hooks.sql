-- Agent hooks (pre/post dispatch lifecycle hooks)
CREATE TABLE IF NOT EXISTS agent_hooks (
    id              TEXT PRIMARY KEY NOT NULL,
    project_id      TEXT NOT NULL REFERENCES projects(id),
    name            TEXT NOT NULL,
    hook_type       TEXT NOT NULL CHECK (hook_type IN ('pre_dispatch', 'post_dispatch', 'on_error', 'on_complete')),
    command         TEXT NOT NULL,
    timeout_seconds INTEGER NOT NULL DEFAULT 30,
    enabled         INTEGER NOT NULL DEFAULT 1,
    sort_order      INTEGER NOT NULL DEFAULT 0,
    created_at      TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
    updated_at      TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now'))
);

CREATE INDEX IF NOT EXISTS idx_agent_hooks_project ON agent_hooks(project_id, hook_type);
