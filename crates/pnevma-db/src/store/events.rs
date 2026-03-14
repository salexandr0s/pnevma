use super::*;

impl Db {
    pub async fn append_event(&self, event: NewEvent) -> Result<(), DbError> {
        sqlx::query(
            r#"
            INSERT INTO events (id, project_id, task_id, session_id, trace_id, source, event_type, payload_json, timestamp)
            VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9)
            "#,
        )
        .bind(event.id)
        .bind(event.project_id)
        .bind(event.task_id)
        .bind(event.session_id)
        .bind(event.trace_id)
        .bind(event.source)
        .bind(event.event_type)
        .bind(event.payload.to_string())
        .bind(Utc::now())
        .execute(&self.pool)
        .await?;
        Ok(())
    }

    pub async fn query_events(&self, filter: EventQueryFilter) -> Result<Vec<EventRow>, DbError> {
        let mut query = String::from(
            r#"
            SELECT id, project_id, task_id, session_id, trace_id, source, event_type, payload_json, timestamp
            FROM events
            WHERE project_id = ?1
            "#,
        );

        if filter.task_id.is_some() {
            query.push_str(" AND task_id = ?2");
        }
        if filter.session_id.is_some() {
            query.push_str(if filter.task_id.is_some() {
                " AND session_id = ?3"
            } else {
                " AND session_id = ?2"
            });
        }
        let mut next_idx = 2;
        if filter.task_id.is_some() {
            next_idx += 1;
        }
        if filter.session_id.is_some() {
            next_idx += 1;
        }
        if filter.event_type.is_some() {
            query.push_str(&format!(" AND event_type = ?{next_idx}"));
            next_idx += 1;
        }
        if filter.from.is_some() {
            query.push_str(&format!(" AND timestamp >= ?{next_idx}"));
            next_idx += 1;
        }
        if filter.to.is_some() {
            query.push_str(&format!(" AND timestamp <= ?{next_idx}"));
            next_idx += 1;
        }

        query.push_str(" ORDER BY timestamp ASC, id ASC");
        if filter.limit.is_some() {
            query.push_str(&format!(" LIMIT ?{next_idx}"));
        }

        let mut q = sqlx::query_as::<_, EventRow>(&query).bind(&filter.project_id);
        if let Some(task_id) = &filter.task_id {
            q = q.bind(task_id);
        }
        if let Some(session_id) = &filter.session_id {
            q = q.bind(session_id);
        }
        if let Some(event_type) = &filter.event_type {
            q = q.bind(event_type);
        }
        if let Some(from) = filter.from {
            q = q.bind(from);
        }
        if let Some(to) = filter.to {
            q = q.bind(to);
        }
        if let Some(limit) = filter.limit {
            q = q.bind(limit);
        }

        let rows = q.fetch_all(&self.pool).await?;
        Ok(rows)
    }

    pub async fn list_recent_events(
        &self,
        project_id: &str,
        limit: i64,
    ) -> Result<Vec<EventRow>, DbError> {
        let mut rows = sqlx::query_as::<_, EventRow>(
            r#"
            SELECT id, project_id, task_id, session_id, trace_id, source, event_type, payload_json, timestamp
            FROM events
            WHERE project_id = ?1
            ORDER BY timestamp DESC, id DESC
            LIMIT ?2
            "#,
        )
        .bind(project_id)
        .bind(limit)
        .fetch_all(&self.pool)
        .await?;
        rows.reverse();
        Ok(rows)
    }
}
