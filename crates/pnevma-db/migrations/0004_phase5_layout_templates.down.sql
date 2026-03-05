-- Rollback for 0004_phase5_layout_templates.sql

DROP INDEX IF EXISTS idx_layout_templates_project_name;
DROP TABLE IF EXISTS pane_layout_templates;
