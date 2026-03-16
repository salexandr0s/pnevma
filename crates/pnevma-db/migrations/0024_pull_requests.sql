-- Pull request tracking
CREATE TABLE IF NOT EXISTS pull_requests (
    id              TEXT PRIMARY KEY NOT NULL,
    project_id      TEXT NOT NULL REFERENCES projects(id),
    task_id         TEXT REFERENCES tasks(id),
    number          INTEGER NOT NULL,
    title           TEXT NOT NULL,
    source_branch   TEXT NOT NULL,
    target_branch   TEXT NOT NULL DEFAULT 'main',
    remote_url      TEXT NOT NULL DEFAULT '',
    status          TEXT NOT NULL DEFAULT 'draft' CHECK (status IN ('draft', 'open', 'review_requested', 'approved', 'merged', 'closed')),
    checks_status   TEXT,
    review_status   TEXT,
    mergeable       INTEGER NOT NULL DEFAULT 1,
    head_sha        TEXT,
    created_at      TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
    updated_at      TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
    merged_at       TEXT,
    UNIQUE(project_id, task_id)
);

CREATE TABLE IF NOT EXISTS pr_check_runs (
    id              TEXT PRIMARY KEY NOT NULL,
    pr_id           TEXT NOT NULL REFERENCES pull_requests(id),
    name            TEXT NOT NULL,
    status          TEXT NOT NULL DEFAULT 'queued',
    conclusion      TEXT,
    details_url     TEXT,
    started_at      TEXT,
    completed_at    TEXT,
    UNIQUE(pr_id, name)
);

CREATE INDEX IF NOT EXISTS idx_pull_requests_project ON pull_requests(project_id);
CREATE INDEX IF NOT EXISTS idx_pr_check_runs_pr ON pr_check_runs(pr_id);
