use crate::automation::runner;
use crate::automation::workflow_store::WorkflowStore;
use crate::automation::DispatchOrigin;
use crate::commands;
use crate::state::AppState;
use chrono::{DateTime, Utc};
use pnevma_agents::{
    reconcile_claims, AgentAdapter, AgentHandle, ReconciliationAction, ReconciliationClaim,
};
use serde::{Deserialize, Serialize};
use std::collections::HashMap;
use std::sync::Arc;
use tokio::sync::RwLock;
use tokio::task::JoinHandle;
use tracing::{debug, error, info, warn};
use uuid::Uuid;

/// A claim on a task to prevent double-dispatch.
#[derive(Debug, Clone)]
pub struct TaskClaim {
    pub task_id: Uuid,
    pub origin: DispatchOrigin,
    pub claimed_at: DateTime<Utc>,
    pub run_id: Uuid,
}

/// State of a tracked run.
#[derive(Debug)]
pub enum RunState {
    Preparing,
    Running {
        session_id: Uuid,
        started_at: DateTime<Utc>,
    },
    Completed {
        failed: bool,
        finished_at: DateTime<Utc>,
    },
    RetryPending {
        attempt: u32,
        retry_after: DateTime<Utc>,
    },
}

/// A run being tracked by the coordinator.
pub struct TrackedRun {
    pub run_id: Uuid,
    pub task_id: Uuid,
    pub origin: DispatchOrigin,
    pub state: RunState,
    pub event_task: Option<JoinHandle<()>>,
    /// Primary key of the `automation_runs` DB row, used for status updates.
    pub db_run_id: Option<String>,
    pub handle: Option<AgentHandle>,
    pub adapter: Option<Arc<dyn AgentAdapter>>,
}

/// Retry queue entry.
#[derive(Debug, Clone)]
pub struct RetryEntry {
    pub run_id: Uuid,
    pub task_id: Uuid,
    pub attempt: u32,
    pub retry_after: DateTime<Utc>,
    pub last_error: String,
    pub db_retry_id: Option<String>,
}

/// Internal statistics.
#[derive(Debug, Default)]
struct CoordinatorStats {
    total_dispatched: u64,
    total_completed: u64,
    total_failed: u64,
    total_retried: u64,
    last_tick_at: Option<DateTime<Utc>>,
}

/// Serializable snapshot of automation state for status reporting.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct AutomationSnapshot {
    pub enabled: bool,
    pub config_source: String,
    pub poll_interval_seconds: u64,
    pub max_concurrent: usize,
    pub active_runs: usize,
    pub queued_tasks: usize,
    pub claimed_task_ids: Vec<String>,
    pub running_task_ids: Vec<String>,
    pub retry_queue_size: usize,
    pub last_tick_at: Option<DateTime<Utc>>,
    pub total_dispatched: u64,
    pub total_completed: u64,
    pub total_failed: u64,
    pub total_retried: u64,
}

/// The main automation coordinator, replacing auto_dispatch.
pub struct AutomationCoordinator {
    state: Arc<AppState>,
    workflow_store: Arc<WorkflowStore>,
    claims: RwLock<HashMap<Uuid, TaskClaim>>,
    running: RwLock<HashMap<Uuid, TrackedRun>>,
    retry_queue: RwLock<Vec<RetryEntry>>,
    stats: RwLock<CoordinatorStats>,
    shutdown: tokio::sync::watch::Receiver<bool>,
}

impl AutomationCoordinator {
    pub fn new(
        state: Arc<AppState>,
        workflow_store: Arc<WorkflowStore>,
        shutdown: tokio::sync::watch::Receiver<bool>,
    ) -> Self {
        Self {
            state,
            workflow_store,
            claims: RwLock::new(HashMap::new()),
            running: RwLock::new(HashMap::new()),
            retry_queue: RwLock::new(Vec::new()),
            stats: RwLock::new(CoordinatorStats::default()),
            shutdown,
        }
    }

    /// Main run loop — tick + sleep until shutdown.
    pub async fn run(self: Arc<Self>) {
        // Wait a moment for the app to fully initialize.
        tokio::time::sleep(std::time::Duration::from_secs(5)).await;

        // Restore any pending retries from DB (survive restarts).
        self.restore_retries_from_db().await;

        loop {
            if *self.shutdown.borrow() {
                info!("automation coordinator shutting down");
                break;
            }

            let interval = self.tick().await;

            let mut shutdown_rx = self.shutdown.clone();
            tokio::select! {
                _ = tokio::time::sleep(std::time::Duration::from_secs(interval)) => {}
                _ = shutdown_rx.changed() => {
                    if *self.shutdown.borrow() {
                        info!("automation coordinator shutting down (signaled)");
                        break;
                    }
                }
            }
        }

        // Abort all running tasks on shutdown
        let mut running = self.running.write().await;
        for (_, tracked) in running.drain() {
            if let Some(handle) = tracked.event_task {
                handle.abort();
            }
        }
    }

    pub async fn shutdown_active_runs(&self) {
        let drained = {
            let mut running = self.running.write().await;
            running
                .drain()
                .map(|(_, tracked)| tracked)
                .collect::<Vec<_>>()
        };
        self.claims.write().await.clear();

        for tracked in drained {
            if let (Some(adapter), Some(handle)) =
                (tracked.adapter.as_ref(), tracked.handle.as_ref())
            {
                if let Err(err) = adapter.stop(handle).await {
                    warn!(task_id = %tracked.task_id, error = %err, "failed to stop active agent run during shutdown");
                }
            }
            if let Some(event_task) = tracked.event_task {
                event_task.abort();
            }
        }
    }

    /// Run one tick. Returns the interval to sleep before next tick.
    pub async fn tick(&self) -> u64 {
        // 1. Reload workflow config
        self.workflow_store.check_reload().await;
        let config = self.workflow_store.effective_config().await;

        // Update last tick time
        self.stats.write().await.last_tick_at = Some(Utc::now());

        // 2. Check if enabled (WORKFLOW.md takes priority, fall back to pnevma.toml)
        let toml_enabled = {
            let current = self.state.current.lock().await;
            current
                .as_ref()
                .map(|ctx| ctx.config.automation.auto_dispatch)
                .unwrap_or(false)
        };

        if !config.enabled && !toml_enabled {
            return config.poll_interval_seconds.max(5);
        }

        let interval = config.poll_interval_seconds.max(5);
        let max_concurrent = config.max_concurrent;

        // 3. Process completions first (free up slots)
        self.process_completions().await;

        // 4. Process retries
        self.process_retries().await;

        // 5. Discover dispatchable tasks
        let active_count = self
            .running
            .read()
            .await
            .values()
            .filter(|r| matches!(r.state, RunState::Preparing | RunState::Running { .. }))
            .count();

        if active_count >= max_concurrent {
            debug!(
                active = active_count,
                max = max_concurrent,
                "at capacity, skipping dispatch"
            );
            return interval;
        }

        let available_slots = max_concurrent - active_count;
        let dispatchable = self
            .discover_dispatchable(&config.active_task_statuses)
            .await;

        if dispatchable.is_empty() {
            debug!("no dispatchable tasks found");
            return interval;
        }

        // 6. Dispatch up to available_slots
        for task_id_str in dispatchable.into_iter().take(available_slots) {
            let task_id = match Uuid::parse_str(&task_id_str) {
                Ok(id) => id,
                Err(_) => continue,
            };

            if !self.try_claim(task_id, DispatchOrigin::AutoDispatch).await {
                continue; // already claimed
            }

            match self.dispatch_claimed(task_id, 1).await {
                Ok(()) => {
                    self.stats.write().await.total_dispatched += 1;
                    info!(task_id = %task_id, "auto-dispatched task");
                }
                Err(e) => {
                    warn!(task_id = %task_id, error = %e, "failed to dispatch claimed task");
                    self.release_claim(task_id).await;
                }
            }
        }

        // 7. Reconcile stale claims
        self.reconcile_stale().await;

        // 8. Poll tracker for new/updated items
        self.poll_tracker_and_upsert().await;

        interval
    }

    /// Discover tasks eligible for auto-dispatch.
    async fn discover_dispatchable(&self, active_statuses: &[String]) -> Vec<String> {
        let tasks = match commands::list_tasks(&self.state).await {
            Ok(t) => t,
            Err(e) => {
                warn!(error = %e, "failed to list tasks for auto-dispatch");
                return Vec::new();
            }
        };

        let claimed = self.claims.read().await;
        let claimed_ids: std::collections::HashSet<String> =
            claimed.keys().map(|id| id.to_string()).collect();

        let target_status = if active_statuses.is_empty() {
            vec!["Ready".to_string()]
        } else {
            active_statuses.to_vec()
        };

        tasks
            .into_iter()
            .filter(|t| {
                target_status.contains(&t.status) && t.auto_dispatch && !claimed_ids.contains(&t.id)
            })
            .map(|t| t.id)
            .collect()
    }

    /// Try to claim a task for dispatch. Returns true if claimed.
    pub async fn try_claim(&self, task_id: Uuid, origin: DispatchOrigin) -> bool {
        let mut claims = self.claims.write().await;
        if claims.contains_key(&task_id) {
            return false;
        }
        claims.insert(
            task_id,
            TaskClaim {
                task_id,
                origin,
                claimed_at: Utc::now(),
                run_id: Uuid::new_v4(),
            },
        );
        true
    }

    /// Release a claim on a task.
    pub async fn release_claim(&self, task_id: Uuid) {
        self.claims.write().await.remove(&task_id);
    }

    /// Register a manually dispatched run into the running set.
    pub async fn register_manual_run(
        &self,
        task_id: Uuid,
        session_id: Uuid,
        handle: AgentHandle,
        adapter: Arc<dyn AgentAdapter>,
    ) {
        let run_id = Uuid::new_v4();
        self.claims.write().await.insert(
            task_id,
            TaskClaim {
                task_id,
                origin: DispatchOrigin::Manual,
                claimed_at: Utc::now(),
                run_id,
            },
        );
        self.running.write().await.insert(
            task_id,
            TrackedRun {
                run_id,
                task_id,
                origin: DispatchOrigin::Manual,
                state: RunState::Running {
                    session_id,
                    started_at: Utc::now(),
                },
                event_task: None,
                db_run_id: None,
                handle: Some(handle),
                adapter: Some(adapter),
            },
        );
    }

    /// Dispatch a claimed task using the runner.
    async fn dispatch_claimed(&self, task_id: Uuid, attempt: u32) -> Result<(), String> {
        let run_id = {
            let claims = self.claims.read().await;
            claims.get(&task_id).map(|c| c.run_id).ok_or_else(|| {
                format!(
                    "BUG: dispatch_claimed called for task {} with no active claim",
                    task_id
                )
            })?
        };

        // Update to Preparing state
        self.running.write().await.insert(
            task_id,
            TrackedRun {
                run_id,
                task_id,
                origin: DispatchOrigin::AutoDispatch,
                state: RunState::Preparing,
                event_task: None,
                db_run_id: None,
                handle: None,
                adapter: None,
            },
        );

        let prepared = runner::prepare(
            task_id.to_string(),
            &self.state.emitter,
            &self.state,
            DispatchOrigin::AutoDispatch,
        )
        .await
        .map_err(|e| e.to_string())?;
        let db_row_id = runner::create_automation_run_record(&prepared, run_id, attempt)
            .await
            .map_err(|e| e.to_string())?;

        let mut running_agent = match runner::start(&prepared).await {
            Ok(agent) => agent,
            Err(e) => {
                let error = e.to_string();
                runner::handle_start_failure(&prepared, &error).await;
                self.running.write().await.remove(&task_id);
                return Err(error);
            }
        };
        let session_id = running_agent.session_id;

        // Take the event_task JoinHandle out of running_agent before borrowing it for send_payload.
        let event_task_handle = std::mem::replace(
            &mut running_agent.event_task,
            tokio::spawn(async {}), // placeholder
        );

        let now = Utc::now();

        // Update to Running state, storing the event_task JoinHandle
        {
            let mut running_map = self.running.write().await;
            if let Some(tracked) = running_map.get_mut(&task_id) {
                tracked.state = RunState::Running {
                    session_id,
                    started_at: now,
                };
                tracked.event_task = Some(event_task_handle);
                tracked.db_run_id = Some(db_row_id);
                tracked.handle = Some(running_agent.handle.clone());
                tracked.adapter = Some(Arc::clone(&prepared.adapter));
            }
        }

        if let Err(e) = runner::send_payload(&prepared, &running_agent).await {
            // handle_send_failure already cleaned DB/worktree/permit.
            // Abort the real event_task stored in TrackedRun and remove the stale entry.
            let real_handle = {
                let mut running_map = self.running.write().await;
                running_map.remove(&task_id).and_then(|t| t.event_task)
            };
            if let Some(h) = real_handle {
                h.abort();
            }
            return Err(e);
        }

        Ok(())
    }

    /// Check for completed runs and update state.
    async fn process_completions(&self) {
        let mut completed_ids: Vec<Uuid> = Vec::new();

        {
            let running = self.running.read().await;
            for (task_id, tracked) in running.iter() {
                // Auto-dispatched runs: check JoinHandle
                if let Some(ref handle) = tracked.event_task {
                    if handle.is_finished() {
                        completed_ids.push(*task_id);
                        continue;
                    }
                }
                // Manual runs without event_task: check DB status
                if tracked.event_task.is_none() {
                    if let DispatchOrigin::Manual = tracked.origin {
                        if self.is_task_terminal(*task_id).await {
                            completed_ids.push(*task_id);
                        }
                    }
                }
            }
        }

        for task_id in completed_ids {
            let task_failed = self.is_task_terminal(task_id).await && {
                let db_opt = {
                    let current = self.state.current.lock().await;
                    current.as_ref().map(|ctx| ctx.db.clone())
                };
                if let Some(db) = db_opt {
                    match db.get_task(&task_id.to_string()).await {
                        Ok(Some(row)) => matches!(row.status.as_str(), "Failed" | "Error"),
                        _ => false,
                    }
                } else {
                    false
                }
            };

            let db_run_id_for_update = {
                let mut running = self.running.write().await;
                let db_run_id = running.get(&task_id).and_then(|t| t.db_run_id.clone());
                running.remove(&task_id);
                db_run_id
            };
            self.claims.write().await.remove(&task_id);

            if task_failed {
                self.stats.write().await.total_failed += 1;
            } else {
                self.stats.write().await.total_completed += 1;
            }

            let _ = db_run_id_for_update;
        }
    }

    /// Check whether a task is in a terminal status via DB.
    async fn is_task_terminal(&self, task_id: Uuid) -> bool {
        let db = {
            let current = self.state.current.lock().await;
            match current.as_ref() {
                Some(ctx) => ctx.db.clone(),
                None => return false,
            }
        };
        match db.get_task(&task_id.to_string()).await {
            Ok(Some(row)) => {
                let status = commands::parse_status(&row.status);
                commands::is_terminal_task_status(&status)
            }
            _ => false,
        }
    }

    /// Process retry queue — re-dispatch tasks whose backoff has elapsed.
    async fn process_retries(&self) {
        let now = Utc::now();
        let to_retry: Vec<RetryEntry> = {
            let mut retry_queue = self.retry_queue.write().await;
            let mut to_retry = Vec::new();
            retry_queue.retain(|entry| {
                if entry.retry_after <= now {
                    to_retry.push(entry.clone());
                    false
                } else {
                    true
                }
            });
            to_retry
        };

        let db = {
            let current = self.state.current.lock().await;
            current.as_ref().map(|ctx| ctx.db.clone())
        };

        for entry in to_retry {
            info!(
                task_id = %entry.task_id,
                attempt = entry.attempt,
                "retrying task from retry queue"
            );

            if self
                .try_claim(entry.task_id, DispatchOrigin::AutoDispatch)
                .await
            {
                match self.dispatch_claimed(entry.task_id, entry.attempt).await {
                    Ok(()) => {
                        self.stats.write().await.total_retried += 1;
                        if let (Some(ref db), Some(ref retry_id)) = (&db, &entry.db_retry_id) {
                            let _ = db
                                .update_automation_retry_outcome(
                                    retry_id,
                                    "dispatched",
                                    Some(Utc::now()),
                                )
                                .await;
                        }
                    }
                    Err(e) => {
                        warn!(task_id = %entry.task_id, error = %e, "retry dispatch failed");
                        self.release_claim(entry.task_id).await;
                        self.stats.write().await.total_failed += 1;
                        if let (Some(ref db), Some(ref retry_id)) = (&db, &entry.db_retry_id) {
                            let _ = db
                                .update_automation_retry_outcome(
                                    retry_id,
                                    "failed",
                                    Some(Utc::now()),
                                )
                                .await;
                        }
                    }
                }
            }
        }
    }

    /// Enqueue a retry entry, persisting to DB.
    pub async fn enqueue_retry(&self, mut entry: RetryEntry) {
        if let Some((db, project_id)) = {
            let current = self.state.current.lock().await;
            current.as_ref().map(|ctx| (ctx.db.clone(), ctx.project_id))
        } {
            let retry_row = pnevma_db::AutomationRetryRow {
                id: Uuid::new_v4().to_string(),
                project_id: project_id.to_string(),
                run_id: entry.run_id.to_string(),
                task_id: entry.task_id.to_string(),
                attempt: entry.attempt as i64,
                reason: entry.last_error.clone(),
                retry_after: entry.retry_after,
                retried_at: None,
                outcome: None,
                created_at: Utc::now(),
            };
            if db.create_automation_retry(&retry_row).await.is_ok() {
                entry.db_retry_id = Some(retry_row.id);
            }
        }
        self.retry_queue.write().await.push(entry);
    }

    /// Restore pending retries from DB on startup.
    async fn restore_retries_from_db(&self) {
        let pair = {
            let current = self.state.current.lock().await;
            current.as_ref().map(|ctx| (ctx.db.clone(), ctx.project_id))
        };
        let (db, project_id) = match pair {
            Some(pair) => pair,
            None => return,
        };

        let rows = match db.list_pending_retries(&project_id.to_string()).await {
            Ok(rows) => rows,
            Err(e) => {
                warn!(error = %e, "failed to load pending retries from DB");
                return;
            }
        };

        let mut retry_queue = self.retry_queue.write().await;
        let existing_task_ids: std::collections::HashSet<Uuid> =
            retry_queue.iter().map(|e| e.task_id).collect();

        for row in rows {
            let task_id = match Uuid::parse_str(&row.task_id) {
                Ok(id) => id,
                Err(_) => continue,
            };
            if existing_task_ids.contains(&task_id) {
                continue;
            }
            retry_queue.push(RetryEntry {
                run_id: Uuid::parse_str(&row.run_id).unwrap_or_else(|_| Uuid::new_v4()),
                task_id,
                attempt: row.attempt as u32,
                retry_after: row.retry_after,
                last_error: row.reason,
                db_retry_id: Some(row.id),
            });
        }
        if !retry_queue.is_empty() {
            info!(
                count = retry_queue.len(),
                "restored pending retries from DB"
            );
        }
    }

    /// Release claims stuck in Preparing for too long (>5 min).
    /// Also runs the reconciler on Running tasks to detect orphaned sessions/worktrees.
    async fn reconcile_stale(&self) {
        let stale_threshold = Utc::now() - chrono::Duration::minutes(5);

        // 1. Find stale claims (Preparing too long or orphaned claims)
        let stale_ids: Vec<Uuid> = {
            let running = self.running.read().await;
            let claims = self.claims.read().await;
            claims
                .iter()
                .filter_map(|(task_id, claim)| {
                    if claim.claimed_at < stale_threshold {
                        if let Some(tracked) = running.get(task_id) {
                            if matches!(tracked.state, RunState::Preparing) {
                                return Some(*task_id);
                            }
                        } else {
                            return Some(*task_id);
                        }
                    }
                    None
                })
                .collect()
        };

        for task_id in stale_ids {
            warn!(task_id = %task_id, "releasing stale claim");
            self.running.write().await.remove(&task_id);
            self.claims.write().await.remove(&task_id);
        }

        // 2. Reconcile running tasks via the reconciler module
        let reconciliation_claims = self.build_reconciliation_claims().await;
        if reconciliation_claims.is_empty() {
            return;
        }

        let active_sessions = self.get_active_session_ids().await;
        let actions = reconcile_claims(&reconciliation_claims, &active_sessions);

        for action in actions {
            match action {
                ReconciliationAction::MarkFailed { task_id, reason } => {
                    warn!(task_id = %task_id, reason = %reason, "reconciler: marking task failed");
                    self.mark_task_failed(task_id, &reason).await;
                    self.running.write().await.remove(&task_id);
                    self.claims.write().await.remove(&task_id);
                    self.stats.write().await.total_failed += 1;
                }
                ReconciliationAction::RefreshLease { .. } => {
                    // Healthy — nothing to do
                }
                ReconciliationAction::CleanupOrphan {
                    task_id,
                    worktree_path: _,
                } => {
                    warn!(task_id = %task_id, "reconciler: cleaning up orphaned task");
                    self.mark_task_failed(task_id, "orphaned session detected by reconciler")
                        .await;
                    // Attempt worktree cleanup
                    let ctx_data = {
                        let current = self.state.current.lock().await;
                        current.as_ref().map(|ctx| {
                            (
                                ctx.db.clone(),
                                ctx.git.clone(),
                                ctx.project_id,
                                ctx.project_path.clone(),
                            )
                        })
                    };
                    if let Some((db, git, project_id, pp)) = ctx_data {
                        let _ = commands::cleanup_task_worktree(
                            &db,
                            &git,
                            project_id,
                            task_id,
                            Some(&self.state.emitter),
                            Some(pp.as_path()),
                        )
                        .await;
                    }
                    self.running.write().await.remove(&task_id);
                    self.claims.write().await.remove(&task_id);
                    self.stats.write().await.total_failed += 1;
                }
            }
        }
    }

    /// Build ReconciliationClaim entries from the Running set.
    async fn build_reconciliation_claims(&self) -> Vec<ReconciliationClaim> {
        let running = self.running.read().await;
        let db = {
            let current = self.state.current.lock().await;
            match current.as_ref() {
                Some(ctx) => ctx.db.clone(),
                None => return Vec::new(),
            }
        };

        let mut claims = Vec::new();
        for tracked in running.values() {
            if let RunState::Running { session_id, .. } = &tracked.state {
                // Look up worktree info from DB
                let task_id_str = tracked.task_id.to_string();
                let (worktree_path, branch) = match db.get_task(&task_id_str).await {
                    Ok(Some(row)) => {
                        let wt_path = db
                            .find_worktree_by_task(&task_id_str)
                            .await
                            .ok()
                            .flatten()
                            .map(|w| w.path);
                        (wt_path, row.branch)
                    }
                    _ => (None, None),
                };

                claims.push(ReconciliationClaim {
                    task_id: tracked.task_id,
                    session_id: *session_id,
                    worktree_path,
                    branch,
                    lease_status: "Active".to_string(),
                });
            }
        }
        claims
    }

    /// Get active session IDs from the session supervisor.
    async fn get_active_session_ids(&self) -> Vec<Uuid> {
        let mut active_ids = {
            let running = self.running.read().await;
            running
                .values()
                .filter_map(
                    |tracked| match (&tracked.state, tracked.event_task.as_ref()) {
                        (RunState::Running { session_id, .. }, Some(event_task))
                            if !event_task.is_finished() =>
                        {
                            Some(*session_id)
                        }
                        _ => None,
                    },
                )
                .collect::<std::collections::HashSet<_>>()
        };

        let current = self.state.current.lock().await;
        if let Some(ctx) = current.as_ref() {
            for session in ctx.sessions.list().await {
                active_ids.insert(session.id);
            }
            if let Ok(rows) = ctx.db.list_sessions(&ctx.project_id.to_string()).await {
                active_ids.extend(rows.into_iter().filter_map(|row| {
                    let is_live_agent =
                        row.r#type.as_deref() == Some("agent") && row.status == "running";
                    if is_live_agent {
                        Uuid::parse_str(&row.id).ok()
                    } else {
                        None
                    }
                }));
            }
        }

        active_ids.into_iter().collect()
    }

    /// Mark a task as Failed in the database.
    async fn mark_task_failed(&self, task_id: Uuid, reason: &str) {
        let (db, project_id) = {
            let current = self.state.current.lock().await;
            match current.as_ref() {
                Some(ctx) => (ctx.db.clone(), ctx.project_id),
                None => return,
            }
        };

        let task_id_str = task_id.to_string();
        match db.get_task(&task_id_str).await {
            Ok(Some(mut row)) => {
                row.status = "Failed".to_string();
                row.updated_at = Utc::now();
                if let Err(e) = db.update_task(&row).await {
                    error!(task_id = %task_id, error = %e, "failed to mark task as Failed");
                }
            }
            Ok(None) => {
                warn!(task_id = %task_id, "task not found when trying to mark as Failed");
            }
            Err(e) => {
                error!(task_id = %task_id, error = %e, "failed to fetch task for status update");
            }
        }

        commands::append_event(
            &db,
            project_id,
            Some(task_id),
            None,
            "coordinator",
            "TaskFailed",
            serde_json::json!({ "reason": reason, "source": "reconciler" }),
        )
        .await;
    }

    /// Poll the external tracker for new/updated items and upsert tasks.
    async fn poll_tracker_and_upsert(&self) {
        let tracker = {
            let current = self.state.current.lock().await;
            match current.as_ref() {
                Some(ctx) => ctx.tracker.clone(),
                None => return,
            }
        };
        let tracker = match tracker {
            Some(t) => t,
            None => return,
        };

        let items = match tracker.poll_once().await {
            Ok(items) => items,
            Err(e) => {
                warn!(error = %e, "tracker poll failed");
                return;
            }
        };

        if items.is_empty() {
            return;
        }

        let pair = {
            let current = self.state.current.lock().await;
            current.as_ref().map(|ctx| (ctx.db.clone(), ctx.project_id))
        };
        let (db, project_id) = match pair {
            Some(pair) => pair,
            None => return,
        };

        let project_id_str = project_id.to_string();
        for item in items {
            let existing = db
                .get_task_external_source(&project_id_str, &item.kind, &item.external_id)
                .await
                .ok()
                .flatten();

            if let Some(source_row) = existing {
                // Update state if changed
                let new_state = item.state.to_string();
                if source_row.state != new_state {
                    let mut updated_row = source_row;
                    updated_row.state = new_state;
                    updated_row.synced_at = Utc::now();
                    let _ = db.upsert_task_external_source(&updated_row).await;
                }
            } else {
                // Create a new task from the tracker item
                let task_id = Uuid::new_v4();
                let now = Utc::now();
                let task_row = pnevma_db::TaskRow {
                    id: task_id.to_string(),
                    project_id: project_id_str.clone(),
                    title: item.title.clone(),
                    goal: item
                        .description
                        .clone()
                        .unwrap_or_else(|| item.title.clone()),
                    scope_json: "[]".to_string(),
                    dependencies_json: "[]".to_string(),
                    acceptance_json: "[]".to_string(),
                    constraints_json: "[]".to_string(),
                    priority: match item.priority {
                        Some(p) if p <= 1.0 => "P0".to_string(),
                        Some(p) if p <= 2.0 => "P1".to_string(),
                        Some(p) if p <= 3.0 => "P2".to_string(),
                        _ => "P2".to_string(),
                    },
                    status: item.state.to_task_status().to_string(),
                    branch: None,
                    worktree_id: None,
                    handoff_summary: None,
                    created_at: now,
                    updated_at: now,
                    auto_dispatch: true,
                    agent_profile_override: None,
                    execution_mode: None,
                    timeout_minutes: None,
                    max_retries: None,
                    loop_iteration: 0,
                    loop_context_json: None,
                };
                if db.create_task(&task_row).await.is_ok() {
                    let source_row = pnevma_db::TaskExternalSourceRow {
                        id: Uuid::new_v4().to_string(),
                        project_id: project_id_str.clone(),
                        task_id: task_id.to_string(),
                        kind: item.kind.clone(),
                        external_id: item.external_id.clone(),
                        identifier: item.identifier.clone(),
                        url: item.url.clone(),
                        state: item.state.to_string(),
                        synced_at: now,
                    };
                    let _ = db.upsert_task_external_source(&source_row).await;
                    info!(
                        external_id = %item.external_id,
                        task_id = %task_id,
                        "created task from tracker item"
                    );
                }
            }
        }
    }

    /// Get a snapshot of the current automation state.
    pub async fn snapshot(&self) -> AutomationSnapshot {
        let config = self.workflow_store.effective_config().await;
        let claims = self.claims.read().await;
        let running = self.running.read().await;
        let retry_queue = self.retry_queue.read().await;
        let stats = self.stats.read().await;

        let toml_enabled = {
            let current = self.state.current.lock().await;
            current
                .as_ref()
                .map(|ctx| ctx.config.automation.auto_dispatch)
                .unwrap_or(false)
        };

        let config_source = if self.workflow_store.current().await.is_some() {
            "WORKFLOW.md".to_string()
        } else if toml_enabled {
            "pnevma.toml".to_string()
        } else {
            "none".to_string()
        };

        let active_runs = running
            .values()
            .filter(|r| matches!(r.state, RunState::Preparing | RunState::Running { .. }))
            .count();

        // Tasks that are claimed but not yet in the running map are queued.
        let queued_tasks = claims.len().saturating_sub(running.len());

        AutomationSnapshot {
            enabled: config.enabled || toml_enabled,
            config_source,
            poll_interval_seconds: config.poll_interval_seconds,
            max_concurrent: config.max_concurrent,
            active_runs,
            queued_tasks,
            claimed_task_ids: claims.keys().map(|id| id.to_string()).collect(),
            running_task_ids: running
                .iter()
                .filter(|(_, r)| matches!(r.state, RunState::Running { .. }))
                .map(|(id, _)| id.to_string())
                .collect(),
            retry_queue_size: retry_queue.len(),
            last_tick_at: stats.last_tick_at,
            total_dispatched: stats.total_dispatched,
            total_completed: stats.total_completed,
            total_failed: stats.total_failed,
            total_retried: stats.total_retried,
        }
    }
}

// ──────────────────────────── Tests ────────────────────────────

#[cfg(test)]
mod tests {
    use super::*;
    use crate::event_emitter::NullEmitter;
    use crate::state::ProjectContext;
    use async_trait::async_trait;
    use chrono::Utc;
    use pnevma_agents::{
        AdapterRegistry, AgentAdapter, AgentConfig, AgentError, AgentEvent, AgentHandle,
        CostRecord, DispatchPool, TaskPayload,
    };
    use pnevma_core::config::{
        AgentsSection, AutomationSection, BranchesSection, PathSection, ProjectSection,
        RedactionSection, RetentionSection,
    };
    use pnevma_core::{GlobalConfig, ProjectConfig, RemoteSection, TrackerSection};
    use pnevma_db::{Db, SessionRow, TaskRow, WorktreeRow};
    use pnevma_git::GitService;
    use pnevma_session::SessionSupervisor;
    use sqlx::sqlite::SqlitePoolOptions;
    use tempfile::TempDir;
    use tokio::sync::Mutex;

    struct NoopAdapter;

    #[async_trait]
    impl AgentAdapter for NoopAdapter {
        async fn spawn(&self, config: AgentConfig) -> Result<AgentHandle, AgentError> {
            Ok(AgentHandle {
                id: Uuid::new_v4(),
                provider: config.provider,
                task_id: Uuid::new_v4(),
                thread_id: None,
                turn_id: None,
            })
        }

        async fn send(&self, _handle: &AgentHandle, _input: TaskPayload) -> Result<(), AgentError> {
            Ok(())
        }

        async fn interrupt(&self, _handle: &AgentHandle) -> Result<(), AgentError> {
            Ok(())
        }

        async fn stop(&self, _handle: &AgentHandle) -> Result<(), AgentError> {
            Ok(())
        }

        fn events(&self, _handle: &AgentHandle) -> tokio::sync::broadcast::Receiver<AgentEvent> {
            let (_tx, rx) = tokio::sync::broadcast::channel(1);
            rx
        }

        async fn parse_usage(&self, handle: &AgentHandle) -> Result<CostRecord, AgentError> {
            Ok(CostRecord {
                provider: "noop".to_string(),
                model: None,
                tokens_in: 0,
                tokens_out: 0,
                estimated_cost_usd: 0.0,
                timestamp: Utc::now(),
                task_id: handle.task_id,
                session_id: handle.id,
            })
        }
    }

    fn make_manual_handle(session_id: Uuid) -> AgentHandle {
        AgentHandle {
            id: session_id,
            provider: "noop".to_string(),
            task_id: Uuid::new_v4(),
            thread_id: None,
            turn_id: None,
        }
    }

    async fn open_test_db() -> Db {
        let pool = SqlitePoolOptions::new()
            .max_connections(1)
            .connect("sqlite::memory:")
            .await
            .expect("memory sqlite");
        let db = Db::from_pool_and_path(pool, std::path::PathBuf::from(":memory:"));
        db.migrate().await.expect("migrate");
        db
    }

    fn make_project_config() -> ProjectConfig {
        ProjectConfig {
            project: ProjectSection {
                name: "test-project".to_string(),
                brief: String::new(),
            },
            agents: AgentsSection {
                default_provider: "claude-code".to_string(),
                max_concurrent: 1,
                claude_code: None,
                codex: None,
            },
            automation: AutomationSection::default(),
            retention: RetentionSection::default(),
            branches: BranchesSection {
                target: "main".to_string(),
                naming: "feat/{slug}".to_string(),
            },
            rules: PathSection::default(),
            conventions: PathSection::default(),
            remote: RemoteSection::default(),
            tracker: TrackerSection::default(),
            redaction: RedactionSection::default(),
        }
    }

    async fn make_state_with_project() -> (Arc<AppState>, Db, Uuid, TempDir) {
        let db = open_test_db().await;
        let project_id = Uuid::new_v4();
        let tempdir = tempfile::tempdir().expect("tempdir");
        let project_root = tempdir.path().join("project");
        std::fs::create_dir_all(&project_root).expect("project root");

        db.upsert_project(
            &project_id.to_string(),
            "test",
            project_root.to_string_lossy().as_ref(),
            None,
            None,
        )
        .await
        .expect("seed project");

        let (shutdown_tx, _shutdown_rx) = tokio::sync::watch::channel(false);
        let ctx = ProjectContext {
            project_id,
            project_path: project_root.clone(),
            config: make_project_config(),
            global_config: GlobalConfig::default(),
            db: db.clone(),
            sessions: SessionSupervisor::new(project_root.join(".pnevma/data")),
            redaction_secrets: Arc::new(RwLock::new(Vec::new())),
            git: Arc::new(GitService::new(&project_root)),
            adapters: AdapterRegistry::default(),
            pool: DispatchPool::new(1),
            tracker: None,
            workflow_store: Arc::new(WorkflowStore::new(&project_root)),
            coordinator: None,
            shutdown_tx,
        };

        let state = Arc::new(AppState {
            current: Mutex::new(Some(ctx)),
            ..AppState::new(Arc::new(NullEmitter))
        });

        (state, db, project_id, tempdir)
    }

    #[test]
    fn automation_snapshot_serializes() {
        let snapshot = AutomationSnapshot {
            enabled: true,
            config_source: "WORKFLOW.md".to_string(),
            poll_interval_seconds: 15,
            max_concurrent: 3,
            active_runs: 1,
            queued_tasks: 2,
            claimed_task_ids: vec!["abc".into()],
            running_task_ids: vec!["def".into()],
            retry_queue_size: 0,
            last_tick_at: Some(Utc::now()),
            total_dispatched: 10,
            total_completed: 8,
            total_failed: 1,
            total_retried: 1,
        };
        let json = serde_json::to_string(&snapshot).unwrap();
        assert!(json.contains("WORKFLOW.md"));
        assert!(json.contains("\"enabled\":true"));
    }

    #[test]
    fn retry_entry_ordering() {
        let e1 = RetryEntry {
            run_id: Uuid::new_v4(),
            task_id: Uuid::new_v4(),
            attempt: 1,
            retry_after: Utc::now() - chrono::Duration::seconds(10),
            last_error: String::new(),
            db_retry_id: None,
        };
        let e2 = RetryEntry {
            run_id: Uuid::new_v4(),
            task_id: Uuid::new_v4(),
            attempt: 2,
            retry_after: Utc::now() + chrono::Duration::seconds(60),
            last_error: "timeout".into(),
            db_retry_id: None,
        };
        // e1 should be eligible now, e2 should not
        assert!(e1.retry_after <= Utc::now());
        assert!(e2.retry_after > Utc::now());
    }

    #[tokio::test]
    async fn try_claim_prevents_double_dispatch() {
        let (_, shutdown_rx) = tokio::sync::watch::channel(false);
        let state = Arc::new(AppState::default());
        let ws = Arc::new(WorkflowStore::new(std::path::Path::new("/tmp/nonexistent")));

        let coord = AutomationCoordinator::new(state, ws, shutdown_rx);
        let task_id = Uuid::new_v4();

        assert!(coord.try_claim(task_id, DispatchOrigin::AutoDispatch).await);
        // Second claim should fail
        assert!(!coord.try_claim(task_id, DispatchOrigin::AutoDispatch).await);
    }

    #[tokio::test]
    async fn release_claim_frees_slot() {
        let (_, shutdown_rx) = tokio::sync::watch::channel(false);
        let state = Arc::new(AppState::default());
        let ws = Arc::new(WorkflowStore::new(std::path::Path::new("/tmp/nonexistent")));

        let coord = AutomationCoordinator::new(state, ws, shutdown_rx);
        let task_id = Uuid::new_v4();

        assert!(coord.try_claim(task_id, DispatchOrigin::AutoDispatch).await);
        coord.release_claim(task_id).await;
        // Should be claimable again
        assert!(coord.try_claim(task_id, DispatchOrigin::AutoDispatch).await);
    }

    #[tokio::test]
    async fn register_manual_run_blocks_auto_claim() {
        let (_, shutdown_rx) = tokio::sync::watch::channel(false);
        let state = Arc::new(AppState::default());
        let ws = Arc::new(WorkflowStore::new(std::path::Path::new("/tmp/nonexistent")));

        let coord = AutomationCoordinator::new(state, ws, shutdown_rx);
        let task_id = Uuid::new_v4();
        let session_id = Uuid::new_v4();

        coord
            .register_manual_run(
                task_id,
                session_id,
                make_manual_handle(session_id),
                Arc::new(NoopAdapter),
            )
            .await;

        // Auto-dispatch claim should fail (task already tracked)
        assert!(!coord.try_claim(task_id, DispatchOrigin::AutoDispatch).await);

        // Verify it's in the running set
        let running = coord.running.read().await;
        assert!(running.contains_key(&task_id));
        if let Some(tracked) = running.get(&task_id) {
            assert!(matches!(tracked.origin, DispatchOrigin::Manual));
        }
    }

    #[tokio::test]
    async fn snapshot_reflects_state() {
        let (_, shutdown_rx) = tokio::sync::watch::channel(false);
        let state = Arc::new(AppState::default());
        let ws = Arc::new(WorkflowStore::new(std::path::Path::new("/tmp/nonexistent")));

        let coord = AutomationCoordinator::new(state, ws, shutdown_rx);

        let snap = coord.snapshot().await;
        assert_eq!(snap.active_runs, 0);
        assert_eq!(snap.retry_queue_size, 0);
        assert_eq!(snap.total_dispatched, 0);

        // Register a manual run and check snapshot again
        let task_id = Uuid::new_v4();
        let session_id = Uuid::new_v4();
        coord
            .register_manual_run(
                task_id,
                session_id,
                make_manual_handle(session_id),
                Arc::new(NoopAdapter),
            )
            .await;

        let snap = coord.snapshot().await;
        assert_eq!(snap.active_runs, 1);
        assert!(snap.running_task_ids.contains(&task_id.to_string()));
    }

    #[tokio::test]
    async fn get_active_session_ids_includes_locally_managed_agent_runs() {
        let (_, shutdown_rx) = tokio::sync::watch::channel(false);
        let state = Arc::new(AppState::default());
        let ws = Arc::new(WorkflowStore::new(std::path::Path::new("/tmp/nonexistent")));
        let coord = AutomationCoordinator::new(state, ws, shutdown_rx);

        let task_id = Uuid::new_v4();
        let session_id = Uuid::new_v4();
        let event_task = tokio::spawn(async {
            tokio::time::sleep(std::time::Duration::from_secs(60)).await;
        });

        coord.running.write().await.insert(
            task_id,
            TrackedRun {
                run_id: Uuid::new_v4(),
                task_id,
                origin: DispatchOrigin::AutoDispatch,
                state: RunState::Running {
                    session_id,
                    started_at: Utc::now(),
                },
                event_task: Some(event_task),
                db_run_id: None,
                handle: None,
                adapter: None,
            },
        );

        let active_sessions = coord.get_active_session_ids().await;
        assert!(
            active_sessions.contains(&session_id),
            "coordinator should treat locally managed auto-dispatch sessions as active"
        );

        let event_task = {
            coord
                .running
                .write()
                .await
                .remove(&task_id)
                .and_then(|tracked| tracked.event_task)
        };
        if let Some(handle) = event_task {
            handle.abort();
        }
    }

    #[tokio::test]
    async fn reconcile_stale_releases_old_claims() {
        let (_, shutdown_rx) = tokio::sync::watch::channel(false);
        let state = Arc::new(AppState::default());
        let ws = Arc::new(WorkflowStore::new(std::path::Path::new("/tmp/nonexistent")));

        let coord = AutomationCoordinator::new(state, ws, shutdown_rx);
        let task_id = Uuid::new_v4();

        // Insert a claim with an old timestamp
        {
            let mut claims = coord.claims.write().await;
            claims.insert(
                task_id,
                TaskClaim {
                    task_id,
                    origin: DispatchOrigin::AutoDispatch,
                    claimed_at: Utc::now() - chrono::Duration::minutes(10),
                    run_id: Uuid::new_v4(),
                },
            );
        }

        coord.reconcile_stale().await;

        // Claim should be released
        assert!(!coord.claims.read().await.contains_key(&task_id));
    }

    #[tokio::test]
    async fn get_active_session_ids_includes_running_agent_rows_from_db() {
        let (state, db, project_id, _tempdir) = make_state_with_project().await;
        let (_, shutdown_rx) = tokio::sync::watch::channel(false);
        let ws = Arc::new(WorkflowStore::new(std::path::Path::new("/tmp/nonexistent")));
        let coord = AutomationCoordinator::new(state, ws, shutdown_rx);

        let session_id = Uuid::new_v4();
        db.upsert_session(&SessionRow {
            id: session_id.to_string(),
            project_id: project_id.to_string(),
            name: "agent-test".to_string(),
            r#type: Some("agent".to_string()),
            status: "running".to_string(),
            pid: None,
            cwd: "/tmp".to_string(),
            command: "claude-code".to_string(),
            branch: None,
            worktree_id: None,
            started_at: Utc::now(),
            last_heartbeat: Utc::now(),
        })
        .await
        .expect("seed session");

        let active = coord.get_active_session_ids().await;
        assert!(active.contains(&session_id));
    }

    #[tokio::test]
    async fn reconcile_stale_keeps_workflow_agent_with_live_db_session() {
        let (state, db, project_id, _tempdir) = make_state_with_project().await;
        let (_, shutdown_rx) = tokio::sync::watch::channel(false);
        let ws = Arc::new(WorkflowStore::new(std::path::Path::new("/tmp/nonexistent")));
        let coord = AutomationCoordinator::new(state.clone(), ws, shutdown_rx);

        let task_id = Uuid::new_v4();
        let session_id = Uuid::new_v4();
        let run_id = Uuid::new_v4();
        let now = Utc::now();
        let project_path = {
            let current = state.current.lock().await;
            current
                .as_ref()
                .expect("project context")
                .project_path
                .clone()
        };
        let worktree_path = project_path
            .join(".pnevma/worktrees")
            .join(task_id.to_string());
        std::fs::create_dir_all(&worktree_path).expect("worktree dir");

        db.create_task(&TaskRow {
            id: task_id.to_string(),
            project_id: project_id.to_string(),
            title: "workflow step".to_string(),
            goal: "keep worktree alive".to_string(),
            scope_json: "[]".to_string(),
            dependencies_json: "[]".to_string(),
            acceptance_json: "[]".to_string(),
            constraints_json: "[]".to_string(),
            priority: "P1".to_string(),
            status: "InProgress".to_string(),
            branch: Some(format!("pnevma/{task_id}/workflow-step")),
            worktree_id: Some(task_id.to_string()),
            handoff_summary: None,
            created_at: now,
            updated_at: now,
            auto_dispatch: true,
            agent_profile_override: None,
            execution_mode: Some("worktree".to_string()),
            timeout_minutes: None,
            max_retries: None,
            loop_iteration: 0,
            loop_context_json: None,
        })
        .await
        .expect("task");
        db.upsert_worktree(&WorktreeRow {
            id: task_id.to_string(),
            project_id: project_id.to_string(),
            task_id: task_id.to_string(),
            path: worktree_path.to_string_lossy().to_string(),
            branch: format!("pnevma/{task_id}/workflow-step"),
            lease_status: "Active".to_string(),
            lease_started: now,
            last_active: now,
        })
        .await
        .expect("worktree");
        db.upsert_session(&SessionRow {
            id: session_id.to_string(),
            project_id: project_id.to_string(),
            name: "agent-workflow-step".to_string(),
            r#type: Some("agent".to_string()),
            status: "running".to_string(),
            pid: None,
            cwd: worktree_path.to_string_lossy().to_string(),
            command: "claude-code".to_string(),
            branch: Some(format!("pnevma/{task_id}/workflow-step")),
            worktree_id: Some(task_id.to_string()),
            started_at: now,
            last_heartbeat: now,
        })
        .await
        .expect("session");

        coord.claims.write().await.insert(
            task_id,
            TaskClaim {
                task_id,
                origin: DispatchOrigin::AutoDispatch,
                claimed_at: now,
                run_id,
            },
        );
        coord.running.write().await.insert(
            task_id,
            TrackedRun {
                run_id,
                task_id,
                origin: DispatchOrigin::AutoDispatch,
                state: RunState::Running {
                    session_id,
                    started_at: now,
                },
                event_task: Some(tokio::spawn(async move {
                    tokio::time::sleep(std::time::Duration::from_secs(60)).await;
                })),
                db_run_id: None,
                handle: None,
                adapter: None,
            },
        );

        coord.reconcile_stale().await;

        assert!(coord.claims.read().await.contains_key(&task_id));
        assert!(db
            .find_worktree_by_task(&task_id.to_string())
            .await
            .expect("worktree lookup")
            .is_some());
    }

    #[tokio::test]
    async fn max_concurrent_blocks_new_dispatch_when_full() {
        // Set up a WorkflowStore with enabled: true and max_concurrent: 3
        let dir = tempfile::tempdir().unwrap();
        let workflow_content =
            "---\nenabled: true\npoll_interval_seconds: 5\nmax_concurrent: 3\n---\n# Workflow\n";
        std::fs::write(dir.path().join("WORKFLOW.md"), workflow_content).unwrap();
        let ws = Arc::new(WorkflowStore::new(dir.path()));
        ws.load().await;

        let (_, shutdown_rx) = tokio::sync::watch::channel(false);
        let state = Arc::new(AppState::default());
        let coord = AutomationCoordinator::new(state, ws, shutdown_rx);

        // Fill running map to max_concurrent (3) with Preparing runs
        for _ in 0..3 {
            let task_id = Uuid::new_v4();
            coord.running.write().await.insert(
                task_id,
                TrackedRun {
                    run_id: Uuid::new_v4(),
                    task_id,
                    origin: DispatchOrigin::AutoDispatch,
                    state: RunState::Preparing,
                    event_task: None,
                    db_run_id: None,
                    handle: None,
                    adapter: None,
                },
            );
        }

        // Call tick() — should return early at the capacity gate without dispatching
        let dispatched_before = coord.stats.read().await.total_dispatched;
        coord.tick().await;
        let dispatched_after = coord.stats.read().await.total_dispatched;

        assert_eq!(
            dispatched_before, dispatched_after,
            "no new tasks should be dispatched when at max_concurrent capacity"
        );
    }

    #[tokio::test]
    async fn enqueue_retry_adds_to_queue() {
        let (_, shutdown_rx) = tokio::sync::watch::channel(false);
        let state = Arc::new(AppState::default());
        let ws = Arc::new(WorkflowStore::new(std::path::Path::new("/tmp/nonexistent")));

        let coord = AutomationCoordinator::new(state, ws, shutdown_rx);

        let entry = RetryEntry {
            run_id: Uuid::new_v4(),
            task_id: Uuid::new_v4(),
            attempt: 2,
            retry_after: Utc::now() + chrono::Duration::seconds(60),
            last_error: "test error".into(),
            db_retry_id: None,
        };

        coord.enqueue_retry(entry.clone()).await;

        let queue = coord.retry_queue.read().await;
        assert_eq!(queue.len(), 1);
        assert_eq!(queue[0].task_id, entry.task_id);
    }
}
