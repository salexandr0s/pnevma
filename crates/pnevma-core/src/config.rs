use crate::CoreError;
use serde::{Deserialize, Serialize};
use std::collections::HashMap;
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
    /// Enable automatic dispatch of Ready tasks when pool has capacity.
    #[serde(default)]
    pub auto_dispatch: bool,
    /// Interval in seconds between auto-dispatch checks.
    #[serde(default = "default_auto_dispatch_interval")]
    pub auto_dispatch_interval_seconds: u64,
}

impl Default for AutomationSection {
    fn default() -> Self {
        Self {
            socket_enabled: default_socket_enabled(),
            socket_path: default_socket_path(),
            socket_auth: default_socket_auth(),
            auto_dispatch: false,
            auto_dispatch_interval_seconds: default_auto_dispatch_interval(),
        }
    }
}

#[derive(Debug, Clone, Serialize, Deserialize, Default)]
pub struct PathSection {
    #[serde(default)]
    pub paths: Vec<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize, Default)]
pub struct RemoteSection {
    /// Enable remote access via Tailscale. Off by default.
    #[serde(default)]
    pub enabled: bool,
    /// HTTPS port for remote access.
    #[serde(default = "default_remote_port")]
    pub port: u16,
    /// TLS mode: "tailscale" or "self-signed".
    #[serde(default = "default_tls_mode")]
    pub tls_mode: String,
    /// Token TTL in hours.
    #[serde(default = "default_token_ttl")]
    pub token_ttl_hours: u64,
    /// API rate limit (requests per minute).
    #[serde(default = "default_rate_limit_rpm")]
    pub rate_limit_rpm: u32,
    /// Max WebSocket connections per IP.
    #[serde(default = "default_max_ws")]
    pub max_ws_per_ip: usize,
    /// Serve built frontend SPA.
    #[serde(default = "default_serve_frontend")]
    pub serve_frontend: bool,
}

fn default_remote_port() -> u16 {
    8443
}
fn default_tls_mode() -> String {
    "tailscale".to_string()
}
fn default_token_ttl() -> u64 {
    24
}
fn default_rate_limit_rpm() -> u32 {
    60
}
fn default_max_ws() -> usize {
    2
}
fn default_serve_frontend() -> bool {
    true
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
    #[serde(default)]
    pub remote: RemoteSection,
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
    #[serde(default)]
    pub keybindings: HashMap<String, String>,
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

fn default_auto_dispatch_interval() -> u64 {
    30
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
    let path = global_config_path();

    if !path.exists() {
        return Ok(GlobalConfig::default());
    }

    let raw = fs::read_to_string(path)?;
    let cfg: GlobalConfig = toml::from_str(&raw)
        .map_err(|e| CoreError::Serialization(format!("invalid global config TOML: {e}")))?;
    Ok(cfg)
}

pub fn global_config_path() -> PathBuf {
    let base = std::env::var("HOME")
        .map(PathBuf::from)
        .unwrap_or_else(|_| PathBuf::from("."));
    base.join(".config/pnevma/config.toml")
}

pub fn save_global_config(config: &GlobalConfig) -> Result<(), CoreError> {
    let path = global_config_path();
    if let Some(parent) = path.parent() {
        fs::create_dir_all(parent)?;
    }
    let encoded = toml::to_string_pretty(config)
        .map_err(|e| CoreError::Serialization(format!("failed to encode global config: {e}")))?;
    fs::write(path, encoded)?;
    Ok(())
}
