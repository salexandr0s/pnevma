-- Attention rules for event-driven notifications
CREATE TABLE IF NOT EXISTS attention_rules (
    id              TEXT PRIMARY KEY NOT NULL,
    project_id      TEXT NOT NULL REFERENCES projects(id),
    name            TEXT NOT NULL,
    description     TEXT,
    event_type      TEXT NOT NULL,
    condition_json  TEXT NOT NULL DEFAULT '{}',
    action          TEXT NOT NULL DEFAULT 'notify',
    severity        TEXT NOT NULL DEFAULT 'info',
    enabled         INTEGER NOT NULL DEFAULT 1,
    cooldown_seconds INTEGER NOT NULL DEFAULT 300,
    last_triggered  TEXT,
    created_at      TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
    updated_at      TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now'))
);

CREATE INDEX IF NOT EXISTS idx_attention_rules_project ON attention_rules(project_id, enabled);
