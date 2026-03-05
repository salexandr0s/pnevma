-- Rollback for 0002_phase1_layout_and_event_filters.sql
--
-- NOTE: SQLite does not support ALTER TABLE DROP COLUMN prior to version 3.35.
-- For environments with SQLite < 3.35, dropping these columns requires recreating
-- the table. Below we provide DROP COLUMN statements; if they fail, recreate the
-- table without those columns using the pattern:
--   CREATE TABLE new_table AS SELECT ... (columns minus the dropped ones) FROM old_table;
--   DROP TABLE old_table; ALTER TABLE new_table RENAME TO old_table;

DROP INDEX IF EXISTS idx_events_project_type_time;
DROP INDEX IF EXISTS idx_events_project_task_time;
DROP INDEX IF EXISTS idx_events_project_session_time;
DROP INDEX IF EXISTS idx_events_project_time;

-- Drop columns added by this migration (requires SQLite >= 3.35).
-- If your SQLite version is older, these statements will fail and you must
-- recreate the events and panes tables without these columns.
ALTER TABLE events DROP COLUMN session_id;
ALTER TABLE events DROP COLUMN task_id;
ALTER TABLE panes DROP COLUMN project_id;
