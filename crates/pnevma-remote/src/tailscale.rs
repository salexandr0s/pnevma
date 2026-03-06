use std::{
    ffi::{OsStr, OsString},
    net::{IpAddr, Ipv4Addr},
    path::PathBuf,
};

use serde::Deserialize;

use crate::error::RemoteError;

const TAILSCALE_BIN_ENV: &str = "PNEVMA_TAILSCALE_BIN";
const FALLBACK_TAILSCALE_PATHS: &[&str] =
    &["/opt/homebrew/bin/tailscale", "/usr/local/bin/tailscale"];

#[derive(Debug, Deserialize)]
struct TailscaleStatus {
    #[serde(rename = "Self")]
    self_info: TailscaleSelf,
}

#[derive(Debug, Deserialize)]
struct TailscaleSelf {
    #[serde(rename = "TailscaleIPs")]
    tailscale_ips: Vec<String>,
}

pub async fn get_tailscale_self_ip() -> Result<Ipv4Addr, RemoteError> {
    let tailscale_bin = resolve_tailscale_binary();
    let output = tokio::process::Command::new(&tailscale_bin)
        .args(["status", "--json"])
        .output()
        .await
        .map_err(|e| {
            RemoteError::NoTailscale(format!("Failed to run {}: {e}", tailscale_bin.display()))
        })?;

    if !output.status.success() {
        let stderr = String::from_utf8_lossy(&output.stderr);
        return Err(RemoteError::NoTailscale(format!(
            "{} status failed: {stderr}",
            tailscale_bin.display()
        )));
    }

    let status: TailscaleStatus = serde_json::from_slice(&output.stdout)
        .map_err(|e| RemoteError::NoTailscale(format!("Failed to parse tailscale status: {e}")))?;

    for ip_str in &status.self_info.tailscale_ips {
        if let Ok(addr) = ip_str.parse::<Ipv4Addr>() {
            // 100.x.x.x range (100.64.0.0/10 CGNAT)
            if addr.octets()[0] == 100 {
                return Ok(addr);
            }
        }
    }

    Err(RemoteError::NoTailscale(
        "No 100.x.x.x Tailscale IP found".to_string(),
    ))
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

/// Check if an IP address is in a Tailscale range.
/// IPv4: 100.64.0.0/10 (CGNAT)
/// IPv6: fd7a:115c:a1e0::/48 (Tailscale ULA prefix)
pub fn is_tailscale_ip(addr: &IpAddr) -> bool {
    match addr {
        IpAddr::V4(v4) => {
            let octets = v4.octets();
            // 100.64.0.0/10: first octet == 100, second octet in [64, 127]
            octets[0] == 100 && (64..=127).contains(&octets[1])
        }
        IpAddr::V6(v6) => {
            let segs = v6.segments();
            // fd7a:115c:a1e0::/48
            segs[0] == 0xfd7a && segs[1] == 0x115c && segs[2] == 0xa1e0
        }
    }
}

#[cfg(test)]
mod tests {
    use std::{fs, path::Path};

    use tempfile::tempdir;

    use super::*;

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
