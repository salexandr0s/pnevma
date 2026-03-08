-- Add role and system_prompt to project-scoped agent profiles
ALTER TABLE agent_profiles ADD COLUMN role TEXT NOT NULL DEFAULT 'build';
ALTER TABLE agent_profiles ADD COLUMN system_prompt TEXT;
