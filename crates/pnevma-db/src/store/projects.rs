use super::*;

impl Db {
    pub async fn upsert_project(
        &self,
        id: &str,
        name: &str,
        path: &str,
        brief: Option<&str>,
        config_path: Option<&str>,
    ) -> Result<(), DbError> {
        let now = Utc::now();
        sqlx::query(
            r#"
            INSERT INTO projects (id, name, path, brief, config_path, created_at)
            VALUES (?1, ?2, ?3, ?4, ?5, ?6)
            ON CONFLICT(id) DO UPDATE SET
              name=excluded.name,
              path=excluded.path,
              brief=excluded.brief,
              config_path=excluded.config_path
            "#,
        )
        .bind(id)
        .bind(name)
        .bind(path)
        .bind(brief)
        .bind(config_path)
        .bind(now)
        .execute(&self.pool)
        .await?;
        Ok(())
    }

    pub async fn list_projects(&self) -> Result<Vec<ProjectRow>, DbError> {
        let rows = sqlx::query_as::<_, ProjectRow>(
            "SELECT id, name, path, brief, config_path, created_at FROM projects ORDER BY created_at DESC",
        )
        .fetch_all(&self.pool)
        .await?;
        Ok(rows)
    }

    pub async fn find_project_by_path(&self, path: &str) -> Result<Option<ProjectRow>, DbError> {
        let row = sqlx::query_as::<_, ProjectRow>(
            r#"
            SELECT id, name, path, brief, config_path, created_at
            FROM projects
            WHERE path = ?1
            LIMIT 1
            "#,
        )
        .bind(path)
        .fetch_optional(&self.pool)
        .await?;
        Ok(row)
    }

    pub async fn get_project(&self, id: &str) -> Result<Option<ProjectRow>, DbError> {
        let row = sqlx::query_as::<_, ProjectRow>(
            r#"
            SELECT id, name, path, brief, config_path, created_at
            FROM projects
            WHERE id = ?1
            LIMIT 1
            "#,
        )
        .bind(id)
        .fetch_optional(&self.pool)
        .await?;
        Ok(row)
    }
}
