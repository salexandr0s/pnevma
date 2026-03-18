use crate::automation::coordinator::AutomationCoordinator;
use crate::automation::workflow_store::WorkflowStore;
use crate::control::ControlServerHandle;
use crate::event_emitter::{BroadcastingEmitter, EventEmitter, NullEmitter};
use pnevma_agents::{AdapterRegistry, DispatchPool};
use pnevma_core::{GlobalConfig, ProjectConfig};
use pnevma_db::{Db, GlobalDb};
use pnevma_git::GitService;
use pnevma_session::SessionSupervisor;
use pnevma_tracker::poll::TrackerCoordinator;
use serde::{Deserialize, Serialize};
use std::collections::HashMap;
use std::path::PathBuf;
use std::sync::Arc;
use std::time::{Duration, Instant};
use tokio::sync::{Mutex, RwLock};
use tokio::task::JoinHandle;
use uuid::Uuid;

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct RecentProject {
    pub id: String,
    pub name: String,
    pub path: String,
}

pub struct ProjectContext {
    pub project_id: Uuid,
    pub project_path: PathBuf,
    pub config: ProjectConfig,
    pub global_config: GlobalConfig,
    pub db: Db,
    pub sessions: SessionSupervisor,
    pub redaction_secrets: Arc<RwLock<Vec<String>>>,
    pub git: Arc<GitService>,
    pub adapters: AdapterRegistry,
    pub pool: Arc<DispatchPool>,
    pub tracker: Option<Arc<TrackerCoordinator>>,
    pub workflow_store: Arc<WorkflowStore>,
    pub coordinator: Option<Arc<AutomationCoordinator>>,
    pub shutdown_tx: tokio::sync::watch::Sender<bool>,
}

pub struct ProjectRuntime {
    session_bridge: JoinHandle<()>,
    health_refresh: JoinHandle<()>,
    coordinator_task: Option<JoinHandle<()>>,
}

impl ProjectRuntime {
    pub fn new(
        session_bridge: JoinHandle<()>,
        health_refresh: JoinHandle<()>,
        coordinator_task: Option<JoinHandle<()>>,
    ) -> Self {
        Self {
            session_bridge,
            health_refresh,
            coordinator_task,
        }
    }

    pub fn abort(self) {
        self.session_bridge.abort();
        self.health_refresh.abort();
        if let Some(task) = self.coordinator_task {
            task.abort();
        }
    }
}

pub struct ManagedService<T> {
    pub generation: u64,
    pub handle: T,
}

pub struct AppState {
    pub current: Mutex<Option<ProjectContext>>,
    pub current_runtime: Mutex<Option<ProjectRuntime>>,
    pub global_db: Option<GlobalDb>,
    pub recents: Mutex<Vec<RecentProject>>,
    pub control_plane: Mutex<Option<ManagedService<ControlServerHandle>>>,
    pub merge_branch_locks: Mutex<HashMap<String, Arc<tokio::sync::Mutex<()>>>>,
    pub remote_handle: Mutex<Option<ManagedService<pnevma_remote::RemoteServerHandle>>>,
    pub remote_events: tokio::sync::broadcast::Sender<pnevma_remote::RemoteEventEnvelope>,
    pub emitter: Arc<dyn EventEmitter>,
    /// Set immediately after Arc<AppState> is created so internal code can get a clone.
    pub self_arc: std::sync::OnceLock<Arc<AppState>>,
    /// Pending browser tool calls awaiting Swift-side completion.
    pub browser_tool_pending: crate::commands::browser_tools::BrowserToolPending,
}

const ACTIVE_PROJECT_LOCK_WARN_THRESHOLD: Duration = Duration::from_millis(50);

impl Default for AppState {
    fn default() -> Self {
        let (remote_events, _rx) = tokio::sync::broadcast::channel(2048);
        Self {
            current: Mutex::new(None),
            current_runtime: Mutex::new(None),
            global_db: None,
            recents: Mutex::new(Vec::new()),
            control_plane: Mutex::new(None),
            merge_branch_locks: Mutex::new(HashMap::new()),
            remote_handle: Mutex::new(None),
            remote_events,
            emitter: Arc::new(NullEmitter),
            self_arc: std::sync::OnceLock::new(),
            browser_tool_pending: crate::commands::browser_tools::new_browser_tool_pending(),
        }
    }
}

impl AppState {
    pub fn new(emitter: Arc<dyn EventEmitter>) -> Self {
        let (remote_events, _rx) = tokio::sync::broadcast::channel(2048);
        let emitter = Arc::new(BroadcastingEmitter::new(emitter, remote_events.clone()))
            as Arc<dyn EventEmitter>;
        Self {
            remote_events,
            emitter,
            ..Default::default()
        }
    }

    pub fn new_with_global_db(emitter: Arc<dyn EventEmitter>, global_db: GlobalDb) -> Self {
        let (remote_events, _rx) = tokio::sync::broadcast::channel(2048);
        let emitter = Arc::new(BroadcastingEmitter::new(emitter, remote_events.clone()))
            as Arc<dyn EventEmitter>;
        Self {
            global_db: Some(global_db),
            remote_events,
            emitter,
            ..Default::default()
        }
    }

    pub fn global_db(&self) -> Result<&GlobalDb, String> {
        self.global_db
            .as_ref()
            .ok_or_else(|| "global database not initialized".to_string())
    }

    /// Get a clone of the Arc<AppState> if it has been registered via set_self_arc.
    pub fn arc(&self) -> Option<Arc<AppState>> {
        self.self_arc.get().cloned()
    }

    async fn lock_current_project(
        &self,
        access: &'static str,
    ) -> tokio::sync::MutexGuard<'_, Option<ProjectContext>> {
        let started = Instant::now();
        let guard = self.current.lock().await;
        let waited = started.elapsed();
        if waited >= ACTIVE_PROJECT_LOCK_WARN_THRESHOLD {
            tracing::warn!(
                access,
                wait_ms = waited.as_millis() as u64,
                "slow active-project lock acquisition"
            );
        } else {
            tracing::trace!(
                access,
                wait_ms = waited.as_millis() as u64,
                "active-project lock acquired"
            );
        }
        guard
    }

    pub async fn with_project<T>(
        &self,
        access: &'static str,
        f: impl FnOnce(&ProjectContext) -> T,
    ) -> Result<T, String> {
        let guard = self.lock_current_project(access).await;
        let ctx = guard
            .as_ref()
            .ok_or_else(|| "no open project".to_string())?;
        Ok(f(ctx))
    }

    pub async fn with_project_mut<T>(
        &self,
        access: &'static str,
        f: impl FnOnce(&mut ProjectContext) -> T,
    ) -> Result<T, String> {
        let mut guard = self.lock_current_project(access).await;
        let ctx = guard
            .as_mut()
            .ok_or_else(|| "no open project".to_string())?;
        Ok(f(ctx))
    }

    pub async fn replace_current_project(
        &self,
        access: &'static str,
        next: ProjectContext,
    ) -> Option<ProjectContext> {
        let mut guard = self.lock_current_project(access).await;
        guard.replace(next)
    }

    pub async fn take_current_project(&self, access: &'static str) -> Option<ProjectContext> {
        let mut guard = self.lock_current_project(access).await;
        guard.take()
    }

    pub async fn has_open_project(&self, access: &'static str) -> bool {
        let guard = self.lock_current_project(access).await;
        guard.is_some()
    }
}
