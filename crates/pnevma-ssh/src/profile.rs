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
    let mut args = vec!["ssh".to_string()];

    args.push("-o".to_string());
    args.push("ServerAliveInterval=30".to_string());
    args.push("-o".to_string());
    args.push("ServerAliveCountMax=3".to_string());

    if profile.port != 22 {
        args.push("-p".to_string());
        args.push(profile.port.to_string());
    }

    if let Some(ref identity_file) = profile.identity_file {
        args.push("-i".to_string());
        args.push(identity_file.clone());
    }

    if let Some(ref proxy_jump) = profile.proxy_jump {
        args.push("-J".to_string());
        args.push(proxy_jump.clone());
    }

    let destination = match &profile.user {
        Some(user) => format!("{}@{}", user, profile.host),
        None => profile.host.clone(),
    };
    args.push(destination);

    args
}
