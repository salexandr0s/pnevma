CREATE TABLE IF NOT EXISTS task_external_sources (
    id TEXT PRIMARY KEY,
    project_id TEXT NOT NULL REFERENCES projects(id) ON DELETE CASCADE,
    task_id TEXT NOT NULL REFERENCES tasks(id) ON DELETE CASCADE,
    kind TEXT NOT NULL,
    external_id TEXT NOT NULL,
    identifier TEXT NOT NULL,
    url TEXT NOT NULL,
    state TEXT NOT NULL,
    synced_at TEXT NOT NULL,
    UNIQUE(project_id, kind, external_id)
);

CREATE INDEX IF NOT EXISTS idx_external_sources_project ON task_external_sources(project_id);
CREATE INDEX IF NOT EXISTS idx_external_sources_task ON task_external_sources(task_id);
CREATE INDEX IF NOT EXISTS idx_external_sources_external ON task_external_sources(kind, external_id);
