use crate::error::DbError;
use chrono::{DateTime, Utc};
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use sqlx::{sqlite::SqlitePoolOptions, FromRow, SqlitePool};
use std::path::{Path, PathBuf};

#[derive(Debug, Clone, Serialize, Deserialize, FromRow)]
pub struct TrustRecord {
    pub path: String,
    pub trusted_at: DateTime<Utc>,
    pub fingerprint: String,
}

#[derive(Debug, Clone, Serialize, Deserialize, FromRow)]
pub struct RecentProjectRow {
    pub path: String,
    pub name: String,
    pub project_id: String,
    pub opened_at: DateTime<Utc>,
}

#[derive(Debug, Clone)]
pub struct GlobalDb {
    pool: SqlitePool,
    path: PathBuf,
}

impl GlobalDb {
    pub async fn open() -> Result<Self, DbError> {
        let home = std::env::var("HOME")
            .map_err(|_| DbError::Config("HOME environment variable is not set".to_string()))?;
        let dir = PathBuf::from(home).join(".local/share/pnevma");
        Self::open_in_dir(dir).await
    }

    pub fn path(&self) -> &Path {
        &self.path
    }

    async fn open_in_dir(dir: PathBuf) -> Result<Self, DbError> {
        tokio::fs::create_dir_all(&dir).await?;
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            let perms = std::fs::Permissions::from_mode(0o700);
            tokio::fs::set_permissions(&dir, perms).await?;
        }
        let db_path = dir.join("global.db");
        let uri = format!("sqlite://{}?mode=rwc", db_path.to_string_lossy());
        let pool = SqlitePoolOptions::new()
            .max_connections(2)
            .connect(&uri)
            .await?;

        sqlx::query(
            "CREATE TABLE IF NOT EXISTS trusted_paths (
                path TEXT PRIMARY KEY,
                trusted_at TEXT NOT NULL,
                fingerprint TEXT NOT NULL
            )",
        )
        .execute(&pool)
        .await?;

        sqlx::query(
            "CREATE TABLE IF NOT EXISTS recent_projects (
                path TEXT PRIMARY KEY,
                name TEXT NOT NULL,
                project_id TEXT NOT NULL,
                opened_at TEXT NOT NULL
            )",
        )
        .execute(&pool)
        .await?;

        #[cfg(unix)]
        if db_path.exists() {
            use std::os::unix::fs::PermissionsExt;
            let perms = std::fs::Permissions::from_mode(0o600);
            tokio::fs::set_permissions(&db_path, perms).await?;
        }

        Ok(Self {
            pool,
            path: db_path,
        })
    }

    pub async fn is_path_trusted(&self, path: &str) -> Result<Option<TrustRecord>, DbError> {
        let row = sqlx::query_as::<_, TrustRecord>(
            "SELECT path, trusted_at, fingerprint FROM trusted_paths WHERE path = ?",
        )
        .bind(path)
        .fetch_optional(&self.pool)
        .await?;
        Ok(row)
    }

    pub async fn trust_path(&self, path: &str, fingerprint: &str) -> Result<(), DbError> {
        let now = Utc::now();
        sqlx::query(
            "INSERT INTO trusted_paths (path, trusted_at, fingerprint)
             VALUES (?, ?, ?)
             ON CONFLICT(path) DO UPDATE SET trusted_at = excluded.trusted_at, fingerprint = excluded.fingerprint",
        )
        .bind(path)
        .bind(now)
        .bind(fingerprint)
        .execute(&self.pool)
        .await?;
        Ok(())
    }

    pub async fn revoke_trust(&self, path: &str) -> Result<(), DbError> {
        sqlx::query("DELETE FROM trusted_paths WHERE path = ?")
            .bind(path)
            .execute(&self.pool)
            .await?;
        Ok(())
    }

    pub async fn list_trusted_paths(&self) -> Result<Vec<TrustRecord>, DbError> {
        let rows = sqlx::query_as::<_, TrustRecord>(
            "SELECT path, trusted_at, fingerprint FROM trusted_paths ORDER BY trusted_at DESC",
        )
        .fetch_all(&self.pool)
        .await?;
        Ok(rows)
    }

    pub async fn add_recent_project(
        &self,
        path: &str,
        name: &str,
        project_id: &str,
    ) -> Result<(), DbError> {
        let now = Utc::now();
        sqlx::query(
            "INSERT INTO recent_projects (path, name, project_id, opened_at)
             VALUES (?, ?, ?, ?)
             ON CONFLICT(path) DO UPDATE SET name = excluded.name, project_id = excluded.project_id, opened_at = excluded.opened_at",
        )
        .bind(path)
        .bind(name)
        .bind(project_id)
        .bind(now)
        .execute(&self.pool)
        .await?;
        Ok(())
    }

    pub async fn list_recent_projects(&self, limit: i64) -> Result<Vec<RecentProjectRow>, DbError> {
        let rows = sqlx::query_as::<_, RecentProjectRow>(
            "SELECT path, name, project_id, opened_at FROM recent_projects ORDER BY opened_at DESC LIMIT ?",
        )
        .bind(limit)
        .fetch_all(&self.pool)
        .await?;
        Ok(rows)
    }

    pub async fn remove_recent_project(&self, path: &str) -> Result<(), DbError> {
        sqlx::query("DELETE FROM recent_projects WHERE path = ?")
            .bind(path)
            .execute(&self.pool)
            .await?;
        Ok(())
    }
}

pub fn sha256_hex(data: &[u8]) -> String {
    format!("{:x}", Sha256::digest(data))
}

#[cfg(test)]
mod tests {
    use super::*;
    use uuid::Uuid;

    #[tokio::test]
    async fn open_in_dir_creates_database_file_for_fresh_home() {
        let root = std::env::temp_dir().join(format!("pnevma-global-db-{}", Uuid::new_v4()));
        let db_dir = root.join(".local/share/pnevma");
        tokio::fs::create_dir_all(&root)
            .await
            .expect("create temp root");

        let db = GlobalDb::open_in_dir(db_dir.clone())
            .await
            .expect("open global db in fresh dir");

        assert_eq!(db.path(), db_dir.join("global.db").as_path());
        assert!(
            db.path().exists(),
            "GlobalDb::open_in_dir should create the SQLite file for a fresh home"
        );

        let trust = db.list_trusted_paths().await.expect("list trusted paths");
        let recents = db
            .list_recent_projects(20)
            .await
            .expect("list recent projects");
        assert!(trust.is_empty(), "fresh global db should start empty");
        assert!(recents.is_empty(), "fresh global db should start empty");

        drop(db);
        let _ = tokio::fs::remove_dir_all(&root).await;
    }
}
