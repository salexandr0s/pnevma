-- Rollback for 0011_workflow_engine.sql
--
-- NOTE: The ALTER TABLE ADD COLUMN statements for workflow_instances
-- (params_json, stage_results_json, expanded_steps_json) cannot be trivially
-- rolled back with DROP COLUMN on SQLite < 3.35.
-- For SQLite >= 3.35:

ALTER TABLE workflow_instances DROP COLUMN expanded_steps_json;
ALTER TABLE workflow_instances DROP COLUMN stage_results_json;
ALTER TABLE workflow_instances DROP COLUMN params_json;

-- NOTE: For SQLite < 3.35, recreate workflow_instances without the added columns:
--   CREATE TABLE workflow_instances_new (
--     id TEXT PRIMARY KEY, project_id TEXT NOT NULL, workflow_name TEXT NOT NULL,
--     description TEXT, status TEXT NOT NULL DEFAULT 'Running',
--     created_at TEXT NOT NULL DEFAULT (datetime('now')),
--     updated_at TEXT NOT NULL DEFAULT (datetime('now'))
--   );
--   INSERT INTO workflow_instances_new SELECT id, project_id, workflow_name, description,
--     status, created_at, updated_at FROM workflow_instances;
--   DROP TABLE workflow_instances;
--   ALTER TABLE workflow_instances_new RENAME TO workflow_instances;

DROP INDEX IF EXISTS idx_workflows_project;
DROP TABLE IF EXISTS workflows;
