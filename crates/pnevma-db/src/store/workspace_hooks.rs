use super::*;

impl Db {
    pub async fn create_workspace_hook_run(
        &self,
        row: &WorkspaceHookRunRow,
    ) -> Result<(), DbError> {
        sqlx::query(
            r#"
            INSERT INTO workspace_hook_runs
            (id, project_id, hook_name, phase, trigger_event, status, exit_code, stdout, stderr, duration_ms, started_at, completed_at)
            VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12)
            "#,
        )
        .bind(&row.id)
        .bind(&row.project_id)
        .bind(&row.hook_name)
        .bind(&row.phase)
        .bind(&row.trigger_event)
        .bind(&row.status)
        .bind(row.exit_code)
        .bind(&row.stdout)
        .bind(&row.stderr)
        .bind(row.duration_ms)
        .bind(&row.started_at)
        .bind(&row.completed_at)
        .execute(&self.pool)
        .await?;
        Ok(())
    }

    #[allow(clippy::too_many_arguments)]
    pub async fn complete_workspace_hook_run(
        &self,
        id: &str,
        status: &str,
        exit_code: i64,
        stdout: Option<&str>,
        stderr: Option<&str>,
        duration_ms: i64,
        completed_at: &str,
    ) -> Result<(), DbError> {
        sqlx::query(
            r#"
            UPDATE workspace_hook_runs SET
                status = ?1, exit_code = ?2, stdout = ?3, stderr = ?4,
                duration_ms = ?5, completed_at = ?6
            WHERE id = ?7
            "#,
        )
        .bind(status)
        .bind(exit_code)
        .bind(stdout)
        .bind(stderr)
        .bind(duration_ms)
        .bind(completed_at)
        .bind(id)
        .execute(&self.pool)
        .await?;
        Ok(())
    }

    pub async fn list_workspace_hook_runs(
        &self,
        project_id: &str,
        limit: i64,
    ) -> Result<Vec<WorkspaceHookRunRow>, DbError> {
        Ok(sqlx::query_as::<_, WorkspaceHookRunRow>(
            "SELECT * FROM workspace_hook_runs WHERE project_id = ?1 ORDER BY started_at DESC LIMIT ?2",
        )
        .bind(project_id)
        .bind(limit)
        .fetch_all(&self.pool)
        .await?)
    }
}
