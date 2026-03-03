CREATE TABLE IF NOT EXISTS task_stories (
    id TEXT PRIMARY KEY,
    task_id TEXT NOT NULL,
    sequence_number INTEGER NOT NULL,
    title TEXT NOT NULL,
    status TEXT NOT NULL DEFAULT 'pending',
    started_at TEXT,
    completed_at TEXT,
    output_summary TEXT,
    UNIQUE(task_id, sequence_number)
);

CREATE INDEX IF NOT EXISTS idx_task_stories_task ON task_stories(task_id, sequence_number);
