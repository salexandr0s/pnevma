use crate::error::DbError;
use crate::models::{
    AgentProfileRow, ArtifactRow, CheckResultRow, CheckRunRow, CheckpointRow, ContextRuleUsageRow,
    CostDailyAggregateRow, CostRow, ErrorSignatureDailyRow, ErrorSignatureRow, EventRow,
    FeedbackRow, MergeQueueRow, NotificationRow, OnboardingStateRow, PaneLayoutTemplateRow,
    PaneRow, ProjectRow, ReviewRow, RuleRow, SecretRefRow, SessionRow, SshProfileRow,
    StoryProgressRow, TaskRow, TaskStoryRow, TelemetryEventRow, WorkflowInstanceRow, WorkflowRow,
    WorkflowTaskRow, WorktreeRow,
};
use chrono::{DateTime, Utc};
use serde_json::Value;
use sqlx::{sqlite::SqlitePoolOptions, SqlitePool};
use std::path::{Path, PathBuf};

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
    pool: SqlitePool,
    path: PathBuf,
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

    pub async fn upsert_project(
        &self,
        id: &str,
        name: &str,
        path: &str,
        brief: Option<&str>,
        config_path: Option<&str>,
    ) -> Result<(), DbError> {
        let now = Utc::now();
        sqlx::query(
            r#"
            INSERT INTO projects (id, name, path, brief, config_path, created_at)
            VALUES (?1, ?2, ?3, ?4, ?5, ?6)
            ON CONFLICT(id) DO UPDATE SET
              name=excluded.name,
              path=excluded.path,
              brief=excluded.brief,
              config_path=excluded.config_path
            "#,
        )
        .bind(id)
        .bind(name)
        .bind(path)
        .bind(brief)
        .bind(config_path)
        .bind(now)
        .execute(&self.pool)
        .await?;
        Ok(())
    }

    pub async fn list_projects(&self) -> Result<Vec<ProjectRow>, DbError> {
        let rows = sqlx::query_as::<_, ProjectRow>(
            "SELECT id, name, path, brief, config_path, created_at FROM projects ORDER BY created_at DESC",
        )
        .fetch_all(&self.pool)
        .await?;
        Ok(rows)
    }

    pub async fn find_project_by_path(&self, path: &str) -> Result<Option<ProjectRow>, DbError> {
        let row = sqlx::query_as::<_, ProjectRow>(
            r#"
            SELECT id, name, path, brief, config_path, created_at
            FROM projects
            WHERE path = ?1
            LIMIT 1
            "#,
        )
        .bind(path)
        .fetch_optional(&self.pool)
        .await?;
        Ok(row)
    }

    pub async fn upsert_session(&self, session: &SessionRow) -> Result<(), DbError> {
        sqlx::query(
            r#"
            INSERT INTO sessions
            (id, project_id, name, type, status, pid, cwd, command, branch, worktree_id, started_at, last_heartbeat)
            VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12)
            ON CONFLICT(id) DO UPDATE SET
              status=excluded.status,
              pid=excluded.pid,
              cwd=excluded.cwd,
              command=excluded.command,
              branch=excluded.branch,
              worktree_id=excluded.worktree_id,
              last_heartbeat=excluded.last_heartbeat
            "#,
        )
        .bind(&session.id)
        .bind(&session.project_id)
        .bind(&session.name)
        .bind(&session.r#type)
        .bind(&session.status)
        .bind(session.pid)
        .bind(&session.cwd)
        .bind(&session.command)
        .bind(&session.branch)
        .bind(&session.worktree_id)
        .bind(session.started_at)
        .bind(session.last_heartbeat)
        .execute(&self.pool)
        .await?;
        Ok(())
    }

    pub async fn list_sessions(&self, project_id: &str) -> Result<Vec<SessionRow>, DbError> {
        let rows = sqlx::query_as::<_, SessionRow>(
            r#"
            SELECT id, project_id, name, type, status, pid, cwd, command, branch, worktree_id, started_at, last_heartbeat
            FROM sessions
            WHERE project_id = ?1
            ORDER BY started_at DESC
            "#,
        )
        .bind(project_id)
        .fetch_all(&self.pool)
        .await?;
        Ok(rows)
    }

    pub async fn upsert_pane(&self, pane: &PaneRow) -> Result<(), DbError> {
        sqlx::query(
            r#"
            INSERT INTO panes (id, project_id, session_id, type, position, label, metadata_json)
            VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7)
            ON CONFLICT(id) DO UPDATE SET
              project_id=excluded.project_id,
              session_id=excluded.session_id,
              type=excluded.type,
              position=excluded.position,
              label=excluded.label,
              metadata_json=excluded.metadata_json
            "#,
        )
        .bind(&pane.id)
        .bind(&pane.project_id)
        .bind(&pane.session_id)
        .bind(&pane.r#type)
        .bind(&pane.position)
        .bind(&pane.label)
        .bind(&pane.metadata_json)
        .execute(&self.pool)
        .await?;
        Ok(())
    }

    pub async fn list_panes(&self, project_id: &str) -> Result<Vec<PaneRow>, DbError> {
        let rows = sqlx::query_as::<_, PaneRow>(
            r#"
            SELECT id, project_id, session_id, type, position, label, metadata_json
            FROM panes
            WHERE project_id = ?1
            ORDER BY
              CASE WHEN position = 'root' THEN 0 ELSE 1 END ASC,
              position ASC,
              id ASC
            "#,
        )
        .bind(project_id)
        .fetch_all(&self.pool)
        .await?;
        Ok(rows)
    }

    pub async fn remove_pane(&self, pane_id: &str) -> Result<(), DbError> {
        sqlx::query("DELETE FROM panes WHERE id = ?1")
            .bind(pane_id)
            .execute(&self.pool)
            .await?;
        Ok(())
    }

    pub async fn upsert_pane_layout_template(
        &self,
        row: &PaneLayoutTemplateRow,
    ) -> Result<(), DbError> {
        sqlx::query(
            r#"
            INSERT INTO pane_layout_templates
            (id, project_id, name, display_name, pane_graph_json, is_system, created_at, updated_at)
            VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8)
            ON CONFLICT(project_id, name) DO UPDATE SET
              display_name = excluded.display_name,
              pane_graph_json = excluded.pane_graph_json,
              is_system = excluded.is_system,
              updated_at = excluded.updated_at
            "#,
        )
        .bind(&row.id)
        .bind(&row.project_id)
        .bind(&row.name)
        .bind(&row.display_name)
        .bind(&row.pane_graph_json)
        .bind(row.is_system)
        .bind(row.created_at)
        .bind(row.updated_at)
        .execute(&self.pool)
        .await?;
        Ok(())
    }

    pub async fn get_pane_layout_template(
        &self,
        project_id: &str,
        name: &str,
    ) -> Result<Option<PaneLayoutTemplateRow>, DbError> {
        let row = sqlx::query_as::<_, PaneLayoutTemplateRow>(
            r#"
            SELECT id, project_id, name, display_name, pane_graph_json, is_system, created_at, updated_at
            FROM pane_layout_templates
            WHERE project_id = ?1 AND name = ?2
            LIMIT 1
            "#,
        )
        .bind(project_id)
        .bind(name)
        .fetch_optional(&self.pool)
        .await?;
        Ok(row)
    }

    pub async fn list_pane_layout_templates(
        &self,
        project_id: &str,
    ) -> Result<Vec<PaneLayoutTemplateRow>, DbError> {
        let rows = sqlx::query_as::<_, PaneLayoutTemplateRow>(
            r#"
            SELECT id, project_id, name, display_name, pane_graph_json, is_system, created_at, updated_at
            FROM pane_layout_templates
            WHERE project_id = ?1
            ORDER BY is_system DESC, name ASC
            "#,
        )
        .bind(project_id)
        .fetch_all(&self.pool)
        .await?;
        Ok(rows)
    }

    pub async fn create_task(&self, task: &TaskRow) -> Result<(), DbError> {
        sqlx::query(
            r#"
            INSERT INTO tasks
            (id, project_id, title, goal, scope_json, dependencies_json, acceptance_json, constraints_json, priority, status, branch, worktree_id, handoff_summary, created_at, updated_at, auto_dispatch, agent_profile_override, execution_mode, timeout_minutes, max_retries)
            VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12, ?13, ?14, ?15, ?16, ?17, ?18, ?19, ?20)
            "#,
        )
        .bind(&task.id)
        .bind(&task.project_id)
        .bind(&task.title)
        .bind(&task.goal)
        .bind(&task.scope_json)
        .bind(&task.dependencies_json)
        .bind(&task.acceptance_json)
        .bind(&task.constraints_json)
        .bind(&task.priority)
        .bind(&task.status)
        .bind(&task.branch)
        .bind(&task.worktree_id)
        .bind(&task.handoff_summary)
        .bind(task.created_at)
        .bind(task.updated_at)
        .bind(task.auto_dispatch)
        .bind(&task.agent_profile_override)
        .bind(&task.execution_mode)
        .bind(task.timeout_minutes)
        .bind(task.max_retries)
        .execute(&self.pool)
        .await?;
        Ok(())
    }

    pub async fn update_task(&self, task: &TaskRow) -> Result<(), DbError> {
        sqlx::query(
            r#"
            UPDATE tasks
            SET title = ?2,
                goal = ?3,
                scope_json = ?4,
                dependencies_json = ?5,
                acceptance_json = ?6,
                constraints_json = ?7,
                priority = ?8,
                status = ?9,
                branch = ?10,
                worktree_id = ?11,
                handoff_summary = ?12,
                updated_at = ?13,
                auto_dispatch = ?14,
                agent_profile_override = ?15,
                execution_mode = ?16,
                timeout_minutes = ?17,
                max_retries = ?18
            WHERE id = ?1
            "#,
        )
        .bind(&task.id)
        .bind(&task.title)
        .bind(&task.goal)
        .bind(&task.scope_json)
        .bind(&task.dependencies_json)
        .bind(&task.acceptance_json)
        .bind(&task.constraints_json)
        .bind(&task.priority)
        .bind(&task.status)
        .bind(&task.branch)
        .bind(&task.worktree_id)
        .bind(&task.handoff_summary)
        .bind(task.updated_at)
        .bind(task.auto_dispatch)
        .bind(&task.agent_profile_override)
        .bind(&task.execution_mode)
        .bind(task.timeout_minutes)
        .bind(task.max_retries)
        .execute(&self.pool)
        .await?;
        Ok(())
    }

    pub async fn get_task(&self, task_id: &str) -> Result<Option<TaskRow>, DbError> {
        let row = sqlx::query_as::<_, TaskRow>(
            r#"
            SELECT id, project_id, title, goal, scope_json, dependencies_json, acceptance_json, constraints_json,
                   priority, status, branch, worktree_id, handoff_summary, created_at, updated_at,
                   auto_dispatch, agent_profile_override, execution_mode, timeout_minutes, max_retries
            FROM tasks
            WHERE id = ?1
            LIMIT 1
            "#,
        )
        .bind(task_id)
        .fetch_optional(&self.pool)
        .await?;
        Ok(row)
    }

    pub async fn delete_task(&self, task_id: &str) -> Result<(), DbError> {
        sqlx::query("DELETE FROM tasks WHERE id = ?1")
            .bind(task_id)
            .execute(&self.pool)
            .await?;
        Ok(())
    }

    pub async fn update_task_profile_override(
        &self,
        task_id: &str,
        profile_name: Option<&str>,
    ) -> Result<(), DbError> {
        sqlx::query(
            r#"
            UPDATE tasks SET agent_profile_override = ?2, updated_at = datetime('now') WHERE id = ?1
            "#,
        )
        .bind(task_id)
        .bind(profile_name)
        .execute(&self.pool)
        .await?;
        Ok(())
    }

    pub async fn replace_task_dependencies(
        &self,
        task_id: &str,
        dependencies: &[String],
    ) -> Result<(), DbError> {
        let mut tx = self.pool.begin().await?;
        sqlx::query("DELETE FROM task_dependencies WHERE task_id = ?1")
            .bind(task_id)
            .execute(&mut *tx)
            .await?;

        for dep in dependencies {
            sqlx::query(
                r#"
                INSERT OR IGNORE INTO task_dependencies (task_id, depends_on_task_id)
                VALUES (?1, ?2)
                "#,
            )
            .bind(task_id)
            .bind(dep)
            .execute(&mut *tx)
            .await?;
        }
        tx.commit().await?;
        Ok(())
    }

    pub async fn list_task_dependencies(&self, task_id: &str) -> Result<Vec<String>, DbError> {
        let rows = sqlx::query_scalar::<_, String>(
            r#"
            SELECT depends_on_task_id
            FROM task_dependencies
            WHERE task_id = ?1
            ORDER BY depends_on_task_id ASC
            "#,
        )
        .bind(task_id)
        .fetch_all(&self.pool)
        .await?;
        Ok(rows)
    }

    pub async fn list_tasks(&self, project_id: &str) -> Result<Vec<TaskRow>, DbError> {
        let rows = sqlx::query_as::<_, TaskRow>(
            r#"
            SELECT id, project_id, title, goal, scope_json, dependencies_json, acceptance_json, constraints_json,
                   priority, status, branch, worktree_id, handoff_summary, created_at, updated_at,
                   auto_dispatch, agent_profile_override, execution_mode, timeout_minutes, max_retries
            FROM tasks
            WHERE project_id = ?1
            ORDER BY created_at DESC
            "#,
        )
        .bind(project_id)
        .fetch_all(&self.pool)
        .await?;
        Ok(rows)
    }

    pub async fn append_event(&self, event: NewEvent) -> Result<(), DbError> {
        sqlx::query(
            r#"
            INSERT INTO events (id, project_id, task_id, session_id, trace_id, source, event_type, payload_json, timestamp)
            VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9)
            "#,
        )
        .bind(event.id)
        .bind(event.project_id)
        .bind(event.task_id)
        .bind(event.session_id)
        .bind(event.trace_id)
        .bind(event.source)
        .bind(event.event_type)
        .bind(event.payload.to_string())
        .bind(Utc::now())
        .execute(&self.pool)
        .await?;
        Ok(())
    }

    pub async fn query_events(&self, filter: EventQueryFilter) -> Result<Vec<EventRow>, DbError> {
        let mut query = String::from(
            r#"
            SELECT id, project_id, task_id, session_id, trace_id, source, event_type, payload_json, timestamp
            FROM events
            WHERE project_id = ?1
            "#,
        );

        if filter.task_id.is_some() {
            query.push_str(" AND task_id = ?2");
        }
        if filter.session_id.is_some() {
            query.push_str(if filter.task_id.is_some() {
                " AND session_id = ?3"
            } else {
                " AND session_id = ?2"
            });
        }
        let mut next_idx = 2;
        if filter.task_id.is_some() {
            next_idx += 1;
        }
        if filter.session_id.is_some() {
            next_idx += 1;
        }
        if filter.event_type.is_some() {
            query.push_str(&format!(" AND event_type = ?{next_idx}"));
            next_idx += 1;
        }
        if filter.from.is_some() {
            query.push_str(&format!(" AND timestamp >= ?{next_idx}"));
            next_idx += 1;
        }
        if filter.to.is_some() {
            query.push_str(&format!(" AND timestamp <= ?{next_idx}"));
            next_idx += 1;
        }

        query.push_str(" ORDER BY timestamp ASC, id ASC");
        if filter.limit.is_some() {
            query.push_str(&format!(" LIMIT ?{next_idx}"));
        }

        let mut q = sqlx::query_as::<_, EventRow>(&query).bind(&filter.project_id);
        if let Some(task_id) = &filter.task_id {
            q = q.bind(task_id);
        }
        if let Some(session_id) = &filter.session_id {
            q = q.bind(session_id);
        }
        if let Some(event_type) = &filter.event_type {
            q = q.bind(event_type);
        }
        if let Some(from) = filter.from {
            q = q.bind(from);
        }
        if let Some(to) = filter.to {
            q = q.bind(to);
        }
        if let Some(limit) = filter.limit {
            q = q.bind(limit);
        }

        let rows = q.fetch_all(&self.pool).await?;
        Ok(rows)
    }

    pub async fn list_recent_events(
        &self,
        project_id: &str,
        limit: i64,
    ) -> Result<Vec<EventRow>, DbError> {
        let mut rows = sqlx::query_as::<_, EventRow>(
            r#"
            SELECT id, project_id, task_id, session_id, trace_id, source, event_type, payload_json, timestamp
            FROM events
            WHERE project_id = ?1
            ORDER BY timestamp DESC, id DESC
            LIMIT ?2
            "#,
        )
        .bind(project_id)
        .bind(limit)
        .fetch_all(&self.pool)
        .await?;
        rows.reverse();
        Ok(rows)
    }

    pub async fn append_cost(&self, cost: &CostRow) -> Result<(), DbError> {
        sqlx::query(
            r#"
            INSERT INTO costs (id, agent_run_id, task_id, session_id, provider, model, tokens_in, tokens_out, estimated_usd, tracked, timestamp)
            VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11)
            "#,
        )
        .bind(&cost.id)
        .bind(&cost.agent_run_id)
        .bind(&cost.task_id)
        .bind(&cost.session_id)
        .bind(&cost.provider)
        .bind(&cost.model)
        .bind(cost.tokens_in)
        .bind(cost.tokens_out)
        .bind(cost.estimated_usd)
        .bind(cost.tracked)
        .bind(cost.timestamp)
        .execute(&self.pool)
        .await?;
        Ok(())
    }

    pub async fn upsert_worktree(&self, row: &WorktreeRow) -> Result<(), DbError> {
        sqlx::query(
            r#"
            INSERT INTO worktrees (id, project_id, task_id, path, branch, lease_status, lease_started, last_active)
            VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8)
            ON CONFLICT(id) DO UPDATE SET
              project_id = excluded.project_id,
              task_id = excluded.task_id,
              path = excluded.path,
              branch = excluded.branch,
              lease_status = excluded.lease_status,
              lease_started = excluded.lease_started,
              last_active = excluded.last_active
            "#,
        )
        .bind(&row.id)
        .bind(&row.project_id)
        .bind(&row.task_id)
        .bind(&row.path)
        .bind(&row.branch)
        .bind(&row.lease_status)
        .bind(row.lease_started)
        .bind(row.last_active)
        .execute(&self.pool)
        .await?;
        Ok(())
    }

    pub async fn find_worktree_by_task(
        &self,
        task_id: &str,
    ) -> Result<Option<WorktreeRow>, DbError> {
        let row = sqlx::query_as::<_, WorktreeRow>(
            r#"
            SELECT id, project_id, task_id, path, branch, lease_status, lease_started, last_active
            FROM worktrees
            WHERE task_id = ?1
            LIMIT 1
            "#,
        )
        .bind(task_id)
        .fetch_optional(&self.pool)
        .await?;
        Ok(row)
    }

    pub async fn list_worktrees(&self, project_id: &str) -> Result<Vec<WorktreeRow>, DbError> {
        let rows = sqlx::query_as::<_, WorktreeRow>(
            r#"
            SELECT id, project_id, task_id, path, branch, lease_status, lease_started, last_active
            FROM worktrees
            WHERE project_id = ?1
            ORDER BY lease_started DESC
            "#,
        )
        .bind(project_id)
        .fetch_all(&self.pool)
        .await?;
        Ok(rows)
    }

    pub async fn list_artifacts(&self, project_id: &str) -> Result<Vec<ArtifactRow>, DbError> {
        let rows = sqlx::query_as::<_, ArtifactRow>(
            r#"
            SELECT id, project_id, task_id, type, path, description, created_at
            FROM artifacts
            WHERE project_id = ?1
            ORDER BY created_at DESC
            "#,
        )
        .bind(project_id)
        .fetch_all(&self.pool)
        .await?;
        Ok(rows)
    }

    pub async fn create_artifact(&self, row: &ArtifactRow) -> Result<(), DbError> {
        sqlx::query(
            r#"
            INSERT INTO artifacts (id, project_id, task_id, type, path, description, created_at)
            VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7)
            "#,
        )
        .bind(&row.id)
        .bind(&row.project_id)
        .bind(&row.task_id)
        .bind(&row.r#type)
        .bind(&row.path)
        .bind(&row.description)
        .bind(row.created_at)
        .execute(&self.pool)
        .await?;
        Ok(())
    }

    pub async fn delete_artifact(&self, artifact_id: &str) -> Result<(), DbError> {
        sqlx::query("DELETE FROM artifacts WHERE id = ?1")
            .bind(artifact_id)
            .execute(&self.pool)
            .await?;
        Ok(())
    }

    pub async fn upsert_rule(&self, row: &RuleRow) -> Result<(), DbError> {
        sqlx::query(
            r#"
            INSERT INTO rules (id, project_id, name, path, scope, active)
            VALUES (?1, ?2, ?3, ?4, ?5, ?6)
            ON CONFLICT(id) DO UPDATE SET
              name = excluded.name,
              path = excluded.path,
              scope = excluded.scope,
              active = excluded.active
            "#,
        )
        .bind(&row.id)
        .bind(&row.project_id)
        .bind(&row.name)
        .bind(&row.path)
        .bind(&row.scope)
        .bind(row.active)
        .execute(&self.pool)
        .await?;
        Ok(())
    }

    pub async fn list_rules(
        &self,
        project_id: &str,
        scope: Option<&str>,
    ) -> Result<Vec<RuleRow>, DbError> {
        let rows = match scope {
            Some(scope) => {
                sqlx::query_as::<_, RuleRow>(
                    r#"
                    SELECT id, project_id, name, path, scope, active
                    FROM rules
                    WHERE project_id = ?1 AND scope = ?2
                    ORDER BY active DESC, name ASC
                    "#,
                )
                .bind(project_id)
                .bind(scope)
                .fetch_all(&self.pool)
                .await?
            }
            None => {
                sqlx::query_as::<_, RuleRow>(
                    r#"
                    SELECT id, project_id, name, path, scope, active
                    FROM rules
                    WHERE project_id = ?1
                    ORDER BY active DESC, name ASC
                    "#,
                )
                .bind(project_id)
                .fetch_all(&self.pool)
                .await?
            }
        };
        Ok(rows)
    }

    pub async fn get_rule(&self, rule_id: &str) -> Result<Option<RuleRow>, DbError> {
        let row = sqlx::query_as::<_, RuleRow>(
            r#"
            SELECT id, project_id, name, path, scope, active
            FROM rules
            WHERE id = ?1
            LIMIT 1
            "#,
        )
        .bind(rule_id)
        .fetch_optional(&self.pool)
        .await?;
        Ok(row)
    }

    pub async fn delete_rule(&self, rule_id: &str) -> Result<(), DbError> {
        sqlx::query("DELETE FROM rules WHERE id = ?1")
            .bind(rule_id)
            .execute(&self.pool)
            .await?;
        Ok(())
    }

    pub async fn create_context_rule_usage(
        &self,
        row: &ContextRuleUsageRow,
    ) -> Result<(), DbError> {
        sqlx::query(
            r#"
            INSERT INTO context_rule_usage
            (id, project_id, run_id, rule_id, included, reason, created_at)
            VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7)
            "#,
        )
        .bind(&row.id)
        .bind(&row.project_id)
        .bind(&row.run_id)
        .bind(&row.rule_id)
        .bind(row.included)
        .bind(&row.reason)
        .bind(row.created_at)
        .execute(&self.pool)
        .await?;
        Ok(())
    }

    pub async fn list_context_rule_usage(
        &self,
        project_id: &str,
        rule_id: &str,
        limit: i64,
    ) -> Result<Vec<ContextRuleUsageRow>, DbError> {
        let rows = sqlx::query_as::<_, ContextRuleUsageRow>(
            r#"
            SELECT id, project_id, run_id, rule_id, included, reason, created_at
            FROM context_rule_usage
            WHERE project_id = ?1 AND rule_id = ?2
            ORDER BY created_at DESC
            LIMIT ?3
            "#,
        )
        .bind(project_id)
        .bind(rule_id)
        .bind(limit)
        .fetch_all(&self.pool)
        .await?;
        Ok(rows)
    }

    pub async fn upsert_onboarding_state(&self, row: &OnboardingStateRow) -> Result<(), DbError> {
        sqlx::query(
            r#"
            INSERT INTO onboarding_state (project_id, step, completed, dismissed, updated_at)
            VALUES (?1, ?2, ?3, ?4, ?5)
            ON CONFLICT(project_id) DO UPDATE SET
              step = excluded.step,
              completed = excluded.completed,
              dismissed = excluded.dismissed,
              updated_at = excluded.updated_at
            "#,
        )
        .bind(&row.project_id)
        .bind(&row.step)
        .bind(row.completed)
        .bind(row.dismissed)
        .bind(row.updated_at)
        .execute(&self.pool)
        .await?;
        Ok(())
    }

    pub async fn get_onboarding_state(
        &self,
        project_id: &str,
    ) -> Result<Option<OnboardingStateRow>, DbError> {
        let row = sqlx::query_as::<_, OnboardingStateRow>(
            r#"
            SELECT project_id, step, completed, dismissed, updated_at
            FROM onboarding_state
            WHERE project_id = ?1
            LIMIT 1
            "#,
        )
        .bind(project_id)
        .fetch_optional(&self.pool)
        .await?;
        Ok(row)
    }

    pub async fn append_telemetry_event(&self, row: &TelemetryEventRow) -> Result<(), DbError> {
        sqlx::query(
            r#"
            INSERT INTO telemetry_events (id, project_id, event_type, payload_json, anonymized, created_at)
            VALUES (?1, ?2, ?3, ?4, ?5, ?6)
            "#,
        )
        .bind(&row.id)
        .bind(&row.project_id)
        .bind(&row.event_type)
        .bind(&row.payload_json)
        .bind(row.anonymized)
        .bind(row.created_at)
        .execute(&self.pool)
        .await?;
        Ok(())
    }

    pub async fn list_telemetry_events(
        &self,
        project_id: &str,
        limit: i64,
    ) -> Result<Vec<TelemetryEventRow>, DbError> {
        let rows = sqlx::query_as::<_, TelemetryEventRow>(
            r#"
            SELECT id, project_id, event_type, payload_json, anonymized, created_at
            FROM telemetry_events
            WHERE project_id = ?1
            ORDER BY created_at DESC
            LIMIT ?2
            "#,
        )
        .bind(project_id)
        .bind(limit)
        .fetch_all(&self.pool)
        .await?;
        Ok(rows)
    }

    pub async fn count_telemetry_events(&self, project_id: &str) -> Result<i64, DbError> {
        let count = sqlx::query_scalar::<_, i64>(
            r#"
            SELECT COUNT(*)
            FROM telemetry_events
            WHERE project_id = ?1
            "#,
        )
        .bind(project_id)
        .fetch_one(&self.pool)
        .await?;
        Ok(count)
    }

    pub async fn clear_telemetry_events(&self, project_id: &str) -> Result<(), DbError> {
        sqlx::query("DELETE FROM telemetry_events WHERE project_id = ?1")
            .bind(project_id)
            .execute(&self.pool)
            .await?;
        Ok(())
    }

    pub async fn create_feedback(&self, row: &FeedbackRow) -> Result<(), DbError> {
        sqlx::query(
            r#"
            INSERT INTO feedback_entries
            (id, project_id, category, body, contact, artifact_path, created_at)
            VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7)
            "#,
        )
        .bind(&row.id)
        .bind(&row.project_id)
        .bind(&row.category)
        .bind(&row.body)
        .bind(&row.contact)
        .bind(&row.artifact_path)
        .bind(row.created_at)
        .execute(&self.pool)
        .await?;
        Ok(())
    }

    pub async fn list_feedback(
        &self,
        project_id: &str,
        limit: i64,
    ) -> Result<Vec<FeedbackRow>, DbError> {
        let rows = sqlx::query_as::<_, FeedbackRow>(
            r#"
            SELECT id, project_id, category, body, contact, artifact_path, created_at
            FROM feedback_entries
            WHERE project_id = ?1
            ORDER BY created_at DESC
            LIMIT ?2
            "#,
        )
        .bind(project_id)
        .bind(limit)
        .fetch_all(&self.pool)
        .await?;
        Ok(rows)
    }

    pub async fn clear_feedback_artifact_path(&self, feedback_id: &str) -> Result<(), DbError> {
        sqlx::query(
            r#"
            UPDATE feedback_entries
            SET artifact_path = NULL
            WHERE id = ?1
            "#,
        )
        .bind(feedback_id)
        .execute(&self.pool)
        .await?;
        Ok(())
    }

    pub async fn remove_worktree_by_task(&self, task_id: &str) -> Result<(), DbError> {
        sqlx::query("DELETE FROM worktrees WHERE task_id = ?1")
            .bind(task_id)
            .execute(&self.pool)
            .await?;
        Ok(())
    }

    pub async fn task_cost_total(&self, task_id: &str) -> Result<f64, DbError> {
        let total: Option<f64> =
            sqlx::query_scalar("SELECT SUM(estimated_usd) FROM costs WHERE task_id = ?1")
                .bind(task_id)
                .fetch_one(&self.pool)
                .await?;
        Ok(total.unwrap_or(0.0))
    }

    pub async fn project_cost_total(&self, project_id: &str) -> Result<f64, DbError> {
        let total: Option<f64> = sqlx::query_scalar(
            r#"
            SELECT SUM(c.estimated_usd)
            FROM costs c
            JOIN tasks t ON t.id = c.task_id
            WHERE t.project_id = ?1
            "#,
        )
        .bind(project_id)
        .fetch_one(&self.pool)
        .await?;
        Ok(total.unwrap_or(0.0))
    }

    /// Aggregate raw costs into hourly buckets for a project.
    ///
    /// Groups costs by (provider, model, hour) and upserts into cost_hourly_aggregates,
    /// overwriting existing sums on conflict to avoid double-counting.
    pub async fn aggregate_costs_hourly(&self, project_id: &str) -> Result<(), DbError> {
        sqlx::query(
            r#"
            INSERT INTO cost_hourly_aggregates
                (id, project_id, provider, model, period_start, tokens_in, tokens_out, estimated_usd, record_count)
            SELECT
                lower(hex(randomblob(16))),
                t.project_id,
                c.provider,
                COALESCE(c.model, ''),
                strftime('%Y-%m-%dT%H:00:00', datetime(c.timestamp)) AS period_start,
                SUM(c.tokens_in),
                SUM(c.tokens_out),
                SUM(c.estimated_usd),
                COUNT(*)
            FROM costs c
            JOIN tasks t ON t.id = c.task_id
            WHERE t.project_id = ?1
            GROUP BY t.project_id, c.provider, COALESCE(c.model, ''), strftime('%Y-%m-%dT%H:00:00', datetime(c.timestamp))
            ON CONFLICT(project_id, provider, model, period_start) DO UPDATE SET
                tokens_in     = excluded.tokens_in,
                tokens_out    = excluded.tokens_out,
                estimated_usd = excluded.estimated_usd,
                record_count  = excluded.record_count
            "#,
        )
        .bind(project_id)
        .execute(&self.pool)
        .await?;
        Ok(())
    }

    /// Aggregate raw costs into daily buckets for a project, joining tasks for completion count.
    pub async fn aggregate_costs_daily(&self, project_id: &str) -> Result<(), DbError> {
        sqlx::query(
            r#"
            INSERT INTO cost_daily_aggregates
                (id, project_id, provider, model, period_date, tokens_in, tokens_out, estimated_usd, record_count, tasks_completed, files_changed)
            SELECT
                lower(hex(randomblob(16))),
                t.project_id,
                c.provider,
                COALESCE(c.model, ''),
                strftime('%Y-%m-%d', datetime(c.timestamp)) AS period_date,
                SUM(c.tokens_in),
                SUM(c.tokens_out),
                SUM(c.estimated_usd),
                COUNT(*),
                COUNT(DISTINCT CASE WHEN t.status = 'Done' THEN t.id END),
                0
            FROM costs c
            JOIN tasks t ON t.id = c.task_id
            WHERE t.project_id = ?1
            GROUP BY t.project_id, c.provider, COALESCE(c.model, ''), strftime('%Y-%m-%d', datetime(c.timestamp))
            ON CONFLICT(project_id, provider, model, period_date) DO UPDATE SET
                tokens_in       = excluded.tokens_in,
                tokens_out      = excluded.tokens_out,
                estimated_usd   = excluded.estimated_usd,
                record_count    = excluded.record_count,
                tasks_completed = excluded.tasks_completed
            "#,
        )
        .bind(project_id)
        .execute(&self.pool)
        .await?;
        Ok(())
    }

    /// Sum daily aggregates by provider over the given number of days.
    pub async fn get_usage_breakdown(
        &self,
        project_id: &str,
        days: i64,
    ) -> Result<Vec<CostDailyAggregateRow>, DbError> {
        let rows = sqlx::query_as::<_, CostDailyAggregateRow>(
            r#"
            SELECT
                lower(hex(randomblob(16))) AS id,
                project_id,
                provider,
                '' AS model,
                '' AS period_date,
                SUM(tokens_in) AS tokens_in,
                SUM(tokens_out) AS tokens_out,
                SUM(estimated_usd) AS estimated_usd,
                SUM(record_count) AS record_count,
                SUM(tasks_completed) AS tasks_completed,
                SUM(files_changed) AS files_changed
            FROM cost_daily_aggregates
            WHERE project_id = ?1
              AND period_date >= date('now', ?2)
            GROUP BY project_id, provider
            ORDER BY estimated_usd DESC
            "#,
        )
        .bind(project_id)
        .bind(format!("-{} days", days))
        .fetch_all(&self.pool)
        .await?;
        Ok(rows)
    }

    /// Sum all daily aggregates by model across all time.
    pub async fn get_usage_by_model(
        &self,
        project_id: &str,
    ) -> Result<Vec<CostDailyAggregateRow>, DbError> {
        let rows = sqlx::query_as::<_, CostDailyAggregateRow>(
            r#"
            SELECT
                lower(hex(randomblob(16))) AS id,
                project_id,
                provider,
                model,
                '' AS period_date,
                SUM(tokens_in) AS tokens_in,
                SUM(tokens_out) AS tokens_out,
                SUM(estimated_usd) AS estimated_usd,
                SUM(record_count) AS record_count,
                SUM(tasks_completed) AS tasks_completed,
                SUM(files_changed) AS files_changed
            FROM cost_daily_aggregates
            WHERE project_id = ?1
            GROUP BY project_id, provider, model
            ORDER BY estimated_usd DESC
            "#,
        )
        .bind(project_id)
        .fetch_all(&self.pool)
        .await?;
        Ok(rows)
    }

    /// Daily totals aggregated across all providers for a trend chart.
    pub async fn get_usage_daily_trend(
        &self,
        project_id: &str,
        days: i64,
    ) -> Result<Vec<CostDailyAggregateRow>, DbError> {
        let rows = sqlx::query_as::<_, CostDailyAggregateRow>(
            r#"
            SELECT
                lower(hex(randomblob(16))) AS id,
                project_id,
                '' AS provider,
                '' AS model,
                period_date,
                SUM(tokens_in) AS tokens_in,
                SUM(tokens_out) AS tokens_out,
                SUM(estimated_usd) AS estimated_usd,
                SUM(record_count) AS record_count,
                SUM(tasks_completed) AS tasks_completed,
                SUM(files_changed) AS files_changed
            FROM cost_daily_aggregates
            WHERE project_id = ?1
              AND period_date >= date('now', ?2)
            GROUP BY project_id, period_date
            ORDER BY period_date ASC
            "#,
        )
        .bind(project_id)
        .bind(format!("-{} days", days))
        .fetch_all(&self.pool)
        .await?;
        Ok(rows)
    }

    pub async fn create_check_run(&self, row: &CheckRunRow) -> Result<(), DbError> {
        sqlx::query(
            r#"
            INSERT INTO check_runs (id, project_id, task_id, status, summary, created_at)
            VALUES (?1, ?2, ?3, ?4, ?5, ?6)
            "#,
        )
        .bind(&row.id)
        .bind(&row.project_id)
        .bind(&row.task_id)
        .bind(&row.status)
        .bind(&row.summary)
        .bind(row.created_at)
        .execute(&self.pool)
        .await?;
        Ok(())
    }

    pub async fn create_check_result(&self, row: &CheckResultRow) -> Result<(), DbError> {
        sqlx::query(
            r#"
            INSERT INTO check_results
            (id, check_run_id, project_id, task_id, description, check_type, command, passed, output, created_at)
            VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10)
            "#,
        )
        .bind(&row.id)
        .bind(&row.check_run_id)
        .bind(&row.project_id)
        .bind(&row.task_id)
        .bind(&row.description)
        .bind(&row.check_type)
        .bind(&row.command)
        .bind(row.passed)
        .bind(&row.output)
        .bind(row.created_at)
        .execute(&self.pool)
        .await?;
        Ok(())
    }

    pub async fn latest_check_run_for_task(
        &self,
        task_id: &str,
    ) -> Result<Option<CheckRunRow>, DbError> {
        let row = sqlx::query_as::<_, CheckRunRow>(
            r#"
            SELECT id, project_id, task_id, status, summary, created_at
            FROM check_runs
            WHERE task_id = ?1
            ORDER BY created_at DESC
            LIMIT 1
            "#,
        )
        .bind(task_id)
        .fetch_optional(&self.pool)
        .await?;
        Ok(row)
    }

    pub async fn list_check_results_for_run(
        &self,
        check_run_id: &str,
    ) -> Result<Vec<CheckResultRow>, DbError> {
        let rows = sqlx::query_as::<_, CheckResultRow>(
            r#"
            SELECT id, check_run_id, project_id, task_id, description, check_type, command, passed, output, created_at
            FROM check_results
            WHERE check_run_id = ?1
            ORDER BY created_at ASC
            "#,
        )
        .bind(check_run_id)
        .fetch_all(&self.pool)
        .await?;
        Ok(rows)
    }

    pub async fn upsert_review(&self, row: &ReviewRow) -> Result<(), DbError> {
        sqlx::query(
            r#"
            INSERT INTO reviews (id, task_id, status, review_pack_path, reviewer_notes, approved_at)
            VALUES (?1, ?2, ?3, ?4, ?5, ?6)
            ON CONFLICT(task_id) DO UPDATE SET
              id = excluded.id,
              status = excluded.status,
              review_pack_path = excluded.review_pack_path,
              reviewer_notes = excluded.reviewer_notes,
              approved_at = excluded.approved_at
            "#,
        )
        .bind(&row.id)
        .bind(&row.task_id)
        .bind(&row.status)
        .bind(&row.review_pack_path)
        .bind(&row.reviewer_notes)
        .bind(row.approved_at)
        .execute(&self.pool)
        .await?;
        Ok(())
    }

    pub async fn get_review_by_task(&self, task_id: &str) -> Result<Option<ReviewRow>, DbError> {
        let row = sqlx::query_as::<_, ReviewRow>(
            r#"
            SELECT id, task_id, status, review_pack_path, reviewer_notes, approved_at
            FROM reviews
            WHERE task_id = ?1
            LIMIT 1
            "#,
        )
        .bind(task_id)
        .fetch_optional(&self.pool)
        .await?;
        Ok(row)
    }

    pub async fn delete_review_by_task(&self, task_id: &str) -> Result<(), DbError> {
        sqlx::query("DELETE FROM reviews WHERE task_id = ?1")
            .bind(task_id)
            .execute(&self.pool)
            .await?;
        Ok(())
    }

    pub async fn upsert_merge_queue_item(&self, row: &MergeQueueRow) -> Result<(), DbError> {
        sqlx::query(
            r#"
            INSERT INTO merge_queue
            (id, project_id, task_id, status, blocked_reason, approved_at, started_at, completed_at)
            VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8)
            ON CONFLICT(task_id) DO UPDATE SET
              id = excluded.id,
              status = excluded.status,
              blocked_reason = excluded.blocked_reason,
              approved_at = excluded.approved_at,
              started_at = excluded.started_at,
              completed_at = excluded.completed_at
            "#,
        )
        .bind(&row.id)
        .bind(&row.project_id)
        .bind(&row.task_id)
        .bind(&row.status)
        .bind(&row.blocked_reason)
        .bind(row.approved_at)
        .bind(row.started_at)
        .bind(row.completed_at)
        .execute(&self.pool)
        .await?;
        Ok(())
    }

    pub async fn get_merge_queue_item_by_task(
        &self,
        task_id: &str,
    ) -> Result<Option<MergeQueueRow>, DbError> {
        let row = sqlx::query_as::<_, MergeQueueRow>(
            r#"
            SELECT id, project_id, task_id, status, blocked_reason, approved_at, started_at, completed_at
            FROM merge_queue
            WHERE task_id = ?1
            LIMIT 1
            "#,
        )
        .bind(task_id)
        .fetch_optional(&self.pool)
        .await?;
        Ok(row)
    }

    pub async fn list_merge_queue(&self, project_id: &str) -> Result<Vec<MergeQueueRow>, DbError> {
        let rows = sqlx::query_as::<_, MergeQueueRow>(
            r#"
            SELECT id, project_id, task_id, status, blocked_reason, approved_at, started_at, completed_at
            FROM merge_queue
            WHERE project_id = ?1
            ORDER BY approved_at ASC
            "#,
        )
        .bind(project_id)
        .fetch_all(&self.pool)
        .await?;
        Ok(rows)
    }

    pub async fn create_notification(&self, row: &NotificationRow) -> Result<(), DbError> {
        sqlx::query(
            r#"
            INSERT INTO notifications
            (id, project_id, task_id, session_id, title, body, level, unread, created_at)
            VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9)
            "#,
        )
        .bind(&row.id)
        .bind(&row.project_id)
        .bind(&row.task_id)
        .bind(&row.session_id)
        .bind(&row.title)
        .bind(&row.body)
        .bind(&row.level)
        .bind(row.unread)
        .bind(row.created_at)
        .execute(&self.pool)
        .await?;
        Ok(())
    }

    pub async fn list_notifications(
        &self,
        project_id: &str,
        unread_only: bool,
    ) -> Result<Vec<NotificationRow>, DbError> {
        let rows = if unread_only {
            sqlx::query_as::<_, NotificationRow>(
                r#"
                SELECT id, project_id, task_id, session_id, title, body, level, unread, created_at
                FROM notifications
                WHERE project_id = ?1 AND unread = 1
                ORDER BY created_at DESC
                "#,
            )
            .bind(project_id)
            .fetch_all(&self.pool)
            .await?
        } else {
            sqlx::query_as::<_, NotificationRow>(
                r#"
                SELECT id, project_id, task_id, session_id, title, body, level, unread, created_at
                FROM notifications
                WHERE project_id = ?1
                ORDER BY created_at DESC
                "#,
            )
            .bind(project_id)
            .fetch_all(&self.pool)
            .await?
        };
        Ok(rows)
    }

    pub async fn mark_notification_read(&self, id: &str) -> Result<(), DbError> {
        sqlx::query("UPDATE notifications SET unread = 0 WHERE id = ?1")
            .bind(id)
            .execute(&self.pool)
            .await?;
        Ok(())
    }

    pub async fn clear_notifications(&self, project_id: &str) -> Result<(), DbError> {
        sqlx::query("UPDATE notifications SET unread = 0 WHERE project_id = ?1")
            .bind(project_id)
            .execute(&self.pool)
            .await?;
        Ok(())
    }

    pub async fn upsert_secret_ref(&self, row: &SecretRefRow) -> Result<(), DbError> {
        sqlx::query(
            r#"
            INSERT INTO secret_refs
            (id, project_id, scope, name, keychain_service, keychain_account, created_at, updated_at)
            VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8)
            ON CONFLICT(project_id, scope, name) DO UPDATE SET
              id = excluded.id,
              keychain_service = excluded.keychain_service,
              keychain_account = excluded.keychain_account,
              updated_at = excluded.updated_at
            "#,
        )
        .bind(&row.id)
        .bind(&row.project_id)
        .bind(&row.scope)
        .bind(&row.name)
        .bind(&row.keychain_service)
        .bind(&row.keychain_account)
        .bind(row.created_at)
        .bind(row.updated_at)
        .execute(&self.pool)
        .await?;
        Ok(())
    }

    pub async fn list_secret_refs(
        &self,
        project_id: &str,
        scope: Option<&str>,
    ) -> Result<Vec<SecretRefRow>, DbError> {
        let rows = match scope {
            Some(scope) => {
                sqlx::query_as::<_, SecretRefRow>(
                    r#"
                    SELECT id, project_id, scope, name, keychain_service, keychain_account, created_at, updated_at
                    FROM secret_refs
                    WHERE (project_id IS NULL OR project_id = ?1) AND scope = ?2
                    ORDER BY scope ASC, name ASC
                    "#,
                )
                .bind(project_id)
                .bind(scope)
                .fetch_all(&self.pool)
                .await?
            }
            None => {
                sqlx::query_as::<_, SecretRefRow>(
                    r#"
                    SELECT id, project_id, scope, name, keychain_service, keychain_account, created_at, updated_at
                    FROM secret_refs
                    WHERE project_id IS NULL OR project_id = ?1
                    ORDER BY scope ASC, name ASC
                    "#,
                )
                .bind(project_id)
                .fetch_all(&self.pool)
                .await?
            }
        };
        Ok(rows)
    }

    pub async fn create_checkpoint(&self, row: &CheckpointRow) -> Result<(), DbError> {
        sqlx::query(
            r#"
            INSERT INTO checkpoints
            (id, project_id, task_id, git_ref, session_metadata_json, created_at, description)
            VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7)
            "#,
        )
        .bind(&row.id)
        .bind(&row.project_id)
        .bind(&row.task_id)
        .bind(&row.git_ref)
        .bind(&row.session_metadata_json)
        .bind(row.created_at)
        .bind(&row.description)
        .execute(&self.pool)
        .await?;
        Ok(())
    }

    pub async fn list_checkpoints(&self, project_id: &str) -> Result<Vec<CheckpointRow>, DbError> {
        let rows = sqlx::query_as::<_, CheckpointRow>(
            r#"
            SELECT id, project_id, task_id, git_ref, session_metadata_json, created_at, description
            FROM checkpoints
            WHERE project_id = ?1
            ORDER BY created_at DESC
            "#,
        )
        .bind(project_id)
        .fetch_all(&self.pool)
        .await?;
        Ok(rows)
    }

    pub async fn get_checkpoint(
        &self,
        checkpoint_id: &str,
    ) -> Result<Option<CheckpointRow>, DbError> {
        let row = sqlx::query_as::<_, CheckpointRow>(
            r#"
            SELECT id, project_id, task_id, git_ref, session_metadata_json, created_at, description
            FROM checkpoints
            WHERE id = ?1
            LIMIT 1
            "#,
        )
        .bind(checkpoint_id)
        .fetch_optional(&self.pool)
        .await?;
        Ok(row)
    }

    // ─── Workflow instances ──────────────────────────────────────────

    pub async fn create_workflow_instance(
        &self,
        instance: &WorkflowInstanceRow,
    ) -> Result<(), DbError> {
        sqlx::query(
            r#"
            INSERT INTO workflow_instances (id, project_id, workflow_name, description, status, created_at, updated_at, params_json, stage_results_json, expanded_steps_json)
            VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10)
            "#,
        )
        .bind(&instance.id)
        .bind(&instance.project_id)
        .bind(&instance.workflow_name)
        .bind(&instance.description)
        .bind(&instance.status)
        .bind(instance.created_at)
        .bind(instance.updated_at)
        .bind(&instance.params_json)
        .bind(&instance.stage_results_json)
        .bind(&instance.expanded_steps_json)
        .execute(&self.pool)
        .await?;
        Ok(())
    }

    pub async fn update_workflow_instance_status(
        &self,
        workflow_id: &str,
        status: &str,
    ) -> Result<(), DbError> {
        sqlx::query(
            r#"
            UPDATE workflow_instances SET status = ?1, updated_at = ?2 WHERE id = ?3
            "#,
        )
        .bind(status)
        .bind(Utc::now())
        .bind(workflow_id)
        .execute(&self.pool)
        .await?;
        Ok(())
    }

    pub async fn get_workflow_instance(
        &self,
        workflow_id: &str,
    ) -> Result<Option<WorkflowInstanceRow>, DbError> {
        let row = sqlx::query_as::<_, WorkflowInstanceRow>(
            r#"
            SELECT id, project_id, workflow_name, description, status, created_at, updated_at,
                   params_json, stage_results_json, expanded_steps_json
            FROM workflow_instances WHERE id = ?1
            "#,
        )
        .bind(workflow_id)
        .fetch_optional(&self.pool)
        .await?;
        Ok(row)
    }

    pub async fn list_workflow_instances(
        &self,
        project_id: &str,
    ) -> Result<Vec<WorkflowInstanceRow>, DbError> {
        let rows = sqlx::query_as::<_, WorkflowInstanceRow>(
            r#"
            SELECT id, project_id, workflow_name, description, status, created_at, updated_at,
                   params_json, stage_results_json, expanded_steps_json
            FROM workflow_instances WHERE project_id = ?1
            ORDER BY created_at DESC
            "#,
        )
        .bind(project_id)
        .fetch_all(&self.pool)
        .await?;
        Ok(rows)
    }

    pub async fn add_workflow_task(
        &self,
        workflow_id: &str,
        step_index: i64,
        task_id: &str,
    ) -> Result<(), DbError> {
        sqlx::query(
            r#"
            INSERT INTO workflow_tasks (workflow_id, step_index, task_id)
            VALUES (?1, ?2, ?3)
            "#,
        )
        .bind(workflow_id)
        .bind(step_index)
        .bind(task_id)
        .execute(&self.pool)
        .await?;
        Ok(())
    }

    pub async fn list_workflow_tasks(
        &self,
        workflow_id: &str,
    ) -> Result<Vec<WorkflowTaskRow>, DbError> {
        let rows = sqlx::query_as::<_, WorkflowTaskRow>(
            r#"
            SELECT workflow_id, step_index, task_id
            FROM workflow_tasks WHERE workflow_id = ?1
            ORDER BY step_index ASC
            "#,
        )
        .bind(workflow_id)
        .fetch_all(&self.pool)
        .await?;
        Ok(rows)
    }

    pub async fn find_workflow_by_task(
        &self,
        task_id: &str,
    ) -> Result<Option<WorkflowTaskRow>, DbError> {
        let row = sqlx::query_as::<_, WorkflowTaskRow>(
            r#"
            SELECT workflow_id, step_index, task_id
            FROM workflow_tasks WHERE task_id = ?1
            "#,
        )
        .bind(task_id)
        .fetch_optional(&self.pool)
        .await?;
        Ok(row)
    }

    pub async fn list_ssh_profiles(&self, project_id: &str) -> Result<Vec<SshProfileRow>, DbError> {
        let rows = sqlx::query_as::<_, SshProfileRow>(
            "SELECT id, project_id, name, host, port, user, identity_file, proxy_jump, tags_json, source, created_at, updated_at FROM ssh_profiles WHERE project_id = ? ORDER BY name"
        )
        .bind(project_id)
        .fetch_all(&self.pool)
        .await?;
        Ok(rows)
    }

    pub async fn get_ssh_profile(&self, id: &str) -> Result<SshProfileRow, DbError> {
        let row = sqlx::query_as::<_, SshProfileRow>(
            "SELECT id, project_id, name, host, port, user, identity_file, proxy_jump, tags_json, source, created_at, updated_at FROM ssh_profiles WHERE id = ?"
        )
        .bind(id)
        .fetch_one(&self.pool)
        .await?;
        Ok(row)
    }

    pub async fn upsert_ssh_profile(&self, row: &SshProfileRow) -> Result<(), DbError> {
        sqlx::query(
            "INSERT INTO ssh_profiles (id, project_id, name, host, port, user, identity_file, proxy_jump, tags_json, source, created_at, updated_at)
             VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
             ON CONFLICT(id) DO UPDATE SET name=excluded.name, host=excluded.host, port=excluded.port, user=excluded.user, identity_file=excluded.identity_file, proxy_jump=excluded.proxy_jump, tags_json=excluded.tags_json, source=excluded.source, updated_at=excluded.updated_at"
        )
        .bind(&row.id)
        .bind(&row.project_id)
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

    pub async fn delete_ssh_profile(&self, id: &str) -> Result<(), DbError> {
        sqlx::query("DELETE FROM ssh_profiles WHERE id = ?")
            .bind(id)
            .execute(&self.pool)
            .await?;
        Ok(())
    }

    // ── Error Signature methods ──────────────────────────────────────────────

    pub async fn upsert_error_signature(&self, row: &ErrorSignatureRow) -> Result<(), DbError> {
        sqlx::query(
            r#"
            INSERT INTO error_signatures
                (id, project_id, signature_hash, canonical_message, category,
                 first_seen, last_seen, total_count, sample_output, remediation_hint)
            VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10)
            ON CONFLICT(project_id, signature_hash) DO UPDATE SET
                last_seen = excluded.last_seen,
                total_count = total_count + 1,
                sample_output = excluded.sample_output
            "#,
        )
        .bind(&row.id)
        .bind(&row.project_id)
        .bind(&row.signature_hash)
        .bind(&row.canonical_message)
        .bind(&row.category)
        .bind(row.first_seen)
        .bind(row.last_seen)
        .bind(row.total_count)
        .bind(&row.sample_output)
        .bind(&row.remediation_hint)
        .execute(&self.pool)
        .await?;
        Ok(())
    }

    pub async fn increment_error_signature_daily(
        &self,
        signature_id: &str,
        date: &str,
    ) -> Result<(), DbError> {
        let id = uuid::Uuid::new_v4().to_string();
        sqlx::query(
            r#"
            INSERT INTO error_signature_daily (id, signature_id, date, count)
            VALUES (?1, ?2, ?3, 1)
            ON CONFLICT(signature_id, date) DO UPDATE SET count = count + 1
            "#,
        )
        .bind(&id)
        .bind(signature_id)
        .bind(date)
        .execute(&self.pool)
        .await?;
        Ok(())
    }

    pub async fn list_error_signatures(
        &self,
        project_id: &str,
        limit: i64,
    ) -> Result<Vec<ErrorSignatureRow>, DbError> {
        let rows = sqlx::query_as::<_, ErrorSignatureRow>(
            r#"
            SELECT id, project_id, signature_hash, canonical_message, category,
                   first_seen, last_seen, total_count, sample_output, remediation_hint
            FROM error_signatures
            WHERE project_id = ?1
            ORDER BY total_count DESC
            LIMIT ?2
            "#,
        )
        .bind(project_id)
        .bind(limit)
        .fetch_all(&self.pool)
        .await?;
        Ok(rows)
    }

    pub async fn get_error_signature(
        &self,
        id: &str,
    ) -> Result<Option<ErrorSignatureRow>, DbError> {
        let row = sqlx::query_as::<_, ErrorSignatureRow>(
            r#"
            SELECT id, project_id, signature_hash, canonical_message, category,
                   first_seen, last_seen, total_count, sample_output, remediation_hint
            FROM error_signatures WHERE id = ?1
            "#,
        )
        .bind(id)
        .fetch_optional(&self.pool)
        .await?;
        Ok(row)
    }

    pub async fn get_error_trend(
        &self,
        project_id: &str,
        days: i64,
    ) -> Result<Vec<ErrorSignatureDailyRow>, DbError> {
        let rows = sqlx::query_as::<_, ErrorSignatureDailyRow>(
            r#"
            SELECT esd.id, esd.signature_id, esd.date, esd.count,
                   es.signature_hash, es.category
            FROM error_signature_daily esd
            JOIN error_signatures es ON es.id = esd.signature_id
            WHERE es.project_id = ?1
              AND esd.date >= date('now', '-' || ?2 || ' days')
            ORDER BY esd.date ASC
            "#,
        )
        .bind(project_id)
        .bind(days)
        .fetch_all(&self.pool)
        .await?;
        Ok(rows)
    }

    // ── Task story methods ──────────────────────────────────────────────────

    pub async fn create_task_story(&self, row: &TaskStoryRow) -> Result<(), DbError> {
        sqlx::query(
            r#"
            INSERT INTO task_stories (id, task_id, sequence_number, title, status, started_at, completed_at, output_summary)
            VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8)
            "#,
        )
        .bind(&row.id)
        .bind(&row.task_id)
        .bind(row.sequence_number)
        .bind(&row.title)
        .bind(&row.status)
        .bind(row.started_at)
        .bind(row.completed_at)
        .bind(&row.output_summary)
        .execute(&self.pool)
        .await?;
        Ok(())
    }

    pub async fn create_stories_batch(&self, rows: &[TaskStoryRow]) -> Result<(), DbError> {
        for row in rows {
            self.create_task_story(row).await?;
        }
        Ok(())
    }

    pub async fn list_task_stories(&self, task_id: &str) -> Result<Vec<TaskStoryRow>, DbError> {
        let rows = sqlx::query_as::<_, TaskStoryRow>(
            r#"
            SELECT id, task_id, sequence_number, title, status, started_at, completed_at, output_summary
            FROM task_stories
            WHERE task_id = ?1
            ORDER BY sequence_number ASC
            "#,
        )
        .bind(task_id)
        .fetch_all(&self.pool)
        .await?;
        Ok(rows)
    }

    pub async fn update_story_status(
        &self,
        id: &str,
        status: &str,
        output_summary: Option<&str>,
    ) -> Result<(), DbError> {
        let now = Utc::now();
        let (started_at, completed_at) = match status {
            "in_progress" => (Some(now), None),
            "completed" | "failed" | "skipped" => (None::<DateTime<Utc>>, Some(now)),
            _ => (None, None),
        };
        sqlx::query(
            r#"
            UPDATE task_stories
            SET status = ?1,
                output_summary = COALESCE(?2, output_summary),
                started_at = CASE WHEN started_at IS NULL AND ?3 IS NOT NULL THEN ?3 ELSE started_at END,
                completed_at = CASE WHEN ?4 IS NOT NULL THEN ?4 ELSE completed_at END
            WHERE id = ?5
            "#,
        )
        .bind(status)
        .bind(output_summary)
        .bind(started_at)
        .bind(completed_at)
        .bind(id)
        .execute(&self.pool)
        .await?;
        Ok(())
    }

    pub async fn get_story_progress(&self, task_id: &str) -> Result<StoryProgressRow, DbError> {
        let row = sqlx::query_as::<_, StoryProgressRow>(
            r#"
            SELECT
                COUNT(*) as total,
                SUM(CASE WHEN status = 'completed' THEN 1 ELSE 0 END) as completed,
                SUM(CASE WHEN status = 'failed' THEN 1 ELSE 0 END) as failed,
                SUM(CASE WHEN status = 'in_progress' THEN 1 ELSE 0 END) as in_progress
            FROM task_stories
            WHERE task_id = ?1
            "#,
        )
        .bind(task_id)
        .fetch_one(&self.pool)
        .await?;
        Ok(row)
    }

    // ─── Workflow definitions ────────────────────────────────────────────────

    pub async fn create_workflow(&self, row: &WorkflowRow) -> Result<(), DbError> {
        sqlx::query(
            r#"
            INSERT INTO workflows (id, project_id, name, description, definition_yaml, source, created_at, updated_at)
            VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8)
            "#,
        )
        .bind(&row.id)
        .bind(&row.project_id)
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

    pub async fn get_workflow(&self, id: &str) -> Result<Option<WorkflowRow>, DbError> {
        let row = sqlx::query_as::<_, WorkflowRow>(
            r#"
            SELECT id, project_id, name, description, definition_yaml, source, created_at, updated_at
            FROM workflows WHERE id = ?1
            "#,
        )
        .bind(id)
        .fetch_optional(&self.pool)
        .await?;
        Ok(row)
    }

    pub async fn get_workflow_by_name(
        &self,
        project_id: &str,
        name: &str,
    ) -> Result<Option<WorkflowRow>, DbError> {
        let row = sqlx::query_as::<_, WorkflowRow>(
            r#"
            SELECT id, project_id, name, description, definition_yaml, source, created_at, updated_at
            FROM workflows WHERE project_id = ?1 AND name = ?2
            "#,
        )
        .bind(project_id)
        .bind(name)
        .fetch_optional(&self.pool)
        .await?;
        Ok(row)
    }

    pub async fn list_workflows(&self, project_id: &str) -> Result<Vec<WorkflowRow>, DbError> {
        let rows = sqlx::query_as::<_, WorkflowRow>(
            r#"
            SELECT id, project_id, name, description, definition_yaml, source, created_at, updated_at
            FROM workflows WHERE project_id = ?1
            ORDER BY name ASC
            "#,
        )
        .bind(project_id)
        .fetch_all(&self.pool)
        .await?;
        Ok(rows)
    }

    pub async fn update_workflow(&self, row: &WorkflowRow) -> Result<(), DbError> {
        sqlx::query(
            r#"
            UPDATE workflows
            SET name = ?1, description = ?2, definition_yaml = ?3, source = ?4, updated_at = ?5
            WHERE id = ?6
            "#,
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

    pub async fn delete_workflow(&self, id: &str) -> Result<(), DbError> {
        sqlx::query("DELETE FROM workflows WHERE id = ?1")
            .bind(id)
            .execute(&self.pool)
            .await?;
        Ok(())
    }

    pub async fn update_workflow_instance_results(
        &self,
        id: &str,
        stage_results_json: &str,
        status: &str,
    ) -> Result<(), DbError> {
        sqlx::query(
            r#"
            UPDATE workflow_instances
            SET stage_results_json = ?1, status = ?2, updated_at = ?3
            WHERE id = ?4
            "#,
        )
        .bind(stage_results_json)
        .bind(status)
        .bind(Utc::now())
        .bind(id)
        .execute(&self.pool)
        .await?;
        Ok(())
    }

    // ─── Agent Profile methods ───────────────────────────────────────────────

    pub async fn create_agent_profile(&self, row: &AgentProfileRow) -> Result<(), DbError> {
        sqlx::query(
            r#"
            INSERT INTO agent_profiles
                (id, project_id, name, provider, model, token_budget, timeout_minutes,
                 max_concurrent, stations_json, config_json, active, created_at, updated_at)
            VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12, ?13)
            "#,
        )
        .bind(&row.id)
        .bind(&row.project_id)
        .bind(&row.name)
        .bind(&row.provider)
        .bind(&row.model)
        .bind(row.token_budget)
        .bind(row.timeout_minutes)
        .bind(row.max_concurrent)
        .bind(&row.stations_json)
        .bind(&row.config_json)
        .bind(row.active)
        .bind(row.created_at)
        .bind(row.updated_at)
        .execute(&self.pool)
        .await?;
        Ok(())
    }

    pub async fn get_agent_profile(&self, id: &str) -> Result<Option<AgentProfileRow>, DbError> {
        let row = sqlx::query_as::<_, AgentProfileRow>(
            r#"
            SELECT id, project_id, name, provider, model, token_budget, timeout_minutes,
                   max_concurrent, stations_json, config_json, active, created_at, updated_at
            FROM agent_profiles
            WHERE id = ?1
            "#,
        )
        .bind(id)
        .fetch_optional(&self.pool)
        .await?;
        Ok(row)
    }

    pub async fn get_agent_profile_by_name(
        &self,
        project_id: &str,
        name: &str,
    ) -> Result<Option<AgentProfileRow>, DbError> {
        let row = sqlx::query_as::<_, AgentProfileRow>(
            r#"
            SELECT id, project_id, name, provider, model, token_budget, timeout_minutes,
                   max_concurrent, stations_json, config_json, active, created_at, updated_at
            FROM agent_profiles
            WHERE project_id = ?1 AND name = ?2
            "#,
        )
        .bind(project_id)
        .bind(name)
        .fetch_optional(&self.pool)
        .await?;
        Ok(row)
    }

    pub async fn list_agent_profiles(
        &self,
        project_id: &str,
    ) -> Result<Vec<AgentProfileRow>, DbError> {
        let rows = sqlx::query_as::<_, AgentProfileRow>(
            r#"
            SELECT id, project_id, name, provider, model, token_budget, timeout_minutes,
                   max_concurrent, stations_json, config_json, active, created_at, updated_at
            FROM agent_profiles
            WHERE project_id = ?1 AND active = 1
            ORDER BY name
            "#,
        )
        .bind(project_id)
        .fetch_all(&self.pool)
        .await?;
        Ok(rows)
    }

    pub async fn update_agent_profile(&self, row: &AgentProfileRow) -> Result<(), DbError> {
        sqlx::query(
            r#"
            UPDATE agent_profiles
            SET name = ?1, provider = ?2, model = ?3, token_budget = ?4,
                timeout_minutes = ?5, max_concurrent = ?6, stations_json = ?7,
                config_json = ?8, active = ?9, updated_at = ?10
            WHERE id = ?11
            "#,
        )
        .bind(&row.name)
        .bind(&row.provider)
        .bind(&row.model)
        .bind(row.token_budget)
        .bind(row.timeout_minutes)
        .bind(row.max_concurrent)
        .bind(&row.stations_json)
        .bind(&row.config_json)
        .bind(row.active)
        .bind(row.updated_at)
        .bind(&row.id)
        .execute(&self.pool)
        .await?;
        Ok(())
    }

    pub async fn delete_agent_profile(&self, id: &str) -> Result<(), DbError> {
        sqlx::query("DELETE FROM agent_profiles WHERE id = ?1")
            .bind(id)
            .execute(&self.pool)
            .await?;
        Ok(())
    }

    pub async fn update_workflow_instance_params(
        &self,
        id: &str,
        params_json: &str,
    ) -> Result<(), DbError> {
        sqlx::query(
            r#"
            UPDATE workflow_instances
            SET params_json = ?1, updated_at = ?2
            WHERE id = ?3
            "#,
        )
        .bind(params_json)
        .bind(Utc::now())
        .bind(id)
        .execute(&self.pool)
        .await?;
        Ok(())
    }

    pub async fn update_workflow_instance_expanded(
        &self,
        id: &str,
        expanded_steps_json: &str,
    ) -> Result<(), DbError> {
        sqlx::query(
            r#"
            UPDATE workflow_instances
            SET expanded_steps_json = ?1, updated_at = ?2
            WHERE id = ?3
            "#,
        )
        .bind(expanded_steps_json)
        .bind(Utc::now())
        .bind(id)
        .execute(&self.pool)
        .await?;
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::models::{
        ContextRuleUsageRow, FeedbackRow, NotificationRow, OnboardingStateRow, RuleRow, SessionRow,
        TaskRow, TelemetryEventRow, WorkflowInstanceRow, WorktreeRow,
    };
    use chrono::Utc;
    use sqlx::sqlite::SqlitePoolOptions;
    use uuid::Uuid;

    async fn open_test_db() -> Db {
        let pool = SqlitePoolOptions::new()
            .max_connections(1)
            .connect("sqlite::memory:")
            .await
            .expect("memory sqlite");
        let db = Db {
            pool,
            path: PathBuf::from(":memory:"),
        };
        db.migrate().await.expect("migrate");
        db
    }

    // ── Helper to create a project that foreign keys can reference ──────────
    async fn seed_project(db: &Db, project_id: &str) {
        db.upsert_project(project_id, "test", "/tmp/test", None, None)
            .await
            .expect("seed project");
    }

    // ── D1: Task roundtrip ──────────────────────────────────────────────────

    #[tokio::test]
    async fn task_roundtrip() {
        let db = open_test_db().await;
        let project_id = Uuid::new_v4().to_string();
        seed_project(&db, &project_id).await;

        let now = Utc::now();
        let task = TaskRow {
            id: Uuid::new_v4().to_string(),
            project_id: project_id.clone(),
            title: "Implement feature X".to_string(),
            goal: "Deliver feature X".to_string(),
            scope_json: "[]".to_string(),
            dependencies_json: "[]".to_string(),
            acceptance_json: "[]".to_string(),
            constraints_json: "[]".to_string(),
            priority: "high".to_string(),
            status: "Pending".to_string(),
            branch: Some("feat/x".to_string()),
            worktree_id: None,
            handoff_summary: None,
            created_at: now,
            updated_at: now,
            auto_dispatch: false,
            agent_profile_override: None,
            execution_mode: None,
            timeout_minutes: None,
            max_retries: None,
        };

        db.create_task(&task).await.expect("create task");

        let loaded = db
            .get_task(&task.id)
            .await
            .expect("get task")
            .expect("task should exist");
        assert_eq!(loaded.id, task.id);
        assert_eq!(loaded.title, "Implement feature X");
        assert_eq!(loaded.priority, "high");
        assert_eq!(loaded.status, "Pending");
        assert_eq!(loaded.branch.as_deref(), Some("feat/x"));
        assert!(!loaded.auto_dispatch);

        // Update and verify
        let mut updated = loaded.clone();
        updated.status = "InProgress".to_string();
        updated.updated_at = Utc::now();
        db.update_task(&updated).await.expect("update task");

        let reloaded = db
            .get_task(&task.id)
            .await
            .expect("get task after update")
            .expect("task should still exist");
        assert_eq!(reloaded.status, "InProgress");

        // list_tasks
        let tasks = db.list_tasks(&project_id).await.expect("list tasks");
        assert_eq!(tasks.len(), 1);

        // delete
        db.delete_task(&task.id).await.expect("delete task");
        let gone = db.get_task(&task.id).await.expect("get deleted task");
        assert!(gone.is_none());
    }

    #[tokio::test]
    async fn task_dependencies_roundtrip() {
        let db = open_test_db().await;
        let project_id = Uuid::new_v4().to_string();
        seed_project(&db, &project_id).await;

        let now = Utc::now();
        let make_task = |id: &str| TaskRow {
            id: id.to_string(),
            project_id: project_id.clone(),
            title: format!("Task {id}"),
            goal: "goal".to_string(),
            scope_json: "[]".to_string(),
            dependencies_json: "[]".to_string(),
            acceptance_json: "[]".to_string(),
            constraints_json: "[]".to_string(),
            priority: "medium".to_string(),
            status: "Pending".to_string(),
            branch: None,
            worktree_id: None,
            handoff_summary: None,
            created_at: now,
            updated_at: now,
            auto_dispatch: false,
            agent_profile_override: None,
            execution_mode: None,
            timeout_minutes: None,
            max_retries: None,
        };

        let t1_id = Uuid::new_v4().to_string();
        let t2_id = Uuid::new_v4().to_string();
        db.create_task(&make_task(&t1_id)).await.expect("create t1");
        db.create_task(&make_task(&t2_id)).await.expect("create t2");

        db.replace_task_dependencies(&t2_id, std::slice::from_ref(&t1_id))
            .await
            .expect("replace deps");

        let deps = db.list_task_dependencies(&t2_id).await.expect("list deps");
        assert_eq!(deps, vec![t1_id.clone()]);

        // replace with empty clears deps
        db.replace_task_dependencies(&t2_id, &[])
            .await
            .expect("clear deps");
        let empty = db
            .list_task_dependencies(&t2_id)
            .await
            .expect("list empty deps");
        assert!(empty.is_empty());
    }

    // ── D1: Session roundtrip ───────────────────────────────────────────────

    #[tokio::test]
    async fn session_roundtrip() {
        let db = open_test_db().await;
        let project_id = Uuid::new_v4().to_string();
        seed_project(&db, &project_id).await;

        let now = Utc::now();
        let session = SessionRow {
            id: Uuid::new_v4().to_string(),
            project_id: project_id.clone(),
            name: "claude-session".to_string(),
            r#type: Some("claude".to_string()),
            status: "running".to_string(),
            pid: Some(12345),
            cwd: "/tmp/project".to_string(),
            command: "claude".to_string(),
            branch: Some("main".to_string()),
            worktree_id: None,
            started_at: now,
            last_heartbeat: now,
        };

        db.upsert_session(&session).await.expect("upsert session");

        let sessions = db.list_sessions(&project_id).await.expect("list sessions");
        assert_eq!(sessions.len(), 1);
        let loaded = &sessions[0];
        assert_eq!(loaded.id, session.id);
        assert_eq!(loaded.name, "claude-session");
        assert_eq!(loaded.pid, Some(12345));
        assert_eq!(loaded.status, "running");

        // upsert updates status
        let mut updated = session.clone();
        updated.status = "stopped".to_string();
        updated.pid = None;
        db.upsert_session(&updated).await.expect("upsert update");

        let sessions2 = db
            .list_sessions(&project_id)
            .await
            .expect("list sessions after update");
        assert_eq!(sessions2[0].status, "stopped");
        assert_eq!(sessions2[0].pid, None);
    }

    // ── D1: Event roundtrip ─────────────────────────────────────────────────

    #[tokio::test]
    async fn event_roundtrip_and_filter() {
        let db = open_test_db().await;
        let project_id = Uuid::new_v4().to_string();
        seed_project(&db, &project_id).await;

        let task_id = Uuid::new_v4().to_string();
        let session_id = Uuid::new_v4().to_string();

        let ev1 = NewEvent {
            id: Uuid::new_v4().to_string(),
            project_id: project_id.clone(),
            task_id: Some(task_id.clone()),
            session_id: Some(session_id.clone()),
            trace_id: "trace-1".to_string(),
            source: "agent".to_string(),
            event_type: "task.start".to_string(),
            payload: serde_json::json!({"key": "value"}),
        };
        let ev2 = NewEvent {
            id: Uuid::new_v4().to_string(),
            project_id: project_id.clone(),
            task_id: Some(task_id.clone()),
            session_id: None,
            trace_id: "trace-2".to_string(),
            source: "system".to_string(),
            event_type: "task.complete".to_string(),
            payload: serde_json::json!({}),
        };

        db.append_event(ev1).await.expect("append ev1");
        db.append_event(ev2).await.expect("append ev2");

        // Unfiltered query
        let all = db
            .query_events(EventQueryFilter {
                project_id: project_id.clone(),
                ..Default::default()
            })
            .await
            .expect("query all events");
        assert_eq!(all.len(), 2);

        // Filter by event_type
        let filtered = db
            .query_events(EventQueryFilter {
                project_id: project_id.clone(),
                event_type: Some("task.start".to_string()),
                ..Default::default()
            })
            .await
            .expect("query filtered events");
        assert_eq!(filtered.len(), 1);
        assert_eq!(filtered[0].event_type, "task.start");
        assert_eq!(filtered[0].source, "agent");

        // limit
        let limited = db
            .query_events(EventQueryFilter {
                project_id: project_id.clone(),
                limit: Some(1),
                ..Default::default()
            })
            .await
            .expect("query limited events");
        assert_eq!(limited.len(), 1);

        // list_recent_events returns in ascending order
        let recent = db
            .list_recent_events(&project_id, 10)
            .await
            .expect("list recent");
        assert_eq!(recent.len(), 2);
    }

    // ── D1: Workflow roundtrip ──────────────────────────────────────────────

    #[tokio::test]
    async fn workflow_instance_roundtrip() {
        let db = open_test_db().await;
        let project_id = Uuid::new_v4().to_string();
        seed_project(&db, &project_id).await;

        let now = Utc::now();
        let instance = WorkflowInstanceRow {
            id: Uuid::new_v4().to_string(),
            project_id: project_id.clone(),
            workflow_name: "deploy".to_string(),
            description: Some("Deploy to prod".to_string()),
            status: "pending".to_string(),
            created_at: now,
            updated_at: now,
            params_json: None,
            stage_results_json: None,
            expanded_steps_json: None,
        };

        db.create_workflow_instance(&instance)
            .await
            .expect("create workflow instance");

        let loaded = db
            .get_workflow_instance(&instance.id)
            .await
            .expect("get workflow instance")
            .expect("instance should exist");
        assert_eq!(loaded.workflow_name, "deploy");
        assert_eq!(loaded.status, "pending");
        assert_eq!(loaded.description.as_deref(), Some("Deploy to prod"));

        // Update status
        db.update_workflow_instance_status(&instance.id, "running")
            .await
            .expect("update status");
        let updated = db
            .get_workflow_instance(&instance.id)
            .await
            .expect("get after update")
            .expect("instance");
        assert_eq!(updated.status, "running");

        // workflow_tasks
        let now2 = Utc::now();
        let task_row = TaskRow {
            id: Uuid::new_v4().to_string(),
            project_id: project_id.clone(),
            title: "wf task".to_string(),
            goal: "goal".to_string(),
            scope_json: "[]".to_string(),
            dependencies_json: "[]".to_string(),
            acceptance_json: "[]".to_string(),
            constraints_json: "[]".to_string(),
            priority: "low".to_string(),
            status: "Pending".to_string(),
            branch: None,
            worktree_id: None,
            handoff_summary: None,
            created_at: now2,
            updated_at: now2,
            auto_dispatch: false,
            agent_profile_override: None,
            execution_mode: None,
            timeout_minutes: None,
            max_retries: None,
        };
        db.create_task(&task_row).await.expect("create wf task");
        db.add_workflow_task(&instance.id, 0, &task_row.id)
            .await
            .expect("add wf task");

        let wf_tasks = db
            .list_workflow_tasks(&instance.id)
            .await
            .expect("list wf tasks");
        assert_eq!(wf_tasks.len(), 1);
        assert_eq!(wf_tasks[0].task_id, task_row.id);
        assert_eq!(wf_tasks[0].step_index, 0);

        // find_workflow_by_task
        let found = db
            .find_workflow_by_task(&task_row.id)
            .await
            .expect("find wf by task")
            .expect("should be found");
        assert_eq!(found.workflow_id, instance.id);

        // list_workflow_instances
        let list = db
            .list_workflow_instances(&project_id)
            .await
            .expect("list instances");
        assert_eq!(list.len(), 1);
    }

    // ── D1: Notification roundtrip ──────────────────────────────────────────

    #[tokio::test]
    async fn notification_roundtrip() {
        let db = open_test_db().await;
        let project_id = Uuid::new_v4().to_string();
        seed_project(&db, &project_id).await;

        let n1 = NotificationRow {
            id: Uuid::new_v4().to_string(),
            project_id: project_id.clone(),
            task_id: None,
            session_id: None,
            title: "Task complete".to_string(),
            body: "Task completed successfully".to_string(),
            level: "info".to_string(),
            unread: true,
            created_at: Utc::now(),
        };
        let n2 = NotificationRow {
            id: Uuid::new_v4().to_string(),
            project_id: project_id.clone(),
            task_id: None,
            session_id: None,
            title: "Error".to_string(),
            body: "Something went wrong".to_string(),
            level: "error".to_string(),
            unread: true,
            created_at: Utc::now(),
        };

        db.create_notification(&n1).await.expect("create n1");
        db.create_notification(&n2).await.expect("create n2");

        // list all
        let all = db
            .list_notifications(&project_id, false)
            .await
            .expect("list all");
        assert_eq!(all.len(), 2);

        // list unread only
        let unread = db
            .list_notifications(&project_id, true)
            .await
            .expect("list unread");
        assert_eq!(unread.len(), 2);

        // mark one read
        db.mark_notification_read(&n1.id).await.expect("mark read");
        let unread_after = db
            .list_notifications(&project_id, true)
            .await
            .expect("list unread after mark");
        assert_eq!(unread_after.len(), 1);
        assert_eq!(unread_after[0].id, n2.id);

        // clear all
        db.clear_notifications(&project_id)
            .await
            .expect("clear notifications");
        let unread_cleared = db
            .list_notifications(&project_id, true)
            .await
            .expect("list after clear");
        assert!(unread_cleared.is_empty());
    }

    // ── D1: Worktree roundtrip ──────────────────────────────────────────────

    #[tokio::test]
    async fn worktree_roundtrip() {
        let db = open_test_db().await;
        let project_id = Uuid::new_v4().to_string();
        seed_project(&db, &project_id).await;

        let now = Utc::now();
        let task_id = Uuid::new_v4().to_string();
        // create a task first (worktrees have FK to tasks with ON DELETE CASCADE)
        let task = TaskRow {
            id: task_id.clone(),
            project_id: project_id.clone(),
            title: "t".to_string(),
            goal: "g".to_string(),
            scope_json: "[]".to_string(),
            dependencies_json: "[]".to_string(),
            acceptance_json: "[]".to_string(),
            constraints_json: "[]".to_string(),
            priority: "low".to_string(),
            status: "Pending".to_string(),
            branch: None,
            worktree_id: None,
            handoff_summary: None,
            created_at: now,
            updated_at: now,
            auto_dispatch: false,
            agent_profile_override: None,
            execution_mode: None,
            timeout_minutes: None,
            max_retries: None,
        };
        db.create_task(&task).await.expect("create task for wt");

        let wt = WorktreeRow {
            id: Uuid::new_v4().to_string(),
            project_id: project_id.clone(),
            task_id: task_id.clone(),
            path: "/tmp/worktrees/feat-x".to_string(),
            branch: "feat/x".to_string(),
            lease_status: "active".to_string(),
            lease_started: now,
            last_active: now,
        };
        db.upsert_worktree(&wt).await.expect("upsert worktree");

        let loaded = db
            .find_worktree_by_task(&task_id)
            .await
            .expect("find worktree")
            .expect("should exist");
        assert_eq!(loaded.id, wt.id);
        assert_eq!(loaded.branch, "feat/x");
        assert_eq!(loaded.lease_status, "active");

        let list = db
            .list_worktrees(&project_id)
            .await
            .expect("list worktrees");
        assert_eq!(list.len(), 1);

        db.remove_worktree_by_task(&task_id)
            .await
            .expect("remove worktree");
        let gone = db
            .find_worktree_by_task(&task_id)
            .await
            .expect("find after remove");
        assert!(gone.is_none());
    }

    #[tokio::test]
    async fn phase5_ops_roundtrip() {
        let db = open_test_db().await;
        let project_id = Uuid::new_v4().to_string();

        db.upsert_project(
            &project_id,
            "test-project",
            "/tmp/test-project",
            Some("brief"),
            None,
        )
        .await
        .expect("upsert project");

        let onboarding = OnboardingStateRow {
            project_id: project_id.clone(),
            step: "dispatch_task".to_string(),
            completed: false,
            dismissed: false,
            updated_at: Utc::now(),
        };
        db.upsert_onboarding_state(&onboarding)
            .await
            .expect("onboarding upsert");
        let loaded_onboarding = db
            .get_onboarding_state(&project_id)
            .await
            .expect("onboarding get")
            .expect("onboarding row");
        assert_eq!(loaded_onboarding.step, "dispatch_task");

        let rule_id = Uuid::new_v4().to_string();
        db.upsert_rule(&RuleRow {
            id: rule_id.clone(),
            project_id: project_id.clone(),
            name: "security".to_string(),
            path: ".pnevma/rules/security.md".to_string(),
            scope: Some("rule".to_string()),
            active: true,
        })
        .await
        .expect("rule upsert");
        db.create_context_rule_usage(&ContextRuleUsageRow {
            id: Uuid::new_v4().to_string(),
            project_id: project_id.clone(),
            run_id: "run-1".to_string(),
            rule_id: rule_id.clone(),
            included: true,
            reason: "active".to_string(),
            created_at: Utc::now(),
        })
        .await
        .expect("rule usage insert");
        let usage = db
            .list_context_rule_usage(&project_id, &rule_id, 100)
            .await
            .expect("rule usage list");
        assert_eq!(usage.len(), 1);
        assert!(usage[0].included);

        db.append_telemetry_event(&TelemetryEventRow {
            id: Uuid::new_v4().to_string(),
            project_id: project_id.clone(),
            event_type: "project.open".to_string(),
            payload_json: "{\"ok\":true}".to_string(),
            anonymized: true,
            created_at: Utc::now(),
        })
        .await
        .expect("append telemetry");
        db.append_telemetry_event(&TelemetryEventRow {
            id: Uuid::new_v4().to_string(),
            project_id: project_id.clone(),
            event_type: "task.dispatch".to_string(),
            payload_json: "{\"ok\":true}".to_string(),
            anonymized: true,
            created_at: Utc::now(),
        })
        .await
        .expect("append telemetry");
        assert_eq!(
            db.count_telemetry_events(&project_id)
                .await
                .expect("telemetry count"),
            2
        );
        db.clear_telemetry_events(&project_id)
            .await
            .expect("telemetry clear");
        assert_eq!(
            db.count_telemetry_events(&project_id)
                .await
                .expect("telemetry count after clear"),
            0
        );

        db.create_feedback(&FeedbackRow {
            id: Uuid::new_v4().to_string(),
            project_id: project_id.clone(),
            category: "ux".to_string(),
            body: "keyboard flow friction".to_string(),
            contact: Some("partner@example.com".to_string()),
            artifact_path: Some(".pnevma/data/feedback/ux.md".to_string()),
            created_at: Utc::now(),
        })
        .await
        .expect("feedback insert");
        let feedback = db
            .list_feedback(&project_id, 100)
            .await
            .expect("feedback list");
        assert_eq!(feedback.len(), 1);
        assert_eq!(feedback[0].category, "ux");
    }

    // ── D1: Workflow definition roundtrip ───────────────────────────────────

    #[tokio::test]
    async fn workflow_definition_roundtrip() {
        let db = open_test_db().await;
        let project_id = Uuid::new_v4().to_string();
        seed_project(&db, &project_id).await;

        let now = Utc::now();
        let wf = crate::models::WorkflowRow {
            id: Uuid::new_v4().to_string(),
            project_id: project_id.clone(),
            name: "ci-pipeline".to_string(),
            description: Some("Runs CI steps".to_string()),
            definition_yaml: "steps:\n  - name: lint\n    goal: run linter\n".to_string(),
            source: "user".to_string(),
            created_at: now,
            updated_at: now,
        };

        // list before any inserts
        let empty = db
            .list_workflows(&project_id)
            .await
            .expect("list before insert");
        assert!(empty.is_empty());

        db.create_workflow(&wf).await.expect("create workflow");

        // get by id
        let loaded = db
            .get_workflow(&wf.id)
            .await
            .expect("get workflow")
            .expect("workflow should exist");
        assert_eq!(loaded.id, wf.id);
        assert_eq!(loaded.name, "ci-pipeline");
        assert_eq!(loaded.description.as_deref(), Some("Runs CI steps"));
        assert_eq!(loaded.source, "user");

        // get by name
        let by_name = db
            .get_workflow_by_name(&project_id, "ci-pipeline")
            .await
            .expect("get by name")
            .expect("should find by name");
        assert_eq!(by_name.id, wf.id);

        // get by name — not found
        let missing = db
            .get_workflow_by_name(&project_id, "nonexistent")
            .await
            .expect("get missing by name");
        assert!(missing.is_none());

        // list_workflows returns one entry
        let list = db
            .list_workflows(&project_id)
            .await
            .expect("list after insert");
        assert_eq!(list.len(), 1);
        assert_eq!(list[0].name, "ci-pipeline");

        // add a second workflow, verify list grows
        let wf2 = crate::models::WorkflowRow {
            id: Uuid::new_v4().to_string(),
            project_id: project_id.clone(),
            name: "deploy".to_string(),
            description: None,
            definition_yaml: "steps:\n  - name: ship\n    goal: deploy\n".to_string(),
            source: "user".to_string(),
            created_at: now,
            updated_at: now,
        };
        db.create_workflow(&wf2).await.expect("create workflow 2");
        let list2 = db
            .list_workflows(&project_id)
            .await
            .expect("list after second insert");
        assert_eq!(list2.len(), 2);
        // list is ordered by name ASC
        assert_eq!(list2[0].name, "ci-pipeline");
        assert_eq!(list2[1].name, "deploy");
    }

    #[tokio::test]
    async fn workflow_definition_update_and_delete() {
        let db = open_test_db().await;
        let project_id = Uuid::new_v4().to_string();
        seed_project(&db, &project_id).await;

        let now = Utc::now();
        let wf = crate::models::WorkflowRow {
            id: Uuid::new_v4().to_string(),
            project_id: project_id.clone(),
            name: "release".to_string(),
            description: Some("Release workflow".to_string()),
            definition_yaml: "steps:\n  - name: build\n    goal: build artifacts\n".to_string(),
            source: "user".to_string(),
            created_at: now,
            updated_at: now,
        };
        db.create_workflow(&wf).await.expect("create");

        // update — replace definition_yaml and name
        let updated = crate::models::WorkflowRow {
            id: wf.id.clone(),
            project_id: project_id.clone(),
            name: "release-v2".to_string(),
            description: Some("Updated release workflow".to_string()),
            definition_yaml:
                "steps:\n  - name: build\n    goal: build\n  - name: publish\n    goal: publish\n"
                    .to_string(),
            source: "user".to_string(),
            created_at: now,
            updated_at: Utc::now(),
        };
        db.update_workflow(&updated).await.expect("update");

        let reloaded = db
            .get_workflow(&wf.id)
            .await
            .expect("get after update")
            .expect("should still exist");
        assert_eq!(reloaded.name, "release-v2");
        assert_eq!(
            reloaded.description.as_deref(),
            Some("Updated release workflow")
        );
        assert!(reloaded.definition_yaml.contains("publish"));

        // delete
        db.delete_workflow(&wf.id).await.expect("delete");
        let gone = db.get_workflow(&wf.id).await.expect("get after delete");
        assert!(gone.is_none());

        let list = db
            .list_workflows(&project_id)
            .await
            .expect("list after delete");
        assert!(list.is_empty());
    }

    #[tokio::test]
    async fn workflow_instance_list_roundtrip() {
        let db = open_test_db().await;
        let project_id = Uuid::new_v4().to_string();
        seed_project(&db, &project_id).await;

        let now = Utc::now();

        // empty list before any inserts
        let empty = db
            .list_workflow_instances(&project_id)
            .await
            .expect("list empty instances");
        assert!(empty.is_empty());

        let inst1 = WorkflowInstanceRow {
            id: Uuid::new_v4().to_string(),
            project_id: project_id.clone(),
            workflow_name: "pipeline-a".to_string(),
            description: Some("first run".to_string()),
            status: "pending".to_string(),
            created_at: now,
            updated_at: now,
            params_json: Some("{\"env\":\"staging\"}".to_string()),
            stage_results_json: None,
            expanded_steps_json: None,
        };
        let inst2 = WorkflowInstanceRow {
            id: Uuid::new_v4().to_string(),
            project_id: project_id.clone(),
            workflow_name: "pipeline-b".to_string(),
            description: None,
            status: "running".to_string(),
            created_at: now,
            updated_at: now,
            params_json: None,
            stage_results_json: None,
            expanded_steps_json: None,
        };

        db.create_workflow_instance(&inst1)
            .await
            .expect("create inst1");
        db.create_workflow_instance(&inst2)
            .await
            .expect("create inst2");

        let list = db
            .list_workflow_instances(&project_id)
            .await
            .expect("list instances");
        assert_eq!(list.len(), 2);

        // get_workflow_instance for each
        let loaded1 = db
            .get_workflow_instance(&inst1.id)
            .await
            .expect("get inst1")
            .expect("inst1 exists");
        assert_eq!(loaded1.workflow_name, "pipeline-a");
        assert_eq!(
            loaded1.params_json.as_deref(),
            Some("{\"env\":\"staging\"}")
        );

        let loaded2 = db
            .get_workflow_instance(&inst2.id)
            .await
            .expect("get inst2")
            .expect("inst2 exists");
        assert_eq!(loaded2.workflow_name, "pipeline-b");
        assert_eq!(loaded2.status, "running");

        // get non-existent
        let missing = db
            .get_workflow_instance("no-such-id")
            .await
            .expect("get missing");
        assert!(missing.is_none());
    }

    #[tokio::test]
    async fn open_creates_database_file_for_fresh_project_root() {
        let project_root = std::env::temp_dir().join(format!("pnevma-db-open-{}", Uuid::new_v4()));
        tokio::fs::create_dir_all(&project_root)
            .await
            .expect("create temp project root");

        let db = Db::open(&project_root)
            .await
            .expect("open db in fresh root");
        assert_eq!(db.path(), project_root.join(".pnevma/pnevma.db").as_path());
        assert!(
            db.path().exists(),
            "Db::open should create the SQLite file for a fresh project root"
        );

        let projects = db.list_projects().await.expect("list migrated projects");
        assert!(
            projects.is_empty(),
            "fresh database should be migrated and empty"
        );

        drop(db);
        let _ = tokio::fs::remove_dir_all(&project_root).await;
    }
}
