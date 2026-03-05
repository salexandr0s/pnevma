-- Rollback for 0005_phase5_ops.sql

DROP INDEX IF EXISTS idx_feedback_entries_project_time;
DROP INDEX IF EXISTS idx_telemetry_events_project_time;
DROP INDEX IF EXISTS idx_context_rule_usage_rule;

DROP TABLE IF EXISTS feedback_entries;
DROP TABLE IF EXISTS telemetry_events;
DROP TABLE IF EXISTS onboarding_state;
DROP TABLE IF EXISTS context_rule_usage;
