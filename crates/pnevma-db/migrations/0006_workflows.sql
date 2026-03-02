-- Workflow instances: tracks running workflow instantiations
CREATE TABLE IF NOT EXISTS workflow_instances (
    id              TEXT PRIMARY KEY,
    project_id      TEXT NOT NULL,
    workflow_name   TEXT NOT NULL,
    description     TEXT,
    status          TEXT NOT NULL DEFAULT 'Running',
    created_at      TEXT NOT NULL DEFAULT (datetime('now')),
    updated_at      TEXT NOT NULL DEFAULT (datetime('now'))
);

-- Join table: maps workflow instance steps to task IDs, with step ordering
CREATE TABLE IF NOT EXISTS workflow_tasks (
    workflow_id     TEXT NOT NULL REFERENCES workflow_instances(id) ON DELETE CASCADE,
    step_index      INTEGER NOT NULL,
    task_id         TEXT NOT NULL REFERENCES tasks(id) ON DELETE CASCADE,
    PRIMARY KEY (workflow_id, step_index)
);

CREATE INDEX IF NOT EXISTS idx_workflow_instances_project ON workflow_instances(project_id);
CREATE INDEX IF NOT EXISTS idx_workflow_tasks_task ON workflow_tasks(task_id);
