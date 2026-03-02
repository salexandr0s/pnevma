CREATE TABLE IF NOT EXISTS pane_layout_templates (
  id TEXT PRIMARY KEY,
  project_id TEXT NOT NULL,
  name TEXT NOT NULL,
  display_name TEXT NOT NULL,
  pane_graph_json TEXT NOT NULL,
  is_system INTEGER NOT NULL DEFAULT 0,
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL,
  FOREIGN KEY (project_id) REFERENCES projects(id) ON DELETE CASCADE,
  UNIQUE(project_id, name)
);

CREATE INDEX IF NOT EXISTS idx_layout_templates_project_name
ON pane_layout_templates(project_id, name);
