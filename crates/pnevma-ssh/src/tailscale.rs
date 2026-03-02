use crate::error::SshError;
use crate::profile::SshProfile;

pub async fn discover_tailscale_devices() -> Result<Vec<SshProfile>, SshError> {
    let output = match tokio::process::Command::new("tailscale")
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

            let mut profile = SshProfile::new(dns_name.clone(), dns_name.clone(), "tailscale");
            profile.tags = vec!["tailscale".to_string()];
            profiles.push(profile);
        }
    }

    Ok(profiles)
}
