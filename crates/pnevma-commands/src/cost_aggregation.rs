use crate::state::AppState;
use std::sync::Arc;
use std::time::Duration;
use tracing::{info, warn};

/// Spawn the cost aggregation background loop.
///
/// Runs every 15 minutes, aggregating raw cost rows into hourly and daily
/// aggregate tables for the currently open project.
pub fn start_cost_aggregation(state: Arc<AppState>) {
    tokio::spawn(async move {
        // Allow the app to fully initialize before first run.
        tokio::time::sleep(Duration::from_secs(30)).await;

        loop {
            run_cycle(&state).await;
            tokio::time::sleep(Duration::from_secs(15 * 60)).await;
        }
    });
}

async fn run_cycle(state: &AppState) {
    let (project_id, db) = {
        let current = state.current.lock().await;
        let Some(ctx) = current.as_ref() else { return };
        (ctx.project_id.to_string(), ctx.db.clone())
    };

    match db.aggregate_costs_hourly(&project_id).await {
        Ok(_) => info!(project_id = %project_id, "cost-aggregation: hourly aggregates updated"),
        Err(e) => {
            warn!(project_id = %project_id, error = %e, "cost-aggregation: hourly aggregate failed")
        }
    }

    match db.aggregate_costs_daily(&project_id).await {
        Ok(_) => info!(project_id = %project_id, "cost-aggregation: daily aggregates updated"),
        Err(e) => {
            warn!(project_id = %project_id, error = %e, "cost-aggregation: daily aggregate failed")
        }
    }
}
