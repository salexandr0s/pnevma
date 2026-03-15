use super::*;

impl Db {
    pub async fn append_cost(&self, cost: &CostRow) -> Result<(), DbError> {
        sqlx::query(
            r#"
            INSERT INTO costs (id, agent_run_id, task_id, session_id, provider, model, tokens_in, tokens_out, estimated_usd, tracked, timestamp)
            VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11)
            "#,
        )
        .bind(&cost.id)
        .bind(&cost.agent_run_id)
        .bind(&cost.task_id)
        .bind(&cost.session_id)
        .bind(&cost.provider)
        .bind(&cost.model)
        .bind(cost.tokens_in)
        .bind(cost.tokens_out)
        .bind(cost.estimated_usd)
        .bind(cost.tracked)
        .bind(cost.timestamp)
        .execute(&self.pool)
        .await?;
        Ok(())
    }

    pub async fn task_cost_total(&self, task_id: &str) -> Result<f64, DbError> {
        let total: Option<f64> =
            sqlx::query_scalar("SELECT SUM(estimated_usd) FROM costs WHERE task_id = ?1")
                .bind(task_id)
                .fetch_one(&self.pool)
                .await?;
        Ok(total.unwrap_or(0.0))
    }

    pub async fn project_cost_total(&self, project_id: &str) -> Result<f64, DbError> {
        let total: Option<f64> = sqlx::query_scalar(
            r#"
            SELECT SUM(c.estimated_usd)
            FROM costs c
            JOIN tasks t ON t.id = c.task_id
            WHERE t.project_id = ?1
            "#,
        )
        .bind(project_id)
        .fetch_one(&self.pool)
        .await?;
        Ok(total.unwrap_or(0.0))
    }

    /// Aggregate raw costs into hourly buckets for a project.
    ///
    /// Groups costs by (provider, model, hour) and upserts into cost_hourly_aggregates,
    /// overwriting existing sums on conflict to avoid double-counting.
    pub async fn aggregate_costs_hourly(&self, project_id: &str) -> Result<(), DbError> {
        sqlx::query(
            r#"
            INSERT INTO cost_hourly_aggregates
                (id, project_id, provider, model, period_start, tokens_in, tokens_out, estimated_usd, record_count)
            SELECT
                lower(hex(randomblob(16))),
                t.project_id,
                c.provider,
                COALESCE(c.model, ''),
                strftime('%Y-%m-%dT%H:00:00', datetime(c.timestamp)) AS period_start,
                SUM(c.tokens_in),
                SUM(c.tokens_out),
                SUM(c.estimated_usd),
                COUNT(*)
            FROM costs c
            JOIN tasks t ON t.id = c.task_id
            WHERE t.project_id = ?1
            GROUP BY t.project_id, c.provider, COALESCE(c.model, ''), strftime('%Y-%m-%dT%H:00:00', datetime(c.timestamp))
            ON CONFLICT(project_id, provider, model, period_start) DO UPDATE SET
                tokens_in     = excluded.tokens_in,
                tokens_out    = excluded.tokens_out,
                estimated_usd = excluded.estimated_usd,
                record_count  = excluded.record_count
            "#,
        )
        .bind(project_id)
        .execute(&self.pool)
        .await?;
        Ok(())
    }

    /// Aggregate raw costs into daily buckets for a project, joining tasks for completion count.
    pub async fn aggregate_costs_daily(&self, project_id: &str) -> Result<(), DbError> {
        sqlx::query(
            r#"
            INSERT INTO cost_daily_aggregates
                (id, project_id, provider, model, period_date, tokens_in, tokens_out, estimated_usd, record_count, tasks_completed, files_changed)
            SELECT
                lower(hex(randomblob(16))),
                t.project_id,
                c.provider,
                COALESCE(c.model, ''),
                strftime('%Y-%m-%d', datetime(c.timestamp)) AS period_date,
                SUM(c.tokens_in),
                SUM(c.tokens_out),
                SUM(c.estimated_usd),
                COUNT(*),
                COUNT(DISTINCT CASE WHEN t.status = 'Done' THEN t.id END),
                0
            FROM costs c
            JOIN tasks t ON t.id = c.task_id
            WHERE t.project_id = ?1
            GROUP BY t.project_id, c.provider, COALESCE(c.model, ''), strftime('%Y-%m-%d', datetime(c.timestamp))
            ON CONFLICT(project_id, provider, model, period_date) DO UPDATE SET
                tokens_in       = excluded.tokens_in,
                tokens_out      = excluded.tokens_out,
                estimated_usd   = excluded.estimated_usd,
                record_count    = excluded.record_count,
                tasks_completed = excluded.tasks_completed
            "#,
        )
        .bind(project_id)
        .execute(&self.pool)
        .await?;
        Ok(())
    }

    /// Sum daily aggregates by provider over the given number of days.
    ///
    /// `days` must be positive; values less than 1 are clamped to 1.
    pub async fn get_usage_breakdown(
        &self,
        project_id: &str,
        days: i64,
    ) -> Result<Vec<CostDailyAggregateRow>, DbError> {
        let days = days.max(1);
        let rows = sqlx::query_as::<_, CostDailyAggregateRow>(
            r#"
            SELECT
                lower(hex(randomblob(16))) AS id,
                project_id,
                provider,
                '' AS model,
                '' AS period_date,
                SUM(tokens_in) AS tokens_in,
                SUM(tokens_out) AS tokens_out,
                SUM(estimated_usd) AS estimated_usd,
                SUM(record_count) AS record_count,
                SUM(tasks_completed) AS tasks_completed,
                SUM(files_changed) AS files_changed
            FROM cost_daily_aggregates
            WHERE project_id = ?1
              AND period_date >= date('now', ?2)
            GROUP BY project_id, provider
            ORDER BY estimated_usd DESC
            "#,
        )
        .bind(project_id)
        .bind(format!("-{} days", days))
        .fetch_all(&self.pool)
        .await?;
        Ok(rows)
    }

    /// Sum all daily aggregates by model across all time.
    pub async fn get_usage_by_model(
        &self,
        project_id: &str,
    ) -> Result<Vec<CostDailyAggregateRow>, DbError> {
        let rows = sqlx::query_as::<_, CostDailyAggregateRow>(
            r#"
            SELECT
                lower(hex(randomblob(16))) AS id,
                project_id,
                provider,
                model,
                '' AS period_date,
                SUM(tokens_in) AS tokens_in,
                SUM(tokens_out) AS tokens_out,
                SUM(estimated_usd) AS estimated_usd,
                SUM(record_count) AS record_count,
                SUM(tasks_completed) AS tasks_completed,
                SUM(files_changed) AS files_changed
            FROM cost_daily_aggregates
            WHERE project_id = ?1
            GROUP BY project_id, provider, model
            ORDER BY estimated_usd DESC
            "#,
        )
        .bind(project_id)
        .fetch_all(&self.pool)
        .await?;
        Ok(rows)
    }

    /// Daily totals aggregated across all providers for a trend chart.
    ///
    /// `days` must be positive; values less than 1 are clamped to 1.
    pub async fn get_usage_daily_trend(
        &self,
        project_id: &str,
        days: i64,
    ) -> Result<Vec<CostDailyAggregateRow>, DbError> {
        let days = days.max(1);
        let rows = sqlx::query_as::<_, CostDailyAggregateRow>(
            r#"
            SELECT
                lower(hex(randomblob(16))) AS id,
                project_id,
                '' AS provider,
                '' AS model,
                period_date,
                SUM(tokens_in) AS tokens_in,
                SUM(tokens_out) AS tokens_out,
                SUM(estimated_usd) AS estimated_usd,
                SUM(record_count) AS record_count,
                SUM(tasks_completed) AS tasks_completed,
                SUM(files_changed) AS files_changed
            FROM cost_daily_aggregates
            WHERE project_id = ?1
              AND period_date >= date('now', ?2)
            GROUP BY project_id, period_date
            ORDER BY period_date ASC
            "#,
        )
        .bind(project_id)
        .bind(format!("-{} days", days))
        .fetch_all(&self.pool)
        .await?;
        Ok(rows)
    }
}
