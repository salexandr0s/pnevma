-- Rollback for 0010_task_stories.sql

DROP INDEX IF EXISTS idx_task_stories_task;
DROP TABLE IF EXISTS task_stories;
