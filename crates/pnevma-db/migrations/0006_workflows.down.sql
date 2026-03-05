-- Rollback for 0006_workflows.sql

DROP INDEX IF EXISTS idx_workflow_tasks_task;
DROP INDEX IF EXISTS idx_workflow_instances_project;
DROP TABLE IF EXISTS workflow_tasks;
DROP TABLE IF EXISTS workflow_instances;
