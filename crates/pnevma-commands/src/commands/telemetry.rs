use super::*;
use pnevma_db::{AgentPerformanceRow, FleetSnapshotRow, TelemetryMetricRow};

// ── Input/View types ────────────────────────────────────────────────────────

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct FleetSnapshotView {
    pub active_sessions: i64,
    pub active_dispatches: i64,
    pub queued_dispatches: i64,
    pub pool_max: i64,
    pub pool_utilization: f64,
    pub total_cost_usd: f64,
    pub tasks_ready: i64,
    pub tasks_in_progress: i64,
    pub tasks_failed: i64,
    pub captured_at: String,
}

impl From<FleetSnapshotRow> for FleetSnapshotView {
    fn from(row: FleetSnapshotRow) -> Self {
        Self {
            active_sessions: row.active_sessions,
            active_dispatches: row.active_dispatches,
            queued_dispatches: row.queued_dispatches,
            pool_max: row.pool_max,
            pool_utilization: row.pool_utilization,
            total_cost_usd: row.total_cost_usd,
            tasks_ready: row.tasks_ready,
            tasks_in_progress: row.tasks_in_progress,
            tasks_failed: row.tasks_failed,
            captured_at: row.captured_at,
        }
    }
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct AgentPerfView {
    pub provider: String,
    pub model: String,
    pub period_start: String,
    pub period_end: String,
    pub runs_total: i64,
    pub runs_success: i64,
    pub runs_failed: i64,
    pub avg_duration_seconds: Option<f64>,
    pub cost_usd: f64,
    pub p95_duration_seconds: Option<f64>,
}

impl From<AgentPerformanceRow> for AgentPerfView {
    fn from(row: AgentPerformanceRow) -> Self {
        Self {
            provider: row.provider,
            model: row.model,
            period_start: row.period_start,
            period_end: row.period_end,
            runs_total: row.runs_total,
            runs_success: row.runs_success,
            runs_failed: row.runs_failed,
            avg_duration_seconds: row.avg_duration_seconds,
            cost_usd: row.cost_usd,
            p95_duration_seconds: row.p95_duration_seconds,
        }
    }
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct MetricView {
    pub metric_name: String,
    pub metric_value: f64,
    pub tags: serde_json::Value,
    pub recorded_at: String,
}

impl From<TelemetryMetricRow> for MetricView {
    fn from(row: TelemetryMetricRow) -> Self {
        let tags = serde_json::from_str(&row.tags_json).unwrap_or(json!({}));
        Self {
            metric_name: row.metric_name,
            metric_value: row.metric_value,
            tags,
            recorded_at: row.recorded_at,
        }
    }
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct MetricsQueryInput {
    pub metric_name: Option<String>,
    pub limit: Option<i64>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct TelemetryPruneInput {
    pub before: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct FleetHistoryInput {
    pub limit: Option<i64>,
}

// ── Command functions ───────────────────────────────────────────────────────

pub async fn telemetry_fleet_snapshot(state: &AppState) -> Result<FleetSnapshotView, String> {
    let (db, project_id) = {
        let current = state.current.lock().await;
        let ctx = current
            .as_ref()
            .ok_or_else(|| "no open project".to_string())?;
        (ctx.db.clone(), ctx.project_id.to_string())
    };

    // Build snapshot from current state
    let sessions = db
        .list_sessions(&project_id)
        .await
        .map_err(|e| e.to_string())?;
    let tasks = db
        .list_tasks(&project_id)
        .await
        .map_err(|e| e.to_string())?;

    let active_sessions = sessions.iter().filter(|s| s.status == "running").count() as i64;
    let tasks_ready = tasks.iter().filter(|t| t.status == "ready").count() as i64;
    let tasks_in_progress = tasks.iter().filter(|t| t.status == "in_progress").count() as i64;
    let tasks_failed = tasks.iter().filter(|t| t.status == "failed").count() as i64;

    let now = chrono::Utc::now().to_rfc3339();
    let row = FleetSnapshotRow {
        id: Uuid::new_v4().to_string(),
        project_id: project_id.clone(),
        active_sessions,
        active_dispatches: 0,
        queued_dispatches: 0,
        pool_max: 0,
        pool_utilization: 0.0,
        total_cost_usd: 0.0,
        tasks_ready,
        tasks_in_progress,
        tasks_failed,
        captured_at: now,
    };

    db.capture_fleet_snapshot(&row)
        .await
        .map_err(|e| e.to_string())?;

    Ok(FleetSnapshotView::from(row))
}

pub async fn telemetry_fleet_history(
    input: FleetHistoryInput,
    state: &AppState,
) -> Result<Vec<FleetSnapshotView>, String> {
    let (db, project_id) = {
        let current = state.current.lock().await;
        let ctx = current
            .as_ref()
            .ok_or_else(|| "no open project".to_string())?;
        (ctx.db.clone(), ctx.project_id.to_string())
    };

    let limit = input.limit.unwrap_or(100);
    let rows = db
        .list_fleet_snapshots(&project_id, limit)
        .await
        .map_err(|e| e.to_string())?;

    Ok(rows.into_iter().map(FleetSnapshotView::from).collect())
}

pub async fn telemetry_agent_performance(state: &AppState) -> Result<Vec<AgentPerfView>, String> {
    let (db, project_id) = {
        let current = state.current.lock().await;
        let ctx = current
            .as_ref()
            .ok_or_else(|| "no open project".to_string())?;
        (ctx.db.clone(), ctx.project_id.to_string())
    };

    let rows = db
        .list_agent_performance(&project_id)
        .await
        .map_err(|e| e.to_string())?;

    Ok(rows.into_iter().map(AgentPerfView::from).collect())
}

pub async fn telemetry_metrics_query(
    input: MetricsQueryInput,
    state: &AppState,
) -> Result<Vec<MetricView>, String> {
    let (db, project_id) = {
        let current = state.current.lock().await;
        let ctx = current
            .as_ref()
            .ok_or_else(|| "no open project".to_string())?;
        (ctx.db.clone(), ctx.project_id.to_string())
    };

    let limit = input.limit.unwrap_or(100);
    let rows = db
        .query_telemetry_metrics(&project_id, input.metric_name.as_deref(), limit)
        .await
        .map_err(|e| e.to_string())?;

    Ok(rows.into_iter().map(MetricView::from).collect())
}

pub async fn telemetry_prune(
    input: TelemetryPruneInput,
    state: &AppState,
) -> Result<serde_json::Value, String> {
    let (db, project_id) = {
        let current = state.current.lock().await;
        let ctx = current
            .as_ref()
            .ok_or_else(|| "no open project".to_string())?;
        (ctx.db.clone(), ctx.project_id.to_string())
    };

    let deleted = db
        .prune_telemetry_metrics(&project_id, &input.before)
        .await
        .map_err(|e| e.to_string())?;

    Ok(json!({ "deleted": deleted }))
}
