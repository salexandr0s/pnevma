use crate::error::DbError;
use crate::models::{
    AgentProfileRow, ArtifactRow, AutomationRetryRow, AutomationRunRow, CheckResultRow,
    CheckRunRow, CheckpointRow, ContextRuleUsageRow, CostDailyAggregateRow, CostRow,
    ErrorSignatureDailyRow, ErrorSignatureRow, EventRow, FeedbackRow, MergeQueueRow,
    NotificationRow, OnboardingStateRow, PaneLayoutTemplateRow, PaneRow, ProjectRow, ReviewRow,
    RuleRow, SecretRefRow, SessionRow, SshProfileRow, StoryProgressRow, TaskExternalSourceRow,
    TaskRow, TaskStoryRow, TelemetryEventRow, WorkflowInstanceRow, WorkflowRow, WorkflowTaskRow,
    WorktreeRow,
};
use chrono::{DateTime, Utc};
use serde_json::Value;
use sqlx::{
    sqlite::{SqliteConnectOptions, SqlitePoolOptions},
    SqlitePool,
};
use std::path::{Path, PathBuf};

mod admin;
mod costs;
mod events;
mod notifications;
mod projects;
mod reviews;
mod sessions;
mod tasks;
mod workflows;
mod worktrees;

#[cfg(test)]
mod tests;

#[derive(Debug, Clone, Default)]
pub struct EventQueryFilter {
    pub project_id: String,
    pub task_id: Option<String>,
    pub session_id: Option<String>,
    pub event_type: Option<String>,
    pub from: Option<DateTime<Utc>>,
    pub to: Option<DateTime<Utc>>,
    pub limit: Option<i64>,
}

#[derive(Debug, Clone)]
pub struct NewEvent {
    pub id: String,
    pub project_id: String,
    pub task_id: Option<String>,
    pub session_id: Option<String>,
    pub trace_id: String,
    pub source: String,
    pub event_type: String,
    pub payload: Value,
}

#[derive(Debug, Clone)]
pub struct Db {
    pub(crate) pool: SqlitePool,
    pub(crate) path: PathBuf,
}

impl Db {
    pub async fn open(project_root: impl AsRef<Path>) -> Result<Self, DbError> {
        let db_path = project_root.as_ref().join(".pnevma/pnevma.db");
        if let Some(parent) = db_path.parent() {
            tokio::fs::create_dir_all(parent).await?;
            #[cfg(unix)]
            {
                use std::os::unix::fs::PermissionsExt;
                let perms = std::fs::Permissions::from_mode(0o700);
                std::fs::set_permissions(parent, perms).map_err(DbError::Io)?;
            }
        }

        // Set PRAGMAs via SqliteConnectOptions so they apply to every connection
        // in the pool, not just the first one acquired (the old post-connect
        // one-shot approach only hit 1 of 5 connections).
        let options = SqliteConnectOptions::new()
            .filename(&db_path)
            .create_if_missing(true)
            .pragma("journal_mode", "wal")
            .pragma("busy_timeout", "5000")
            .pragma("foreign_keys", "on");

        let pool = SqlitePoolOptions::new()
            .max_connections(5)
            .connect_with(options)
            .await?;

        // Defense-in-depth: the parent directory already has 0o700 permissions
        // (set above), so no other user can access files within it during the
        // window between file creation and this chmod.  We still tighten the
        // file itself to 0o600 as a secondary safeguard.
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            if db_path.exists() {
                let perms = std::fs::Permissions::from_mode(0o600);
                std::fs::set_permissions(&db_path, perms).map_err(DbError::Io)?;
            }
        }

        let db = Self {
            pool,
            path: db_path,
        };
        db.migrate().await?;

        // Defense-in-depth: verify database integrity after migration.
        let (integrity,): (String,) = sqlx::query_as("PRAGMA quick_check")
            .fetch_one(&db.pool)
            .await
            .map_err(DbError::Sql)?;
        if integrity != "ok" {
            return Err(DbError::Integrity(format!(
                "database integrity check failed: {}",
                integrity
            )));
        }

        Ok(db)
    }

    /// Create a `Db` from an existing pool and path. Intended for test helpers
    /// that construct in-memory databases.
    pub fn from_pool_and_path(pool: SqlitePool, path: PathBuf) -> Self {
        Self { pool, path }
    }

    pub fn pool(&self) -> &SqlitePool {
        &self.pool
    }

    pub fn path(&self) -> &Path {
        &self.path
    }

    pub async fn migrate(&self) -> Result<(), DbError> {
        sqlx::migrate!("./migrations").run(&self.pool).await?;
        Ok(())
    }
}
