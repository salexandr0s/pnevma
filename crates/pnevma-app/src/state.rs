use crate::control::ControlServerHandle;
use pnevma_agents::{AdapterRegistry, DispatchPool};
use pnevma_core::{GlobalConfig, ProjectConfig};
use pnevma_db::Db;
use pnevma_git::GitService;
use pnevma_session::SessionSupervisor;
use serde::{Deserialize, Serialize};
use std::collections::HashMap;
use std::path::PathBuf;
use std::sync::Arc;
use tokio::sync::Mutex;
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
    pub git: Arc<GitService>,
    pub adapters: AdapterRegistry,
    pub pool: Arc<DispatchPool>,
}

#[derive(Default)]
pub struct AppState {
    pub current: Mutex<Option<ProjectContext>>,
    pub recents: Mutex<Vec<RecentProject>>,
    pub control_plane: Mutex<Option<ControlServerHandle>>,
    pub merge_branch_locks: Mutex<HashMap<String, Arc<tokio::sync::Mutex<()>>>>,
}
