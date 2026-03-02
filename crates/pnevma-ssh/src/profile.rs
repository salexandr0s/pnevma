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
