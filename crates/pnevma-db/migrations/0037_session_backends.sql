ALTER TABLE sessions ADD COLUMN backend TEXT NOT NULL DEFAULT 'tmux_compat';
ALTER TABLE sessions ADD COLUMN durability TEXT NOT NULL DEFAULT 'durable';
ALTER TABLE sessions ADD COLUMN lifecycle_state TEXT NOT NULL DEFAULT 'attached';
ALTER TABLE sessions ADD COLUMN connection_id TEXT;
ALTER TABLE sessions ADD COLUMN remote_session_id TEXT;
ALTER TABLE sessions ADD COLUMN controller_id TEXT;
ALTER TABLE sessions ADD COLUMN last_output_at TEXT;
ALTER TABLE sessions ADD COLUMN detached_at TEXT;
ALTER TABLE sessions ADD COLUMN last_error TEXT;
