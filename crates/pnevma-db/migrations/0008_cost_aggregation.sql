CREATE TABLE IF NOT EXISTS cost_hourly_aggregates (
    id TEXT PRIMARY KEY,
    project_id TEXT NOT NULL,
    provider TEXT NOT NULL,
    model TEXT NOT NULL DEFAULT '',
    period_start TEXT NOT NULL,
    tokens_in INTEGER NOT NULL DEFAULT 0,
    tokens_out INTEGER NOT NULL DEFAULT 0,
    estimated_usd REAL NOT NULL DEFAULT 0.0,
    record_count INTEGER NOT NULL DEFAULT 0,
    UNIQUE(project_id, provider, model, period_start)
);

CREATE TABLE IF NOT EXISTS cost_daily_aggregates (
    id TEXT PRIMARY KEY,
    project_id TEXT NOT NULL,
    provider TEXT NOT NULL,
    model TEXT NOT NULL DEFAULT '',
    period_date TEXT NOT NULL,
    tokens_in INTEGER NOT NULL DEFAULT 0,
    tokens_out INTEGER NOT NULL DEFAULT 0,
    estimated_usd REAL NOT NULL DEFAULT 0.0,
    record_count INTEGER NOT NULL DEFAULT 0,
    tasks_completed INTEGER NOT NULL DEFAULT 0,
    files_changed INTEGER NOT NULL DEFAULT 0,
    UNIQUE(project_id, provider, model, period_date)
);
