PRAGMA foreign_keys = OFF;

ALTER TABLE costs RENAME TO costs_new;

CREATE TABLE costs (
  id TEXT PRIMARY KEY,
  agent_run_id TEXT,
  task_id TEXT NOT NULL,
  session_id TEXT NOT NULL,
  provider TEXT NOT NULL,
  model TEXT,
  tokens_in INTEGER NOT NULL,
  tokens_out INTEGER NOT NULL,
  estimated_usd REAL NOT NULL,
  tracked INTEGER NOT NULL,
  timestamp TEXT NOT NULL,
  FOREIGN KEY (agent_run_id) REFERENCES agent_runs(id) ON DELETE SET NULL,
  FOREIGN KEY (task_id) REFERENCES tasks(id) ON DELETE CASCADE,
  FOREIGN KEY (session_id) REFERENCES sessions(id) ON DELETE CASCADE
);

INSERT INTO costs (
  id,
  agent_run_id,
  task_id,
  session_id,
  provider,
  model,
  tokens_in,
  tokens_out,
  estimated_usd,
  tracked,
  timestamp
)
SELECT
  id,
  CASE
    WHEN agent_run_id IS NOT NULL
      AND EXISTS (SELECT 1 FROM agent_runs WHERE agent_runs.id = costs_new.agent_run_id)
    THEN agent_run_id
    ELSE NULL
  END,
  task_id,
  session_id,
  provider,
  model,
  tokens_in,
  tokens_out,
  estimated_usd,
  tracked,
  timestamp
FROM costs_new;

DROP TABLE costs_new;

PRAGMA foreign_keys = ON;
