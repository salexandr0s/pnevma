use crate::control::ControlServerHandle;
use crate::event_emitter::{BroadcastingEmitter, EventEmitter, NullEmitter};
use pnevma_agents::{AdapterRegistry, DispatchPool};
use pnevma_core::{GlobalConfig, ProjectConfig};
use pnevma_db::Db;
use pnevma_git::GitService;
use pnevma_session::SessionSupervisor;
use serde::{Deserialize, Serialize};
use std::collections::HashMap;
use std::path::PathBuf;
use std::sync::Arc;
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
}

pub struct ProjectRuntime {
    session_bridge: JoinHandle<()>,
    health_refresh: JoinHandle<()>,
}

impl ProjectRuntime {
    pub fn new(session_bridge: JoinHandle<()>, health_refresh: JoinHandle<()>) -> Self {
        Self {
            session_bridge,
            health_refresh,
        }
    }

    pub fn abort(self) {
        self.session_bridge.abort();
        self.health_refresh.abort();
    }
}

pub struct AppState {
    pub current: Mutex<Option<ProjectContext>>,
    pub current_runtime: Mutex<Option<ProjectRuntime>>,
    pub recents: Mutex<Vec<RecentProject>>,
    pub control_plane: Mutex<Option<ControlServerHandle>>,
    pub merge_branch_locks: Mutex<HashMap<String, Arc<tokio::sync::Mutex<()>>>>,
    pub remote_handle: Mutex<Option<pnevma_remote::RemoteServerHandle>>,
    pub remote_events: tokio::sync::broadcast::Sender<pnevma_remote::RemoteEventEnvelope>,
    pub emitter: Arc<dyn EventEmitter>,
}

impl Default for AppState {
    fn default() -> Self {
        let (remote_events, _rx) = tokio::sync::broadcast::channel(2048);
        Self {
            current: Mutex::new(None),
            current_runtime: Mutex::new(None),
            recents: Mutex::new(Vec::new()),
            control_plane: Mutex::new(None),
            merge_branch_locks: Mutex::new(HashMap::new()),
            remote_handle: Mutex::new(None),
            remote_events,
            emitter: Arc::new(NullEmitter),
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
}
