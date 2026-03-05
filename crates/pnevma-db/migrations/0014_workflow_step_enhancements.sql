-- Add execution_mode, timeout_minutes, and max_retries to tasks for workflow step enhancements.
ALTER TABLE tasks ADD COLUMN execution_mode TEXT DEFAULT 'worktree';
ALTER TABLE tasks ADD COLUMN timeout_minutes INTEGER;
ALTER TABLE tasks ADD COLUMN max_retries INTEGER DEFAULT 0;
