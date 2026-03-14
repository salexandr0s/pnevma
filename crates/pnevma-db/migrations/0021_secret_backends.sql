PRAGMA foreign_keys = OFF;

ALTER TABLE secret_refs RENAME TO secret_refs_old;

CREATE TABLE secret_refs (
  id TEXT PRIMARY KEY,
  project_id TEXT,
  scope TEXT NOT NULL,
  name TEXT NOT NULL,
  backend TEXT NOT NULL DEFAULT 'keychain',
  keychain_service TEXT,
  keychain_account TEXT,
  env_file_path TEXT,
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL,
  FOREIGN KEY (project_id) REFERENCES projects(id) ON DELETE CASCADE,
  UNIQUE (project_id, scope, name),
  CHECK (backend IN ('keychain', 'env_file')),
  CHECK (
    (backend = 'keychain' AND keychain_service IS NOT NULL AND keychain_account IS NOT NULL AND env_file_path IS NULL)
    OR
    (backend = 'env_file' AND keychain_service IS NULL AND keychain_account IS NULL AND env_file_path IS NOT NULL)
  )
);

INSERT INTO secret_refs (
  id,
  project_id,
  scope,
  name,
  backend,
  keychain_service,
  keychain_account,
  env_file_path,
  created_at,
  updated_at
)
SELECT
  id,
  project_id,
  scope,
  name,
  'keychain',
  keychain_service,
  keychain_account,
  NULL,
  created_at,
  updated_at
FROM secret_refs_old;

DROP TABLE secret_refs_old;

PRAGMA foreign_keys = ON;
