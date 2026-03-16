use super::*;

impl Db {
    pub async fn create_editor_profile(&self, row: &EditorProfileRow) -> Result<(), DbError> {
        sqlx::query(
            r#"
            INSERT INTO editor_profiles
            (id, project_id, name, editor, settings_json, extensions_json, keybindings_json, active, created_at, updated_at)
            VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10)
            "#,
        )
        .bind(&row.id)
        .bind(&row.project_id)
        .bind(&row.name)
        .bind(&row.editor)
        .bind(&row.settings_json)
        .bind(&row.extensions_json)
        .bind(&row.keybindings_json)
        .bind(row.active)
        .bind(&row.created_at)
        .bind(&row.updated_at)
        .execute(&self.pool)
        .await?;
        Ok(())
    }

    pub async fn list_editor_profiles(
        &self,
        project_id: &str,
    ) -> Result<Vec<EditorProfileRow>, DbError> {
        Ok(sqlx::query_as::<_, EditorProfileRow>(
            "SELECT * FROM editor_profiles WHERE project_id = ?1 ORDER BY name",
        )
        .bind(project_id)
        .fetch_all(&self.pool)
        .await?)
    }

    pub async fn get_editor_profile(&self, id: &str) -> Result<Option<EditorProfileRow>, DbError> {
        Ok(
            sqlx::query_as::<_, EditorProfileRow>("SELECT * FROM editor_profiles WHERE id = ?1")
                .bind(id)
                .fetch_optional(&self.pool)
                .await?,
        )
    }

    pub async fn update_editor_profile(&self, row: &EditorProfileRow) -> Result<(), DbError> {
        sqlx::query(
            r#"
            UPDATE editor_profiles SET
                name = ?2, editor = ?3, settings_json = ?4, extensions_json = ?5,
                keybindings_json = ?6, active = ?7, updated_at = ?8
            WHERE id = ?1
            "#,
        )
        .bind(&row.id)
        .bind(&row.name)
        .bind(&row.editor)
        .bind(&row.settings_json)
        .bind(&row.extensions_json)
        .bind(&row.keybindings_json)
        .bind(row.active)
        .bind(&row.updated_at)
        .execute(&self.pool)
        .await?;
        Ok(())
    }

    pub async fn delete_editor_profile(&self, id: &str) -> Result<(), DbError> {
        sqlx::query("DELETE FROM editor_profiles WHERE id = ?1")
            .bind(id)
            .execute(&self.pool)
            .await?;
        Ok(())
    }

    pub async fn set_active_editor_profile(
        &self,
        project_id: &str,
        id: &str,
    ) -> Result<(), DbError> {
        // Deactivate all profiles for this project first
        sqlx::query("UPDATE editor_profiles SET active = 0 WHERE project_id = ?1")
            .bind(project_id)
            .execute(&self.pool)
            .await?;
        // Activate the chosen one
        sqlx::query("UPDATE editor_profiles SET active = 1 WHERE id = ?1")
            .bind(id)
            .execute(&self.pool)
            .await?;
        Ok(())
    }
}
