use std::{
    ffi::{OsStr, OsString},
    path::PathBuf,
    sync::OnceLock,
};

use regex::Regex;

use crate::error::SshError;
use crate::profile::SshProfile;

const TAILSCALE_BIN_ENV: &str = "PNEVMA_TAILSCALE_BIN";
const FALLBACK_TAILSCALE_PATHS: &[&str] =
    &["/opt/homebrew/bin/tailscale", "/usr/local/bin/tailscale"];

/// Validates Tailscale DNS names: only alphanumeric, dots, hyphens, underscores.
fn is_valid_dns_name(name: &str) -> bool {
    static RE: OnceLock<Regex> = OnceLock::new();
    let re = RE.get_or_init(|| Regex::new(r"^[a-zA-Z0-9._-]+$").unwrap());
    re.is_match(name)
}

/// Parse Tailscale status JSON into SSH profiles. Extracted for testability.
pub(crate) fn parse_tailscale_status(json: &serde_json::Value) -> Vec<SshProfile> {
    let mut profiles = vec![];
    if let Some(peers) = json.get("Peer").and_then(|p| p.as_object()) {
        for (_key, peer) in peers {
            let online = peer
                .get("Online")
                .and_then(|v| v.as_bool())
                .unwrap_or(false);
            if !online {
                continue;
            }
            let dns_name = peer
                .get("DNSName")
                .and_then(|v| v.as_str())
                .unwrap_or("")
                .trim_end_matches('.')
                .to_string();
            if dns_name.is_empty() {
                continue;
            }
            if !is_valid_dns_name(&dns_name) {
                continue;
            }
            let mut profile = SshProfile::new(dns_name.clone(), dns_name.clone(), "tailscale");
            profile.tags = vec!["tailscale".to_string()];
            profiles.push(profile);
        }
    }
    profiles
}

pub async fn discover_tailscale_devices() -> Result<Vec<SshProfile>, SshError> {
    let tailscale_bin = resolve_tailscale_binary();
    let output = match tokio::process::Command::new(&tailscale_bin)
        .args(["status", "--json"])
        .output()
        .await
    {
        Ok(out) => out,
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => {
            return Ok(vec![]);
        }
        Err(e) => return Err(SshError::Io(e)),
    };

    if !output.status.success() {
        // Tailscale not running or not logged in — degrade gracefully
        return Ok(vec![]);
    }

    let json: serde_json::Value =
        serde_json::from_slice(&output.stdout).map_err(|e| SshError::Parse(e.to_string()))?;

    Ok(parse_tailscale_status(&json))
}

fn resolve_tailscale_binary() -> PathBuf {
    resolve_tailscale_binary_from(
        std::env::var_os(TAILSCALE_BIN_ENV).map(PathBuf::from),
        std::env::var_os("PATH"),
        FALLBACK_TAILSCALE_PATHS.iter().map(PathBuf::from),
    )
}

fn resolve_tailscale_binary_from<I>(
    explicit_override: Option<PathBuf>,
    path_var: Option<OsString>,
    fallback_candidates: I,
) -> PathBuf
where
    I: IntoIterator<Item = PathBuf>,
{
    if let Some(path) = explicit_override {
        return path;
    }

    if let Some(path) = find_binary_on_path("tailscale", path_var.as_deref()) {
        return path;
    }

    fallback_candidates
        .into_iter()
        .find(|path| path.is_file())
        .unwrap_or_else(|| PathBuf::from("tailscale"))
}

fn find_binary_on_path(binary: &str, path_var: Option<&OsStr>) -> Option<PathBuf> {
    let path_var = path_var?;
    std::env::split_paths(path_var)
        .map(|dir| dir.join(binary))
        .find(|candidate| candidate.is_file())
}

#[cfg(test)]
mod tests {
    use std::{fs, path::Path};

    use tempfile::tempdir;

    use super::*;

    #[test]
    fn empty_json_returns_empty_profiles() {
        let json = serde_json::json!({});
        let profiles = parse_tailscale_status(&json);
        assert!(profiles.is_empty());
    }

    #[test]
    fn online_peer_with_valid_dns_is_included() {
        let json = serde_json::json!({
            "Peer": {
                "abc123": {
                    "Online": true,
                    "DNSName": "mybox.tailnet.ts.net."
                }
            }
        });
        let profiles = parse_tailscale_status(&json);
        assert_eq!(profiles.len(), 1);
        assert_eq!(profiles[0].name, "mybox.tailnet.ts.net");
        assert_eq!(profiles[0].source, "tailscale");
        assert!(profiles[0].tags.contains(&"tailscale".to_string()));
    }

    #[test]
    fn offline_peer_is_excluded() {
        let json = serde_json::json!({
            "Peer": {
                "abc123": {
                    "Online": false,
                    "DNSName": "offline-box.tailnet.ts.net."
                }
            }
        });
        let profiles = parse_tailscale_status(&json);
        assert!(profiles.is_empty());
    }

    #[test]
    fn peer_with_invalid_dns_name_is_skipped() {
        let json = serde_json::json!({
            "Peer": {
                "abc123": {
                    "Online": true,
                    "DNSName": "bad name with spaces"
                }
            }
        });
        let profiles = parse_tailscale_status(&json);
        assert!(profiles.is_empty());
    }

    #[test]
    fn peer_with_empty_dns_name_is_skipped() {
        let json = serde_json::json!({
            "Peer": {
                "abc123": {
                    "Online": true,
                    "DNSName": ""
                }
            }
        });
        let profiles = parse_tailscale_status(&json);
        assert!(profiles.is_empty());
    }

    #[test]
    fn trailing_dot_in_dns_name_is_stripped() {
        let json = serde_json::json!({
            "Peer": {
                "abc123": {
                    "Online": true,
                    "DNSName": "worker.example.ts.net."
                }
            }
        });
        let profiles = parse_tailscale_status(&json);
        assert_eq!(profiles.len(), 1);
        assert_eq!(profiles[0].name, "worker.example.ts.net");
    }

    #[test]
    fn multiple_peers_mixed_online_status() {
        let json = serde_json::json!({
            "Peer": {
                "peer1": { "Online": true,  "DNSName": "box1.ts.net." },
                "peer2": { "Online": false, "DNSName": "box2.ts.net." },
                "peer3": { "Online": true,  "DNSName": "box3.ts.net." }
            }
        });
        let profiles = parse_tailscale_status(&json);
        assert_eq!(profiles.len(), 2);
        let names: Vec<&str> = profiles.iter().map(|p| p.name.as_str()).collect();
        assert!(names.contains(&"box1.ts.net"));
        assert!(names.contains(&"box3.ts.net"));
    }

    #[test]
    fn peer_missing_online_field_defaults_to_offline() {
        let json = serde_json::json!({
            "Peer": {
                "abc123": {
                    "DNSName": "mystery.ts.net."
                }
            }
        });
        let profiles = parse_tailscale_status(&json);
        // Missing Online defaults to false → excluded
        assert!(profiles.is_empty());
    }

    #[test]
    fn resolve_tailscale_binary_prefers_explicit_override() {
        let temp = tempdir().unwrap();
        let override_path = create_fake_binary(temp.path(), "override-tailscale");
        let path_entry = create_fake_binary(temp.path(), "tailscale");
        let resolved = resolve_tailscale_binary_from(
            Some(override_path.clone()),
            Some(std::env::join_paths([temp.path()]).unwrap()),
            [path_entry],
        );

        assert_eq!(resolved, override_path);
    }

    #[test]
    fn resolve_tailscale_binary_uses_path_entry_when_available() {
        let temp = tempdir().unwrap();
        let path_entry = create_fake_binary(temp.path(), "tailscale");
        let resolved = resolve_tailscale_binary_from(
            None,
            Some(std::env::join_paths([temp.path()]).unwrap()),
            std::iter::empty(),
        );

        assert_eq!(resolved, path_entry);
    }

    #[test]
    fn resolve_tailscale_binary_uses_fallback_when_path_is_missing() {
        let temp = tempdir().unwrap();
        let fallback = create_fake_binary(temp.path(), "fallback-tailscale");
        let resolved = resolve_tailscale_binary_from(
            None,
            Some(std::env::join_paths([temp.path().join("missing")]).unwrap()),
            [fallback.clone()],
        );

        assert_eq!(resolved, fallback);
    }

    #[test]
    fn resolve_tailscale_binary_returns_bare_command_when_unavailable() {
        let resolved = resolve_tailscale_binary_from(None, None, std::iter::empty());

        assert_eq!(resolved, PathBuf::from("tailscale"));
    }

    fn create_fake_binary(dir: &Path, name: &str) -> PathBuf {
        let path = dir.join(name);
        fs::write(&path, b"#!/bin/sh\nexit 0\n").unwrap();
        path
    }
}
