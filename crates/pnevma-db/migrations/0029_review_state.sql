-- Code review state tracking
CREATE TABLE IF NOT EXISTS review_files (
    id              TEXT PRIMARY KEY NOT NULL,
    project_id      TEXT NOT NULL REFERENCES projects(id),
    task_id         TEXT NOT NULL REFERENCES tasks(id),
    file_path       TEXT NOT NULL,
    status          TEXT NOT NULL DEFAULT 'pending',
    reviewer_notes  TEXT,
    created_at      TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
    updated_at      TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now'))
);

CREATE TABLE IF NOT EXISTS review_comments (
    id              TEXT PRIMARY KEY NOT NULL,
    project_id      TEXT NOT NULL REFERENCES projects(id),
    task_id         TEXT NOT NULL REFERENCES tasks(id),
    file_path       TEXT,
    line_number     INTEGER,
    body            TEXT NOT NULL,
    author          TEXT NOT NULL DEFAULT 'user',
    resolved        INTEGER NOT NULL DEFAULT 0,
    created_at      TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now'))
);

CREATE TABLE IF NOT EXISTS review_checklist_items (
    id              TEXT PRIMARY KEY NOT NULL,
    project_id      TEXT NOT NULL REFERENCES projects(id),
    task_id         TEXT NOT NULL REFERENCES tasks(id),
    label           TEXT NOT NULL,
    checked         INTEGER NOT NULL DEFAULT 0,
    sort_order      INTEGER NOT NULL DEFAULT 0,
    created_at      TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now'))
);

CREATE INDEX IF NOT EXISTS idx_review_files_task ON review_files(task_id);
CREATE INDEX IF NOT EXISTS idx_review_comments_task ON review_comments(task_id);
CREATE INDEX IF NOT EXISTS idx_review_checklist_task ON review_checklist_items(task_id);
