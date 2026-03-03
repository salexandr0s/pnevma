-- Workflow definitions stored in DB (complement to YAML files on disk)
CREATE TABLE IF NOT EXISTS workflows (
    id TEXT PRIMARY KEY,
    project_id TEXT NOT NULL,
    name TEXT NOT NULL,
    description TEXT,
    definition_yaml TEXT NOT NULL,
    source TEXT NOT NULL DEFAULT 'user',
    created_at TEXT NOT NULL,
    updated_at TEXT NOT NULL,
    UNIQUE(project_id, name)
);

CREATE INDEX IF NOT EXISTS idx_workflows_project ON workflows(project_id);

-- Extend workflow_instances with new fields
ALTER TABLE workflow_instances ADD COLUMN params_json TEXT;
ALTER TABLE workflow_instances ADD COLUMN stage_results_json TEXT;
ALTER TABLE workflow_instances ADD COLUMN expanded_steps_json TEXT;
