-- Rollback for 0013_gap_fixes.sql
--
-- NOTE: FTS5 virtual tables and triggers must be dropped manually.
-- The ALTER TABLE ADD COLUMN rollback for `auto_dispatch` and `agent_profile_override`
-- on tasks requires SQLite >= 3.35 for DROP COLUMN.

DROP TRIGGER IF EXISTS events_fts_insert;
DROP TRIGGER IF EXISTS tasks_fts_delete;
DROP TRIGGER IF EXISTS tasks_fts_update;
DROP TRIGGER IF EXISTS tasks_fts_insert;

DROP TABLE IF EXISTS events_fts;
DROP TABLE IF EXISTS tasks_fts;

-- Drop columns added to tasks (requires SQLite >= 3.35).
-- For SQLite < 3.35, recreate the tasks table without these columns.
ALTER TABLE tasks DROP COLUMN agent_profile_override;
ALTER TABLE tasks DROP COLUMN auto_dispatch;
