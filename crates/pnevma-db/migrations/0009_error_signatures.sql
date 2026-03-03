CREATE TABLE IF NOT EXISTS error_signatures (
    id TEXT PRIMARY KEY,
    project_id TEXT NOT NULL,
    signature_hash TEXT NOT NULL,
    canonical_message TEXT NOT NULL,
    category TEXT NOT NULL DEFAULT 'unknown',
    first_seen TEXT NOT NULL,
    last_seen TEXT NOT NULL,
    total_count INTEGER NOT NULL DEFAULT 1,
    sample_output TEXT,
    remediation_hint TEXT,
    UNIQUE(project_id, signature_hash)
);

CREATE TABLE IF NOT EXISTS error_signature_daily (
    id TEXT PRIMARY KEY,
    signature_id TEXT NOT NULL REFERENCES error_signatures(id),
    date TEXT NOT NULL,
    count INTEGER NOT NULL DEFAULT 1,
    UNIQUE(signature_id, date)
);

CREATE INDEX IF NOT EXISTS idx_error_sig_project ON error_signatures(project_id, total_count DESC);
CREATE INDEX IF NOT EXISTS idx_error_sig_daily ON error_signature_daily(signature_id, date);
