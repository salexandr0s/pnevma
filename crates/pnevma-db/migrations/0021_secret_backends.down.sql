PRAGMA foreign_keys = OFF;

ALTER TABLE secret_refs RENAME TO secret_refs_new;

CREATE TABLE secret_refs (
  id TEXT PRIMARY KEY,
  project_id TEXT,
  scope TEXT NOT NULL,
  name TEXT NOT NULL,
  keychain_service TEXT NOT NULL,
  keychain_account TEXT NOT NULL,
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL,
  UNIQUE (project_id, scope, name)
);

INSERT INTO secret_refs (
  id,
  project_id,
  scope,
  name,
  keychain_service,
  keychain_account,
  created_at,
  updated_at
)
SELECT
  id,
  project_id,
  scope,
  name,
  keychain_service,
  keychain_account,
  created_at,
  updated_at
FROM secret_refs_new
WHERE backend = 'keychain';

DROP TABLE secret_refs_new;

PRAGMA foreign_keys = ON;
