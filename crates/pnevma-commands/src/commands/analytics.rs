// Analytics commands — usage intelligence and error insights.

use super::*;
use chrono::{DateTime, Duration, NaiveDate, NaiveDateTime, NaiveTime, Utc};
use sqlx::FromRow;
use std::collections::{BTreeMap, HashMap, HashSet};

// ─── Legacy analytics contracts ─────────────────────────────────────────────

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct UsageBreakdownView {
    pub provider: String,
    pub tokens_in: i64,
    pub tokens_out: i64,
    pub estimated_usd: f64,
    pub record_count: i64,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct UsageByModelView {
    pub provider: String,
    pub model: String,
    pub tokens_in: i64,
    pub tokens_out: i64,
    pub estimated_usd: f64,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct UsageDailyTrendView {
    pub date: String,
    pub tokens_in: i64,
    pub tokens_out: i64,
    pub estimated_usd: f64,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ErrorSignatureView {
    pub id: String,
    pub signature_hash: String,
    pub canonical_message: String,
    pub category: String,
    pub first_seen: chrono::DateTime<chrono::Utc>,
    pub last_seen: chrono::DateTime<chrono::Utc>,
    pub total_count: i64,
    pub sample_output: Option<String>,
    pub remediation_hint: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ErrorTrendPoint {
    pub date: String,
    pub count: i64,
    pub signature_hash: String,
    pub category: String,
}

// ─── New usage intelligence contracts ───────────────────────────────────────

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum UsageAnalyticsScope {
    Project,
    Global,
}

impl UsageAnalyticsScope {
    fn from_param(scope: Option<String>) -> Self {
        match scope.as_deref() {
            Some("global") => Self::Global,
            _ => Self::Project,
        }
    }

    fn as_str(self) -> &'static str {
        match self {
            Self::Project => "project",
            Self::Global => "global",
        }
    }
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct UsageAnalyticsSummaryView {
    pub scope: String,
    pub from: String,
    pub to: String,
    pub totals: UsageTotalsView,
    pub daily_trend: Vec<UsageDailyTrendView>,
    pub top_providers: Vec<UsageBreakdownItemView>,
    pub top_models: Vec<UsageBreakdownItemView>,
    pub top_tasks: Vec<UsageTaskExplorerRowView>,
    pub activity: UsageActivityView,
    pub error_hotspots: Vec<ErrorSignatureView>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct UsageTotalsView {
    pub total_input_tokens: i64,
    pub total_output_tokens: i64,
    pub total_tokens: i64,
    pub total_cost_usd: f64,
    pub avg_daily_cost_usd: f64,
    pub avg_daily_tokens: i64,
    pub active_sessions: i64,
    pub tasks_with_spend: i64,
    pub error_hotspot_count: i64,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct UsageBreakdownItemView {
    pub key: String,
    pub label: String,
    pub secondary_label: Option<String>,
    pub total_tokens: i64,
    pub estimated_usd: f64,
    pub record_count: i64,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct UsageActivityView {
    pub weekdays: Vec<UsageActivityBucketView>,
    pub hours: Vec<UsageActivityBucketView>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct UsageActivityBucketView {
    pub index: i64,
    pub label: String,
    pub total_tokens: i64,
    pub estimated_usd: f64,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct UsageSessionExplorerRowView {
    pub project_name: String,
    pub session_id: String,
    pub session_name: String,
    pub session_status: String,
    pub branch: Option<String>,
    pub task_id: Option<String>,
    pub task_title: Option<String>,
    pub task_status: Option<String>,
    pub providers: Vec<String>,
    pub models: Vec<String>,
    pub total_input_tokens: i64,
    pub total_output_tokens: i64,
    pub total_tokens: i64,
    pub total_cost_usd: f64,
    pub started_at: DateTime<Utc>,
    pub last_heartbeat: DateTime<Utc>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct UsageTaskExplorerRowView {
    pub project_name: String,
    pub task_id: String,
    pub title: String,
    pub status: String,
    pub providers: Vec<String>,
    pub models: Vec<String>,
    pub session_count: i64,
    pub total_input_tokens: i64,
    pub total_output_tokens: i64,
    pub total_tokens: i64,
    pub total_cost_usd: f64,
    pub last_activity_at: Option<DateTime<Utc>>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct UsageDiagnosticsView {
    pub scope: String,
    pub from: String,
    pub to: String,
    pub project_names: Vec<String>,
    pub tracked_cost_rows: i64,
    pub untracked_cost_rows: i64,
    pub last_tracked_cost_at: Option<DateTime<Utc>>,
    pub local_provider_snapshots: Vec<crate::commands::usage_local::ProviderUsageSnapshot>,
}

#[derive(Debug, Clone)]
struct AnalyticsProjectContext {
    project_id: String,
    project_name: String,
    project_path: String,
    db: Db,
}

#[derive(Debug, Clone)]
struct UsageTimeRange {
    from: DateTime<Utc>,
    to: DateTime<Utc>,
    from_date: String,
    to_date: String,
    day_count: i64,
}

#[derive(Debug, Clone, FromRow)]
struct BreakdownAggregateRow {
    key: String,
    secondary_label: Option<String>,
    total_tokens: i64,
    estimated_usd: f64,
    record_count: i64,
}

#[derive(Debug, Clone, FromRow)]
struct UsageTotalsRow {
    total_input_tokens: i64,
    total_output_tokens: i64,
    total_cost_usd: f64,
    tasks_with_spend: i64,
}

#[derive(Debug, Clone, FromRow)]
struct UsageSessionExplorerRowDb {
    session_id: String,
    session_name: String,
    session_status: String,
    branch: Option<String>,
    task_id: Option<String>,
    task_title: Option<String>,
    task_status: Option<String>,
    providers_csv: Option<String>,
    models_csv: Option<String>,
    total_input_tokens: i64,
    total_output_tokens: i64,
    total_cost_usd: f64,
    started_at: DateTime<Utc>,
    last_heartbeat: DateTime<Utc>,
}

#[derive(Debug, Clone, FromRow)]
struct UsageTaskExplorerRowDb {
    task_id: String,
    title: String,
    status: String,
    providers_csv: Option<String>,
    models_csv: Option<String>,
    session_count: i64,
    total_input_tokens: i64,
    total_output_tokens: i64,
    total_cost_usd: f64,
    last_activity_at: Option<DateTime<Utc>>,
}

#[derive(Debug, Clone, FromRow)]
struct ActivityAggregateRow {
    bucket: i64,
    total_tokens: i64,
    estimated_usd: f64,
}

#[derive(Debug, Clone, FromRow)]
struct DailyTrendAggregateRow {
    period_date: String,
    tokens_in: i64,
    tokens_out: i64,
    estimated_usd: f64,
}

#[derive(Debug, Clone, FromRow)]
struct DiagnosticsAggregateRow {
    tracked_cost_rows: i64,
    untracked_cost_rows: i64,
    last_tracked_cost_at: Option<DateTime<Utc>>,
}

#[derive(Debug, Clone, FromRow)]
struct ErrorHotspotAggregateRow {
    id: String,
    signature_hash: String,
    canonical_message: String,
    category: String,
    first_seen: DateTime<Utc>,
    last_seen: DateTime<Utc>,
    total_count: i64,
    sample_output: Option<String>,
    remediation_hint: Option<String>,
}

fn parse_usage_boundary(input: &str, end_of_day: bool) -> Option<(DateTime<Utc>, NaiveDate)> {
    if let Ok(parsed) = DateTime::parse_from_rfc3339(input) {
        return Some((parsed.with_timezone(&Utc), parsed.date_naive()));
    }

    let date = NaiveDate::parse_from_str(input, "%Y-%m-%d").ok()?;
    let time = if end_of_day {
        NaiveTime::from_hms_milli_opt(23, 59, 59, 999)?
    } else {
        NaiveTime::from_hms_opt(0, 0, 0)?
    };
    Some((
        DateTime::<Utc>::from_naive_utc_and_offset(NaiveDateTime::new(date, time), Utc),
        date,
    ))
}

fn resolve_usage_time_range(
    from: Option<String>,
    to: Option<String>,
) -> Result<UsageTimeRange, String> {
    let default_to = Utc::now();
    let default_from = default_to - Duration::days(29);
    let (mut from_dt, mut from_day) = from
        .as_deref()
        .and_then(|value| parse_usage_boundary(value, false))
        .unwrap_or((default_from, default_from.date_naive()));
    let (mut to_dt, mut to_day) = to
        .as_deref()
        .and_then(|value| parse_usage_boundary(value, true))
        .unwrap_or((default_to, default_to.date_naive()));

    if from_dt > to_dt {
        std::mem::swap(&mut from_dt, &mut to_dt);
        std::mem::swap(&mut from_day, &mut to_day);
    }

    let from_date = from_day.format("%Y-%m-%d").to_string();
    let to_date = to_day.format("%Y-%m-%d").to_string();
    let day_count = (to_day - from_day).num_days() + 1;

    Ok(UsageTimeRange {
        from: from_dt,
        to: to_dt,
        from_date,
        to_date,
        day_count: day_count.max(1),
    })
}

fn fallback_project_name(path: &str) -> String {
    Path::new(path)
        .file_name()
        .and_then(|name| name.to_str())
        .filter(|name| !name.is_empty())
        .unwrap_or("Project")
        .to_string()
}

async fn current_analytics_context(
    state: &AppState,
) -> Result<Option<AnalyticsProjectContext>, String> {
    let current = {
        let current = state.current.lock().await;
        current.as_ref().map(|ctx| {
            (
                ctx.project_id.to_string(),
                ctx.project_path.to_string_lossy().to_string(),
                ctx.db.clone(),
            )
        })
    };

    let Some((project_id, project_path, db)) = current else {
        return Ok(None);
    };

    let project_name = db
        .find_project_by_path(&project_path)
        .await
        .map_err(|e| e.to_string())?
        .map(|project| project.name)
        .unwrap_or_else(|| fallback_project_name(&project_path));

    Ok(Some(AnalyticsProjectContext {
        project_id,
        project_name,
        project_path,
        db,
    }))
}

async fn analytics_contexts_global(
    state: &AppState,
) -> Result<Vec<AnalyticsProjectContext>, String> {
    let mut contexts = Vec::new();
    let mut seen_paths = HashSet::new();

    if let Some(current) = current_analytics_context(state).await? {
        seen_paths.insert(current.project_path.clone());
        contexts.push(current);
    }

    let Some(global_db) = state.global_db.as_ref() else {
        return Ok(contexts);
    };

    for trusted in global_db
        .list_trusted_paths()
        .await
        .map_err(|e| e.to_string())?
    {
        if !seen_paths.insert(trusted.path.clone()) {
            continue;
        }

        let path = PathBuf::from(&trusted.path);
        if !path.exists() {
            continue;
        }

        let db = match Db::open(&path).await {
            Ok(db) => db,
            Err(_) => continue,
        };
        let Some(project) = db
            .find_project_by_path(&trusted.path)
            .await
            .map_err(|e| e.to_string())?
        else {
            continue;
        };

        contexts.push(AnalyticsProjectContext {
            project_id: project.id,
            project_name: project.name,
            project_path: trusted.path,
            db,
        });
    }

    Ok(contexts)
}

async fn analytics_contexts_for_scope(
    scope: UsageAnalyticsScope,
    state: &AppState,
) -> Result<Vec<AnalyticsProjectContext>, String> {
    match scope {
        UsageAnalyticsScope::Project => current_analytics_context(state)
            .await?
            .map(|ctx| vec![ctx])
            .ok_or_else(|| "no open project".to_string()),
        UsageAnalyticsScope::Global => {
            let contexts = analytics_contexts_global(state).await?;
            if contexts.is_empty() {
                Err("no projects available".to_string())
            } else {
                Ok(contexts)
            }
        }
    }
}

async fn analytics_contexts_legacy(
    state: &AppState,
) -> Result<Vec<AnalyticsProjectContext>, String> {
    if let Some(current) = current_analytics_context(state).await? {
        return Ok(vec![current]);
    }

    let contexts = analytics_contexts_global(state).await?;
    if contexts.is_empty() {
        Err("no projects available".to_string())
    } else {
        Ok(contexts)
    }
}

fn csv_labels(raw: Option<String>) -> Vec<String> {
    let mut seen = HashSet::new();
    raw.unwrap_or_default()
        .split(',')
        .map(str::trim)
        .filter(|value| !value.is_empty())
        .filter_map(|value| {
            let owned = value.to_string();
            if seen.insert(owned.clone()) {
                Some(owned)
            } else {
                None
            }
        })
        .collect()
}

fn make_breakdown_item(row: BreakdownAggregateRow) -> UsageBreakdownItemView {
    UsageBreakdownItemView {
        key: row.key.clone(),
        label: row.key,
        secondary_label: row.secondary_label,
        total_tokens: row.total_tokens,
        estimated_usd: row.estimated_usd,
        record_count: row.record_count,
    }
}

fn weekday_label(index: i64) -> &'static str {
    match index {
        0 => "Mon",
        1 => "Tue",
        2 => "Wed",
        3 => "Thu",
        4 => "Fri",
        5 => "Sat",
        _ => "Sun",
    }
}

async fn query_usage_totals(
    ctx: &AnalyticsProjectContext,
    range: &UsageTimeRange,
) -> Result<UsageTotalsRow, String> {
    sqlx::query_as::<_, UsageTotalsRow>(
        r#"
        SELECT
            COALESCE(SUM(c.tokens_in), 0) AS total_input_tokens,
            COALESCE(SUM(c.tokens_out), 0) AS total_output_tokens,
            COALESCE(SUM(c.estimated_usd), 0.0) AS total_cost_usd,
            COUNT(DISTINCT c.task_id) AS tasks_with_spend
        FROM costs c
        JOIN tasks t ON t.id = c.task_id
        WHERE t.project_id = ?1
          AND datetime(c.timestamp) >= datetime(?2)
          AND datetime(c.timestamp) <= datetime(?3)
        "#,
    )
    .bind(&ctx.project_id)
    .bind(range.from.to_rfc3339())
    .bind(range.to.to_rfc3339())
    .fetch_one(ctx.db.pool())
    .await
    .map_err(|e| e.to_string())
}

async fn query_active_sessions(ctx: &AnalyticsProjectContext) -> Result<i64, String> {
    sqlx::query_scalar::<_, i64>(
        r#"
        SELECT COUNT(*)
        FROM sessions
        WHERE project_id = ?1
          AND status = 'running'
        "#,
    )
    .bind(&ctx.project_id)
    .fetch_one(ctx.db.pool())
    .await
    .map_err(|e| e.to_string())
}

async fn query_error_signature_count(
    ctx: &AnalyticsProjectContext,
    range: Option<&UsageTimeRange>,
) -> Result<i64, String> {
    match range {
        Some(range) => sqlx::query_scalar::<_, i64>(
            r#"
                SELECT COUNT(DISTINCT es.id)
                FROM error_signatures es
                JOIN error_signature_daily esd ON esd.signature_id = es.id
                WHERE es.project_id = ?1
                  AND esd.date >= ?2
                  AND esd.date <= ?3
                "#,
        )
        .bind(&ctx.project_id)
        .bind(&range.from_date)
        .bind(&range.to_date)
        .fetch_one(ctx.db.pool())
        .await
        .map_err(|e| e.to_string()),
        None => sqlx::query_scalar::<_, i64>(
            r#"
                SELECT COUNT(*)
                FROM error_signatures
                WHERE project_id = ?1
                "#,
        )
        .bind(&ctx.project_id)
        .fetch_one(ctx.db.pool())
        .await
        .map_err(|e| e.to_string()),
    }
}

async fn query_error_hotspots(
    ctx: &AnalyticsProjectContext,
    range: &UsageTimeRange,
) -> Result<Vec<ErrorSignatureView>, String> {
    let rows = sqlx::query_as::<_, ErrorHotspotAggregateRow>(
        r#"
        SELECT
            es.id AS id,
            es.signature_hash AS signature_hash,
            es.canonical_message AS canonical_message,
            es.category AS category,
            es.first_seen AS first_seen,
            es.last_seen AS last_seen,
            COALESCE(SUM(esd.count), 0) AS total_count,
            es.sample_output AS sample_output,
            es.remediation_hint AS remediation_hint
        FROM error_signatures es
        JOIN error_signature_daily esd ON esd.signature_id = es.id
        WHERE es.project_id = ?1
          AND esd.date >= ?2
          AND esd.date <= ?3
        GROUP BY
            es.id,
            es.signature_hash,
            es.canonical_message,
            es.category,
            es.first_seen,
            es.last_seen,
            es.sample_output,
            es.remediation_hint
        ORDER BY total_count DESC, es.last_seen DESC
        "#,
    )
    .bind(&ctx.project_id)
    .bind(&range.from_date)
    .bind(&range.to_date)
    .fetch_all(ctx.db.pool())
    .await
    .map_err(|e| e.to_string())?;

    Ok(rows
        .into_iter()
        .map(|row| ErrorSignatureView {
            id: row.id,
            signature_hash: row.signature_hash,
            canonical_message: row.canonical_message,
            category: row.category,
            first_seen: row.first_seen,
            last_seen: row.last_seen,
            total_count: row.total_count,
            sample_output: row.sample_output,
            remediation_hint: row.remediation_hint,
        })
        .collect())
}

async fn query_provider_breakdown(
    ctx: &AnalyticsProjectContext,
    range: &UsageTimeRange,
) -> Result<Vec<UsageBreakdownItemView>, String> {
    let rows = sqlx::query_as::<_, BreakdownAggregateRow>(
        r#"
        SELECT
            provider AS key,
            NULL AS secondary_label,
            COALESCE(SUM(tokens_in + tokens_out), 0) AS total_tokens,
            COALESCE(SUM(estimated_usd), 0.0) AS estimated_usd,
            COALESCE(SUM(record_count), 0) AS record_count
        FROM cost_daily_aggregates
        WHERE project_id = ?1
          AND period_date >= ?2
          AND period_date <= ?3
        GROUP BY provider
        ORDER BY estimated_usd DESC, key ASC
        "#,
    )
    .bind(&ctx.project_id)
    .bind(&range.from_date)
    .bind(&range.to_date)
    .fetch_all(ctx.db.pool())
    .await
    .map_err(|e| e.to_string())?;

    Ok(rows.into_iter().map(make_breakdown_item).collect())
}

async fn query_model_breakdown(
    ctx: &AnalyticsProjectContext,
    range: &UsageTimeRange,
) -> Result<Vec<UsageBreakdownItemView>, String> {
    let rows = sqlx::query_as::<_, BreakdownAggregateRow>(
        r#"
        SELECT
            CASE WHEN model = '' THEN 'unknown' ELSE model END AS key,
            provider AS secondary_label,
            COALESCE(SUM(tokens_in + tokens_out), 0) AS total_tokens,
            COALESCE(SUM(estimated_usd), 0.0) AS estimated_usd,
            COALESCE(SUM(record_count), 0) AS record_count
        FROM cost_daily_aggregates
        WHERE project_id = ?1
          AND period_date >= ?2
          AND period_date <= ?3
        GROUP BY provider, model
        ORDER BY estimated_usd DESC, key ASC
        "#,
    )
    .bind(&ctx.project_id)
    .bind(&range.from_date)
    .bind(&range.to_date)
    .fetch_all(ctx.db.pool())
    .await
    .map_err(|e| e.to_string())?;

    Ok(rows.into_iter().map(make_breakdown_item).collect())
}

async fn query_daily_trend(
    ctx: &AnalyticsProjectContext,
    range: &UsageTimeRange,
) -> Result<Vec<UsageDailyTrendView>, String> {
    let rows = sqlx::query_as::<_, DailyTrendAggregateRow>(
        r#"
        SELECT
            period_date,
            COALESCE(SUM(tokens_in), 0) AS tokens_in,
            COALESCE(SUM(tokens_out), 0) AS tokens_out,
            COALESCE(SUM(estimated_usd), 0.0) AS estimated_usd
        FROM cost_daily_aggregates
        WHERE project_id = ?1
          AND period_date >= ?2
          AND period_date <= ?3
        GROUP BY period_date
        ORDER BY period_date ASC
        "#,
    )
    .bind(&ctx.project_id)
    .bind(&range.from_date)
    .bind(&range.to_date)
    .fetch_all(ctx.db.pool())
    .await
    .map_err(|e| e.to_string())?;

    Ok(rows
        .into_iter()
        .map(|row| UsageDailyTrendView {
            date: row.period_date,
            tokens_in: row.tokens_in,
            tokens_out: row.tokens_out,
            estimated_usd: row.estimated_usd,
        })
        .collect())
}

async fn query_usage_activity(
    ctx: &AnalyticsProjectContext,
    range: &UsageTimeRange,
) -> Result<UsageActivityView, String> {
    let weekday_rows = sqlx::query_as::<_, ActivityAggregateRow>(
        r#"
        SELECT
            ((CAST(strftime('%w', period_start) AS INTEGER) + 6) % 7) AS bucket,
            COALESCE(SUM(tokens_in + tokens_out), 0) AS total_tokens,
            COALESCE(SUM(estimated_usd), 0.0) AS estimated_usd
        FROM cost_hourly_aggregates
        WHERE project_id = ?1
          AND datetime(period_start) >= datetime(?2)
          AND datetime(period_start) <= datetime(?3)
        GROUP BY bucket
        ORDER BY bucket ASC
        "#,
    )
    .bind(&ctx.project_id)
    .bind(range.from.to_rfc3339())
    .bind(range.to.to_rfc3339())
    .fetch_all(ctx.db.pool())
    .await
    .map_err(|e| e.to_string())?;

    let hour_rows = sqlx::query_as::<_, ActivityAggregateRow>(
        r#"
        SELECT
            CAST(strftime('%H', period_start) AS INTEGER) AS bucket,
            COALESCE(SUM(tokens_in + tokens_out), 0) AS total_tokens,
            COALESCE(SUM(estimated_usd), 0.0) AS estimated_usd
        FROM cost_hourly_aggregates
        WHERE project_id = ?1
          AND datetime(period_start) >= datetime(?2)
          AND datetime(period_start) <= datetime(?3)
        GROUP BY bucket
        ORDER BY bucket ASC
        "#,
    )
    .bind(&ctx.project_id)
    .bind(range.from.to_rfc3339())
    .bind(range.to.to_rfc3339())
    .fetch_all(ctx.db.pool())
    .await
    .map_err(|e| e.to_string())?;

    let mut weekday_map = HashMap::new();
    for row in weekday_rows {
        weekday_map.insert(row.bucket, row);
    }

    let mut hour_map = HashMap::new();
    for row in hour_rows {
        hour_map.insert(row.bucket, row);
    }

    let weekdays = (0..7)
        .map(|index| {
            let row = weekday_map.remove(&index);
            UsageActivityBucketView {
                index,
                label: weekday_label(index).to_string(),
                total_tokens: row.as_ref().map(|value| value.total_tokens).unwrap_or(0),
                estimated_usd: row.as_ref().map(|value| value.estimated_usd).unwrap_or(0.0),
            }
        })
        .collect();

    let hours = (0..24)
        .map(|index| {
            let row = hour_map.remove(&index);
            UsageActivityBucketView {
                index,
                label: format!("{index:02}:00"),
                total_tokens: row.as_ref().map(|value| value.total_tokens).unwrap_or(0),
                estimated_usd: row.as_ref().map(|value| value.estimated_usd).unwrap_or(0.0),
            }
        })
        .collect();

    Ok(UsageActivityView { weekdays, hours })
}

async fn query_task_rows(
    ctx: &AnalyticsProjectContext,
    range: &UsageTimeRange,
) -> Result<Vec<UsageTaskExplorerRowView>, String> {
    let rows = sqlx::query_as::<_, UsageTaskExplorerRowDb>(
        r#"
        SELECT
            t.id AS task_id,
            t.title AS title,
            t.status AS status,
            GROUP_CONCAT(DISTINCT c.provider) AS providers_csv,
            GROUP_CONCAT(DISTINCT COALESCE(c.model, '')) AS models_csv,
            COUNT(DISTINCT c.session_id) AS session_count,
            COALESCE(SUM(c.tokens_in), 0) AS total_input_tokens,
            COALESCE(SUM(c.tokens_out), 0) AS total_output_tokens,
            COALESCE(SUM(c.estimated_usd), 0.0) AS total_cost_usd,
            MAX(c.timestamp) AS last_activity_at
        FROM tasks t
        JOIN costs c ON c.task_id = t.id
        WHERE t.project_id = ?1
          AND datetime(c.timestamp) >= datetime(?2)
          AND datetime(c.timestamp) <= datetime(?3)
        GROUP BY t.id, t.title, t.status
        ORDER BY total_cost_usd DESC, title ASC
        "#,
    )
    .bind(&ctx.project_id)
    .bind(range.from.to_rfc3339())
    .bind(range.to.to_rfc3339())
    .fetch_all(ctx.db.pool())
    .await
    .map_err(|e| e.to_string())?;

    Ok(rows
        .into_iter()
        .map(|row| UsageTaskExplorerRowView {
            project_name: ctx.project_name.clone(),
            task_id: row.task_id,
            title: row.title,
            status: row.status,
            providers: csv_labels(row.providers_csv),
            models: csv_labels(row.models_csv),
            session_count: row.session_count,
            total_input_tokens: row.total_input_tokens,
            total_output_tokens: row.total_output_tokens,
            total_tokens: row.total_input_tokens + row.total_output_tokens,
            total_cost_usd: row.total_cost_usd,
            last_activity_at: row.last_activity_at,
        })
        .collect())
}

async fn query_session_rows(
    ctx: &AnalyticsProjectContext,
    range: &UsageTimeRange,
) -> Result<Vec<UsageSessionExplorerRowView>, String> {
    let rows = sqlx::query_as::<_, UsageSessionExplorerRowDb>(
        r#"
        SELECT
            s.id AS session_id,
            s.name AS session_name,
            s.status AS session_status,
            s.branch AS branch,
            MAX(t.id) AS task_id,
            MAX(t.title) AS task_title,
            MAX(t.status) AS task_status,
            GROUP_CONCAT(DISTINCT c.provider) AS providers_csv,
            GROUP_CONCAT(DISTINCT COALESCE(c.model, '')) AS models_csv,
            COALESCE(SUM(c.tokens_in), 0) AS total_input_tokens,
            COALESCE(SUM(c.tokens_out), 0) AS total_output_tokens,
            COALESCE(SUM(c.estimated_usd), 0.0) AS total_cost_usd,
            s.started_at AS started_at,
            s.last_heartbeat AS last_heartbeat
        FROM sessions s
        JOIN costs c ON c.session_id = s.id
        JOIN tasks t ON t.id = c.task_id
        WHERE s.project_id = ?1
          AND datetime(c.timestamp) >= datetime(?2)
          AND datetime(c.timestamp) <= datetime(?3)
        GROUP BY s.id, s.name, s.status, s.branch, s.started_at, s.last_heartbeat
        ORDER BY total_cost_usd DESC, s.started_at DESC
        "#,
    )
    .bind(&ctx.project_id)
    .bind(range.from.to_rfc3339())
    .bind(range.to.to_rfc3339())
    .fetch_all(ctx.db.pool())
    .await
    .map_err(|e| e.to_string())?;

    Ok(rows
        .into_iter()
        .map(|row| UsageSessionExplorerRowView {
            project_name: ctx.project_name.clone(),
            session_id: row.session_id,
            session_name: row.session_name,
            session_status: row.session_status,
            branch: row.branch,
            task_id: row.task_id,
            task_title: row.task_title,
            task_status: row.task_status,
            providers: csv_labels(row.providers_csv),
            models: csv_labels(row.models_csv),
            total_input_tokens: row.total_input_tokens,
            total_output_tokens: row.total_output_tokens,
            total_tokens: row.total_input_tokens + row.total_output_tokens,
            total_cost_usd: row.total_cost_usd,
            started_at: row.started_at,
            last_heartbeat: row.last_heartbeat,
        })
        .collect())
}

async fn query_diagnostics(
    ctx: &AnalyticsProjectContext,
    range: &UsageTimeRange,
) -> Result<DiagnosticsAggregateRow, String> {
    sqlx::query_as::<_, DiagnosticsAggregateRow>(
        r#"
        SELECT
            COALESCE(SUM(CASE WHEN c.tracked THEN 1 ELSE 0 END), 0) AS tracked_cost_rows,
            COALESCE(SUM(CASE WHEN c.tracked THEN 0 ELSE 1 END), 0) AS untracked_cost_rows,
            MAX(CASE WHEN c.tracked THEN c.timestamp ELSE NULL END) AS last_tracked_cost_at
        FROM costs c
        JOIN tasks t ON t.id = c.task_id
        WHERE t.project_id = ?1
          AND datetime(c.timestamp) >= datetime(?2)
          AND datetime(c.timestamp) <= datetime(?3)
        "#,
    )
    .bind(&ctx.project_id)
    .bind(range.from.to_rfc3339())
    .bind(range.to.to_rfc3339())
    .fetch_one(ctx.db.pool())
    .await
    .map_err(|e| e.to_string())
}

fn merge_breakdowns(
    items: Vec<UsageBreakdownItemView>,
    key_fn: impl Fn(&UsageBreakdownItemView) -> String,
) -> Vec<UsageBreakdownItemView> {
    let mut merged: BTreeMap<String, UsageBreakdownItemView> = BTreeMap::new();
    for item in items {
        let key = key_fn(&item);
        let entry = merged.entry(key).or_insert(UsageBreakdownItemView {
            key: item.key.clone(),
            label: item.label.clone(),
            secondary_label: item.secondary_label.clone(),
            total_tokens: 0,
            estimated_usd: 0.0,
            record_count: 0,
        });
        entry.total_tokens += item.total_tokens;
        entry.estimated_usd += item.estimated_usd;
        entry.record_count += item.record_count;
        if entry.secondary_label.is_none() {
            entry.secondary_label = item.secondary_label.clone();
        }
    }

    let mut values: Vec<_> = merged.into_values().collect();
    values.sort_by(|left, right| {
        right
            .estimated_usd
            .partial_cmp(&left.estimated_usd)
            .unwrap_or(std::cmp::Ordering::Equal)
            .then_with(|| left.label.cmp(&right.label))
    });
    values
}

fn merge_daily_trend(items: Vec<UsageDailyTrendView>) -> Vec<UsageDailyTrendView> {
    let mut merged: BTreeMap<String, UsageDailyTrendView> = BTreeMap::new();
    for item in items {
        let entry = merged
            .entry(item.date.clone())
            .or_insert(UsageDailyTrendView {
                date: item.date.clone(),
                tokens_in: 0,
                tokens_out: 0,
                estimated_usd: 0.0,
            });
        entry.tokens_in += item.tokens_in;
        entry.tokens_out += item.tokens_out;
        entry.estimated_usd += item.estimated_usd;
    }
    merged.into_values().collect()
}

fn merge_activity(items: Vec<UsageActivityView>) -> UsageActivityView {
    let mut weekday_map: BTreeMap<i64, UsageActivityBucketView> = BTreeMap::new();
    let mut hour_map: BTreeMap<i64, UsageActivityBucketView> = BTreeMap::new();

    for item in items {
        for bucket in item.weekdays {
            let entry = weekday_map
                .entry(bucket.index)
                .or_insert(UsageActivityBucketView {
                    index: bucket.index,
                    label: bucket.label.clone(),
                    total_tokens: 0,
                    estimated_usd: 0.0,
                });
            entry.total_tokens += bucket.total_tokens;
            entry.estimated_usd += bucket.estimated_usd;
        }
        for bucket in item.hours {
            let entry = hour_map
                .entry(bucket.index)
                .or_insert(UsageActivityBucketView {
                    index: bucket.index,
                    label: bucket.label.clone(),
                    total_tokens: 0,
                    estimated_usd: 0.0,
                });
            entry.total_tokens += bucket.total_tokens;
            entry.estimated_usd += bucket.estimated_usd;
        }
    }

    UsageActivityView {
        weekdays: weekday_map.into_values().collect(),
        hours: hour_map.into_values().collect(),
    }
}

async fn aggregate_error_hotspots(
    contexts: &[AnalyticsProjectContext],
    range: Option<&UsageTimeRange>,
    limit: i64,
) -> Result<(i64, Vec<ErrorSignatureView>), String> {
    let mut aggregate: HashMap<String, ErrorSignatureView> = HashMap::new();

    for ctx in contexts {
        let rows = match range {
            Some(range) => query_error_hotspots(ctx, range).await?,
            None => ctx
                .db
                .list_error_signatures(&ctx.project_id, limit)
                .await
                .map_err(|e| e.to_string())?
                .into_iter()
                .map(|row| ErrorSignatureView {
                    id: row.id,
                    signature_hash: row.signature_hash,
                    canonical_message: row.canonical_message,
                    category: row.category,
                    first_seen: row.first_seen,
                    last_seen: row.last_seen,
                    total_count: row.total_count,
                    sample_output: row.sample_output,
                    remediation_hint: row.remediation_hint,
                })
                .collect(),
        };
        for row in rows {
            let entry = aggregate
                .entry(row.signature_hash.clone())
                .or_insert(ErrorSignatureView {
                    id: row.id.clone(),
                    signature_hash: row.signature_hash.clone(),
                    canonical_message: row.canonical_message.clone(),
                    category: row.category.clone(),
                    first_seen: row.first_seen,
                    last_seen: row.last_seen,
                    total_count: 0,
                    sample_output: row.sample_output.clone(),
                    remediation_hint: row.remediation_hint.clone(),
                });
            entry.total_count += row.total_count;
            if row.first_seen < entry.first_seen {
                entry.first_seen = row.first_seen;
            }
            if row.last_seen > entry.last_seen {
                entry.last_seen = row.last_seen;
            }
            if entry.sample_output.is_none() {
                entry.sample_output = row.sample_output.clone();
            }
            if entry.remediation_hint.is_none() {
                entry.remediation_hint = row.remediation_hint.clone();
            }
        }
    }

    let mut values: Vec<_> = aggregate.into_values().collect();
    values.sort_by(|left, right| right.total_count.cmp(&left.total_count));
    let total_count = if range.is_some() {
        values.len() as i64
    } else {
        let mut total = 0;
        for ctx in contexts {
            total += query_error_signature_count(ctx, None).await?;
        }
        total
    };
    values.truncate(limit.max(1) as usize);
    Ok((total_count, values))
}

// ─── Legacy analytics commands ──────────────────────────────────────────────

pub async fn get_usage_breakdown(
    days: Option<i64>,
    state: &AppState,
) -> Result<Vec<UsageBreakdownView>, String> {
    let days = days.unwrap_or(30);
    let contexts = analytics_contexts_legacy(state).await?;
    let mut aggregate: BTreeMap<String, UsageBreakdownView> = BTreeMap::new();

    for ctx in contexts {
        let rows = ctx
            .db
            .get_usage_breakdown(&ctx.project_id, days)
            .await
            .map_err(|e| e.to_string())?;
        for row in rows {
            let entry = aggregate
                .entry(row.provider.clone())
                .or_insert(UsageBreakdownView {
                    provider: row.provider.clone(),
                    tokens_in: 0,
                    tokens_out: 0,
                    estimated_usd: 0.0,
                    record_count: 0,
                });
            entry.tokens_in += row.tokens_in;
            entry.tokens_out += row.tokens_out;
            entry.estimated_usd += row.estimated_usd;
            entry.record_count += row.record_count;
        }
    }

    Ok(aggregate.into_values().collect())
}

pub async fn get_usage_by_model(state: &AppState) -> Result<Vec<UsageByModelView>, String> {
    let contexts = analytics_contexts_legacy(state).await?;
    let mut aggregate: BTreeMap<(String, String), UsageByModelView> = BTreeMap::new();

    for ctx in contexts {
        let rows = ctx
            .db
            .get_usage_by_model(&ctx.project_id)
            .await
            .map_err(|e| e.to_string())?;
        for row in rows {
            let key = (row.provider.clone(), row.model.clone());
            let entry = aggregate.entry(key).or_insert(UsageByModelView {
                provider: row.provider.clone(),
                model: row.model.clone(),
                tokens_in: 0,
                tokens_out: 0,
                estimated_usd: 0.0,
            });
            entry.tokens_in += row.tokens_in;
            entry.tokens_out += row.tokens_out;
            entry.estimated_usd += row.estimated_usd;
        }
    }

    Ok(aggregate.into_values().collect())
}

pub async fn get_usage_daily_trend(
    days: Option<i64>,
    state: &AppState,
) -> Result<Vec<UsageDailyTrendView>, String> {
    let days = days.unwrap_or(30);
    let contexts = analytics_contexts_legacy(state).await?;
    let mut aggregate: BTreeMap<String, UsageDailyTrendView> = BTreeMap::new();

    for ctx in contexts {
        let rows = ctx
            .db
            .get_usage_daily_trend(&ctx.project_id, days)
            .await
            .map_err(|e| e.to_string())?;
        for row in rows {
            let entry = aggregate
                .entry(row.period_date.clone())
                .or_insert(UsageDailyTrendView {
                    date: row.period_date.clone(),
                    tokens_in: 0,
                    tokens_out: 0,
                    estimated_usd: 0.0,
                });
            entry.tokens_in += row.tokens_in;
            entry.tokens_out += row.tokens_out;
            entry.estimated_usd += row.estimated_usd;
        }
    }

    Ok(aggregate.into_values().collect())
}

pub async fn list_error_signatures(
    limit: Option<i64>,
    state: &AppState,
) -> Result<Vec<ErrorSignatureView>, String> {
    let limit = limit.unwrap_or(50);
    let contexts = analytics_contexts_legacy(state).await?;
    let (_, hotspots) = aggregate_error_hotspots(&contexts, None, limit).await?;
    Ok(hotspots)
}

pub async fn get_error_signature(
    id: String,
    state: &AppState,
) -> Result<Option<ErrorSignatureView>, String> {
    let db = {
        let current = state.current.lock().await;
        let ctx = current
            .as_ref()
            .ok_or_else(|| "no open project".to_string())?;
        ctx.db.clone()
    };

    let row = db
        .get_error_signature(&id)
        .await
        .map_err(|e| e.to_string())?;

    Ok(row.map(|r| ErrorSignatureView {
        id: r.id,
        signature_hash: r.signature_hash,
        canonical_message: r.canonical_message,
        category: r.category,
        first_seen: r.first_seen,
        last_seen: r.last_seen,
        total_count: r.total_count,
        sample_output: r.sample_output,
        remediation_hint: r.remediation_hint,
    }))
}

pub async fn get_error_trend(
    days: Option<i64>,
    state: &AppState,
) -> Result<Vec<ErrorTrendPoint>, String> {
    let (project_id, db) = {
        let current = state.current.lock().await;
        let ctx = current
            .as_ref()
            .ok_or_else(|| "no open project".to_string())?;
        (ctx.project_id.to_string(), ctx.db.clone())
    };

    let rows = db
        .get_error_trend(&project_id, days.unwrap_or(30))
        .await
        .map_err(|e| e.to_string())?;

    Ok(rows
        .into_iter()
        .map(|r| ErrorTrendPoint {
            date: r.date,
            count: r.count,
            signature_hash: r.signature_hash.unwrap_or_default(),
            category: r.category.unwrap_or_default(),
        })
        .collect())
}

// ─── Usage intelligence commands ────────────────────────────────────────────

pub async fn get_usage_summary(
    scope: Option<String>,
    from: Option<String>,
    to: Option<String>,
    state: &AppState,
) -> Result<UsageAnalyticsSummaryView, String> {
    let scope = UsageAnalyticsScope::from_param(scope);
    let range = resolve_usage_time_range(from, to)?;
    let contexts = analytics_contexts_for_scope(scope, state).await?;

    let mut total_input_tokens = 0;
    let mut total_output_tokens = 0;
    let mut total_cost_usd = 0.0;
    let mut active_sessions = 0;
    let mut tasks_with_spend = 0;
    let mut provider_items = Vec::new();
    let mut model_items = Vec::new();
    let mut trend_items = Vec::new();
    let mut task_items = Vec::new();
    let mut activity_items = Vec::new();

    for ctx in &contexts {
        let totals = query_usage_totals(ctx, &range).await?;
        total_input_tokens += totals.total_input_tokens;
        total_output_tokens += totals.total_output_tokens;
        total_cost_usd += totals.total_cost_usd;
        tasks_with_spend += totals.tasks_with_spend;
        active_sessions += query_active_sessions(ctx).await?;

        provider_items.extend(query_provider_breakdown(ctx, &range).await?);
        model_items.extend(query_model_breakdown(ctx, &range).await?);
        trend_items.extend(query_daily_trend(ctx, &range).await?);
        task_items.extend(query_task_rows(ctx, &range).await?);
        activity_items.push(query_usage_activity(ctx, &range).await?);
    }

    let (error_hotspot_count, error_hotspots) =
        aggregate_error_hotspots(&contexts, Some(&range), 5).await?;

    let mut top_tasks = task_items;
    top_tasks.sort_by(|left, right| {
        right
            .total_cost_usd
            .partial_cmp(&left.total_cost_usd)
            .unwrap_or(std::cmp::Ordering::Equal)
            .then_with(|| left.title.cmp(&right.title))
    });
    top_tasks.truncate(5);

    let total_tokens = total_input_tokens + total_output_tokens;

    Ok(UsageAnalyticsSummaryView {
        scope: scope.as_str().to_string(),
        from: range.from_date.clone(),
        to: range.to_date.clone(),
        totals: UsageTotalsView {
            total_input_tokens,
            total_output_tokens,
            total_tokens,
            total_cost_usd,
            avg_daily_cost_usd: total_cost_usd / range.day_count as f64,
            avg_daily_tokens: total_tokens / range.day_count as i64,
            active_sessions,
            tasks_with_spend,
            error_hotspot_count,
        },
        daily_trend: merge_daily_trend(trend_items),
        top_providers: merge_breakdowns(provider_items, |item| item.key.clone())
            .into_iter()
            .take(6)
            .collect(),
        top_models: merge_breakdowns(model_items, |item| {
            format!(
                "{}::{}",
                item.secondary_label.clone().unwrap_or_default(),
                item.key
            )
        })
        .into_iter()
        .take(6)
        .collect(),
        top_tasks,
        activity: merge_activity(activity_items),
        error_hotspots,
    })
}

pub async fn get_usage_sessions(
    scope: Option<String>,
    from: Option<String>,
    to: Option<String>,
    state: &AppState,
) -> Result<Vec<UsageSessionExplorerRowView>, String> {
    let scope = UsageAnalyticsScope::from_param(scope);
    let range = resolve_usage_time_range(from, to)?;
    let contexts = analytics_contexts_for_scope(scope, state).await?;

    let mut rows = Vec::new();
    for ctx in &contexts {
        rows.extend(query_session_rows(ctx, &range).await?);
    }

    rows.sort_by(|left, right| {
        right
            .total_cost_usd
            .partial_cmp(&left.total_cost_usd)
            .unwrap_or(std::cmp::Ordering::Equal)
            .then_with(|| right.started_at.cmp(&left.started_at))
    });
    Ok(rows)
}

pub async fn get_usage_tasks(
    scope: Option<String>,
    from: Option<String>,
    to: Option<String>,
    state: &AppState,
) -> Result<Vec<UsageTaskExplorerRowView>, String> {
    let scope = UsageAnalyticsScope::from_param(scope);
    let range = resolve_usage_time_range(from, to)?;
    let contexts = analytics_contexts_for_scope(scope, state).await?;

    let mut rows = Vec::new();
    for ctx in &contexts {
        rows.extend(query_task_rows(ctx, &range).await?);
    }

    rows.sort_by(|left, right| {
        right
            .total_cost_usd
            .partial_cmp(&left.total_cost_usd)
            .unwrap_or(std::cmp::Ordering::Equal)
            .then_with(|| left.title.cmp(&right.title))
    });
    Ok(rows)
}

pub async fn get_usage_diagnostics(
    scope: Option<String>,
    from: Option<String>,
    to: Option<String>,
    state: &AppState,
) -> Result<UsageDiagnosticsView, String> {
    let scope = UsageAnalyticsScope::from_param(scope);
    let range = resolve_usage_time_range(from, to)?;
    let contexts = analytics_contexts_for_scope(scope, state).await?;

    let mut tracked_cost_rows = 0;
    let mut untracked_cost_rows = 0;
    let mut last_tracked_cost_at = None;
    let mut project_names = Vec::new();

    for ctx in &contexts {
        let diagnostics = query_diagnostics(ctx, &range).await?;
        tracked_cost_rows += diagnostics.tracked_cost_rows;
        untracked_cost_rows += diagnostics.untracked_cost_rows;
        if diagnostics.last_tracked_cost_at > last_tracked_cost_at {
            last_tracked_cost_at = diagnostics.last_tracked_cost_at;
        }
        project_names.push(ctx.project_name.clone());
    }
    project_names.sort();
    project_names.dedup();
    let from_date = range.from_date.clone();
    let to_date = range.to_date.clone();
    let local_provider_snapshots =
        crate::commands::get_local_usage_for_dates(Some(from_date.clone()), Some(to_date.clone()))
            .await;

    Ok(UsageDiagnosticsView {
        scope: scope.as_str().to_string(),
        from: from_date,
        to: to_date,
        project_names,
        tracked_cost_rows,
        untracked_cost_rows,
        last_tracked_cost_at,
        local_provider_snapshots,
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn resolve_usage_time_range_swaps_inputs_and_counts_days() {
        let range = resolve_usage_time_range(
            Some("2026-03-08".to_string()),
            Some("2026-03-01".to_string()),
        )
        .expect("range");

        assert_eq!(range.from_date, "2026-03-01");
        assert_eq!(range.to_date, "2026-03-08");
        assert_eq!(range.day_count, 8);
    }

    #[test]
    fn resolve_usage_time_range_preserves_requested_local_dates_for_rfc3339_inputs() {
        let range = resolve_usage_time_range(
            Some("2026-03-11T00:00:00+01:00".to_string()),
            Some("2026-03-11T23:59:59.999+01:00".to_string()),
        )
        .expect("range");

        assert_eq!(range.from_date, "2026-03-11");
        assert_eq!(range.to_date, "2026-03-11");
        assert_eq!(range.day_count, 1);
        assert_eq!(range.from.to_rfc3339(), "2026-03-10T23:00:00+00:00");
        assert_eq!(range.to.to_rfc3339(), "2026-03-11T22:59:59.999+00:00");
    }

    #[test]
    fn csv_labels_deduplicates_and_discards_blanks() {
        let labels = csv_labels(Some("claude, codex, claude, , codex".to_string()));
        assert_eq!(labels, vec!["claude".to_string(), "codex".to_string()]);
    }

    #[test]
    fn merge_breakdowns_accumulates_cost_and_tokens() {
        let merged = merge_breakdowns(
            vec![
                UsageBreakdownItemView {
                    key: "claude".to_string(),
                    label: "claude".to_string(),
                    secondary_label: None,
                    total_tokens: 100,
                    estimated_usd: 1.0,
                    record_count: 2,
                },
                UsageBreakdownItemView {
                    key: "claude".to_string(),
                    label: "claude".to_string(),
                    secondary_label: None,
                    total_tokens: 50,
                    estimated_usd: 0.5,
                    record_count: 1,
                },
            ],
            |item| item.key.clone(),
        );

        assert_eq!(merged.len(), 1);
        assert_eq!(merged[0].total_tokens, 150);
        assert_eq!(merged[0].record_count, 3);
        assert!((merged[0].estimated_usd - 1.5).abs() < f64::EPSILON);
    }
}
