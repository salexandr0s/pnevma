-- Reverse: recreate workflow_tasks without iteration column.
CREATE TABLE workflow_tasks_old (
    workflow_id TEXT NOT NULL REFERENCES workflow_instances(id) ON DELETE CASCADE,
    step_index  INTEGER NOT NULL,
    task_id     TEXT NOT NULL REFERENCES tasks(id) ON DELETE CASCADE,
    PRIMARY KEY (workflow_id, step_index)
);

INSERT INTO workflow_tasks_old (workflow_id, step_index, task_id)
    SELECT workflow_id, step_index, task_id FROM workflow_tasks WHERE iteration = 0;

DROP TABLE workflow_tasks;
ALTER TABLE workflow_tasks_old RENAME TO workflow_tasks;

CREATE INDEX IF NOT EXISTS idx_workflow_tasks_task ON workflow_tasks(task_id);

-- Drop loop columns from tasks (requires SQLite >= 3.35).
-- Iteration > 0 rows from workflow_tasks are intentionally dropped on rollback.
ALTER TABLE tasks DROP COLUMN loop_iteration;
ALTER TABLE tasks DROP COLUMN loop_context_json;
