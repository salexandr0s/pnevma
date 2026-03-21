use std::path::PathBuf;

use chrono::{DateTime, Utc};
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};

use crate::error::SshError;

/// SSH keepalive mode determines how aggressively dead connections are detected.
#[derive(Debug, Clone, Copy, Default)]
pub enum SshKeepAliveMode {
    /// 10s interval, 2 max → 20s detection. For interactive attach sessions.
    Interactive,
    /// 30s interval, 3 max → 90s detection. For background operations.
    #[default]
    Background,
}

const KEEPALIVE_INTERACTIVE_INTERVAL: u32 = 10;
const KEEPALIVE_INTERACTIVE_COUNT: u32 = 2;
const KEEPALIVE_BACKGROUND_INTERVAL: u32 = 30;
const KEEPALIVE_BACKGROUND_COUNT: u32 = 3;

const CONTROL_SOCKET_DIR: &str = ".pnevma/ssh/control";
const CONTROL_PERSIST_SECS: u32 = 60;

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct SshProfile {
    pub id: String,
    pub name: String,
    pub host: String,
    pub port: u16,
    pub user: Option<String>,
    pub identity_file: Option<String>,
    pub proxy_jump: Option<String>,
    pub tags: Vec<String>,
    pub source: String,
    pub created_at: DateTime<Utc>,
    pub updated_at: DateTime<Utc>,
    /// Enable OpenSSH ControlMaster connection multiplexing.
    /// `None` and `Some(true)` both enable it; `Some(false)` disables it.
    #[serde(default)]
    pub use_control_master: Option<bool>,
}

impl SshProfile {
    pub fn new(
        name: impl Into<String>,
        host: impl Into<String>,
        source: impl Into<String>,
    ) -> Result<Self, SshError> {
        let host = host.into();
        validate_hostname(&host)?;
        let now = Utc::now();
        Ok(Self {
            id: uuid::Uuid::new_v4().to_string(),
            name: name.into(),
            host,
            port: 22,
            user: None,
            identity_file: None,
            proxy_jump: None,
            tags: vec![],
            source: source.into(),
            created_at: now,
            updated_at: now,
            use_control_master: None,
        })
    }
}

/// Validates that a string contains no control characters or null bytes.
fn has_no_control_chars(s: &str) -> bool {
    !s.contains('\0') && !s.chars().any(|c| c.is_control())
}

pub fn validate_hostname(host: &str) -> Result<(), SshError> {
    if host.is_empty() {
        return Err(SshError::Parse("hostname must not be empty".to_string()));
    }
    if host.len() > 256 {
        return Err(SshError::Parse(
            "hostname must not exceed 256 characters".to_string(),
        ));
    }
    if host.chars().any(|c| c.is_whitespace()) {
        return Err(SshError::Parse(
            "hostname must not contain whitespace".to_string(),
        ));
    }
    if !has_no_control_chars(host) {
        return Err(SshError::Parse(
            "hostname must not contain control characters or null bytes".to_string(),
        ));
    }
    if !host
        .chars()
        .all(|c| c.is_alphanumeric() || matches!(c, '-' | '.' | ':' | '@' | '[' | ']' | '_'))
    {
        return Err(SshError::Parse(format!(
            "hostname contains invalid characters: {host}"
        )));
    }
    Ok(())
}

pub fn validate_username(user: &str) -> Result<(), SshError> {
    if user.is_empty() {
        return Err(SshError::Parse("username must not be empty".to_string()));
    }
    if user.len() > 256 {
        return Err(SshError::Parse(
            "username must not exceed 256 characters".to_string(),
        ));
    }
    if user.contains('/') || user.contains('\\') || user.contains("..") {
        return Err(SshError::Parse(
            "username must not contain '/', '\\', or '..'".to_string(),
        ));
    }
    if user.chars().any(|c| c.is_whitespace()) {
        return Err(SshError::Parse(
            "username must not contain whitespace".to_string(),
        ));
    }
    if !has_no_control_chars(user) {
        return Err(SshError::Parse(
            "username must not contain control characters or null bytes".to_string(),
        ));
    }
    Ok(())
}

pub fn validate_identity_path(path: &str) -> Result<(), SshError> {
    if path.is_empty() {
        return Err(SshError::Parse(
            "identity path must not be empty".to_string(),
        ));
    }
    if path.len() > 1024 {
        return Err(SshError::Parse(
            "identity path must not exceed 1024 characters".to_string(),
        ));
    }
    if !has_no_control_chars(path) {
        return Err(SshError::Parse(
            "identity path must not contain control characters or null bytes".to_string(),
        ));
    }
    Ok(())
}

pub fn validate_proxy_jump(pj: &str) -> Result<(), SshError> {
    if pj.is_empty() {
        return Err(SshError::Parse("proxy jump must not be empty".to_string()));
    }
    if pj.len() > 256 {
        return Err(SshError::Parse(
            "proxy jump must not exceed 256 characters".to_string(),
        ));
    }
    if pj.chars().any(|c| c.is_whitespace()) {
        return Err(SshError::Parse(
            "proxy jump must not contain whitespace".to_string(),
        ));
    }
    if !has_no_control_chars(pj) {
        return Err(SshError::Parse(
            "proxy jump must not contain control characters or null bytes".to_string(),
        ));
    }
    Ok(())
}

/// Validates all fields of an SSH profile.
pub fn validate_profile(profile: &SshProfile) -> Result<(), SshError> {
    validate_hostname(&profile.host)?;
    if let Some(ref user) = profile.user {
        validate_username(user)?;
    }
    if let Some(ref identity) = profile.identity_file {
        validate_identity_path(identity)?;
    }
    if let Some(ref pj) = profile.proxy_jump {
        validate_proxy_jump(pj)?;
    }
    Ok(())
}

/// Validates SSH profile fields without requiring a full SshProfile struct.
pub fn validate_profile_fields(
    host: &str,
    user: Option<&str>,
    identity_file: Option<&str>,
    proxy_jump: Option<&str>,
) -> Result<(), SshError> {
    validate_hostname(host)?;
    if let Some(user) = user {
        validate_username(user)?;
    }
    if let Some(identity) = identity_file {
        validate_identity_path(identity)?;
    }
    if let Some(pj) = proxy_jump {
        validate_proxy_jump(pj)?;
    }
    Ok(())
}

pub fn build_ssh_command(profile: &SshProfile, keepalive: SshKeepAliveMode) -> Vec<String> {
    let (interval, count) = match keepalive {
        SshKeepAliveMode::Interactive => {
            (KEEPALIVE_INTERACTIVE_INTERVAL, KEEPALIVE_INTERACTIVE_COUNT)
        }
        SshKeepAliveMode::Background => (KEEPALIVE_BACKGROUND_INTERVAL, KEEPALIVE_BACKGROUND_COUNT),
    };
    let mut args = vec![
        "ssh".into(),
        "-o".into(),
        format!("ServerAliveInterval={interval}"),
        "-o".into(),
        format!("ServerAliveCountMax={count}"),
    ];
    if profile.use_control_master.unwrap_or(true) {
        // Only enable ControlMaster when we can compute a safe socket path
        // (requires $HOME to be set — never fall back to /tmp).
        if let Some(socket_path) = control_socket_path(profile) {
            args.extend([
                "-o".into(),
                "ControlMaster=auto".into(),
                "-o".into(),
                format!("ControlPath={}", socket_path.display()),
                "-o".into(),
                format!("ControlPersist={CONTROL_PERSIST_SECS}"),
            ]);
        }
    }
    if profile.port != 22 {
        args.extend(["-p".to_string(), profile.port.to_string()]);
    }
    if let Some(ref identity_file) = profile.identity_file {
        args.extend(["-i".to_string(), identity_file.clone()]);
    }
    if let Some(ref proxy_jump) = profile.proxy_jump {
        args.extend(["-J".to_string(), proxy_jump.clone()]);
    }
    args.push(match &profile.user {
        Some(user) => format!("{user}@{}", profile.host),
        None => profile.host.clone(),
    });
    args
}

/// Returns the home directory, or `None` if `$HOME` is not set.
/// Never falls back to `/tmp` — callers must handle the `None` case.
fn home_dir() -> Option<String> {
    std::env::var("HOME").ok().filter(|h| !h.is_empty())
}

/// Compute a hashed control socket path for ControlMaster multiplexing.
/// Uses SHA256 prefix (16 hex chars) to stay within the 104-char macOS limit.
/// Returns `None` if `$HOME` is not set (ControlMaster requires a user-owned directory).
pub fn control_socket_path(profile: &SshProfile) -> Option<PathBuf> {
    let home = home_dir()?;
    let key = format!(
        "{}@{}:{}",
        profile.user.as_deref().unwrap_or("_"),
        profile.host,
        profile.port
    );
    let hash = format!("{:x}", Sha256::digest(key.as_bytes()));
    Some(
        PathBuf::from(home)
            .join(CONTROL_SOCKET_DIR)
            .join(&hash[..16]),
    )
}

/// Ensure the ControlMaster socket directory exists with 0700 permissions.
/// Returns `Err` if `$HOME` is not set.
pub fn ensure_control_socket_dir() -> std::io::Result<()> {
    let home = home_dir()
        .ok_or_else(|| std::io::Error::new(std::io::ErrorKind::NotFound, "HOME is not set"))?;
    let dir = PathBuf::from(home).join(CONTROL_SOCKET_DIR);
    // Always create + set permissions (idempotent), avoiding TOCTOU race.
    std::fs::create_dir_all(&dir)?;
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        std::fs::set_permissions(&dir, std::fs::Permissions::from_mode(0o700))?;
    }
    Ok(())
}

/// Remove all control sockets. Call on app shutdown.
pub fn cleanup_control_sockets() -> std::io::Result<()> {
    let Some(home) = home_dir() else {
        return Ok(());
    };
    let dir = PathBuf::from(home).join(CONTROL_SOCKET_DIR);
    if dir.is_dir() {
        for entry in std::fs::read_dir(&dir)? {
            let path = entry?.path();
            let _ = std::fs::remove_file(&path);
        }
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    fn base_profile() -> SshProfile {
        SshProfile::new("mybox", "mybox.example.com", "manual").unwrap()
    }

    #[test]
    fn build_ssh_command_minimal() {
        let p = base_profile();
        let cmd = build_ssh_command(&p, SshKeepAliveMode::Background);
        assert_eq!(cmd[0], "ssh");
        // Default port 22 should not add -p flag
        assert!(!cmd.contains(&"-p".to_string()));
        // Last arg should be host (no user@)
        assert_eq!(cmd.last().unwrap(), "mybox.example.com");
    }

    #[test]
    fn build_ssh_command_with_user() {
        let mut p = base_profile();
        p.user = Some("admin".to_string());
        let cmd = build_ssh_command(&p, SshKeepAliveMode::Background);
        assert_eq!(cmd.last().unwrap(), "admin@mybox.example.com");
    }

    #[test]
    fn build_ssh_command_with_non_default_port() {
        let mut p = base_profile();
        p.port = 2222;
        let cmd = build_ssh_command(&p, SshKeepAliveMode::Background);
        let port_idx = cmd.iter().position(|a| a == "-p").expect("-p flag");
        assert_eq!(cmd[port_idx + 1], "2222");
    }

    #[test]
    fn build_ssh_command_with_identity_file() {
        let mut p = base_profile();
        p.identity_file = Some("/home/user/.ssh/id_ed25519".to_string());
        let cmd = build_ssh_command(&p, SshKeepAliveMode::Background);
        let i_idx = cmd.iter().position(|a| a == "-i").expect("-i flag");
        assert_eq!(cmd[i_idx + 1], "/home/user/.ssh/id_ed25519");
    }

    #[test]
    fn build_ssh_command_with_proxy_jump() {
        let mut p = base_profile();
        p.proxy_jump = Some("bastion.example.com".to_string());
        let cmd = build_ssh_command(&p, SshKeepAliveMode::Background);
        let j_idx = cmd.iter().position(|a| a == "-J").expect("-J flag");
        assert_eq!(cmd[j_idx + 1], "bastion.example.com");
    }

    #[test]
    fn build_ssh_command_background_keepalive() {
        let p = base_profile();
        let cmd = build_ssh_command(&p, SshKeepAliveMode::Background);
        assert!(cmd.contains(&"ServerAliveInterval=30".to_string()));
        assert!(cmd.contains(&"ServerAliveCountMax=3".to_string()));
    }

    #[test]
    fn build_ssh_command_interactive_keepalive() {
        let p = base_profile();
        let cmd = build_ssh_command(&p, SshKeepAliveMode::Interactive);
        assert!(cmd.contains(&"ServerAliveInterval=10".to_string()));
        assert!(cmd.contains(&"ServerAliveCountMax=2".to_string()));
    }

    #[test]
    fn build_ssh_command_includes_control_master() {
        let p = base_profile();
        let cmd = build_ssh_command(&p, SshKeepAliveMode::Background);
        assert!(cmd.contains(&"ControlMaster=auto".to_string()));
        assert!(
            cmd.iter().any(|a| a.starts_with("ControlPath=")),
            "should have ControlPath"
        );
        assert!(
            cmd.iter().any(|a| a.starts_with("ControlPersist=")),
            "should have ControlPersist"
        );
    }

    #[test]
    fn build_ssh_command_control_master_disabled() {
        let mut p = base_profile();
        p.use_control_master = Some(false);
        let cmd = build_ssh_command(&p, SshKeepAliveMode::Background);
        assert!(
            !cmd.contains(&"ControlMaster=auto".to_string()),
            "ControlMaster should not be present when disabled"
        );
    }

    #[test]
    fn control_socket_path_under_limit() {
        let mut p = base_profile();
        // Use a very long hostname to test path length
        p.host = "a".repeat(253);
        p.user = Some("verylongusername".to_string());
        let path = control_socket_path(&p).expect("HOME should be set in test");
        let path_str = path.to_string_lossy();
        assert!(
            path_str.len() < 104,
            "socket path must be under 104 chars, got {} chars: {path_str}",
            path_str.len()
        );
    }

    #[test]
    fn ssh_profile_new_defaults() {
        let p = SshProfile::new("test", "test.host", "manual").unwrap();
        assert_eq!(p.port, 22);
        assert!(p.user.is_none());
        assert!(p.identity_file.is_none());
        assert!(p.proxy_jump.is_none());
        assert!(p.tags.is_empty());
        assert_eq!(p.source, "manual");
        assert!(!p.id.is_empty());
        assert!(p.use_control_master.is_none());
    }

    #[test]
    fn rejects_hostname_with_control_chars() {
        assert!(validate_hostname("foo\nbar").is_err());
        assert!(validate_hostname("foo\0bar").is_err());
    }

    #[test]
    fn rejects_hostname_with_whitespace() {
        assert!(validate_hostname("foo bar").is_err());
    }

    #[test]
    fn accepts_valid_hostnames() {
        assert!(validate_hostname("example.com").is_ok());
        assert!(validate_hostname("192.168.1.1").is_ok());
        assert!(validate_hostname("[::1]").is_ok());
        assert!(validate_hostname("user@host").is_ok());
    }

    #[test]
    fn rejects_invalid_usernames() {
        assert!(validate_username("user/name").is_err());
        assert!(validate_username("user\\name").is_err());
        assert!(validate_username("user..name").is_err());
        assert!(validate_username("user name").is_err());
        assert!(validate_username("").is_err());
    }

    #[test]
    fn accepts_valid_usernames() {
        assert!(validate_username("admin").is_ok());
        assert!(validate_username("deploy-bot").is_ok());
    }

    #[test]
    fn ssh_profile_new_validates_host() {
        assert!(SshProfile::new("test", "valid.host", "manual").is_ok());
        assert!(SshProfile::new("test", "bad\nhost", "manual").is_err());
    }
}
