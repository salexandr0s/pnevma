-- Telemetry, fleet snapshots, and agent performance
CREATE TABLE IF NOT EXISTS telemetry_metrics (
    id              TEXT PRIMARY KEY NOT NULL,
    project_id      TEXT NOT NULL REFERENCES projects(id),
    metric_name     TEXT NOT NULL,
    metric_value    REAL NOT NULL,
    tags_json       TEXT NOT NULL DEFAULT '{}',
    recorded_at     TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now'))
);

CREATE TABLE IF NOT EXISTS fleet_snapshots (
    id                  TEXT PRIMARY KEY NOT NULL,
    project_id          TEXT NOT NULL REFERENCES projects(id),
    active_sessions     INTEGER NOT NULL DEFAULT 0,
    active_dispatches   INTEGER NOT NULL DEFAULT 0,
    queued_dispatches   INTEGER NOT NULL DEFAULT 0,
    pool_max            INTEGER NOT NULL DEFAULT 0,
    pool_utilization    REAL NOT NULL DEFAULT 0.0,
    total_cost_usd      REAL NOT NULL DEFAULT 0.0,
    tasks_ready         INTEGER NOT NULL DEFAULT 0,
    tasks_in_progress   INTEGER NOT NULL DEFAULT 0,
    tasks_failed        INTEGER NOT NULL DEFAULT 0,
    captured_at         TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now'))
);

CREATE TABLE IF NOT EXISTS agent_performance (
    id              TEXT PRIMARY KEY NOT NULL,
    project_id      TEXT NOT NULL REFERENCES projects(id),
    provider        TEXT NOT NULL,
    model           TEXT NOT NULL,
    period_start    TEXT NOT NULL,
    period_end      TEXT NOT NULL,
    runs_total      INTEGER NOT NULL DEFAULT 0,
    runs_success    INTEGER NOT NULL DEFAULT 0,
    runs_failed     INTEGER NOT NULL DEFAULT 0,
    avg_duration_seconds REAL,
    tokens_in       INTEGER NOT NULL DEFAULT 0,
    tokens_out      INTEGER NOT NULL DEFAULT 0,
    cost_usd        REAL NOT NULL DEFAULT 0.0,
    p95_duration_seconds REAL,
    UNIQUE(project_id, provider, model, period_start)
);

CREATE INDEX IF NOT EXISTS idx_telemetry_metrics_project ON telemetry_metrics(project_id, metric_name);
CREATE INDEX IF NOT EXISTS idx_fleet_snapshots_project ON fleet_snapshots(project_id, captured_at);
CREATE INDEX IF NOT EXISTS idx_agent_performance_project ON agent_performance(project_id);
