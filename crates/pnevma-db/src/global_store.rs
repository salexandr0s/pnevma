use crate::error::DbError;
use crate::models::{GlobalAgentProfileRow, GlobalSshProfileRow, GlobalWorkflowRow};
use chrono::{DateTime, Utc};
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use sqlx::{
    sqlite::{SqliteConnectOptions, SqlitePoolOptions},
    FromRow, SqlitePool,
};
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

#[derive(Debug, Clone, Serialize, Deserialize, FromRow)]
pub struct HarnessFavoriteRow {
    pub source_key: String,
    pub created_at: DateTime<Utc>,
}

#[derive(Debug, Clone, Serialize, Deserialize, FromRow)]
pub struct HarnessCollectionRow {
    pub id: String,
    pub name: String,
    pub created_at: DateTime<Utc>,
    pub updated_at: DateTime<Utc>,
}

#[derive(Debug, Clone, Serialize, Deserialize, FromRow)]
pub struct HarnessCollectionItemRow {
    pub collection_id: String,
    pub source_key: String,
    pub created_at: DateTime<Utc>,
}

#[derive(Debug, Clone, Serialize, Deserialize, FromRow)]
pub struct HarnessScanRootRow {
    pub id: String,
    pub path: String,
    pub label: Option<String>,
    pub enabled: bool,
    pub created_at: DateTime<Utc>,
    pub updated_at: DateTime<Utc>,
}

#[derive(Debug, Clone, Serialize, Deserialize, FromRow)]
pub struct HarnessInstallRecordRow {
    pub id: String,
    pub source_key: String,
    pub source_path: String,
    pub source_root_path: String,
    pub target_path: String,
    pub target_root_path: String,
    pub tool: String,
    pub scope: String,
    pub backing_mode: String,
    pub removal_policy: String,
    pub last_synced_fingerprint: Option<String>,
    pub created_at: DateTime<Utc>,
    pub updated_at: DateTime<Utc>,
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
        let options = SqliteConnectOptions::new()
            .filename(&db_path)
            .create_if_missing(true)
            .pragma("journal_mode", "wal")
            .pragma("busy_timeout", "5000")
            .pragma("foreign_keys", "on");

        let pool = SqlitePoolOptions::new()
            .max_connections(2)
            .connect_with(options)
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
            "CREATE TABLE IF NOT EXISTS harness_favorites (
                source_key TEXT PRIMARY KEY,
                created_at TEXT NOT NULL
            )",
        )
        .execute(&pool)
        .await?;

        sqlx::query(
            "CREATE TABLE IF NOT EXISTS harness_collections (
                id TEXT PRIMARY KEY,
                name TEXT NOT NULL UNIQUE,
                created_at TEXT NOT NULL,
                updated_at TEXT NOT NULL
            )",
        )
        .execute(&pool)
        .await?;

        sqlx::query(
            "CREATE TABLE IF NOT EXISTS harness_collection_items (
                collection_id TEXT NOT NULL,
                source_key TEXT NOT NULL,
                created_at TEXT NOT NULL,
                PRIMARY KEY (collection_id, source_key),
                FOREIGN KEY (collection_id) REFERENCES harness_collections(id) ON DELETE CASCADE
            )",
        )
        .execute(&pool)
        .await?;

        sqlx::query(
            "CREATE TABLE IF NOT EXISTS harness_scan_roots (
                id TEXT PRIMARY KEY,
                path TEXT NOT NULL UNIQUE,
                label TEXT,
                enabled INTEGER NOT NULL DEFAULT 1,
                created_at TEXT NOT NULL,
                updated_at TEXT NOT NULL
            )",
        )
        .execute(&pool)
        .await?;

        sqlx::query(
            "CREATE TABLE IF NOT EXISTS harness_install_records (
                id TEXT PRIMARY KEY,
                source_key TEXT NOT NULL,
                source_path TEXT NOT NULL,
                source_root_path TEXT NOT NULL,
                target_path TEXT NOT NULL UNIQUE,
                target_root_path TEXT NOT NULL,
                tool TEXT NOT NULL,
                scope TEXT NOT NULL,
                backing_mode TEXT NOT NULL,
                removal_policy TEXT NOT NULL,
                last_synced_fingerprint TEXT,
                created_at TEXT NOT NULL,
                updated_at TEXT NOT NULL
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

        // Add columns if they don't exist (safe for both fresh and existing DBs).
        // The column_exists check avoids noisy ALTER TABLE attempts; the error
        // catch handles TOCTOU races when multiple processes open the same DB.
        for (column, col_def) in &[
            ("source", "TEXT NOT NULL DEFAULT 'user'"),
            ("source_path", "TEXT"),
            ("user_modified", "INTEGER NOT NULL DEFAULT 0"),
            ("thinking_level", "TEXT"),
            ("thinking_budget", "INTEGER"),
            ("tool_restrictions_json", "TEXT"),
            ("extra_flags_json", "TEXT"),
        ] {
            if !Self::column_exists(&pool, "global_agent_profiles", column).await? {
                let stmt = format!(
                    "ALTER TABLE global_agent_profiles ADD COLUMN {} {}",
                    column, col_def
                );
                match sqlx::query(&stmt).execute(&pool).await {
                    Ok(_) => {}
                    Err(sqlx::Error::Database(ref db_err))
                        if db_err.message().contains("duplicate column") => {}
                    Err(e) => return Err(e.into()),
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

    async fn column_exists(pool: &SqlitePool, table: &str, column: &str) -> Result<bool, DbError> {
        let query = format!("PRAGMA table_info({})", table);
        let rows: Vec<(i64, String, String, i64, Option<String>, i64)> =
            sqlx::query_as(&query).fetch_all(pool).await?;
        Ok(rows.iter().any(|r| r.1 == column))
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
                 source, source_path, user_modified,
                 thinking_level, thinking_budget, tool_restrictions_json, extra_flags_json)
             VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12, ?13, ?14, ?15, ?16, ?17, ?18, ?19, ?20, ?21)",
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
        .bind(&row.thinking_level)
        .bind(row.thinking_budget)
        .bind(&row.tool_restrictions_json)
        .bind(&row.extra_flags_json)
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
                    source, source_path, user_modified,
                    thinking_level, thinking_budget, tool_restrictions_json, extra_flags_json
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
                    source, source_path, user_modified,
                    thinking_level, thinking_budget, tool_restrictions_json, extra_flags_json
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
                    source, source_path, user_modified,
                    thinking_level, thinking_budget, tool_restrictions_json, extra_flags_json
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
                    source, source_path, user_modified,
                    thinking_level, thinking_budget, tool_restrictions_json, extra_flags_json
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
                 source = ?13, source_path = ?14, user_modified = ?15,
                 thinking_level = ?16, thinking_budget = ?17,
                 tool_restrictions_json = ?18, extra_flags_json = ?19
             WHERE id = ?20",
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
        .bind(&row.thinking_level)
        .bind(row.thinking_budget)
        .bind(&row.tool_restrictions_json)
        .bind(&row.extra_flags_json)
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
    ) -> Result<GlobalSshProfileRow, DbError> {
        let stored = sqlx::query_as::<_, GlobalSshProfileRow>(
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
                updated_at = excluded.updated_at
             RETURNING id, name, host, port, user, identity_file, proxy_jump, tags_json, source, created_at, updated_at",
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
        .fetch_one(&self.pool)
        .await?;
        Ok(stored)
    }

    pub async fn delete_global_ssh_profile(&self, id: &str) -> Result<(), DbError> {
        sqlx::query("DELETE FROM global_ssh_profiles WHERE id = ?1")
            .bind(id)
            .execute(&self.pool)
            .await?;
        Ok(())
    }

    pub async fn list_harness_favorites(&self) -> Result<Vec<HarnessFavoriteRow>, DbError> {
        let rows = sqlx::query_as::<_, HarnessFavoriteRow>(
            "SELECT source_key, created_at
             FROM harness_favorites
             ORDER BY created_at DESC",
        )
        .fetch_all(&self.pool)
        .await?;
        Ok(rows)
    }

    pub async fn set_harness_favorite(
        &self,
        source_key: &str,
        favorite: bool,
    ) -> Result<(), DbError> {
        if favorite {
            sqlx::query(
                "INSERT INTO harness_favorites (source_key, created_at)
                 VALUES (?1, ?2)
                 ON CONFLICT(source_key) DO NOTHING",
            )
            .bind(source_key)
            .bind(Utc::now())
            .execute(&self.pool)
            .await?;
        } else {
            sqlx::query("DELETE FROM harness_favorites WHERE source_key = ?1")
                .bind(source_key)
                .execute(&self.pool)
                .await?;
        }
        Ok(())
    }

    pub async fn list_harness_collections(&self) -> Result<Vec<HarnessCollectionRow>, DbError> {
        let rows = sqlx::query_as::<_, HarnessCollectionRow>(
            "SELECT id, name, created_at, updated_at
             FROM harness_collections
             ORDER BY lower(name) ASC",
        )
        .fetch_all(&self.pool)
        .await?;
        Ok(rows)
    }

    pub async fn create_harness_collection(
        &self,
        row: &HarnessCollectionRow,
    ) -> Result<(), DbError> {
        sqlx::query(
            "INSERT INTO harness_collections (id, name, created_at, updated_at)
             VALUES (?1, ?2, ?3, ?4)",
        )
        .bind(&row.id)
        .bind(&row.name)
        .bind(row.created_at)
        .bind(row.updated_at)
        .execute(&self.pool)
        .await?;
        Ok(())
    }

    pub async fn rename_harness_collection(&self, id: &str, name: &str) -> Result<(), DbError> {
        sqlx::query(
            "UPDATE harness_collections
             SET name = ?1, updated_at = ?2
             WHERE id = ?3",
        )
        .bind(name)
        .bind(Utc::now())
        .bind(id)
        .execute(&self.pool)
        .await?;
        Ok(())
    }

    pub async fn delete_harness_collection(&self, id: &str) -> Result<(), DbError> {
        sqlx::query("DELETE FROM harness_collections WHERE id = ?1")
            .bind(id)
            .execute(&self.pool)
            .await?;
        Ok(())
    }

    pub async fn list_harness_collection_items(
        &self,
    ) -> Result<Vec<HarnessCollectionItemRow>, DbError> {
        let rows = sqlx::query_as::<_, HarnessCollectionItemRow>(
            "SELECT collection_id, source_key, created_at
             FROM harness_collection_items
             ORDER BY created_at DESC",
        )
        .fetch_all(&self.pool)
        .await?;
        Ok(rows)
    }

    pub async fn add_harness_collection_item(
        &self,
        collection_id: &str,
        source_key: &str,
    ) -> Result<(), DbError> {
        sqlx::query(
            "INSERT INTO harness_collection_items (collection_id, source_key, created_at)
             VALUES (?1, ?2, ?3)
             ON CONFLICT(collection_id, source_key) DO NOTHING",
        )
        .bind(collection_id)
        .bind(source_key)
        .bind(Utc::now())
        .execute(&self.pool)
        .await?;
        Ok(())
    }

    pub async fn remove_harness_collection_item(
        &self,
        collection_id: &str,
        source_key: &str,
    ) -> Result<(), DbError> {
        sqlx::query(
            "DELETE FROM harness_collection_items
             WHERE collection_id = ?1 AND source_key = ?2",
        )
        .bind(collection_id)
        .bind(source_key)
        .execute(&self.pool)
        .await?;
        Ok(())
    }

    pub async fn list_harness_scan_roots(&self) -> Result<Vec<HarnessScanRootRow>, DbError> {
        let rows = sqlx::query_as::<_, HarnessScanRootRow>(
            "SELECT id, path, label, enabled, created_at, updated_at
             FROM harness_scan_roots
             ORDER BY lower(path) ASC",
        )
        .fetch_all(&self.pool)
        .await?;
        Ok(rows)
    }

    pub async fn upsert_harness_scan_root(
        &self,
        row: &HarnessScanRootRow,
    ) -> Result<HarnessScanRootRow, DbError> {
        let stored = sqlx::query_as::<_, HarnessScanRootRow>(
            "INSERT INTO harness_scan_roots (id, path, label, enabled, created_at, updated_at)
             VALUES (?1, ?2, ?3, ?4, ?5, ?6)
             ON CONFLICT(path) DO UPDATE SET
                label = excluded.label,
                enabled = excluded.enabled,
                updated_at = excluded.updated_at
             RETURNING id, path, label, enabled, created_at, updated_at",
        )
        .bind(&row.id)
        .bind(&row.path)
        .bind(&row.label)
        .bind(row.enabled)
        .bind(row.created_at)
        .bind(row.updated_at)
        .fetch_one(&self.pool)
        .await?;
        Ok(stored)
    }

    pub async fn set_harness_scan_root_enabled(
        &self,
        id: &str,
        enabled: bool,
    ) -> Result<(), DbError> {
        sqlx::query(
            "UPDATE harness_scan_roots
             SET enabled = ?1, updated_at = ?2
             WHERE id = ?3",
        )
        .bind(enabled)
        .bind(Utc::now())
        .bind(id)
        .execute(&self.pool)
        .await?;
        Ok(())
    }

    pub async fn delete_harness_scan_root(&self, id: &str) -> Result<(), DbError> {
        sqlx::query("DELETE FROM harness_scan_roots WHERE id = ?1")
            .bind(id)
            .execute(&self.pool)
            .await?;
        Ok(())
    }

    pub async fn list_harness_install_records(
        &self,
    ) -> Result<Vec<HarnessInstallRecordRow>, DbError> {
        let rows = sqlx::query_as::<_, HarnessInstallRecordRow>(
            "SELECT id, source_key, source_path, source_root_path, target_path, target_root_path,
                    tool, scope, backing_mode, removal_policy, last_synced_fingerprint,
                    created_at, updated_at
             FROM harness_install_records
             ORDER BY created_at ASC",
        )
        .fetch_all(&self.pool)
        .await?;
        Ok(rows)
    }

    pub async fn upsert_harness_install_record(
        &self,
        row: &HarnessInstallRecordRow,
    ) -> Result<HarnessInstallRecordRow, DbError> {
        let stored = sqlx::query_as::<_, HarnessInstallRecordRow>(
            "INSERT INTO harness_install_records
                (id, source_key, source_path, source_root_path, target_path, target_root_path,
                 tool, scope, backing_mode, removal_policy, last_synced_fingerprint,
                 created_at, updated_at)
             VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12, ?13)
             ON CONFLICT(target_path) DO UPDATE SET
                source_key = excluded.source_key,
                source_path = excluded.source_path,
                source_root_path = excluded.source_root_path,
                target_root_path = excluded.target_root_path,
                tool = excluded.tool,
                scope = excluded.scope,
                backing_mode = excluded.backing_mode,
                removal_policy = excluded.removal_policy,
                last_synced_fingerprint = excluded.last_synced_fingerprint,
                updated_at = excluded.updated_at
             RETURNING id, source_key, source_path, source_root_path, target_path, target_root_path,
                       tool, scope, backing_mode, removal_policy, last_synced_fingerprint,
                       created_at, updated_at",
        )
        .bind(&row.id)
        .bind(&row.source_key)
        .bind(&row.source_path)
        .bind(&row.source_root_path)
        .bind(&row.target_path)
        .bind(&row.target_root_path)
        .bind(&row.tool)
        .bind(&row.scope)
        .bind(&row.backing_mode)
        .bind(&row.removal_policy)
        .bind(&row.last_synced_fingerprint)
        .bind(row.created_at)
        .bind(row.updated_at)
        .fetch_one(&self.pool)
        .await?;
        Ok(stored)
    }

    pub async fn delete_harness_install_record_by_target_path(
        &self,
        target_path: &str,
    ) -> Result<(), DbError> {
        sqlx::query("DELETE FROM harness_install_records WHERE target_path = ?1")
            .bind(target_path)
            .execute(&self.pool)
            .await?;
        Ok(())
    }

    pub async fn delete_harness_install_records_by_source_key(
        &self,
        source_key: &str,
    ) -> Result<(), DbError> {
        sqlx::query("DELETE FROM harness_install_records WHERE source_key = ?1")
            .bind(source_key)
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

    #[cfg(unix)]
    #[tokio::test]
    async fn open_creates_global_dir_with_0700() {
        use std::os::unix::fs::PermissionsExt;
        let root = std::env::temp_dir().join(format!("pnevma-gdb-dir-perm-{}", Uuid::new_v4()));
        let db_dir = root.join(".local/share/pnevma");
        tokio::fs::create_dir_all(&root)
            .await
            .expect("create temp root");

        let _db = GlobalDb::open_in_dir(db_dir.clone())
            .await
            .expect("open global db");
        let meta = std::fs::metadata(&db_dir).expect("stat global db dir");
        let mode = meta.permissions().mode() & 0o777;
        assert_eq!(
            mode, 0o700,
            "expected global db dir mode 0700, got {:o}",
            mode
        );

        let _ = tokio::fs::remove_dir_all(&root).await;
    }

    #[cfg(unix)]
    #[tokio::test]
    async fn open_corrects_overly_permissive_global_dir() {
        use std::os::unix::fs::PermissionsExt;
        let root = std::env::temp_dir().join(format!("pnevma-gdb-dir-fix-{}", Uuid::new_v4()));
        let db_dir = root.join(".local/share/pnevma");
        tokio::fs::create_dir_all(&db_dir)
            .await
            .expect("create global db dir");
        std::fs::set_permissions(&db_dir, std::fs::Permissions::from_mode(0o755))
            .expect("set permissive mode");

        let _db = GlobalDb::open_in_dir(db_dir.clone())
            .await
            .expect("open global db");
        let meta = std::fs::metadata(&db_dir).expect("stat global db dir");
        let mode = meta.permissions().mode() & 0o777;
        assert_eq!(mode, 0o700, "expected corrected mode 0700, got {:o}", mode);

        let _ = tokio::fs::remove_dir_all(&root).await;
    }

    #[cfg(unix)]
    #[tokio::test]
    async fn open_creates_global_db_file_with_0600() {
        use std::os::unix::fs::PermissionsExt;
        let root = std::env::temp_dir().join(format!("pnevma-gdb-file-perm-{}", Uuid::new_v4()));
        let db_dir = root.join(".local/share/pnevma");
        tokio::fs::create_dir_all(&root)
            .await
            .expect("create temp root");

        let db = GlobalDb::open_in_dir(db_dir.clone())
            .await
            .expect("open global db");
        let meta = std::fs::metadata(db.path()).expect("stat global db file");
        let mode = meta.permissions().mode() & 0o777;
        assert_eq!(
            mode, 0o600,
            "expected global db file mode 0600, got {:o}",
            mode
        );

        drop(db);
        let _ = tokio::fs::remove_dir_all(&root).await;
    }

    #[tokio::test]
    async fn upsert_global_ssh_profile_returns_persisted_row_on_name_conflict() {
        let root = std::env::temp_dir().join(format!("pnevma-gdb-ssh-upsert-{}", Uuid::new_v4()));
        let db_dir = root.join(".local/share/pnevma");
        tokio::fs::create_dir_all(&root)
            .await
            .expect("create temp root");

        let db = GlobalDb::open_in_dir(db_dir).await.expect("open global db");
        let now = Utc::now();
        let original = GlobalSshProfileRow {
            id: "profile-original".to_string(),
            name: "Build Box".to_string(),
            host: "build-1.example.com".to_string(),
            port: 22,
            user: Some("builder".to_string()),
            identity_file: Some("/tmp/id_ed25519".to_string()),
            proxy_jump: None,
            tags_json: "[]".to_string(),
            source: "manual".to_string(),
            created_at: now,
            updated_at: now,
        };
        let updated = GlobalSshProfileRow {
            id: "profile-updated".to_string(),
            name: original.name.clone(),
            host: "build-2.example.com".to_string(),
            port: 2222,
            user: Some("ops".to_string()),
            identity_file: Some("/tmp/id_ed25519_new".to_string()),
            proxy_jump: Some("jump.example.com".to_string()),
            tags_json: "[\"release\"]".to_string(),
            source: "manual".to_string(),
            created_at: now + chrono::Duration::seconds(30),
            updated_at: now + chrono::Duration::seconds(30),
        };

        let first = db
            .upsert_global_ssh_profile(&original)
            .await
            .expect("insert ssh profile");
        let second = db
            .upsert_global_ssh_profile(&updated)
            .await
            .expect("update ssh profile");

        assert_eq!(first.id, original.id);
        assert_eq!(
            second.id, original.id,
            "name conflict must keep persisted row id"
        );
        assert_eq!(second.host, updated.host);
        assert_eq!(second.port, updated.port);
        assert_eq!(second.user, updated.user);
        assert_eq!(second.identity_file, updated.identity_file);
        assert_eq!(second.proxy_jump, updated.proxy_jump);
        assert_eq!(second.tags_json, updated.tags_json);
        assert_eq!(second.created_at, original.created_at);
        assert_eq!(second.updated_at, updated.updated_at);

        assert!(
            db.get_global_ssh_profile(&updated.id)
                .await
                .expect("get conflicting id")
                .is_none(),
            "conflicting insert id must not create a second row"
        );

        let persisted = db
            .get_global_ssh_profile(&original.id)
            .await
            .expect("get persisted row")
            .expect("persisted row exists");
        assert_eq!(persisted.host, updated.host);
        assert_eq!(persisted.port, updated.port);
        assert_eq!(persisted.user, updated.user);

        drop(db);
        let _ = tokio::fs::remove_dir_all(&root).await;
    }

    #[tokio::test]
    async fn harness_scan_roots_roundtrip() {
        let root = std::env::temp_dir().join(format!("pnevma-gdb-harness-root-{}", Uuid::new_v4()));
        let db_dir = root.join(".local/share/pnevma");
        tokio::fs::create_dir_all(&root)
            .await
            .expect("create temp root");

        let db = GlobalDb::open_in_dir(db_dir).await.expect("open global db");
        let now = Utc::now();
        let row = HarnessScanRootRow {
            id: "root-1".to_string(),
            path: "/tmp/skills".to_string(),
            label: Some("Temp".to_string()),
            enabled: true,
            created_at: now,
            updated_at: now,
        };

        let stored = db
            .upsert_harness_scan_root(&row)
            .await
            .expect("upsert harness scan root");
        assert_eq!(stored.path, row.path);

        db.set_harness_scan_root_enabled(&row.id, false)
            .await
            .expect("disable scan root");

        let rows = db
            .list_harness_scan_roots()
            .await
            .expect("list harness scan roots");
        assert_eq!(rows.len(), 1);
        assert!(!rows[0].enabled);

        db.delete_harness_scan_root(&row.id)
            .await
            .expect("delete scan root");
        assert!(db
            .list_harness_scan_roots()
            .await
            .expect("list after delete")
            .is_empty());

        drop(db);
        let _ = tokio::fs::remove_dir_all(&root).await;
    }

    #[tokio::test]
    async fn harness_favorites_roundtrip() {
        let root = std::env::temp_dir().join(format!("pnevma-gdb-harness-fav-{}", Uuid::new_v4()));
        let db_dir = root.join(".local/share/pnevma");
        tokio::fs::create_dir_all(&root)
            .await
            .expect("create temp root");

        let db = GlobalDb::open_in_dir(db_dir).await.expect("open global db");
        db.set_harness_favorite("abc123", true)
            .await
            .expect("favorite item");
        let rows = db.list_harness_favorites().await.expect("list favorites");
        assert_eq!(rows.len(), 1);
        assert_eq!(rows[0].source_key, "abc123");

        db.set_harness_favorite("abc123", false)
            .await
            .expect("unfavorite item");
        assert!(db
            .list_harness_favorites()
            .await
            .expect("list empty favorites")
            .is_empty());

        drop(db);
        let _ = tokio::fs::remove_dir_all(&root).await;
    }

    #[tokio::test]
    async fn harness_install_records_roundtrip() {
        let root =
            std::env::temp_dir().join(format!("pnevma-gdb-harness-install-{}", Uuid::new_v4()));
        let db_dir = root.join(".local/share/pnevma");
        tokio::fs::create_dir_all(&root)
            .await
            .expect("create temp root");

        let db = GlobalDb::open_in_dir(db_dir).await.expect("open global db");
        let now = Utc::now();
        let row = HarnessInstallRecordRow {
            id: "install-1".to_string(),
            source_key: "source-1".to_string(),
            source_path: "/tmp/source/SKILL.md".to_string(),
            source_root_path: "/tmp/source".to_string(),
            target_path: "/tmp/target/SKILL.md".to_string(),
            target_root_path: "/tmp/target".to_string(),
            tool: "codex".to_string(),
            scope: "user".to_string(),
            backing_mode: "copy".to_string(),
            removal_policy: "delete_target".to_string(),
            last_synced_fingerprint: Some("abc".to_string()),
            created_at: now,
            updated_at: now,
        };

        let stored = db
            .upsert_harness_install_record(&row)
            .await
            .expect("upsert install record");
        assert_eq!(stored.target_path, row.target_path);

        let rows = db
            .list_harness_install_records()
            .await
            .expect("list install records");
        assert_eq!(rows.len(), 1);
        assert_eq!(rows[0].removal_policy, "delete_target");

        db.delete_harness_install_record_by_target_path(&row.target_path)
            .await
            .expect("delete install record");
        assert!(db
            .list_harness_install_records()
            .await
            .expect("list after delete")
            .is_empty());

        drop(db);
        let _ = tokio::fs::remove_dir_all(&root).await;
    }
}
