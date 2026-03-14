use std::{
    ffi::{OsStr, OsString},
    net::IpAddr,
    path::PathBuf,
    sync::OnceLock,
};

use regex::Regex;
use serde::{Deserialize, Serialize};

use crate::error::SshError;

const TAILSCALE_BIN_ENV: &str = "PNEVMA_TAILSCALE_BIN";
const FALLBACK_TAILSCALE_PATHS: &[&str] =
    &["/opt/homebrew/bin/tailscale", "/usr/local/bin/tailscale"];

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct TailscaleDevice {
    pub id: String,
    pub hostname: String,
    pub ip_address: String,
    pub is_online: bool,
}

/// Validates Tailscale DNS names: only alphanumeric, dots, hyphens, underscores.
fn is_valid_dns_name(name: &str) -> bool {
    static RE: OnceLock<Regex> = OnceLock::new();
    let re = RE.get_or_init(|| Regex::new(r"^[a-zA-Z0-9._-]+$").unwrap());
    re.is_match(name)
}

fn preferred_tailscale_ip(peer: &serde_json::Value) -> Option<String> {
    let candidates: Vec<String> = peer
        .get("TailscaleIPs")
        .and_then(|value| value.as_array())
        .into_iter()
        .flatten()
        .chain(
            peer.get("Addrs")
                .and_then(|value| value.as_array())
                .into_iter()
                .flatten(),
        )
        .filter_map(|value| value.as_str())
        .map(str::trim)
        .filter(|value| !value.is_empty())
        .map(str::to_string)
        .collect();

    candidates
        .iter()
        .find(|value| value.parse::<IpAddr>().is_ok_and(|addr| addr.is_ipv4()))
        .cloned()
        .or_else(|| {
            candidates
                .into_iter()
                .find(|value| value.parse::<IpAddr>().is_ok())
        })
}

/// Parse Tailscale status JSON into device rows for the SSH manager.
pub(crate) fn parse_tailscale_status(json: &serde_json::Value) -> Vec<TailscaleDevice> {
    let mut devices = vec![];
    if let Some(peers) = json.get("Peer").and_then(|p| p.as_object()) {
        for (peer_id, peer) in peers {
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
            let Some(ip_address) = preferred_tailscale_ip(peer) else {
                continue;
            };
            devices.push(TailscaleDevice {
                id: peer_id.to_string(),
                hostname: dns_name,
                ip_address,
                is_online: true,
            });
        }
    }
    devices
}

pub async fn discover_tailscale_devices() -> Result<Vec<TailscaleDevice>, SshError> {
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
        if path.is_file() {
            tracing::info!(path = %path.display(), "using PNEVMA_TAILSCALE_BIN override");
            return path;
        }
        tracing::warn!(
            path = %path.display(),
            "PNEVMA_TAILSCALE_BIN points to non-existent or non-file path, falling back to discovery"
        );
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
    fn empty_json_returns_empty_devices() {
        let json = serde_json::json!({});
        let devices = parse_tailscale_status(&json);
        assert!(devices.is_empty());
    }

    #[test]
    fn online_peer_with_valid_dns_and_ip_is_included() {
        let json = serde_json::json!({
            "Peer": {
                "abc123": {
                    "Online": true,
                    "DNSName": "mybox.tailnet.ts.net.",
                    "TailscaleIPs": ["100.64.0.10"]
                }
            }
        });
        let devices = parse_tailscale_status(&json);
        assert_eq!(devices.len(), 1);
        assert_eq!(devices[0].id, "abc123");
        assert_eq!(devices[0].hostname, "mybox.tailnet.ts.net");
        assert_eq!(devices[0].ip_address, "100.64.0.10");
        assert!(devices[0].is_online);
    }

    #[test]
    fn offline_peer_is_excluded() {
        let json = serde_json::json!({
            "Peer": {
                "abc123": {
                    "Online": false,
                    "DNSName": "offline-box.tailnet.ts.net.",
                    "TailscaleIPs": ["100.64.0.11"]
                }
            }
        });
        let devices = parse_tailscale_status(&json);
        assert!(devices.is_empty());
    }

    #[test]
    fn peer_with_invalid_dns_name_is_skipped() {
        let json = serde_json::json!({
            "Peer": {
                "abc123": {
                    "Online": true,
                    "DNSName": "bad name with spaces",
                    "TailscaleIPs": ["100.64.0.12"]
                }
            }
        });
        let devices = parse_tailscale_status(&json);
        assert!(devices.is_empty());
    }

    #[test]
    fn peer_with_empty_dns_name_is_skipped() {
        let json = serde_json::json!({
            "Peer": {
                "abc123": {
                    "Online": true,
                    "DNSName": "",
                    "TailscaleIPs": ["100.64.0.13"]
                }
            }
        });
        let devices = parse_tailscale_status(&json);
        assert!(devices.is_empty());
    }

    #[test]
    fn trailing_dot_in_dns_name_is_stripped() {
        let json = serde_json::json!({
            "Peer": {
                "abc123": {
                    "Online": true,
                    "DNSName": "worker.example.ts.net.",
                    "TailscaleIPs": ["100.64.0.14"]
                }
            }
        });
        let devices = parse_tailscale_status(&json);
        assert_eq!(devices.len(), 1);
        assert_eq!(devices[0].hostname, "worker.example.ts.net");
    }

    #[test]
    fn multiple_peers_mixed_online_status() {
        let json = serde_json::json!({
            "Peer": {
                "peer1": { "Online": true,  "DNSName": "box1.ts.net.", "TailscaleIPs": ["100.64.0.15"] },
                "peer2": { "Online": false, "DNSName": "box2.ts.net.", "TailscaleIPs": ["100.64.0.16"] },
                "peer3": { "Online": true,  "DNSName": "box3.ts.net.", "TailscaleIPs": ["100.64.0.17"] }
            }
        });
        let devices = parse_tailscale_status(&json);
        assert_eq!(devices.len(), 2);
        let names: Vec<&str> = devices
            .iter()
            .map(|device| device.hostname.as_str())
            .collect();
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
        let devices = parse_tailscale_status(&json);
        // Missing Online defaults to false → excluded
        assert!(devices.is_empty());
    }

    #[test]
    fn peer_without_tailscale_ip_is_skipped() {
        let json = serde_json::json!({
            "Peer": {
                "abc123": {
                    "Online": true,
                    "DNSName": "worker.ts.net."
                }
            }
        });
        let devices = parse_tailscale_status(&json);
        assert!(devices.is_empty());
    }

    #[test]
    fn prefers_ipv4_tailscale_ip_when_multiple_addresses_exist() {
        let json = serde_json::json!({
            "Peer": {
                "abc123": {
                    "Online": true,
                    "DNSName": "worker.ts.net.",
                    "TailscaleIPs": ["fd7a:115c:a1e0::fa39:7f76", "100.126.127.118"]
                }
            }
        });
        let devices = parse_tailscale_status(&json);
        assert_eq!(devices.len(), 1);
        assert_eq!(devices[0].ip_address, "100.126.127.118");
    }

    #[test]
    fn falls_back_to_addrs_when_tailscale_ips_are_missing() {
        let json = serde_json::json!({
            "Peer": {
                "abc123": {
                    "Online": true,
                    "DNSName": "worker.ts.net.",
                    "Addrs": ["100.64.0.18"]
                }
            }
        });
        let devices = parse_tailscale_status(&json);
        assert_eq!(devices.len(), 1);
        assert_eq!(devices[0].ip_address, "100.64.0.18");
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

    #[test]
    fn resolve_tailscale_binary_ignores_nonexistent_override() {
        let temp = tempdir().unwrap();
        let path_entry = create_fake_binary(temp.path(), "tailscale");
        let resolved = resolve_tailscale_binary_from(
            Some(PathBuf::from("/nonexistent/tailscale")),
            Some(std::env::join_paths([temp.path()]).unwrap()),
            std::iter::empty(),
        );
        assert_eq!(resolved, path_entry);
    }

    fn create_fake_binary(dir: &Path, name: &str) -> PathBuf {
        let path = dir.join(name);
        fs::write(&path, b"#!/bin/sh\nexit 0\n").unwrap();
        path
    }
}
