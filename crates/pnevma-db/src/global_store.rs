use crate::error::DbError;
use crate::models::{GlobalAgentProfileRow, GlobalSshProfileRow, GlobalWorkflowRow};
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

        sqlx::query(
            "CREATE TABLE IF NOT EXISTS app_metadata (
                key TEXT PRIMARY KEY,
                value TEXT NOT NULL
            )",
        )
        .execute(&pool)
        .await?;

        sqlx::query(
            "CREATE TABLE IF NOT EXISTS global_workflows (
                id TEXT PRIMARY KEY,
                name TEXT NOT NULL UNIQUE,
                description TEXT,
                definition_yaml TEXT NOT NULL,
                source TEXT NOT NULL DEFAULT 'user',
                created_at TEXT NOT NULL,
                updated_at TEXT NOT NULL
            )",
        )
        .execute(&pool)
        .await?;

        sqlx::query(
            "CREATE TABLE IF NOT EXISTS global_agent_profiles (
                id TEXT PRIMARY KEY,
                name TEXT NOT NULL UNIQUE,
                role TEXT NOT NULL DEFAULT 'build',
                provider TEXT NOT NULL DEFAULT 'anthropic',
                model TEXT NOT NULL DEFAULT 'claude-sonnet-4-6',
                token_budget INTEGER NOT NULL DEFAULT 200000,
                timeout_minutes INTEGER NOT NULL DEFAULT 30,
                max_concurrent INTEGER NOT NULL DEFAULT 2,
                stations_json TEXT NOT NULL DEFAULT '[]',
                config_json TEXT NOT NULL DEFAULT '{}',
                system_prompt TEXT,
                active INTEGER NOT NULL DEFAULT 1,
                created_at TEXT NOT NULL,
                updated_at TEXT NOT NULL
            )",
        )
        .execute(&pool)
        .await?;

        for stmt in &[
            "ALTER TABLE global_agent_profiles ADD COLUMN source TEXT NOT NULL DEFAULT 'user'",
            "ALTER TABLE global_agent_profiles ADD COLUMN source_path TEXT",
            "ALTER TABLE global_agent_profiles ADD COLUMN user_modified INTEGER NOT NULL DEFAULT 0",
        ] {
            match sqlx::query(stmt).execute(&pool).await {
                Ok(_) => {}
                Err(e) => {
                    let msg = e.to_string();
                    if !msg.contains("duplicate column name") {
                        return Err(e.into());
                    }
                }
            }
        }

        sqlx::query(
            "CREATE TABLE IF NOT EXISTS global_ssh_profiles (
                id TEXT PRIMARY KEY,
                name TEXT NOT NULL UNIQUE,
                host TEXT NOT NULL,
                port INTEGER NOT NULL DEFAULT 22,
                user TEXT,
                identity_file TEXT,
                proxy_jump TEXT,
                tags_json TEXT NOT NULL DEFAULT '[]',
                source TEXT NOT NULL DEFAULT 'manual',
                created_at TEXT NOT NULL,
                updated_at TEXT NOT NULL
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

    pub async fn get_metadata(&self, key: &str) -> Result<Option<String>, DbError> {
        let row: Option<(String,)> = sqlx::query_as("SELECT value FROM app_metadata WHERE key = ?")
            .bind(key)
            .fetch_optional(&self.pool)
            .await?;
        Ok(row.map(|(value,)| value))
    }

    pub async fn set_metadata(&self, key: &str, value: &str) -> Result<(), DbError> {
        sqlx::query(
            "INSERT INTO app_metadata (key, value)
             VALUES (?, ?)
             ON CONFLICT(key) DO UPDATE SET value = excluded.value",
        )
        .bind(key)
        .bind(value)
        .execute(&self.pool)
        .await?;
        Ok(())
    }

    // ─── Global Workflow methods ──────────────────────────────────────────────

    pub async fn create_global_workflow(&self, row: &GlobalWorkflowRow) -> Result<(), DbError> {
        sqlx::query(
            "INSERT INTO global_workflows (id, name, description, definition_yaml, source, created_at, updated_at)
             VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7)",
        )
        .bind(&row.id)
        .bind(&row.name)
        .bind(&row.description)
        .bind(&row.definition_yaml)
        .bind(&row.source)
        .bind(row.created_at)
        .bind(row.updated_at)
        .execute(&self.pool)
        .await?;
        Ok(())
    }

    pub async fn get_global_workflow(
        &self,
        id: &str,
    ) -> Result<Option<GlobalWorkflowRow>, DbError> {
        let row = sqlx::query_as::<_, GlobalWorkflowRow>(
            "SELECT id, name, description, definition_yaml, source, created_at, updated_at
             FROM global_workflows WHERE id = ?1",
        )
        .bind(id)
        .fetch_optional(&self.pool)
        .await?;
        Ok(row)
    }

    pub async fn get_global_workflow_by_name(
        &self,
        name: &str,
    ) -> Result<Option<GlobalWorkflowRow>, DbError> {
        let row = sqlx::query_as::<_, GlobalWorkflowRow>(
            "SELECT id, name, description, definition_yaml, source, created_at, updated_at
             FROM global_workflows WHERE name = ?1",
        )
        .bind(name)
        .fetch_optional(&self.pool)
        .await?;
        Ok(row)
    }

    pub async fn list_global_workflows(&self) -> Result<Vec<GlobalWorkflowRow>, DbError> {
        let rows = sqlx::query_as::<_, GlobalWorkflowRow>(
            "SELECT id, name, description, definition_yaml, source, created_at, updated_at
             FROM global_workflows ORDER BY name",
        )
        .fetch_all(&self.pool)
        .await?;
        Ok(rows)
    }

    pub async fn update_global_workflow(&self, row: &GlobalWorkflowRow) -> Result<(), DbError> {
        sqlx::query(
            "UPDATE global_workflows SET name = ?1, description = ?2, definition_yaml = ?3, source = ?4, updated_at = ?5
             WHERE id = ?6",
        )
        .bind(&row.name)
        .bind(&row.description)
        .bind(&row.definition_yaml)
        .bind(&row.source)
        .bind(row.updated_at)
        .bind(&row.id)
        .execute(&self.pool)
        .await?;
        Ok(())
    }

    pub async fn delete_global_workflow(&self, id: &str) -> Result<(), DbError> {
        sqlx::query("DELETE FROM global_workflows WHERE id = ?1")
            .bind(id)
            .execute(&self.pool)
            .await?;
        Ok(())
    }

    // ─── Global Agent Profile methods ─────────────────────────────────────────

    pub async fn create_global_agent_profile(
        &self,
        row: &GlobalAgentProfileRow,
    ) -> Result<(), DbError> {
        sqlx::query(
            "INSERT INTO global_agent_profiles
                (id, name, role, provider, model, token_budget, timeout_minutes,
                 max_concurrent, stations_json, config_json, system_prompt, active, created_at, updated_at,
                 source, source_path, user_modified)
             VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12, ?13, ?14, ?15, ?16, ?17)",
        )
        .bind(&row.id)
        .bind(&row.name)
        .bind(&row.role)
        .bind(&row.provider)
        .bind(&row.model)
        .bind(row.token_budget)
        .bind(row.timeout_minutes)
        .bind(row.max_concurrent)
        .bind(&row.stations_json)
        .bind(&row.config_json)
        .bind(&row.system_prompt)
        .bind(row.active)
        .bind(row.created_at)
        .bind(row.updated_at)
        .bind(&row.source)
        .bind(&row.source_path)
        .bind(row.user_modified)
        .execute(&self.pool)
        .await?;
        Ok(())
    }

    pub async fn get_global_agent_profile(
        &self,
        id: &str,
    ) -> Result<Option<GlobalAgentProfileRow>, DbError> {
        let row = sqlx::query_as::<_, GlobalAgentProfileRow>(
            "SELECT id, name, role, provider, model, token_budget, timeout_minutes,
                    max_concurrent, stations_json, config_json, system_prompt, active, created_at, updated_at,
                    source, source_path, user_modified
             FROM global_agent_profiles WHERE id = ?1",
        )
        .bind(id)
        .fetch_optional(&self.pool)
        .await?;
        Ok(row)
    }

    pub async fn get_global_agent_profile_by_name(
        &self,
        name: &str,
    ) -> Result<Option<GlobalAgentProfileRow>, DbError> {
        let row = sqlx::query_as::<_, GlobalAgentProfileRow>(
            "SELECT id, name, role, provider, model, token_budget, timeout_minutes,
                    max_concurrent, stations_json, config_json, system_prompt, active, created_at, updated_at,
                    source, source_path, user_modified
             FROM global_agent_profiles WHERE name = ?1",
        )
        .bind(name)
        .fetch_optional(&self.pool)
        .await?;
        Ok(row)
    }

    pub async fn get_global_agent_profile_by_source_path(
        &self,
        source_path: &str,
    ) -> Result<Option<GlobalAgentProfileRow>, DbError> {
        let row = sqlx::query_as::<_, GlobalAgentProfileRow>(
            "SELECT id, name, role, provider, model, token_budget, timeout_minutes,
                    max_concurrent, stations_json, config_json, system_prompt, active, created_at, updated_at,
                    source, source_path, user_modified
             FROM global_agent_profiles WHERE source_path = ?1",
        )
        .bind(source_path)
        .fetch_optional(&self.pool)
        .await?;
        Ok(row)
    }

    pub async fn list_global_agent_profiles(&self) -> Result<Vec<GlobalAgentProfileRow>, DbError> {
        let rows = sqlx::query_as::<_, GlobalAgentProfileRow>(
            "SELECT id, name, role, provider, model, token_budget, timeout_minutes,
                    max_concurrent, stations_json, config_json, system_prompt, active, created_at, updated_at,
                    source, source_path, user_modified
             FROM global_agent_profiles WHERE active = 1 ORDER BY name",
        )
        .fetch_all(&self.pool)
        .await?;
        Ok(rows)
    }

    pub async fn update_global_agent_profile(
        &self,
        row: &GlobalAgentProfileRow,
    ) -> Result<(), DbError> {
        sqlx::query(
            "UPDATE global_agent_profiles
             SET name = ?1, role = ?2, provider = ?3, model = ?4, token_budget = ?5,
                 timeout_minutes = ?6, max_concurrent = ?7, stations_json = ?8,
                 config_json = ?9, system_prompt = ?10, active = ?11, updated_at = ?12,
                 source = ?13, source_path = ?14, user_modified = ?15
             WHERE id = ?16",
        )
        .bind(&row.name)
        .bind(&row.role)
        .bind(&row.provider)
        .bind(&row.model)
        .bind(row.token_budget)
        .bind(row.timeout_minutes)
        .bind(row.max_concurrent)
        .bind(&row.stations_json)
        .bind(&row.config_json)
        .bind(&row.system_prompt)
        .bind(row.active)
        .bind(row.updated_at)
        .bind(&row.source)
        .bind(&row.source_path)
        .bind(row.user_modified)
        .bind(&row.id)
        .execute(&self.pool)
        .await?;
        Ok(())
    }

    pub async fn delete_global_agent_profile(&self, id: &str) -> Result<(), DbError> {
        sqlx::query("DELETE FROM global_agent_profiles WHERE id = ?1")
            .bind(id)
            .execute(&self.pool)
            .await?;
        Ok(())
    }

    // ─── Global SSH Profile methods ──────────────────────────────────────────

    pub async fn list_global_ssh_profiles(&self) -> Result<Vec<GlobalSshProfileRow>, DbError> {
        let rows = sqlx::query_as::<_, GlobalSshProfileRow>(
            "SELECT id, name, host, port, user, identity_file, proxy_jump, tags_json, source, created_at, updated_at
             FROM global_ssh_profiles ORDER BY name",
        )
        .fetch_all(&self.pool)
        .await?;
        Ok(rows)
    }

    pub async fn get_global_ssh_profile(
        &self,
        id: &str,
    ) -> Result<Option<GlobalSshProfileRow>, DbError> {
        let row = sqlx::query_as::<_, GlobalSshProfileRow>(
            "SELECT id, name, host, port, user, identity_file, proxy_jump, tags_json, source, created_at, updated_at
             FROM global_ssh_profiles WHERE id = ?1",
        )
        .bind(id)
        .fetch_optional(&self.pool)
        .await?;
        Ok(row)
    }

    pub async fn upsert_global_ssh_profile(
        &self,
        row: &GlobalSshProfileRow,
    ) -> Result<(), DbError> {
        sqlx::query(
            "INSERT INTO global_ssh_profiles
                (id, name, host, port, user, identity_file, proxy_jump, tags_json, source, created_at, updated_at)
             VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11)
             ON CONFLICT(name) DO UPDATE SET
                host = excluded.host,
                port = excluded.port,
                user = excluded.user,
                identity_file = excluded.identity_file,
                proxy_jump = excluded.proxy_jump,
                tags_json = excluded.tags_json,
                source = excluded.source,
                updated_at = excluded.updated_at",
        )
        .bind(&row.id)
        .bind(&row.name)
        .bind(&row.host)
        .bind(row.port)
        .bind(&row.user)
        .bind(&row.identity_file)
        .bind(&row.proxy_jump)
        .bind(&row.tags_json)
        .bind(&row.source)
        .bind(row.created_at)
        .bind(row.updated_at)
        .execute(&self.pool)
        .await?;
        Ok(())
    }

    pub async fn delete_global_ssh_profile(&self, id: &str) -> Result<(), DbError> {
        sqlx::query("DELETE FROM global_ssh_profiles WHERE id = ?1")
            .bind(id)
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
