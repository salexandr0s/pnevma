CREATE TABLE IF NOT EXISTS agent_profiles (
    id TEXT PRIMARY KEY,
    project_id TEXT NOT NULL,
    name TEXT NOT NULL,
    provider TEXT NOT NULL DEFAULT 'anthropic',
    model TEXT NOT NULL DEFAULT 'claude-sonnet-4-6',
    token_budget INTEGER NOT NULL DEFAULT 200000,
    timeout_minutes INTEGER NOT NULL DEFAULT 30,
    max_concurrent INTEGER NOT NULL DEFAULT 2,
    stations_json TEXT NOT NULL DEFAULT '[]',
    config_json TEXT NOT NULL DEFAULT '{}',
    active INTEGER NOT NULL DEFAULT 1,
    created_at TEXT NOT NULL,
    updated_at TEXT NOT NULL,
    UNIQUE(project_id, name)
);

CREATE INDEX IF NOT EXISTS idx_agent_profiles_project ON agent_profiles(project_id);
