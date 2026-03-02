use std::path::Path;

use serde::{Deserialize, Serialize};

use crate::error::SshError;

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct SshKeyInfo {
    pub name: String,
    pub path: String,
    pub key_type: String,
    pub fingerprint: String,
}

pub fn list_ssh_keys(ssh_dir: &Path) -> Result<Vec<SshKeyInfo>, SshError> {
    let mut keys = vec![];

    let entries = match std::fs::read_dir(ssh_dir) {
        Ok(e) => e,
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => return Ok(vec![]),
        Err(e) => return Err(SshError::Io(e)),
    };

    for entry in entries {
        let entry = entry?;
        let file_name = entry.file_name();
        let name_str = file_name.to_string_lossy();

        if !name_str.ends_with(".pub") {
            continue;
        }

        let path = entry.path();
        let path_str = path.to_string_lossy().to_string();

        let key_info = fingerprint_key(&path_str)?;
        let name = name_str.trim_end_matches(".pub").to_string();

        keys.push(SshKeyInfo {
            name,
            path: path_str,
            key_type: key_info.0,
            fingerprint: key_info.1,
        });
    }

    Ok(keys)
}

pub fn generate_key(
    ssh_dir: &Path,
    name: &str,
    key_type: &str,
    comment: &str,
) -> Result<SshKeyInfo, SshError> {
    let effective_type = if key_type.is_empty() {
        "ed25519"
    } else {
        key_type
    };
    let key_path = ssh_dir.join(name);
    let key_path_str = key_path.to_string_lossy().to_string();

    let output = std::process::Command::new("ssh-keygen")
        .args([
            "-t",
            effective_type,
            "-f",
            &key_path_str,
            "-C",
            comment,
            "-N",
            "",
        ])
        .output()?;

    if !output.status.success() {
        let stderr = String::from_utf8_lossy(&output.stderr);
        return Err(SshError::Command(stderr.to_string()));
    }

    let pub_path = format!("{}.pub", key_path_str);
    let (key_type_out, fingerprint) = fingerprint_key(&pub_path)?;

    Ok(SshKeyInfo {
        name: name.to_string(),
        path: pub_path,
        key_type: key_type_out,
        fingerprint,
    })
}

fn fingerprint_key(pub_path: &str) -> Result<(String, String), SshError> {
    let output = std::process::Command::new("ssh-keygen")
        .args(["-lf", pub_path])
        .output()?;

    if !output.status.success() {
        let stderr = String::from_utf8_lossy(&output.stderr);
        return Err(SshError::Command(stderr.to_string()));
    }

    let stdout = String::from_utf8_lossy(&output.stdout);
    // Format: "2048 SHA256:xxx comment (RSA)"
    parse_keygen_output(stdout.trim())
}

fn parse_keygen_output(line: &str) -> Result<(String, String), SshError> {
    // Extract key_type from last parenthesized token
    let key_type = line
        .rsplit_once('(')
        .and_then(|(_, rest)| rest.strip_suffix(')'))
        .unwrap_or("unknown")
        .to_string();

    // fingerprint is second whitespace-separated token
    let fingerprint = line
        .split_whitespace()
        .nth(1)
        .ok_or_else(|| SshError::Parse(format!("unexpected ssh-keygen output: {}", line)))?
        .to_string();

    Ok((key_type, fingerprint))
}
