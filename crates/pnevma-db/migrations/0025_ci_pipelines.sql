-- CI pipeline and deployment tracking
CREATE TABLE IF NOT EXISTS ci_pipelines (
    id              TEXT PRIMARY KEY NOT NULL,
    project_id      TEXT NOT NULL REFERENCES projects(id),
    task_id         TEXT REFERENCES tasks(id),
    pr_id           TEXT REFERENCES pull_requests(id),
    provider        TEXT NOT NULL DEFAULT 'github',
    run_number      INTEGER,
    workflow_name   TEXT,
    head_sha        TEXT,
    status          TEXT NOT NULL DEFAULT 'queued',
    conclusion      TEXT,
    html_url        TEXT,
    started_at      TEXT,
    completed_at    TEXT,
    created_at      TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
    updated_at      TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now'))
);

CREATE TABLE IF NOT EXISTS ci_jobs (
    id              TEXT PRIMARY KEY NOT NULL,
    pipeline_id     TEXT NOT NULL REFERENCES ci_pipelines(id),
    name            TEXT NOT NULL,
    status          TEXT NOT NULL DEFAULT 'queued',
    conclusion      TEXT,
    started_at      TEXT,
    completed_at    TEXT
);

CREATE TABLE IF NOT EXISTS deployments (
    id              TEXT PRIMARY KEY NOT NULL,
    project_id      TEXT NOT NULL REFERENCES projects(id),
    task_id         TEXT REFERENCES tasks(id),
    environment     TEXT NOT NULL,
    status          TEXT NOT NULL DEFAULT 'pending',
    ref_name        TEXT,
    sha             TEXT,
    url             TEXT,
    created_at      TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
    updated_at      TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now'))
);

CREATE INDEX IF NOT EXISTS idx_ci_pipelines_project ON ci_pipelines(project_id);
CREATE INDEX IF NOT EXISTS idx_ci_jobs_pipeline ON ci_jobs(pipeline_id);
CREATE INDEX IF NOT EXISTS idx_deployments_project ON deployments(project_id);
