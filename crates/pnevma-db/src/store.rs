use crate::error::DbError;
use crate::models::{CostRow, EventRow, PaneRow, ProjectRow, SessionRow, TaskRow, WorktreeRow};
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
        }

        let uri = format!("sqlite://{}", db_path.to_string_lossy());
        let pool = SqlitePoolOptions::new()
            .max_connections(5)
            .connect(&uri)
            .await?;

        let db = Self {
            pool,
            path: db_path,
        };
        db.migrate().await?;
        Ok(db)
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

    pub async fn create_task(&self, task: &TaskRow) -> Result<(), DbError> {
        sqlx::query(
            r#"
            INSERT INTO tasks
            (id, project_id, title, goal, scope_json, dependencies_json, acceptance_json, constraints_json, priority, status, branch, worktree_id, handoff_summary, created_at, updated_at)
            VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12, ?13, ?14, ?15)
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
                updated_at = ?13
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
        .execute(&self.pool)
        .await?;
        Ok(())
    }

    pub async fn get_task(&self, task_id: &str) -> Result<Option<TaskRow>, DbError> {
        let row = sqlx::query_as::<_, TaskRow>(
            r#"
            SELECT id, project_id, title, goal, scope_json, dependencies_json, acceptance_json, constraints_json,
                   priority, status, branch, worktree_id, handoff_summary, created_at, updated_at
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
                   priority, status, branch, worktree_id, handoff_summary, created_at, updated_at
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
}
