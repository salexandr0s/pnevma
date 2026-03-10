// Analytics commands — Features 1, 4, 9
// This module will contain:
// - get_usage_breakdown, get_usage_by_model, get_usage_daily_trend (Feature 1)
// - list_error_signatures, get_error_signature, get_error_trend (Feature 4)
// - get_session_analytics, export_analytics_csv (Feature 9)

use super::*;
use std::collections::{BTreeMap, HashMap, HashSet};

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

struct AnalyticsProjectContext {
    project_id: String,
    db: Db,
}

async fn analytics_project_contexts(
    state: &AppState,
) -> Result<Vec<AnalyticsProjectContext>, String> {
    let mut contexts = Vec::new();
    let mut seen_paths = HashSet::new();

    let current_context = {
        let current = state.current.lock().await;
        current.as_ref().map(|ctx| {
            (
                ctx.project_path.to_string_lossy().to_string(),
                AnalyticsProjectContext {
                    project_id: ctx.project_id.to_string(),
                    db: ctx.db.clone(),
                },
            )
        })
    };
    if let Some((path, context)) = current_context {
        seen_paths.insert(path);
        contexts.push(context);
    }

    for trusted in state
        .global_db()?
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
            db,
        });
    }

    Ok(contexts)
}

pub async fn get_usage_breakdown(
    days: Option<i64>,
    state: &AppState,
) -> Result<Vec<UsageBreakdownView>, String> {
    let days = days.unwrap_or(30);

    let current_context = {
        let current = state.current.lock().await;
        current.as_ref().map(|ctx| AnalyticsProjectContext {
            project_id: ctx.project_id.to_string(),
            db: ctx.db.clone(),
        })
    };
    if let Some(ctx) = current_context {
        let rows = ctx
            .db
            .get_usage_breakdown(&ctx.project_id, days)
            .await
            .map_err(|e| e.to_string())?;
        return Ok(rows
            .into_iter()
            .map(|r| UsageBreakdownView {
                provider: r.provider,
                tokens_in: r.tokens_in,
                tokens_out: r.tokens_out,
                estimated_usd: r.estimated_usd,
                record_count: r.record_count,
            })
            .collect());
    }

    let mut aggregate: BTreeMap<String, UsageBreakdownView> = BTreeMap::new();
    for ctx in analytics_project_contexts(state).await? {
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
    let current_context = {
        let current = state.current.lock().await;
        current.as_ref().map(|ctx| AnalyticsProjectContext {
            project_id: ctx.project_id.to_string(),
            db: ctx.db.clone(),
        })
    };
    if let Some(ctx) = current_context {
        let rows = ctx
            .db
            .get_usage_by_model(&ctx.project_id)
            .await
            .map_err(|e| e.to_string())?;
        return Ok(rows
            .into_iter()
            .map(|r| UsageByModelView {
                provider: r.provider,
                model: r.model,
                tokens_in: r.tokens_in,
                tokens_out: r.tokens_out,
                estimated_usd: r.estimated_usd,
            })
            .collect());
    }

    let mut aggregate: BTreeMap<(String, String), UsageByModelView> = BTreeMap::new();
    for ctx in analytics_project_contexts(state).await? {
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

    let current_context = {
        let current = state.current.lock().await;
        current.as_ref().map(|ctx| AnalyticsProjectContext {
            project_id: ctx.project_id.to_string(),
            db: ctx.db.clone(),
        })
    };
    if let Some(ctx) = current_context {
        let rows = ctx
            .db
            .get_usage_daily_trend(&ctx.project_id, days)
            .await
            .map_err(|e| e.to_string())?;
        return Ok(rows
            .into_iter()
            .map(|r| UsageDailyTrendView {
                date: r.period_date,
                tokens_in: r.tokens_in,
                tokens_out: r.tokens_out,
                estimated_usd: r.estimated_usd,
            })
            .collect());
    }

    let mut aggregate: BTreeMap<String, UsageDailyTrendView> = BTreeMap::new();
    for ctx in analytics_project_contexts(state).await? {
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
    let limit = limit.unwrap_or(50);

    let current_context = {
        let current = state.current.lock().await;
        current.as_ref().map(|ctx| AnalyticsProjectContext {
            project_id: ctx.project_id.to_string(),
            db: ctx.db.clone(),
        })
    };
    if let Some(ctx) = current_context {
        let rows = ctx
            .db
            .list_error_signatures(&ctx.project_id, limit)
            .await
            .map_err(|e| e.to_string())?;
        return Ok(rows
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
            .collect());
    }

    let mut aggregate: HashMap<String, ErrorSignatureView> = HashMap::new();
    for ctx in analytics_project_contexts(state).await? {
        let rows = ctx
            .db
            .list_error_signatures(&ctx.project_id, limit)
            .await
            .map_err(|e| e.to_string())?;
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
                entry.sample_output = row.sample_output;
            }
            if entry.remediation_hint.is_none() {
                entry.remediation_hint = row.remediation_hint;
            }
        }
    }

    let mut values: Vec<ErrorSignatureView> = aggregate.into_values().collect();
    values.sort_by(|left, right| right.total_count.cmp(&left.total_count));
    values.truncate(limit as usize);
    Ok(values)
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
