use super::*;

impl Db {
    pub async fn create_intake_item(&self, row: &IntakeQueueRow) -> Result<(), DbError> {
        sqlx::query(
            r#"
            INSERT INTO intake_queue
            (id, project_id, kind, external_id, identifier, title, url, state, priority, labels_json, source_updated_at, ingested_at, status, promoted_task_id)
            VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12, ?13, ?14)
            "#,
        )
        .bind(&row.id)
        .bind(&row.project_id)
        .bind(&row.kind)
        .bind(&row.external_id)
        .bind(&row.identifier)
        .bind(&row.title)
        .bind(&row.url)
        .bind(&row.state)
        .bind(&row.priority)
        .bind(&row.labels_json)
        .bind(&row.source_updated_at)
        .bind(&row.ingested_at)
        .bind(&row.status)
        .bind(&row.promoted_task_id)
        .execute(&self.pool)
        .await?;
        Ok(())
    }

    pub async fn list_intake_items(
        &self,
        project_id: &str,
        status: Option<&str>,
    ) -> Result<Vec<IntakeQueueRow>, DbError> {
        if let Some(status) = status {
            Ok(sqlx::query_as::<_, IntakeQueueRow>(
                "SELECT * FROM intake_queue WHERE project_id = ?1 AND status = ?2 ORDER BY ingested_at DESC",
            )
            .bind(project_id)
            .bind(status)
            .fetch_all(&self.pool)
            .await?)
        } else {
            Ok(sqlx::query_as::<_, IntakeQueueRow>(
                "SELECT * FROM intake_queue WHERE project_id = ?1 ORDER BY ingested_at DESC",
            )
            .bind(project_id)
            .fetch_all(&self.pool)
            .await?)
        }
    }

    pub async fn update_intake_status(
        &self,
        id: &str,
        status: &str,
        promoted_task_id: Option<&str>,
    ) -> Result<(), DbError> {
        sqlx::query("UPDATE intake_queue SET status = ?1, promoted_task_id = ?2 WHERE id = ?3")
            .bind(status)
            .bind(promoted_task_id)
            .bind(id)
            .execute(&self.pool)
            .await?;
        Ok(())
    }

    pub async fn get_intake_item(&self, id: &str) -> Result<Option<IntakeQueueRow>, DbError> {
        Ok(
            sqlx::query_as::<_, IntakeQueueRow>("SELECT * FROM intake_queue WHERE id = ?1")
                .bind(id)
                .fetch_optional(&self.pool)
                .await?,
        )
    }
}
