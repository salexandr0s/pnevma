-- Intake queue: ingest external issues/PRs for triage
CREATE TABLE IF NOT EXISTS intake_queue (
    id              TEXT PRIMARY KEY NOT NULL,
    project_id      TEXT NOT NULL REFERENCES projects(id),
    kind            TEXT NOT NULL CHECK (kind IN ('issue', 'pull_request', 'task')),
    external_id     TEXT NOT NULL,
    identifier      TEXT NOT NULL,
    title           TEXT NOT NULL,
    url             TEXT NOT NULL DEFAULT '',
    state           TEXT NOT NULL DEFAULT 'open',
    priority        TEXT,
    labels_json     TEXT NOT NULL DEFAULT '[]',
    source_updated_at TEXT,
    ingested_at     TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
    status          TEXT NOT NULL DEFAULT 'pending' CHECK (status IN ('pending', 'accepted', 'rejected')),
    promoted_task_id TEXT REFERENCES tasks(id)
);

CREATE INDEX IF NOT EXISTS idx_intake_queue_project_status ON intake_queue(project_id, status);

-- Extend task_external_sources with optional metadata columns
ALTER TABLE task_external_sources ADD COLUMN title TEXT;
ALTER TABLE task_external_sources ADD COLUMN description TEXT;
ALTER TABLE task_external_sources ADD COLUMN labels_json TEXT NOT NULL DEFAULT '[]';
