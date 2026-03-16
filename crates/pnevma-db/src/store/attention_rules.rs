use super::*;

impl Db {
    pub async fn create_attention_rule(&self, row: &AttentionRuleRow) -> Result<(), DbError> {
        sqlx::query(
            r#"
            INSERT INTO attention_rules
            (id, project_id, name, description, event_type, condition_json, action, severity, enabled, cooldown_seconds, last_triggered, created_at, updated_at)
            VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12, ?13)
            "#,
        )
        .bind(&row.id)
        .bind(&row.project_id)
        .bind(&row.name)
        .bind(&row.description)
        .bind(&row.event_type)
        .bind(&row.condition_json)
        .bind(&row.action)
        .bind(&row.severity)
        .bind(row.enabled)
        .bind(row.cooldown_seconds)
        .bind(&row.last_triggered)
        .bind(&row.created_at)
        .bind(&row.updated_at)
        .execute(&self.pool)
        .await?;
        Ok(())
    }

    pub async fn list_attention_rules(
        &self,
        project_id: &str,
    ) -> Result<Vec<AttentionRuleRow>, DbError> {
        Ok(sqlx::query_as::<_, AttentionRuleRow>(
            "SELECT * FROM attention_rules WHERE project_id = ?1 ORDER BY name",
        )
        .bind(project_id)
        .fetch_all(&self.pool)
        .await?)
    }

    pub async fn get_attention_rule(&self, id: &str) -> Result<Option<AttentionRuleRow>, DbError> {
        Ok(
            sqlx::query_as::<_, AttentionRuleRow>("SELECT * FROM attention_rules WHERE id = ?1")
                .bind(id)
                .fetch_optional(&self.pool)
                .await?,
        )
    }

    pub async fn update_attention_rule(&self, row: &AttentionRuleRow) -> Result<(), DbError> {
        sqlx::query(
            r#"
            UPDATE attention_rules SET
                name = ?2, description = ?3, event_type = ?4, condition_json = ?5,
                action = ?6, severity = ?7, enabled = ?8, cooldown_seconds = ?9,
                updated_at = ?10
            WHERE id = ?1
            "#,
        )
        .bind(&row.id)
        .bind(&row.name)
        .bind(&row.description)
        .bind(&row.event_type)
        .bind(&row.condition_json)
        .bind(&row.action)
        .bind(&row.severity)
        .bind(row.enabled)
        .bind(row.cooldown_seconds)
        .bind(&row.updated_at)
        .execute(&self.pool)
        .await?;
        Ok(())
    }

    pub async fn delete_attention_rule(&self, id: &str) -> Result<(), DbError> {
        sqlx::query("DELETE FROM attention_rules WHERE id = ?1")
            .bind(id)
            .execute(&self.pool)
            .await?;
        Ok(())
    }

    pub async fn update_attention_rule_triggered(
        &self,
        id: &str,
        last_triggered: &str,
    ) -> Result<(), DbError> {
        sqlx::query("UPDATE attention_rules SET last_triggered = ?1 WHERE id = ?2")
            .bind(last_triggered)
            .bind(id)
            .execute(&self.pool)
            .await?;
        Ok(())
    }
}
