-- Session restore tracking
ALTER TABLE sessions ADD COLUMN restore_status TEXT;
ALTER TABLE sessions ADD COLUMN exit_code INTEGER;
ALTER TABLE sessions ADD COLUMN ended_at TEXT;

CREATE TABLE IF NOT EXISTS session_restore_log (
    id              TEXT PRIMARY KEY NOT NULL,
    session_id      TEXT NOT NULL REFERENCES sessions(id),
    project_id      TEXT NOT NULL REFERENCES projects(id),
    action          TEXT NOT NULL,
    outcome         TEXT NOT NULL,
    error_message   TEXT,
    created_at      TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now'))
);

CREATE INDEX IF NOT EXISTS idx_session_restore_log_session ON session_restore_log(session_id);
