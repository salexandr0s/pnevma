use serde::{Deserialize, Serialize};

/// A single telemetry metric data point.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct MetricPoint {
    pub metric_name: String,
    pub metric_value: f64,
    pub tags: serde_json::Value,
    pub recorded_at: String,
}

/// Snapshot of fleet utilization at a point in time.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct FleetSnapshot {
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

/// Aggregated agent performance for a given provider + model over a time period.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct AgentPerformanceSummary {
    pub provider: String,
    pub model: String,
    pub period_start: String,
    pub period_end: String,
    pub runs_total: i64,
    pub runs_success: i64,
    pub runs_failed: i64,
    pub avg_duration_seconds: Option<f64>,
    pub tokens_in: i64,
    pub tokens_out: i64,
    pub cost_usd: f64,
    pub p95_duration_seconds: Option<f64>,
}
