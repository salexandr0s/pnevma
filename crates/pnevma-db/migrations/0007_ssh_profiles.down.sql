-- Rollback for 0007_ssh_profiles.sql

DROP INDEX IF EXISTS idx_ssh_profiles_project;
DROP TABLE IF EXISTS ssh_profiles;
