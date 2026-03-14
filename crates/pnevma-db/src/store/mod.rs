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
use sqlx::{sqlite::SqlitePoolOptions, SqlitePool};
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

        // Open in read-write-create mode so a brand new project root can cold-start
        // without a pre-created SQLite file.
        let uri = format!("sqlite://{}?mode=rwc", db_path.to_string_lossy());
        let pool = SqlitePoolOptions::new()
            .max_connections(5)
            .connect(&uri)
            .await?;

        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            if db_path.exists() {
                let perms = std::fs::Permissions::from_mode(0o600);
                std::fs::set_permissions(&db_path, perms).map_err(DbError::Io)?;
            }
        }

        sqlx::query("PRAGMA journal_mode=WAL;")
            .execute(&pool)
            .await?;
        sqlx::query("PRAGMA busy_timeout = 5000;")
            .execute(&pool)
            .await?;
        sqlx::query("PRAGMA foreign_keys = ON;")
            .execute(&pool)
            .await?;

        let db = Self {
            pool,
            path: db_path,
        };
        db.migrate().await?;
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
