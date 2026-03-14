use super::*;

impl Db {
    pub async fn create_task(&self, task: &TaskRow) -> Result<(), DbError> {
        sqlx::query(
            r#"
            INSERT INTO tasks
            (id, project_id, title, goal, scope_json, dependencies_json, acceptance_json, constraints_json, priority, status, branch, worktree_id, handoff_summary, created_at, updated_at, auto_dispatch, agent_profile_override, execution_mode, timeout_minutes, max_retries, loop_iteration, loop_context_json)
            VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12, ?13, ?14, ?15, ?16, ?17, ?18, ?19, ?20, ?21, ?22)
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
        .bind(task.loop_iteration)
        .bind(&task.loop_context_json)
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
                max_retries = ?18,
                loop_iteration = ?19,
                loop_context_json = ?20
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
        .bind(task.loop_iteration)
        .bind(&task.loop_context_json)
        .execute(&self.pool)
        .await?;
        Ok(())
    }

    pub async fn get_task(&self, task_id: &str) -> Result<Option<TaskRow>, DbError> {
        let row = sqlx::query_as::<_, TaskRow>(
            r#"
            SELECT id, project_id, title, goal, scope_json, dependencies_json, acceptance_json, constraints_json,
                   priority, status, branch, worktree_id, handoff_summary, created_at, updated_at,
                   auto_dispatch, agent_profile_override, execution_mode, timeout_minutes, max_retries,
                   loop_iteration, loop_context_json
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
                   auto_dispatch, agent_profile_override, execution_mode, timeout_minutes, max_retries,
                   loop_iteration, loop_context_json
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

    /// Atomically claim the oldest task with status `Ready` for a project,
    /// setting its status to `Dispatching`. Returns the task ID if one was
    /// claimed, or `None` if no ready tasks exist (or another caller won the
    /// race). This prevents the TOCTOU race in `dispatch_next_ready`.
    pub async fn claim_next_ready_task(&self, project_id: &str) -> Result<Option<String>, DbError> {
        let result = sqlx::query_scalar::<_, String>(
            r#"
            UPDATE tasks
            SET status = 'Dispatching',
                updated_at = datetime('now')
            WHERE id = (
                SELECT id FROM tasks
                WHERE project_id = ?1 AND status = 'Ready'
                ORDER BY created_at ASC
                LIMIT 1
            ) AND status = 'Ready'
            RETURNING id
            "#,
        )
        .bind(project_id)
        .fetch_optional(&self.pool)
        .await?;
        Ok(result)
    }

    /// Conditionally update a task's status only if it currently matches
    /// `expected_status`. Returns true if the update was applied. Used for
    /// reverting failed dispatch claims.
    pub async fn update_task_status(
        &self,
        task_id: &str,
        expected_status: &str,
        new_status: &str,
    ) -> Result<bool, DbError> {
        let result = sqlx::query(
            "UPDATE tasks SET status = ?1, updated_at = datetime('now') WHERE id = ?2 AND status = ?3",
        )
        .bind(new_status)
        .bind(task_id)
        .bind(expected_status)
        .execute(&self.pool)
        .await?;
        Ok(result.rows_affected() > 0)
    }

    /// Bulk-update all tasks in a project matching `expected_status` to `new_status`.
    /// Returns the number of rows updated. Used for startup recovery of orphaned states.
    pub async fn update_task_status_bulk(
        &self,
        project_id: &str,
        expected_status: &str,
        new_status: &str,
    ) -> Result<u64, DbError> {
        let result = sqlx::query(
            "UPDATE tasks SET status = ?1, updated_at = datetime('now') WHERE project_id = ?2 AND status = ?3",
        )
        .bind(new_status)
        .bind(project_id)
        .bind(expected_status)
        .execute(&self.pool)
        .await?;
        Ok(result.rows_affected())
    }

    /// Swap a specific dependency on a task (replace old_dep with new_dep).
    pub async fn swap_task_dependency(
        &self,
        task_id: &str,
        old_dep: &str,
        new_dep: &str,
    ) -> Result<(), DbError> {
        sqlx::query(
            r#"
            UPDATE task_dependencies
            SET depends_on_task_id = ?3
            WHERE task_id = ?1 AND depends_on_task_id = ?2
            "#,
        )
        .bind(task_id)
        .bind(old_dep)
        .bind(new_dep)
        .execute(&self.pool)
        .await?;
        Ok(())
    }

    /// Conditionally update a task row only if the current status matches the
    /// expected value (optimistic locking). Returns true if the update was
    /// applied, false if the status has already changed.
    pub async fn update_task_conditional(
        &self,
        task: &TaskRow,
        expected_status: &str,
    ) -> Result<bool, DbError> {
        let result = sqlx::query(
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
                max_retries = ?18,
                loop_iteration = ?19,
                loop_context_json = ?20
            WHERE id = ?1 AND status = ?21
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
        .bind(task.loop_iteration)
        .bind(&task.loop_context_json)
        .bind(expected_status)
        .execute(&self.pool)
        .await?;
        Ok(result.rows_affected() > 0)
    }

    /// Find InProgress tasks that still appear recoverable because a live agent
    /// session is attached via worktree, branch, or worktree cwd.
    pub async fn list_recoverable_in_progress_tasks(
        &self,
        project_id: &str,
    ) -> Result<Vec<TaskRow>, DbError> {
        let rows = sqlx::query_as::<_, TaskRow>(
            r#"
            SELECT t.id, t.project_id, t.title, t.goal, t.scope_json, t.dependencies_json,
                   t.acceptance_json, t.constraints_json, t.priority, t.status, t.branch,
                   t.worktree_id, t.handoff_summary, t.created_at, t.updated_at,
                   t.auto_dispatch, t.agent_profile_override, t.execution_mode,
                   t.timeout_minutes, t.max_retries, t.loop_iteration, t.loop_context_json
            FROM tasks t
            WHERE t.project_id = ?1
              AND t.status = 'InProgress'
              AND EXISTS (
                SELECT 1
                FROM sessions s
                WHERE s.project_id = t.project_id
                  AND s.status = 'running'
                  AND COALESCE(s.type, '') = 'agent'
                  AND (
                    (t.worktree_id IS NOT NULL AND s.worktree_id = t.worktree_id)
                    OR (t.branch IS NOT NULL AND s.branch = t.branch)
                    OR EXISTS (
                        SELECT 1
                        FROM worktrees wt
                        WHERE wt.task_id = t.id
                          AND s.cwd = wt.path
                    )
                  )
              )
            ORDER BY t.updated_at DESC
            "#,
        )
        .bind(project_id)
        .fetch_all(&self.pool)
        .await?;
        Ok(rows)
    }

    /// Find tasks stuck in InProgress that have no active automation run.
    /// Used at startup to detect tasks orphaned by a crash.
    pub async fn list_orphaned_in_progress_tasks(
        &self,
        project_id: &str,
    ) -> Result<Vec<TaskRow>, DbError> {
        let rows = sqlx::query_as::<_, TaskRow>(
            r#"
            SELECT t.id, t.project_id, t.title, t.goal, t.scope_json, t.dependencies_json,
                   t.acceptance_json, t.constraints_json, t.priority, t.status, t.branch,
                   t.worktree_id, t.handoff_summary, t.created_at, t.updated_at,
                   t.auto_dispatch, t.agent_profile_override, t.execution_mode,
                   t.timeout_minutes, t.max_retries, t.loop_iteration, t.loop_context_json
            FROM tasks t
            WHERE t.project_id = ?1
              AND t.status = 'InProgress'
              AND NOT EXISTS (
                SELECT 1 FROM automation_runs ar
                WHERE ar.task_id = t.id AND ar.status = 'running'
              )
            "#,
        )
        .bind(project_id)
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
        let mut tx = self.pool.begin().await?;
        for row in rows {
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
            .execute(&mut *tx)
            .await?;
        }
        tx.commit().await?;
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

    pub async fn upsert_task_external_source(
        &self,
        row: &TaskExternalSourceRow,
    ) -> Result<(), DbError> {
        sqlx::query(
            "INSERT INTO task_external_sources (id, project_id, task_id, kind, external_id, identifier, url, state, synced_at)
             VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
             ON CONFLICT(project_id, kind, external_id) DO UPDATE SET
                task_id = excluded.task_id,
                identifier = excluded.identifier,
                url = excluded.url,
                state = excluded.state,
                synced_at = excluded.synced_at",
        )
        .bind(&row.id)
        .bind(&row.project_id)
        .bind(&row.task_id)
        .bind(&row.kind)
        .bind(&row.external_id)
        .bind(&row.identifier)
        .bind(&row.url)
        .bind(&row.state)
        .bind(row.synced_at)
        .execute(&self.pool)
        .await?;
        Ok(())
    }

    pub async fn get_task_external_source(
        &self,
        project_id: &str,
        kind: &str,
        external_id: &str,
    ) -> Result<Option<TaskExternalSourceRow>, DbError> {
        let row = sqlx::query_as::<_, TaskExternalSourceRow>(
            "SELECT * FROM task_external_sources WHERE project_id = ? AND kind = ? AND external_id = ?",
        )
        .bind(project_id)
        .bind(kind)
        .bind(external_id)
        .fetch_optional(&self.pool)
        .await?;
        Ok(row)
    }

    pub async fn list_task_external_sources(
        &self,
        project_id: &str,
    ) -> Result<Vec<TaskExternalSourceRow>, DbError> {
        let rows = sqlx::query_as::<_, TaskExternalSourceRow>(
            "SELECT * FROM task_external_sources WHERE project_id = ? ORDER BY synced_at DESC",
        )
        .bind(project_id)
        .fetch_all(&self.pool)
        .await?;
        Ok(rows)
    }

    pub async fn get_external_source_by_task(
        &self,
        task_id: &str,
    ) -> Result<Option<TaskExternalSourceRow>, DbError> {
        let row = sqlx::query_as::<_, TaskExternalSourceRow>(
            "SELECT * FROM task_external_sources WHERE task_id = ?",
        )
        .bind(task_id)
        .fetch_optional(&self.pool)
        .await?;
        Ok(row)
    }

    pub async fn delete_task_external_source(&self, id: &str) -> Result<(), DbError> {
        sqlx::query("DELETE FROM task_external_sources WHERE id = ?")
            .bind(id)
            .execute(&self.pool)
            .await?;
        Ok(())
    }
}
