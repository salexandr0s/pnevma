use chrono::{DateTime, Utc};
use serde::{Deserialize, Serialize};

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
}

impl SshProfile {
    pub fn new(
        name: impl Into<String>,
        host: impl Into<String>,
        source: impl Into<String>,
    ) -> Self {
        let now = Utc::now();
        Self {
            id: uuid::Uuid::new_v4().to_string(),
            name: name.into(),
            host: host.into(),
            port: 22,
            user: None,
            identity_file: None,
            proxy_jump: None,
            tags: vec![],
            source: source.into(),
            created_at: now,
            updated_at: now,
        }
    }
}

pub fn build_ssh_command(profile: &SshProfile) -> Vec<String> {
    let mut args = vec![
        "ssh".into(),
        "-o".into(),
        "ServerAliveInterval=30".into(),
        "-o".into(),
        "ServerAliveCountMax=3".into(),
    ];
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

#[cfg(test)]
mod tests {
    use super::*;

    fn base_profile() -> SshProfile {
        SshProfile::new("mybox", "mybox.example.com", "manual")
    }

    #[test]
    fn build_ssh_command_minimal() {
        let p = base_profile();
        let cmd = build_ssh_command(&p);
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
        let cmd = build_ssh_command(&p);
        assert_eq!(cmd.last().unwrap(), "admin@mybox.example.com");
    }

    #[test]
    fn build_ssh_command_with_non_default_port() {
        let mut p = base_profile();
        p.port = 2222;
        let cmd = build_ssh_command(&p);
        let port_idx = cmd.iter().position(|a| a == "-p").expect("-p flag");
        assert_eq!(cmd[port_idx + 1], "2222");
    }

    #[test]
    fn build_ssh_command_with_identity_file() {
        let mut p = base_profile();
        p.identity_file = Some("/home/user/.ssh/id_ed25519".to_string());
        let cmd = build_ssh_command(&p);
        let i_idx = cmd.iter().position(|a| a == "-i").expect("-i flag");
        assert_eq!(cmd[i_idx + 1], "/home/user/.ssh/id_ed25519");
    }

    #[test]
    fn build_ssh_command_with_proxy_jump() {
        let mut p = base_profile();
        p.proxy_jump = Some("bastion.example.com".to_string());
        let cmd = build_ssh_command(&p);
        let j_idx = cmd.iter().position(|a| a == "-J").expect("-J flag");
        assert_eq!(cmd[j_idx + 1], "bastion.example.com");
    }

    #[test]
    fn build_ssh_command_includes_keepalive_options() {
        let p = base_profile();
        let cmd = build_ssh_command(&p);
        let o_count = cmd.iter().filter(|a| a.as_str() == "-o").count();
        assert_eq!(o_count, 2, "should have two -o flags");
        assert!(cmd.contains(&"ServerAliveInterval=30".to_string()));
        assert!(cmd.contains(&"ServerAliveCountMax=3".to_string()));
    }

    #[test]
    fn ssh_profile_new_defaults() {
        let p = SshProfile::new("test", "test.host", "manual");
        assert_eq!(p.port, 22);
        assert!(p.user.is_none());
        assert!(p.identity_file.is_none());
        assert!(p.proxy_jump.is_none());
        assert!(p.tags.is_empty());
        assert_eq!(p.source, "manual");
        assert!(!p.id.is_empty());
    }
}
