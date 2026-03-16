use super::*;

impl Db {
    pub async fn create_session_restore_log(
        &self,
        row: &SessionRestoreLogRow,
    ) -> Result<(), DbError> {
        sqlx::query(
            r#"
            INSERT INTO session_restore_log (id, session_id, project_id, action, outcome, error_message, created_at)
            VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7)
            "#,
        )
        .bind(&row.id)
        .bind(&row.session_id)
        .bind(&row.project_id)
        .bind(&row.action)
        .bind(&row.outcome)
        .bind(&row.error_message)
        .bind(&row.created_at)
        .execute(&self.pool)
        .await?;
        Ok(())
    }

    pub async fn list_session_restore_log(
        &self,
        session_id: &str,
    ) -> Result<Vec<SessionRestoreLogRow>, DbError> {
        Ok(sqlx::query_as::<_, SessionRestoreLogRow>(
            "SELECT * FROM session_restore_log WHERE session_id = ?1 ORDER BY created_at DESC",
        )
        .bind(session_id)
        .fetch_all(&self.pool)
        .await?)
    }

    pub async fn update_session_restore_status(
        &self,
        session_id: &str,
        restore_status: &str,
    ) -> Result<(), DbError> {
        sqlx::query("UPDATE sessions SET restore_status = ?1 WHERE id = ?2")
            .bind(restore_status)
            .bind(session_id)
            .execute(&self.pool)
            .await?;
        Ok(())
    }

    pub async fn update_session_exit(
        &self,
        session_id: &str,
        exit_code: i64,
        ended_at: &str,
    ) -> Result<(), DbError> {
        sqlx::query("UPDATE sessions SET exit_code = ?1, ended_at = ?2 WHERE id = ?3")
            .bind(exit_code)
            .bind(ended_at)
            .bind(session_id)
            .execute(&self.pool)
            .await?;
        Ok(())
    }
}
