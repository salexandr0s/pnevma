ALTER TABLE agent_profiles ADD COLUMN source TEXT NOT NULL DEFAULT 'user';
ALTER TABLE agent_profiles ADD COLUMN source_path TEXT;
ALTER TABLE agent_profiles ADD COLUMN user_modified INTEGER NOT NULL DEFAULT 0;
