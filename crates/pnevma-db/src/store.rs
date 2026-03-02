use crate::error::DbError;
use crate::models::{
    ArtifactRow, CheckResultRow, CheckRunRow, CheckpointRow, ContextRuleUsageRow, CostRow,
    EventRow, FeedbackRow, MergeQueueRow, NotificationRow, OnboardingStateRow,
    PaneLayoutTemplateRow, PaneRow, ProjectRow, ReviewRow, RuleRow, SecretRefRow, SessionRow,
    TaskRow, TelemetryEventRow, WorktreeRow,
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
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::models::{
        ContextRuleUsageRow, FeedbackRow, OnboardingStateRow, RuleRow, TelemetryEventRow,
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
}
