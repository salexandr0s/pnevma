-- Rollback for 0003_phase3_review_trust.sql

DROP INDEX IF EXISTS idx_notifications_project_unread;
DROP INDEX IF EXISTS idx_merge_queue_project_status;
DROP INDEX IF EXISTS idx_check_results_task;
DROP INDEX IF EXISTS idx_check_runs_project_task;

DROP TABLE IF EXISTS secret_refs;
DROP TABLE IF EXISTS notifications;
DROP TABLE IF EXISTS merge_queue;
DROP TABLE IF EXISTS check_results;
DROP TABLE IF EXISTS check_runs;
