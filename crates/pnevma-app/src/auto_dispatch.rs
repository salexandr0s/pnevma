use crate::commands;
use crate::state::AppState;
use std::time::Duration;
use tauri::{AppHandle, Manager};
use tracing::{debug, info, warn};

/// Start the auto-dispatch background loop.
///
/// Periodically checks for Ready tasks and dispatches them when the pool
/// has capacity. Reads the `automation.auto_dispatch` and
/// `automation.auto_dispatch_interval_seconds` settings from the active
/// project config.
pub fn start_auto_dispatch(app: AppHandle) {
    tauri::async_runtime::spawn(async move {
        // Wait a moment for the app to fully initialize before polling.
        tokio::time::sleep(Duration::from_secs(5)).await;

        loop {
            let interval = run_cycle(&app).await;
            tokio::time::sleep(Duration::from_secs(interval)).await;
        }
    });
}

/// Run one auto-dispatch cycle. Returns the interval to sleep before next cycle.
async fn run_cycle(app: &AppHandle) -> u64 {
    let state = app.state::<AppState>();

    // Read config under the lock, then drop it before calling dispatch functions.
    let (interval, available_slots) = {
        let current = state.current.lock().await;
        let ctx = match current.as_ref() {
            Some(c) => c,
            None => return 10, // no project open, check again later
        };

        let config = &ctx.config;
        if !config.automation.auto_dispatch {
            return config.automation.auto_dispatch_interval_seconds;
        }

        let interval = config.automation.auto_dispatch_interval_seconds.max(5);

        // Check pool capacity.
        let (max, active, queued) = ctx.pool.state().await;
        if active >= max {
            debug!(
                max,
                active, queued, "auto-dispatch: pool at capacity, skipping cycle"
            );
            return interval;
        }

        (interval, max - active)
    };

    // Fetch ready tasks — re-acquire state via app.state() for Tauri State wrapper.
    let tasks = match commands::list_tasks(app.state::<AppState>()).await {
        Ok(t) => t,
        Err(e) => {
            warn!(error = %e, "auto-dispatch: failed to list tasks");
            return interval;
        }
    };

    let ready: Vec<_> = tasks.into_iter().filter(|t| t.status == "Ready").collect();

    if ready.is_empty() {
        debug!("auto-dispatch: no ready tasks");
        return interval;
    }

    // Dispatch up to available_slots tasks, oldest first.
    let mut dispatched = 0usize;
    for task in ready.into_iter().take(available_slots) {
        let task_id = task.id.clone();
        match commands::dispatch_task(task_id.clone(), app.clone(), app.state::<AppState>()).await {
            Ok(status) => {
                info!(
                    task_id = %task_id,
                    title = %task.title,
                    status = %status,
                    "auto-dispatch: dispatched task"
                );
                dispatched += 1;
            }
            Err(e) => {
                warn!(
                    task_id = %task_id,
                    error = %e,
                    "auto-dispatch: failed to dispatch task"
                );
            }
        }
    }

    if dispatched > 0 {
        info!(dispatched, "auto-dispatch: cycle complete");
    }

    interval
}
