use crate::error::DbError;
use chrono::{DateTime, Utc};
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use sqlx::{sqlite::SqlitePoolOptions, FromRow, SqlitePool};

#[derive(Debug, Clone, Serialize, Deserialize, FromRow)]
pub struct TrustRecord {
    pub path: String,
    pub trusted_at: DateTime<Utc>,
    pub fingerprint: String,
}

#[derive(Debug, Clone)]
pub struct GlobalDb {
    pool: SqlitePool,
}

impl GlobalDb {
    pub async fn open() -> Result<Self, DbError> {
        let home = std::env::var("HOME").unwrap_or_else(|_| ".".to_string());
        let dir = std::path::PathBuf::from(home).join(".local/share/pnevma");
        tokio::fs::create_dir_all(&dir).await?;
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

        Ok(Self { pool })
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
}

pub fn sha256_hex(data: &[u8]) -> String {
    let mut hasher = Sha256::new();
    hasher.update(data);
    let result = hasher.finalize();
    result.iter().map(|b| format!("{b:02x}")).collect()
}
