// Analytics commands — Features 1, 4, 9
// This module will contain:
// - get_usage_breakdown, get_usage_by_model, get_usage_daily_trend (Feature 1)
// - list_error_signatures, get_error_signature, get_error_trend (Feature 4)
// - get_session_analytics, export_analytics_csv (Feature 9)

use super::*;

// ─── Feature 1: Cost Aggregation views ──────────────────────────────────────

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

pub async fn get_usage_breakdown(
    days: Option<i64>,
    state: &AppState,
) -> Result<Vec<UsageBreakdownView>, String> {
    let (project_id, db) = {
        let current = state.current.lock().await;
        let ctx = current
            .as_ref()
            .ok_or_else(|| "no open project".to_string())?;
        (ctx.project_id.to_string(), ctx.db.clone())
    };

    let rows = db
        .get_usage_breakdown(&project_id, days.unwrap_or(30))
        .await
        .map_err(|e| e.to_string())?;

    Ok(rows
        .into_iter()
        .map(|r| UsageBreakdownView {
            provider: r.provider,
            tokens_in: r.tokens_in,
            tokens_out: r.tokens_out,
            estimated_usd: r.estimated_usd,
            record_count: r.record_count,
        })
        .collect())
}

pub async fn get_usage_by_model(state: &AppState) -> Result<Vec<UsageByModelView>, String> {
    let (project_id, db) = {
        let current = state.current.lock().await;
        let ctx = current
            .as_ref()
            .ok_or_else(|| "no open project".to_string())?;
        (ctx.project_id.to_string(), ctx.db.clone())
    };

    let rows = db
        .get_usage_by_model(&project_id)
        .await
        .map_err(|e| e.to_string())?;

    Ok(rows
        .into_iter()
        .map(|r| UsageByModelView {
            provider: r.provider,
            model: r.model,
            tokens_in: r.tokens_in,
            tokens_out: r.tokens_out,
            estimated_usd: r.estimated_usd,
        })
        .collect())
}

pub async fn get_usage_daily_trend(
    days: Option<i64>,
    state: &AppState,
) -> Result<Vec<UsageDailyTrendView>, String> {
    let (project_id, db) = {
        let current = state.current.lock().await;
        let ctx = current
            .as_ref()
            .ok_or_else(|| "no open project".to_string())?;
        (ctx.project_id.to_string(), ctx.db.clone())
    };

    let rows = db
        .get_usage_daily_trend(&project_id, days.unwrap_or(30))
        .await
        .map_err(|e| e.to_string())?;

    Ok(rows
        .into_iter()
        .map(|r| UsageDailyTrendView {
            date: r.period_date,
            tokens_in: r.tokens_in,
            tokens_out: r.tokens_out,
            estimated_usd: r.estimated_usd,
        })
        .collect())
}

// ─── Feature 4: Error Signature views ───────────────────────────────────────

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

pub async fn list_error_signatures(
    limit: Option<i64>,
    state: &AppState,
) -> Result<Vec<ErrorSignatureView>, String> {
    let (project_id, db) = {
        let current = state.current.lock().await;
        let ctx = current
            .as_ref()
            .ok_or_else(|| "no open project".to_string())?;
        (ctx.project_id.to_string(), ctx.db.clone())
    };

    let rows = db
        .list_error_signatures(&project_id, limit.unwrap_or(50))
        .await
        .map_err(|e| e.to_string())?;

    Ok(rows
        .into_iter()
        .map(|r| ErrorSignatureView {
            id: r.id,
            signature_hash: r.signature_hash,
            canonical_message: r.canonical_message,
            category: r.category,
            first_seen: r.first_seen,
            last_seen: r.last_seen,
            total_count: r.total_count,
            sample_output: r.sample_output,
            remediation_hint: r.remediation_hint,
        })
        .collect())
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
