-- Rollback for 0001_initial.sql
-- Drop tables in reverse dependency order to satisfy foreign key constraints.

DROP TABLE IF EXISTS reviews;
DROP TABLE IF EXISTS checkpoints;
DROP TABLE IF EXISTS events;
DROP TABLE IF EXISTS costs;
DROP TABLE IF EXISTS rules;
DROP TABLE IF EXISTS artifacts;
DROP TABLE IF EXISTS agent_runs;
DROP TABLE IF EXISTS worktrees;
DROP TABLE IF EXISTS task_dependencies;
DROP TABLE IF EXISTS tasks;
DROP TABLE IF EXISTS panes;
DROP TABLE IF EXISTS sessions;
DROP TABLE IF EXISTS projects;
