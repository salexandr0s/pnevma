use super::*;

impl Db {
    pub async fn allocate_port(&self, row: &PortAllocationRow) -> Result<(), DbError> {
        sqlx::query(
            r#"
            INSERT INTO port_allocations (id, project_id, task_id, session_id, port, protocol, label, allocated_at, released_at)
            VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9)
            "#,
        )
        .bind(&row.id)
        .bind(&row.project_id)
        .bind(&row.task_id)
        .bind(&row.session_id)
        .bind(row.port)
        .bind(&row.protocol)
        .bind(&row.label)
        .bind(&row.allocated_at)
        .bind(&row.released_at)
        .execute(&self.pool)
        .await?;
        Ok(())
    }

    pub async fn release_port(&self, id: &str, released_at: &str) -> Result<(), DbError> {
        sqlx::query("UPDATE port_allocations SET released_at = ?1 WHERE id = ?2")
            .bind(released_at)
            .bind(id)
            .execute(&self.pool)
            .await?;
        Ok(())
    }

    pub async fn list_port_allocations(
        &self,
        project_id: &str,
    ) -> Result<Vec<PortAllocationRow>, DbError> {
        Ok(sqlx::query_as::<_, PortAllocationRow>(
            "SELECT * FROM port_allocations WHERE project_id = ?1 AND released_at IS NULL ORDER BY port",
        )
        .bind(project_id)
        .fetch_all(&self.pool)
        .await?)
    }

    pub async fn get_port_allocation_by_port(
        &self,
        project_id: &str,
        port: i64,
    ) -> Result<Option<PortAllocationRow>, DbError> {
        Ok(sqlx::query_as::<_, PortAllocationRow>(
            "SELECT * FROM port_allocations WHERE project_id = ?1 AND port = ?2 AND released_at IS NULL",
        )
        .bind(project_id)
        .bind(port)
        .fetch_optional(&self.pool)
        .await?)
    }
}
