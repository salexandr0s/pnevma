use super::*;

impl Db {
    pub async fn create_agent_hook(&self, row: &AgentHookRow) -> Result<(), DbError> {
        sqlx::query(
            r#"
            INSERT INTO agent_hooks (id, project_id, name, hook_type, command, timeout_seconds, enabled, sort_order, created_at, updated_at)
            VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10)
            "#,
        )
        .bind(&row.id)
        .bind(&row.project_id)
        .bind(&row.name)
        .bind(&row.hook_type)
        .bind(&row.command)
        .bind(row.timeout_seconds)
        .bind(row.enabled)
        .bind(row.sort_order)
        .bind(&row.created_at)
        .bind(&row.updated_at)
        .execute(&self.pool)
        .await?;
        Ok(())
    }

    pub async fn list_agent_hooks(
        &self,
        project_id: &str,
        hook_type: Option<&str>,
    ) -> Result<Vec<AgentHookRow>, DbError> {
        if let Some(ht) = hook_type {
            Ok(sqlx::query_as::<_, AgentHookRow>(
                "SELECT * FROM agent_hooks WHERE project_id = ?1 AND hook_type = ?2 AND enabled = 1 ORDER BY sort_order",
            )
            .bind(project_id)
            .bind(ht)
            .fetch_all(&self.pool)
            .await?)
        } else {
            Ok(sqlx::query_as::<_, AgentHookRow>(
                "SELECT * FROM agent_hooks WHERE project_id = ?1 ORDER BY sort_order",
            )
            .bind(project_id)
            .fetch_all(&self.pool)
            .await?)
        }
    }

    pub async fn get_agent_hook(&self, id: &str) -> Result<Option<AgentHookRow>, DbError> {
        Ok(
            sqlx::query_as::<_, AgentHookRow>("SELECT * FROM agent_hooks WHERE id = ?1")
                .bind(id)
                .fetch_optional(&self.pool)
                .await?,
        )
    }

    pub async fn update_agent_hook(&self, row: &AgentHookRow) -> Result<(), DbError> {
        sqlx::query(
            r#"
            UPDATE agent_hooks SET
                name = ?2, hook_type = ?3, command = ?4, timeout_seconds = ?5,
                enabled = ?6, sort_order = ?7, updated_at = ?8
            WHERE id = ?1
            "#,
        )
        .bind(&row.id)
        .bind(&row.name)
        .bind(&row.hook_type)
        .bind(&row.command)
        .bind(row.timeout_seconds)
        .bind(row.enabled)
        .bind(row.sort_order)
        .bind(&row.updated_at)
        .execute(&self.pool)
        .await?;
        Ok(())
    }

    pub async fn delete_agent_hook(&self, id: &str) -> Result<(), DbError> {
        sqlx::query("DELETE FROM agent_hooks WHERE id = ?1")
            .bind(id)
            .execute(&self.pool)
            .await?;
        Ok(())
    }
}
