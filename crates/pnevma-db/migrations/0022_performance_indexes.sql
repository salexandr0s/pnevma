-- Performance indexes for common query paths
CREATE INDEX IF NOT EXISTS idx_costs_task_id ON costs(task_id);
CREATE INDEX IF NOT EXISTS idx_costs_session_id ON costs(session_id);
CREATE INDEX IF NOT EXISTS idx_tasks_project_id ON tasks(project_id);
CREATE INDEX IF NOT EXISTS idx_tasks_project_status ON tasks(project_id, status);
CREATE INDEX IF NOT EXISTS idx_sessions_project_id ON sessions(project_id);
CREATE INDEX IF NOT EXISTS idx_worktrees_task_id ON worktrees(task_id);
CREATE INDEX IF NOT EXISTS idx_reviews_task_id ON reviews(task_id);
