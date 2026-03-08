-- Add iteration column to workflow_tasks for loop support.
-- Recreate the table because PRIMARY KEY includes new column.
CREATE TABLE workflow_tasks_new (
    workflow_id TEXT NOT NULL REFERENCES workflow_instances(id) ON DELETE CASCADE,
    step_index  INTEGER NOT NULL,
    iteration   INTEGER NOT NULL DEFAULT 0,
    task_id     TEXT NOT NULL REFERENCES tasks(id) ON DELETE CASCADE,
    PRIMARY KEY (workflow_id, step_index, iteration)
);

INSERT INTO workflow_tasks_new (workflow_id, step_index, task_id, iteration)
    SELECT workflow_id, step_index, task_id, 0 FROM workflow_tasks;

DROP TABLE workflow_tasks;
ALTER TABLE workflow_tasks_new RENAME TO workflow_tasks;

CREATE INDEX IF NOT EXISTS idx_workflow_tasks_task ON workflow_tasks(task_id);

-- Add loop context columns to tasks.
ALTER TABLE tasks ADD COLUMN loop_iteration INTEGER NOT NULL DEFAULT 0;
ALTER TABLE tasks ADD COLUMN loop_context_json TEXT;
