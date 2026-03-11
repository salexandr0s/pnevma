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
    /// Allow the agent to skip permission prompts. Defaults to false.
    #[serde(default)]
    pub auto_approve: bool,
    /// Allow npm exec / npx access for auto-approved Claude sessions.
    #[serde(default)]
    pub allow_npx: bool,
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
    #[serde(default = "default_socket_rate_limit_rpm")]
    pub socket_rate_limit_rpm: u32,
    /// Enable automatic dispatch of Ready tasks when pool has capacity.
    #[serde(default)]
    pub auto_dispatch: bool,
    /// Interval in seconds between auto-dispatch checks.
    #[serde(default = "default_auto_dispatch_interval")]
    pub auto_dispatch_interval_seconds: u64,
    /// Allowed session commands. Defaults to common shells + agents.
    #[serde(default = "default_allowed_commands")]
    pub allowed_commands: Vec<String>,
}

fn default_allowed_commands() -> Vec<String> {
    ["zsh", "bash", "sh", "fish", "claude-code", "codex"]
        .iter()
        .map(|s| s.to_string())
        .collect()
}

impl Default for AutomationSection {
    fn default() -> Self {
        Self {
            socket_enabled: default_socket_enabled(),
            socket_path: default_socket_path(),
            socket_auth: default_socket_auth(),
            socket_rate_limit_rpm: default_socket_rate_limit_rpm(),
            auto_dispatch: false,
            auto_dispatch_interval_seconds: default_auto_dispatch_interval(),
            allowed_commands: default_allowed_commands(),
        }
    }
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct RetentionSection {
    #[serde(default)]
    pub enabled: bool,
    #[serde(default = "default_artifact_retention_days")]
    pub artifact_days: i64,
    #[serde(default = "default_review_retention_days")]
    pub review_days: i64,
    #[serde(default = "default_scrollback_retention_days")]
    pub scrollback_days: i64,
}

impl Default for RetentionSection {
    fn default() -> Self {
        Self {
            enabled: false,
            artifact_days: default_artifact_retention_days(),
            review_days: default_review_retention_days(),
            scrollback_days: default_scrollback_retention_days(),
        }
    }
}

#[derive(Debug, Clone, Serialize, Deserialize, Default)]
pub struct PathSection {
    #[serde(default)]
    pub paths: Vec<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
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
    /// Allowed CORS origins for remote access.
    #[serde(default)]
    pub allowed_origins: Vec<String>,
    /// Allow self-signed TLS certificate fallback when Tailscale certs are unavailable.
    #[serde(default)]
    pub tls_allow_self_signed_fallback: bool,
    /// Allow remote WebSocket clients to send terminal input to live sessions.
    #[serde(default)]
    pub allow_session_input: bool,
}

impl Default for RemoteSection {
    fn default() -> Self {
        Self {
            enabled: false,
            port: default_remote_port(),
            tls_mode: default_tls_mode(),
            token_ttl_hours: default_token_ttl(),
            rate_limit_rpm: default_rate_limit_rpm(),
            max_ws_per_ip: default_max_ws(),
            serve_frontend: default_serve_frontend(),
            allowed_origins: vec![],
            tls_allow_self_signed_fallback: false,
            allow_session_input: false,
        }
    }
}

#[derive(Debug, Clone, Serialize, Deserialize, Default)]
pub struct RedactionSection {
    #[serde(default)]
    pub extra_patterns: Vec<String>,
    #[serde(default)]
    pub enable_entropy_guard: bool,
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
pub struct TrackerSection {
    #[serde(default)]
    pub enabled: bool,
    #[serde(default = "default_tracker_kind")]
    pub kind: String,
    pub team_id: Option<String>,
    #[serde(default)]
    pub labels: Vec<String>,
    #[serde(default = "default_tracker_poll_interval")]
    pub poll_interval_seconds: u64,
    pub api_key_secret: Option<String>,
}

fn default_tracker_kind() -> String {
    "linear".to_string()
}
fn default_tracker_poll_interval() -> u64 {
    120
}

impl Default for TrackerSection {
    fn default() -> Self {
        Self {
            enabled: false,
            kind: default_tracker_kind(),
            team_id: None,
            labels: Vec::new(),
            poll_interval_seconds: default_tracker_poll_interval(),
            api_key_secret: None,
        }
    }
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ProjectConfig {
    pub project: ProjectSection,
    pub agents: AgentsSection,
    #[serde(default)]
    pub automation: AutomationSection,
    #[serde(default)]
    pub retention: RetentionSection,
    pub branches: BranchesSection,
    #[serde(default)]
    pub rules: PathSection,
    #[serde(default)]
    pub conventions: PathSection,
    #[serde(default)]
    pub remote: RemoteSection,
    #[serde(default)]
    pub redaction: RedactionSection,
    #[serde(default)]
    pub tracker: TrackerSection,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct GlobalConfig {
    #[serde(default)]
    pub default_provider: Option<String>,
    #[serde(default)]
    pub theme: Option<String>,
    #[serde(default)]
    pub telemetry_opt_in: bool,
    #[serde(default)]
    pub crash_reports_opt_in: bool,
    #[serde(default)]
    pub socket_auth_mode: Option<String>,
    #[serde(default)]
    pub socket_password_file: Option<String>,
    #[serde(default)]
    pub keybindings: HashMap<String, String>,
    #[serde(default = "default_global_auto_save_workspace_on_quit")]
    pub auto_save_workspace_on_quit: bool,
    #[serde(default = "default_global_restore_windows_on_launch")]
    pub restore_windows_on_launch: bool,
    #[serde(default = "default_global_auto_update")]
    pub auto_update: bool,
    #[serde(default)]
    pub default_shell: Option<String>,
    #[serde(default = "default_global_terminal_font")]
    pub terminal_font: String,
    #[serde(default = "default_global_terminal_font_size")]
    pub terminal_font_size: u32,
    #[serde(default = "default_global_scrollback_lines")]
    pub scrollback_lines: u32,
    #[serde(default = "default_global_sidebar_background_offset")]
    pub sidebar_background_offset: f64,
    #[serde(default = "default_global_focus_border_enabled")]
    pub focus_border_enabled: bool,
    #[serde(default = "default_global_focus_border_opacity")]
    pub focus_border_opacity: f64,
    #[serde(default = "default_global_focus_border_width")]
    pub focus_border_width: f64,
    #[serde(default)]
    pub focus_border_color: Option<String>,
    #[serde(default)]
    pub usage_providers: UsageProvidersConfig,
}

impl Default for GlobalConfig {
    fn default() -> Self {
        Self {
            default_provider: None,
            theme: None,
            telemetry_opt_in: false,
            crash_reports_opt_in: false,
            socket_auth_mode: None,
            socket_password_file: None,
            keybindings: HashMap::new(),
            auto_save_workspace_on_quit: default_global_auto_save_workspace_on_quit(),
            restore_windows_on_launch: default_global_restore_windows_on_launch(),
            auto_update: default_global_auto_update(),
            default_shell: None,
            terminal_font: default_global_terminal_font(),
            terminal_font_size: default_global_terminal_font_size(),
            scrollback_lines: default_global_scrollback_lines(),
            sidebar_background_offset: default_global_sidebar_background_offset(),
            focus_border_enabled: default_global_focus_border_enabled(),
            focus_border_opacity: default_global_focus_border_opacity(),
            focus_border_width: default_global_focus_border_width(),
            focus_border_color: None,
            usage_providers: UsageProvidersConfig::default(),
        }
    }
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct UsageProvidersConfig {
    #[serde(default = "default_usage_refresh_interval_seconds")]
    pub refresh_interval_seconds: u64,
    #[serde(default)]
    pub codex: UsageProviderConfig,
    #[serde(default)]
    pub claude: UsageProviderConfig,
}

impl Default for UsageProvidersConfig {
    fn default() -> Self {
        Self {
            refresh_interval_seconds: default_usage_refresh_interval_seconds(),
            codex: UsageProviderConfig::default(),
            claude: UsageProviderConfig::default(),
        }
    }
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct UsageProviderConfig {
    #[serde(default = "default_usage_provider_source")]
    pub source: String,
    #[serde(default)]
    pub web_extras_enabled: bool,
    #[serde(default = "default_usage_keychain_prompt_policy")]
    pub keychain_prompt_policy: String,
}

impl Default for UsageProviderConfig {
    fn default() -> Self {
        Self {
            source: default_usage_provider_source(),
            web_extras_enabled: false,
            keychain_prompt_policy: default_usage_keychain_prompt_policy(),
        }
    }
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

fn default_socket_rate_limit_rpm() -> u32 {
    300
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

fn default_artifact_retention_days() -> i64 {
    30
}

fn default_review_retention_days() -> i64 {
    30
}

fn default_scrollback_retention_days() -> i64 {
    14
}

fn default_global_auto_save_workspace_on_quit() -> bool {
    true
}

fn default_global_restore_windows_on_launch() -> bool {
    true
}

fn default_global_auto_update() -> bool {
    true
}

fn default_global_terminal_font() -> String {
    "SF Mono".to_string()
}

fn default_global_terminal_font_size() -> u32 {
    13
}

fn default_global_scrollback_lines() -> u32 {
    10_000
}

fn default_global_sidebar_background_offset() -> f64 {
    0.05
}

fn default_global_focus_border_enabled() -> bool {
    true
}

fn default_global_focus_border_opacity() -> f64 {
    0.4
}

fn default_global_focus_border_width() -> f64 {
    2.0
}

fn default_usage_refresh_interval_seconds() -> u64 {
    120
}

fn default_usage_provider_source() -> String {
    "auto".to_string()
}

fn default_usage_keychain_prompt_policy() -> String {
    "user_action".to_string()
}

fn looks_like_valid_origin(origin: &str) -> bool {
    let trimmed = origin.trim();
    if trimmed.is_empty() || trimmed.contains('?') || trimmed.contains('#') {
        return false;
    }

    let Some((scheme, remainder)) = trimmed.split_once("://") else {
        return false;
    };
    if scheme != "http" && scheme != "https" {
        return false;
    }

    let remainder = remainder.strip_suffix('/').unwrap_or(remainder);
    !remainder.is_empty() && !remainder.contains('/') && !remainder.contains('@')
}

fn looks_like_hex_color(color: &str) -> bool {
    let trimmed = color.trim();
    let raw = trimmed.strip_prefix('#').unwrap_or(trimmed);
    raw.len() == 6 && raw.chars().all(|ch| ch.is_ascii_hexdigit())
}

fn validate_project_config(cfg: &ProjectConfig) -> Result<(), CoreError> {
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
    if cfg.automation.socket_rate_limit_rpm == 0 {
        return Err(CoreError::InvalidConfig(
            "automation.socket_rate_limit_rpm must be greater than 0".to_string(),
        ));
    }
    if cfg.retention.artifact_days <= 0 {
        return Err(CoreError::InvalidConfig(
            "retention.artifact_days must be greater than 0".to_string(),
        ));
    }
    if cfg.retention.review_days <= 0 {
        return Err(CoreError::InvalidConfig(
            "retention.review_days must be greater than 0".to_string(),
        ));
    }
    if cfg.retention.scrollback_days <= 0 {
        return Err(CoreError::InvalidConfig(
            "retention.scrollback_days must be greater than 0".to_string(),
        ));
    }
    if cfg.remote.tls_mode != "tailscale" && cfg.remote.tls_mode != "self-signed" {
        return Err(CoreError::InvalidConfig(
            "remote.tls_mode must be either 'tailscale' or 'self-signed'".to_string(),
        ));
    }
    if cfg.remote.token_ttl_hours == 0 {
        return Err(CoreError::InvalidConfig(
            "remote.token_ttl_hours must be greater than 0".to_string(),
        ));
    }
    if cfg.remote.rate_limit_rpm == 0 {
        return Err(CoreError::InvalidConfig(
            "remote.rate_limit_rpm must be greater than 0".to_string(),
        ));
    }
    if cfg.remote.max_ws_per_ip == 0 {
        return Err(CoreError::InvalidConfig(
            "remote.max_ws_per_ip must be greater than 0".to_string(),
        ));
    }
    if cfg.remote.tls_allow_self_signed_fallback && cfg.remote.tls_mode != "tailscale" {
        return Err(CoreError::InvalidConfig(
            "remote.tls_allow_self_signed_fallback is only valid when remote.tls_mode = 'tailscale'"
                .to_string(),
        ));
    }
    for origin in &cfg.remote.allowed_origins {
        if !looks_like_valid_origin(origin) {
            return Err(CoreError::InvalidConfig(format!(
                "remote.allowed_origins contains an invalid origin: {origin}"
            )));
        }
    }
    for pattern in &cfg.redaction.extra_patterns {
        regex::Regex::new(pattern).map_err(|err| {
            CoreError::InvalidConfig(format!(
                "redaction.extra_patterns contains an invalid regex {pattern:?}: {err}"
            ))
        })?;
    }
    Ok(())
}

fn validate_global_config(cfg: &GlobalConfig) -> Result<(), CoreError> {
    if let Some(mode) = &cfg.socket_auth_mode {
        if mode != "same-user" && mode != "password" {
            return Err(CoreError::InvalidConfig(
                "socket_auth_mode must be either 'same-user' or 'password'".to_string(),
            ));
        }
    }

    if let Some(path) = &cfg.socket_password_file {
        if path.trim().is_empty() {
            return Err(CoreError::InvalidConfig(
                "socket_password_file must not be empty".to_string(),
            ));
        }
    }

    if let Some(shell) = &cfg.default_shell {
        if shell.trim().is_empty() {
            return Err(CoreError::InvalidConfig(
                "default_shell must not be empty when set".to_string(),
            ));
        }
        if shell.len() > 256 {
            return Err(CoreError::InvalidConfig(
                "default_shell exceeds 256 characters".to_string(),
            ));
        }
        if shell.chars().any(|ch| ch == '\0' || ch.is_control()) {
            return Err(CoreError::InvalidConfig(
                "default_shell contains unsafe control characters".to_string(),
            ));
        }
    }

    if cfg.terminal_font.trim().is_empty() {
        return Err(CoreError::InvalidConfig(
            "terminal_font must not be empty".to_string(),
        ));
    }
    if cfg.terminal_font.len() > 128 {
        return Err(CoreError::InvalidConfig(
            "terminal_font exceeds 128 characters".to_string(),
        ));
    }
    if cfg
        .terminal_font
        .chars()
        .any(|ch| ch == '\0' || ch.is_control())
    {
        return Err(CoreError::InvalidConfig(
            "terminal_font contains unsafe control characters".to_string(),
        ));
    }

    if !(8..=32).contains(&cfg.terminal_font_size) {
        return Err(CoreError::InvalidConfig(
            "terminal_font_size must be between 8 and 32".to_string(),
        ));
    }

    if !(1_000..=100_000).contains(&cfg.scrollback_lines) {
        return Err(CoreError::InvalidConfig(
            "scrollback_lines must be between 1000 and 100000".to_string(),
        ));
    }

    if !(0.0..=0.3).contains(&cfg.sidebar_background_offset) {
        return Err(CoreError::InvalidConfig(
            "sidebar_background_offset must be between 0.0 and 0.3".to_string(),
        ));
    }

    if !(0.1..=1.0).contains(&cfg.focus_border_opacity) {
        return Err(CoreError::InvalidConfig(
            "focus_border_opacity must be between 0.1 and 1.0".to_string(),
        ));
    }

    if !(1.0..=6.0).contains(&cfg.focus_border_width) {
        return Err(CoreError::InvalidConfig(
            "focus_border_width must be between 1.0 and 6.0".to_string(),
        ));
    }

    if let Some(color) = &cfg.focus_border_color {
        if !color.trim().is_empty() && color != "accent" && !looks_like_hex_color(color) {
            return Err(CoreError::InvalidConfig(
                "focus_border_color must be 'accent' or a #RRGGBB hex value".to_string(),
            ));
        }
    }

    if !(30..=900).contains(&cfg.usage_providers.refresh_interval_seconds) {
        return Err(CoreError::InvalidConfig(
            "usage_providers.refresh_interval_seconds must be between 30 and 900".to_string(),
        ));
    }

    validate_usage_provider_config(&cfg.usage_providers.codex, "usage_providers.codex")?;
    validate_usage_provider_config(&cfg.usage_providers.claude, "usage_providers.claude")?;

    Ok(())
}

fn validate_usage_provider_config(cfg: &UsageProviderConfig, label: &str) -> Result<(), CoreError> {
    if cfg.source != "auto" && cfg.source != "cli" && cfg.source != "oauth" && cfg.source != "local"
    {
        return Err(CoreError::InvalidConfig(format!(
            "{label}.source must be one of auto, cli, oauth, or local"
        )));
    }

    if cfg.keychain_prompt_policy != "never"
        && cfg.keychain_prompt_policy != "user_action"
        && cfg.keychain_prompt_policy != "always"
    {
        return Err(CoreError::InvalidConfig(format!(
            "{label}.keychain_prompt_policy must be one of never, user_action, or always"
        )));
    }

    Ok(())
}

pub fn load_project_config(path: &Path) -> Result<ProjectConfig, CoreError> {
    let raw = fs::read_to_string(path)?;
    let cfg: ProjectConfig = toml::from_str(&raw)
        .map_err(|e| CoreError::Serialization(format!("invalid project config TOML: {e}")))?;
    validate_project_config(&cfg)?;
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
    validate_global_config(&cfg)?;
    Ok(cfg)
}

pub fn global_config_path() -> PathBuf {
    let base = std::env::var("HOME")
        .map(PathBuf::from)
        .unwrap_or_else(|_| PathBuf::from("."));
    base.join(".config/pnevma/config.toml")
}

pub fn save_global_config(config: &GlobalConfig) -> Result<(), CoreError> {
    validate_global_config(config)?;
    let path = global_config_path();
    if let Some(parent) = path.parent() {
        fs::create_dir_all(parent)?;
    }
    let encoded = toml::to_string_pretty(config)
        .map_err(|e| CoreError::Serialization(format!("failed to encode global config: {e}")))?;
    fs::write(path, encoded)?;
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn automation_default_includes_allowed_commands() {
        let auto = AutomationSection::default();
        assert!(auto.allowed_commands.contains(&"zsh".to_string()));
        assert!(auto.allowed_commands.contains(&"bash".to_string()));
        assert!(auto.allowed_commands.contains(&"claude-code".to_string()));
        assert!(!auto.allowed_commands.contains(&"curl".to_string()));
    }

    fn valid_project_config() -> ProjectConfig {
        ProjectConfig {
            project: ProjectSection {
                name: "demo".to_string(),
                brief: "demo".to_string(),
            },
            agents: AgentsSection {
                default_provider: "codex".to_string(),
                max_concurrent: 1,
                claude_code: None,
                codex: None,
            },
            automation: AutomationSection::default(),
            retention: RetentionSection::default(),
            branches: BranchesSection {
                target: "main".to_string(),
                naming: "pnevma/{task_id}/{slug}".to_string(),
            },
            rules: PathSection::default(),
            conventions: PathSection::default(),
            remote: RemoteSection::default(),
            redaction: RedactionSection::default(),
            tracker: TrackerSection::default(),
        }
    }

    #[test]
    fn remote_tls_mode_must_be_supported() {
        let mut cfg = valid_project_config();
        cfg.remote.tls_mode = "invalid".to_string();
        let err = validate_project_config(&cfg).expect_err("invalid tls mode");
        assert!(err.to_string().contains("remote.tls_mode"));
    }

    #[test]
    fn remote_allowed_origin_must_be_valid() {
        let mut cfg = valid_project_config();
        cfg.remote.allowed_origins = vec!["https://example.com/path".to_string()];
        let err = validate_project_config(&cfg).expect_err("invalid origin");
        assert!(err.to_string().contains("remote.allowed_origins"));
    }

    #[test]
    fn remote_self_signed_fallback_requires_tailscale_mode() {
        let mut cfg = valid_project_config();
        cfg.remote.tls_mode = "self-signed".to_string();
        cfg.remote.tls_allow_self_signed_fallback = true;
        let err = validate_project_config(&cfg).expect_err("invalid fallback combination");
        assert!(err.to_string().contains("tls_allow_self_signed_fallback"));
    }

    #[test]
    fn retention_days_must_be_positive() {
        let mut cfg = valid_project_config();
        cfg.retention.review_days = 0;
        let err = validate_project_config(&cfg).expect_err("invalid retention days");
        assert!(err.to_string().contains("retention.review_days"));
    }

    #[test]
    fn automation_socket_rate_limit_must_be_positive() {
        let mut cfg = valid_project_config();
        cfg.automation.socket_rate_limit_rpm = 0;
        let err = validate_project_config(&cfg).expect_err("invalid socket rate limit");
        assert!(err.to_string().contains("automation.socket_rate_limit_rpm"));
    }

    #[test]
    fn redaction_extra_patterns_must_compile() {
        let mut cfg = valid_project_config();
        cfg.redaction.extra_patterns = vec!["[".to_string()];
        let err = validate_project_config(&cfg).expect_err("invalid regex");
        assert!(err.to_string().contains("redaction.extra_patterns"));
    }

    #[test]
    fn origin_validator_accepts_host_port_and_trailing_slash() {
        assert!(looks_like_valid_origin("https://localhost:8443"));
        assert!(looks_like_valid_origin("https://localhost:8443/"));
        assert!(looks_like_valid_origin("http://[::1]:8443"));
    }

    #[test]
    fn global_socket_auth_mode_must_be_supported() {
        let cfg = GlobalConfig {
            socket_auth_mode: Some("invalid".to_string()),
            ..GlobalConfig::default()
        };
        let err = validate_global_config(&cfg).expect_err("invalid socket auth mode");
        assert!(err.to_string().contains("socket_auth_mode"));
    }

    #[test]
    fn global_socket_password_file_must_not_be_empty() {
        let cfg = GlobalConfig {
            socket_password_file: Some("   ".to_string()),
            ..GlobalConfig::default()
        };
        let err = validate_global_config(&cfg).expect_err("empty socket password file");
        assert!(err.to_string().contains("socket_password_file"));
    }

    #[test]
    fn global_terminal_settings_must_be_in_range() {
        let cfg = GlobalConfig {
            terminal_font_size: 40,
            ..GlobalConfig::default()
        };
        let err = validate_global_config(&cfg).expect_err("invalid terminal font size");
        assert!(err.to_string().contains("terminal_font_size"));

        let cfg = GlobalConfig {
            scrollback_lines: 500,
            ..GlobalConfig::default()
        };
        let err = validate_global_config(&cfg).expect_err("invalid scrollback lines");
        assert!(err.to_string().contains("scrollback_lines"));
    }

    #[test]
    fn global_visual_settings_must_be_in_range() {
        let cfg = GlobalConfig {
            sidebar_background_offset: 0.5,
            ..GlobalConfig::default()
        };
        let err = validate_global_config(&cfg).expect_err("invalid sidebar offset");
        assert!(err.to_string().contains("sidebar_background_offset"));

        let cfg = GlobalConfig {
            focus_border_opacity: 0.05,
            ..GlobalConfig::default()
        };
        let err = validate_global_config(&cfg).expect_err("invalid focus border opacity");
        assert!(err.to_string().contains("focus_border_opacity"));

        let cfg = GlobalConfig {
            focus_border_width: 9.0,
            ..GlobalConfig::default()
        };
        let err = validate_global_config(&cfg).expect_err("invalid focus border width");
        assert!(err.to_string().contains("focus_border_width"));
    }

    #[test]
    fn global_focus_border_color_must_be_valid() {
        let cfg = GlobalConfig {
            focus_border_color: Some("blue".to_string()),
            ..GlobalConfig::default()
        };
        let err = validate_global_config(&cfg).expect_err("invalid focus border color");
        assert!(err.to_string().contains("focus_border_color"));

        let valid = GlobalConfig {
            focus_border_color: Some("#A1B2C3".to_string()),
            ..GlobalConfig::default()
        };
        validate_global_config(&valid).expect("hex color should be allowed");
    }

    #[test]
    fn global_default_shell_must_be_safe() {
        let cfg = GlobalConfig {
            default_shell: Some("   ".to_string()),
            ..GlobalConfig::default()
        };
        let err = validate_global_config(&cfg).expect_err("blank shell");
        assert!(err.to_string().contains("default_shell"));
    }
}
