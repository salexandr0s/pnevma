use super::*;

impl Db {
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
}
