use super::*;

impl Db {
    pub async fn record_telemetry_metric(&self, row: &TelemetryMetricRow) -> Result<(), DbError> {
        sqlx::query(
            r#"
            INSERT INTO telemetry_metrics (id, project_id, metric_name, metric_value, tags_json, recorded_at)
            VALUES (?1, ?2, ?3, ?4, ?5, ?6)
            "#,
        )
        .bind(&row.id)
        .bind(&row.project_id)
        .bind(&row.metric_name)
        .bind(row.metric_value)
        .bind(&row.tags_json)
        .bind(&row.recorded_at)
        .execute(&self.pool)
        .await?;
        Ok(())
    }

    pub async fn query_telemetry_metrics(
        &self,
        project_id: &str,
        metric_name: Option<&str>,
        limit: i64,
    ) -> Result<Vec<TelemetryMetricRow>, DbError> {
        if let Some(name) = metric_name {
            Ok(sqlx::query_as::<_, TelemetryMetricRow>(
                "SELECT * FROM telemetry_metrics WHERE project_id = ?1 AND metric_name = ?2 ORDER BY recorded_at DESC LIMIT ?3",
            )
            .bind(project_id)
            .bind(name)
            .bind(limit)
            .fetch_all(&self.pool)
            .await?)
        } else {
            Ok(sqlx::query_as::<_, TelemetryMetricRow>(
                "SELECT * FROM telemetry_metrics WHERE project_id = ?1 ORDER BY recorded_at DESC LIMIT ?2",
            )
            .bind(project_id)
            .bind(limit)
            .fetch_all(&self.pool)
            .await?)
        }
    }

    pub async fn prune_telemetry_metrics(
        &self,
        project_id: &str,
        before: &str,
    ) -> Result<u64, DbError> {
        let result =
            sqlx::query("DELETE FROM telemetry_metrics WHERE project_id = ?1 AND recorded_at < ?2")
                .bind(project_id)
                .bind(before)
                .execute(&self.pool)
                .await?;
        Ok(result.rows_affected())
    }

    pub async fn capture_fleet_snapshot(&self, row: &FleetSnapshotRow) -> Result<(), DbError> {
        sqlx::query(
            r#"
            INSERT INTO fleet_snapshots
            (id, project_id, active_sessions, active_dispatches, queued_dispatches, pool_max, pool_utilization, total_cost_usd, tasks_ready, tasks_in_progress, tasks_failed, captured_at)
            VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12)
            "#,
        )
        .bind(&row.id)
        .bind(&row.project_id)
        .bind(row.active_sessions)
        .bind(row.active_dispatches)
        .bind(row.queued_dispatches)
        .bind(row.pool_max)
        .bind(row.pool_utilization)
        .bind(row.total_cost_usd)
        .bind(row.tasks_ready)
        .bind(row.tasks_in_progress)
        .bind(row.tasks_failed)
        .bind(&row.captured_at)
        .execute(&self.pool)
        .await?;
        Ok(())
    }

    pub async fn list_fleet_snapshots(
        &self,
        project_id: &str,
        limit: i64,
    ) -> Result<Vec<FleetSnapshotRow>, DbError> {
        Ok(sqlx::query_as::<_, FleetSnapshotRow>(
            "SELECT * FROM fleet_snapshots WHERE project_id = ?1 ORDER BY captured_at DESC LIMIT ?2",
        )
        .bind(project_id)
        .bind(limit)
        .fetch_all(&self.pool)
        .await?)
    }

    pub async fn upsert_agent_performance(&self, row: &AgentPerformanceRow) -> Result<(), DbError> {
        sqlx::query(
            r#"
            INSERT INTO agent_performance
            (id, project_id, provider, model, period_start, period_end, runs_total, runs_success, runs_failed, avg_duration_seconds, tokens_in, tokens_out, cost_usd, p95_duration_seconds)
            VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12, ?13, ?14)
            ON CONFLICT(project_id, provider, model, period_start) DO UPDATE SET
                period_end = excluded.period_end,
                runs_total = excluded.runs_total,
                runs_success = excluded.runs_success,
                runs_failed = excluded.runs_failed,
                avg_duration_seconds = excluded.avg_duration_seconds,
                tokens_in = excluded.tokens_in,
                tokens_out = excluded.tokens_out,
                cost_usd = excluded.cost_usd,
                p95_duration_seconds = excluded.p95_duration_seconds
            "#,
        )
        .bind(&row.id)
        .bind(&row.project_id)
        .bind(&row.provider)
        .bind(&row.model)
        .bind(&row.period_start)
        .bind(&row.period_end)
        .bind(row.runs_total)
        .bind(row.runs_success)
        .bind(row.runs_failed)
        .bind(row.avg_duration_seconds)
        .bind(row.tokens_in)
        .bind(row.tokens_out)
        .bind(row.cost_usd)
        .bind(row.p95_duration_seconds)
        .execute(&self.pool)
        .await?;
        Ok(())
    }

    pub async fn list_agent_performance(
        &self,
        project_id: &str,
    ) -> Result<Vec<AgentPerformanceRow>, DbError> {
        Ok(sqlx::query_as::<_, AgentPerformanceRow>(
            "SELECT * FROM agent_performance WHERE project_id = ?1 ORDER BY period_start DESC",
        )
        .bind(project_id)
        .fetch_all(&self.pool)
        .await?)
    }
}
