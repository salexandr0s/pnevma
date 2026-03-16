-- Task lineage (fork tracking)
ALTER TABLE tasks ADD COLUMN forked_from_task_id TEXT REFERENCES tasks(id);
ALTER TABLE tasks ADD COLUMN lineage_summary TEXT;
ALTER TABLE tasks ADD COLUMN lineage_depth INTEGER NOT NULL DEFAULT 0;

CREATE TABLE IF NOT EXISTS task_lineage (
    id              TEXT PRIMARY KEY NOT NULL,
    project_id      TEXT NOT NULL REFERENCES projects(id),
    parent_task_id  TEXT NOT NULL REFERENCES tasks(id),
    child_task_id   TEXT NOT NULL REFERENCES tasks(id),
    fork_reason     TEXT,
    created_at      TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
    UNIQUE(parent_task_id, child_task_id)
);

CREATE INDEX IF NOT EXISTS idx_task_lineage_parent ON task_lineage(parent_task_id);
CREATE INDEX IF NOT EXISTS idx_task_lineage_child ON task_lineage(child_task_id);
