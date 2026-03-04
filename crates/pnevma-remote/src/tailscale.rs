use std::net::{IpAddr, Ipv4Addr};

use serde::Deserialize;

use crate::error::RemoteError;

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
    let output = tokio::process::Command::new("tailscale")
        .args(["status", "--json"])
        .output()
        .await
        .map_err(|e| RemoteError::NoTailscale(format!("Failed to run tailscale: {e}")))?;

    if !output.status.success() {
        let stderr = String::from_utf8_lossy(&output.stderr);
        return Err(RemoteError::NoTailscale(format!(
            "tailscale status failed: {stderr}"
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

/// Check if an IP address is in the Tailscale CGNAT range 100.64.0.0/10.
pub fn is_tailscale_ip(addr: &IpAddr) -> bool {
    match addr {
        IpAddr::V4(v4) => {
            let octets = v4.octets();
            // 100.64.0.0/10: first octet == 100, second octet in [64, 127]
            octets[0] == 100 && (64..=127).contains(&octets[1])
        }
        IpAddr::V6(_) => false,
    }
}
