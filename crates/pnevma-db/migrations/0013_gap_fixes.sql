-- Gap 2: auto_dispatch flag on tasks
ALTER TABLE tasks ADD COLUMN auto_dispatch INTEGER NOT NULL DEFAULT 0;

-- Gap 5: profile override on tasks
ALTER TABLE tasks ADD COLUMN agent_profile_override TEXT;

-- Gap 3: FTS5 virtual tables for full-text search
CREATE VIRTUAL TABLE IF NOT EXISTS tasks_fts USING fts5(
    title, goal, content=tasks, content_rowid=rowid
);
CREATE VIRTUAL TABLE IF NOT EXISTS events_fts USING fts5(
    event_type, source, payload_json, content=events, content_rowid=rowid
);

-- Triggers to keep FTS in sync with tasks (idempotent)
DROP TRIGGER IF EXISTS tasks_fts_insert;
CREATE TRIGGER tasks_fts_insert AFTER INSERT ON tasks BEGIN
    INSERT INTO tasks_fts(rowid, title, goal) VALUES (NEW.rowid, NEW.title, NEW.goal);
END;
DROP TRIGGER IF EXISTS tasks_fts_update;
CREATE TRIGGER tasks_fts_update AFTER UPDATE OF title, goal ON tasks BEGIN
    DELETE FROM tasks_fts WHERE rowid = OLD.rowid;
    INSERT INTO tasks_fts(rowid, title, goal) VALUES (NEW.rowid, NEW.title, NEW.goal);
END;
DROP TRIGGER IF EXISTS tasks_fts_delete;
CREATE TRIGGER tasks_fts_delete AFTER DELETE ON tasks BEGIN
    DELETE FROM tasks_fts WHERE rowid = OLD.rowid;
END;

-- Triggers to keep FTS in sync with events (idempotent)
DROP TRIGGER IF EXISTS events_fts_insert;
CREATE TRIGGER events_fts_insert AFTER INSERT ON events BEGIN
    INSERT INTO events_fts(rowid, event_type, source, payload_json)
    VALUES (NEW.rowid, NEW.event_type, NEW.source, NEW.payload_json);
END;

-- Backfill existing data into FTS tables (idempotent)
DELETE FROM tasks_fts;
INSERT INTO tasks_fts(rowid, title, goal)
    SELECT rowid, title, goal FROM tasks;
DELETE FROM events_fts;
INSERT INTO events_fts(rowid, event_type, source, payload_json)
    SELECT rowid, event_type, source, payload_json FROM events;
