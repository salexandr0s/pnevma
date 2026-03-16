use super::*;

impl Db {
    pub async fn create_task_lineage(&self, row: &TaskLineageRow) -> Result<(), DbError> {
        sqlx::query(
            r#"
            INSERT INTO task_lineage (id, project_id, parent_task_id, child_task_id, fork_reason, created_at)
            VALUES (?1, ?2, ?3, ?4, ?5, ?6)
            "#,
        )
        .bind(&row.id)
        .bind(&row.project_id)
        .bind(&row.parent_task_id)
        .bind(&row.child_task_id)
        .bind(&row.fork_reason)
        .bind(&row.created_at)
        .execute(&self.pool)
        .await?;
        Ok(())
    }

    pub async fn list_task_children(
        &self,
        parent_task_id: &str,
    ) -> Result<Vec<TaskLineageRow>, DbError> {
        Ok(sqlx::query_as::<_, TaskLineageRow>(
            "SELECT * FROM task_lineage WHERE parent_task_id = ?1 ORDER BY created_at",
        )
        .bind(parent_task_id)
        .fetch_all(&self.pool)
        .await?)
    }

    pub async fn list_task_ancestors(
        &self,
        child_task_id: &str,
    ) -> Result<Vec<TaskLineageRow>, DbError> {
        Ok(sqlx::query_as::<_, TaskLineageRow>(
            "SELECT * FROM task_lineage WHERE child_task_id = ?1 ORDER BY created_at",
        )
        .bind(child_task_id)
        .fetch_all(&self.pool)
        .await?)
    }

    pub async fn get_task_lineage(
        &self,
        parent_task_id: &str,
        child_task_id: &str,
    ) -> Result<Option<TaskLineageRow>, DbError> {
        Ok(sqlx::query_as::<_, TaskLineageRow>(
            "SELECT * FROM task_lineage WHERE parent_task_id = ?1 AND child_task_id = ?2",
        )
        .bind(parent_task_id)
        .bind(child_task_id)
        .fetch_optional(&self.pool)
        .await?)
    }
}
