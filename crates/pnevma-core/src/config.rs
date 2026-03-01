use crate::CoreError;
use serde::{Deserialize, Serialize};
use std::fs;
use std::path::{Path, PathBuf};

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ProjectSection {
    pub name: String,
    pub brief: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct AgentProviderConfig {
    #[serde(default)]
    pub model: Option<String>,
    pub token_budget: usize,
    pub timeout_minutes: u64,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct AgentsSection {
    pub default_provider: String,
    #[serde(default = "default_max_concurrent")]
    pub max_concurrent: usize,
    #[serde(rename = "claude-code")]
    #[serde(default)]
    pub claude_code: Option<AgentProviderConfig>,
    #[serde(default)]
    pub codex: Option<AgentProviderConfig>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct BranchesSection {
    #[serde(default = "default_branch")]
    pub target: String,
    pub naming: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct AutomationSection {
    #[serde(default = "default_socket_enabled")]
    pub socket_enabled: bool,
    #[serde(default = "default_socket_path")]
    pub socket_path: String,
    #[serde(default = "default_socket_auth")]
    pub socket_auth: String,
}

impl Default for AutomationSection {
    fn default() -> Self {
        Self {
            socket_enabled: default_socket_enabled(),
            socket_path: default_socket_path(),
            socket_auth: default_socket_auth(),
        }
    }
}

#[derive(Debug, Clone, Serialize, Deserialize, Default)]
pub struct PathSection {
    #[serde(default)]
    pub paths: Vec<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ProjectConfig {
    pub project: ProjectSection,
    pub agents: AgentsSection,
    #[serde(default)]
    pub automation: AutomationSection,
    pub branches: BranchesSection,
    #[serde(default)]
    pub rules: PathSection,
    #[serde(default)]
    pub conventions: PathSection,
}

#[derive(Debug, Clone, Serialize, Deserialize, Default)]
pub struct GlobalConfig {
    #[serde(default)]
    pub default_provider: Option<String>,
    #[serde(default)]
    pub theme: Option<String>,
    #[serde(default)]
    pub telemetry_opt_in: bool,
    #[serde(default)]
    pub socket_auth_mode: Option<String>,
    #[serde(default)]
    pub socket_password_file: Option<String>,
}

fn default_branch() -> String {
    "main".to_string()
}

fn default_socket_path() -> String {
    ".pnevma/run/control.sock".to_string()
}

fn default_socket_auth() -> String {
    "same-user".to_string()
}

fn default_socket_enabled() -> bool {
    true
}

fn default_max_concurrent() -> usize {
    4
}

pub fn load_project_config(path: &Path) -> Result<ProjectConfig, CoreError> {
    let raw = fs::read_to_string(path)?;
    let cfg: ProjectConfig = toml::from_str(&raw)
        .map_err(|e| CoreError::Serialization(format!("invalid project config TOML: {e}")))?;

    if cfg.project.name.trim().is_empty() {
        return Err(CoreError::InvalidConfig(
            "project.name is required".to_string(),
        ));
    }
    if cfg.project.brief.trim().is_empty() {
        return Err(CoreError::InvalidConfig(
            "project.brief is required".to_string(),
        ));
    }
    if cfg.agents.default_provider.trim().is_empty() {
        return Err(CoreError::InvalidConfig(
            "agents.default_provider is required".to_string(),
        ));
    }
    if cfg.agents.max_concurrent == 0 {
        return Err(CoreError::InvalidConfig(
            "agents.max_concurrent must be greater than 0".to_string(),
        ));
    }
    if cfg.automation.socket_auth != "same-user" && cfg.automation.socket_auth != "password" {
        return Err(CoreError::InvalidConfig(
            "automation.socket_auth must be either 'same-user' or 'password'".to_string(),
        ));
    }
    if cfg.automation.socket_path.trim().is_empty() {
        return Err(CoreError::InvalidConfig(
            "automation.socket_path must not be empty".to_string(),
        ));
    }

    Ok(cfg)
}

pub fn load_global_config() -> Result<GlobalConfig, CoreError> {
    let base = std::env::var("HOME")
        .map(PathBuf::from)
        .unwrap_or_else(|_| PathBuf::from("."));
    let path = base.join(".config/pnevma/config.toml");

    if !path.exists() {
        return Ok(GlobalConfig::default());
    }

    let raw = fs::read_to_string(path)?;
    let cfg: GlobalConfig = toml::from_str(&raw)
        .map_err(|e| CoreError::Serialization(format!("invalid global config TOML: {e}")))?;
    Ok(cfg)
}
