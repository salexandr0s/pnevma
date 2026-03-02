use std::path::Path;

use crate::error::SshError;
use crate::profile::SshProfile;

pub fn parse_ssh_config(path: &Path) -> Result<Vec<SshProfile>, SshError> {
    if !path.exists() {
        return Ok(vec![]);
    }

    let content = std::fs::read_to_string(path)?;
    let home_dir = dirs_home();

    let mut profiles: Vec<SshProfile> = vec![];
    let mut current_host_pattern: Option<String> = None;
    let mut current_hostname: Option<String> = None;
    let mut current_user: Option<String> = None;
    let mut current_port: Option<u16> = None;
    let mut current_identity_file: Option<String> = None;
    let mut current_proxy_jump: Option<String> = None;

    let flush = |pattern: &str,
                 hostname: Option<String>,
                 user: Option<String>,
                 port: Option<u16>,
                 identity_file: Option<String>,
                 proxy_jump: Option<String>|
     -> SshProfile {
        let host = hostname.unwrap_or_else(|| pattern.to_string());
        let mut profile = SshProfile::new(pattern, host, "ssh_config");
        profile.user = user;
        profile.port = port.unwrap_or(22);
        profile.identity_file = identity_file;
        profile.proxy_jump = proxy_jump;
        profile.tags = vec!["ssh_config".to_string()];
        profile
    };

    for line in content.lines() {
        let line = line.trim();
        if line.is_empty() || line.starts_with('#') {
            continue;
        }

        let (key, value) = if let Some(pos) = line.find([' ', '\t', '=']) {
            let key = line[..pos].trim().to_lowercase();
            let value = line[pos..]
                .trim_start_matches([' ', '\t', '='])
                .trim()
                .to_string();
            (key, value)
        } else {
            continue;
        };

        if key == "host" {
            if let Some(ref pattern) = current_host_pattern.take() {
                if pattern != "*" {
                    profiles.push(flush(
                        pattern,
                        current_hostname.take(),
                        current_user.take(),
                        current_port.take(),
                        current_identity_file.take(),
                        current_proxy_jump.take(),
                    ));
                } else {
                    current_hostname = None;
                    current_user = None;
                    current_port = None;
                    current_identity_file = None;
                    current_proxy_jump = None;
                }
            }

            if value != "*" {
                current_host_pattern = Some(value);
            }
        } else if current_host_pattern.is_some() {
            match key.as_str() {
                "hostname" => current_hostname = Some(value),
                "user" => current_user = Some(value),
                "port" => current_port = value.parse().ok(),
                "identityfile" => {
                    let expanded = if let Some(rest) = value.strip_prefix('~') {
                        format!("{}{}", home_dir, rest)
                    } else {
                        value
                    };
                    current_identity_file = Some(expanded);
                }
                "proxyjump" => current_proxy_jump = Some(value),
                _ => {}
            }
        }
    }

    // Flush last block
    if let Some(ref pattern) = current_host_pattern {
        if pattern != "*" {
            profiles.push(flush(
                pattern,
                current_hostname,
                current_user,
                current_port,
                current_identity_file,
                current_proxy_jump,
            ));
        }
    }

    Ok(profiles)
}

fn dirs_home() -> String {
    std::env::var("HOME").unwrap_or_else(|_| "~".to_string())
}
