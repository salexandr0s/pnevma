-- Editor profiles for workspace environment configuration
CREATE TABLE IF NOT EXISTS editor_profiles (
    id              TEXT PRIMARY KEY NOT NULL,
    project_id      TEXT NOT NULL REFERENCES projects(id),
    name            TEXT NOT NULL,
    editor          TEXT NOT NULL DEFAULT 'vscode',
    settings_json   TEXT NOT NULL DEFAULT '{}',
    extensions_json TEXT NOT NULL DEFAULT '[]',
    keybindings_json TEXT NOT NULL DEFAULT '[]',
    active          INTEGER NOT NULL DEFAULT 0,
    created_at      TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
    updated_at      TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
    UNIQUE(project_id, name)
);

CREATE INDEX IF NOT EXISTS idx_editor_profiles_project ON editor_profiles(project_id);
