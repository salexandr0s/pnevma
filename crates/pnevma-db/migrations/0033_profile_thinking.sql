-- Extended agent profile fields for thinking/tool control (project DB only)
-- global_agent_profiles lives in the global DB and is extended separately.
ALTER TABLE agent_profiles ADD COLUMN thinking_level TEXT;
ALTER TABLE agent_profiles ADD COLUMN thinking_budget INTEGER;
ALTER TABLE agent_profiles ADD COLUMN tool_restrictions_json TEXT;
ALTER TABLE agent_profiles ADD COLUMN extra_flags_json TEXT;
