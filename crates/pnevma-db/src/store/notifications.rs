use super::*;

impl Db {
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
}
