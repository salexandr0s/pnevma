ALTER TABLE panes ADD COLUMN project_id TEXT;

UPDATE panes
SET project_id = (
  SELECT sessions.project_id
  FROM sessions
  WHERE sessions.id = panes.session_id
)
WHERE project_id IS NULL;

ALTER TABLE events ADD COLUMN task_id TEXT;
ALTER TABLE events ADD COLUMN session_id TEXT;

CREATE INDEX IF NOT EXISTS idx_events_project_time
ON events(project_id, timestamp);

CREATE INDEX IF NOT EXISTS idx_events_project_session_time
ON events(project_id, session_id, timestamp);

CREATE INDEX IF NOT EXISTS idx_events_project_task_time
ON events(project_id, task_id, timestamp);

CREATE INDEX IF NOT EXISTS idx_events_project_type_time
ON events(project_id, event_type, timestamp);
