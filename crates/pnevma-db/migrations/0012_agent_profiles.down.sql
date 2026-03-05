-- Rollback for 0012_agent_profiles.sql

DROP INDEX IF EXISTS idx_agent_profiles_project;
DROP TABLE IF EXISTS agent_profiles;
