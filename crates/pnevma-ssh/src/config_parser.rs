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

/// Parse SSH config from a string (for testing without touching the filesystem).
pub fn parse_ssh_config_str(content: &str) -> Vec<SshProfile> {
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

    profiles
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::Write;

    // ── parse_ssh_config_str edge cases ────────────────────────────────────

    #[test]
    fn empty_config_returns_empty_list() {
        let profiles = parse_ssh_config_str("");
        assert!(profiles.is_empty());
    }

    #[test]
    fn config_with_only_comments_returns_empty() {
        let content = "# This is a comment\n# Another comment\n";
        let profiles = parse_ssh_config_str(content);
        assert!(profiles.is_empty());
    }

    #[test]
    fn single_host_block_parsed() {
        let content = "\
Host dev-server
    HostName dev.example.com
    User deploy
    Port 2222
    IdentityFile ~/.ssh/id_ed25519
";
        let profiles = parse_ssh_config_str(content);
        assert_eq!(profiles.len(), 1);
        let p = &profiles[0];
        assert_eq!(p.name, "dev-server");
        assert_eq!(p.host, "dev.example.com");
        assert_eq!(p.user.as_deref(), Some("deploy"));
        assert_eq!(p.port, 2222);
        assert!(p.identity_file.is_some());
    }

    #[test]
    fn multiple_host_blocks_all_parsed() {
        let content = "\
Host alpha
    HostName alpha.example.com
    User admin

Host beta
    HostName beta.example.com
    Port 2222
";
        let profiles = parse_ssh_config_str(content);
        assert_eq!(profiles.len(), 2);
        let names: Vec<&str> = profiles.iter().map(|p| p.name.as_str()).collect();
        assert!(names.contains(&"alpha"));
        assert!(names.contains(&"beta"));
    }

    #[test]
    fn wildcard_host_block_is_skipped() {
        let content = "\
Host *
    ServerAliveInterval 60

Host real-host
    HostName real.example.com
";
        let profiles = parse_ssh_config_str(content);
        assert_eq!(profiles.len(), 1);
        assert_eq!(profiles[0].name, "real-host");
    }

    #[test]
    fn proxy_jump_is_captured() {
        let content = "\
Host bastion
    HostName bastion.example.com
    ProxyJump jump@proxy.example.com
";
        let profiles = parse_ssh_config_str(content);
        assert_eq!(profiles.len(), 1);
        assert_eq!(
            profiles[0].proxy_jump.as_deref(),
            Some("jump@proxy.example.com")
        );
    }

    #[test]
    fn host_without_hostname_uses_pattern_as_host() {
        let content = "\
Host mybox
    User ubuntu
";
        let profiles = parse_ssh_config_str(content);
        assert_eq!(profiles.len(), 1);
        // no HostName → host falls back to the pattern
        assert_eq!(profiles[0].host, "mybox");
    }

    #[test]
    fn comments_inline_and_blank_lines_ignored() {
        let content = "\
# Top comment

Host prod
    # inline comment
    HostName prod.example.com
    User root
";
        let profiles = parse_ssh_config_str(content);
        assert_eq!(profiles.len(), 1);
        assert_eq!(profiles[0].name, "prod");
    }

    // ── parse_ssh_config (filesystem) ──────────────────────────────────────

    #[test]
    fn nonexistent_file_returns_empty_vec() {
        let result = parse_ssh_config(std::path::Path::new("/nonexistent/path/to/ssh_config"));
        assert!(result.is_ok());
        assert!(result.unwrap().is_empty());
    }

    #[test]
    fn existing_file_parsed_correctly() {
        let mut tmp = tempfile::NamedTempFile::new().expect("tmp file");
        writeln!(
            tmp,
            "Host staging\n    HostName staging.example.com\n    User ci\n    Port 22\n"
        )
        .unwrap();
        let profiles = parse_ssh_config(tmp.path()).expect("parse");
        assert_eq!(profiles.len(), 1);
        assert_eq!(profiles[0].name, "staging");
        assert_eq!(profiles[0].user.as_deref(), Some("ci"));
    }
}
