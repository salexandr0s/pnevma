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

/// Validates that a key name does not contain path traversal characters.
fn validate_key_name(name: &str) -> Result<(), SshError> {
    if name.is_empty() {
        return Err(SshError::Parse("key name must not be empty".to_string()));
    }
    if name.contains('/')
        || name.contains('\\')
        || name.contains('\0')
        || name.contains("..")
        || name.chars().any(|c| c.is_whitespace() || c.is_control())
    {
        return Err(SshError::Parse(format!(
            "invalid key name: must not contain '/', '\\', '\\0', '..', whitespace, or control characters: {name}"
        )));
    }
    Ok(())
}

fn generate_passphrase() -> String {
    use rand::Rng;
    let mut rng = rand::thread_rng();
    (0..32)
        .map(|_| {
            let idx = rng.gen_range(0..62);
            match idx {
                0..=9 => (b'0' + idx) as char,
                10..=35 => (b'a' + idx - 10) as char,
                _ => (b'A' + idx - 36) as char,
            }
        })
        .collect()
}

fn store_passphrase_in_keychain(key_name: &str, passphrase: &str) -> Result<(), SshError> {
    let output = std::process::Command::new("security")
        .args([
            "add-generic-password",
            "-a",
            key_name,
            "-s",
            "pnevma-ssh-key",
            "-w",
            passphrase,
            "-U", // Update if exists
        ])
        .output()?;

    if !output.status.success() {
        let stderr = String::from_utf8_lossy(&output.stderr);
        return Err(SshError::Command(format!(
            "failed to store passphrase in keychain: {}",
            stderr.trim()
        )));
    }
    Ok(())
}

pub fn retrieve_passphrase_from_keychain(key_name: &str) -> Result<String, SshError> {
    let output = std::process::Command::new("security")
        .args([
            "find-generic-password",
            "-a",
            key_name,
            "-s",
            "pnevma-ssh-key",
            "-w",
        ])
        .output()?;

    if !output.status.success() {
        let stderr = String::from_utf8_lossy(&output.stderr);
        return Err(SshError::Command(format!(
            "failed to retrieve passphrase from keychain: {}",
            stderr.trim()
        )));
    }

    Ok(String::from_utf8_lossy(&output.stdout).trim().to_string())
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

        let key_info = fingerprint_key(&path, Some(ssh_dir))?;
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
    validate_key_name(name)?;

    const ALLOWED_KEY_TYPES: &[&str] = &["ed25519", "ecdsa", "rsa"];

    if !key_type.is_empty() && !ALLOWED_KEY_TYPES.contains(&key_type) {
        return Err(SshError::Parse(format!(
            "unsupported key type: {key_type}. Allowed: {}",
            ALLOWED_KEY_TYPES.join(", ")
        )));
    }

    let effective_type = if key_type.is_empty() {
        "ed25519"
    } else {
        key_type
    };
    let key_path = ssh_dir.join(name);

    // Defense-in-depth: ensure the resolved path stays within ssh_dir
    let canonical_ssh_dir = ssh_dir.canonicalize().map_err(SshError::Io)?;
    // The key_path may not exist yet, but its parent must be within ssh_dir.
    // We check that the parent resolves inside ssh_dir.
    let parent = key_path
        .parent()
        .ok_or_else(|| SshError::Parse("invalid key path".to_string()))?;
    let canonical_parent = parent.canonicalize().map_err(SshError::Io)?;
    if !canonical_parent.starts_with(&canonical_ssh_dir) {
        return Err(SshError::Parse(format!(
            "key path escapes SSH directory: {}",
            key_path.display()
        )));
    }

    // Validate the comment before passing it to ssh-keygen.
    if comment.len() > 256 {
        return Err(SshError::Parse(
            "key comment must not exceed 256 characters".to_string(),
        ));
    }
    if comment.contains('\0') || !comment.chars().all(|c| (' '..='\x7e').contains(&c)) {
        return Err(SshError::Parse(
            "key comment must contain only printable ASCII characters (0x20-0x7E)".to_string(),
        ));
    }

    let key_path_str = key_path.to_string_lossy().to_string();

    let passphrase = generate_passphrase();

    let output = std::process::Command::new("ssh-keygen")
        .args([
            "-t",
            effective_type,
            "-f",
            &key_path_str,
            "-C",
            comment,
            "-N",
            &passphrase,
        ])
        .output()?;

    if !output.status.success() {
        let stderr = String::from_utf8_lossy(&output.stderr);
        return Err(SshError::Command(stderr.to_string()));
    }

    // Store passphrase in macOS Keychain
    if let Err(e) = store_passphrase_in_keychain(name, &passphrase) {
        tracing::warn!(key_name = %name, error = %e, "failed to store passphrase in keychain");
    }

    // Set restrictive permissions on the private key file
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        let perms = std::fs::Permissions::from_mode(0o600);
        std::fs::set_permissions(&key_path, perms).map_err(SshError::Io)?;

        // Verify permissions were set correctly
        let meta = std::fs::metadata(&key_path).map_err(SshError::Io)?;
        let mode = meta.permissions().mode() & 0o777;
        if mode != 0o600 {
            return Err(SshError::Command(format!(
                "failed to set key permissions: expected 0600, got {:o}",
                mode
            )));
        }
    }

    let pub_path = format!("{}.pub", key_path_str);
    let (key_type_out, fingerprint) = fingerprint_key(Path::new(&pub_path), Some(ssh_dir))?;

    Ok(SshKeyInfo {
        name: name.to_string(),
        path: pub_path,
        key_type: key_type_out,
        fingerprint,
    })
}

fn fingerprint_key(
    pub_path: &Path,
    expected_parent: Option<&Path>,
) -> Result<(String, String), SshError> {
    // Validate path stays within expected directory
    if let Some(parent) = expected_parent {
        let canonical_parent = parent.canonicalize().map_err(SshError::Io)?;
        let canonical_path = pub_path.canonicalize().map_err(SshError::Io)?;
        if !canonical_path.starts_with(&canonical_parent) {
            return Err(SshError::Parse(format!(
                "key path {} escapes expected directory {}",
                canonical_path.display(),
                canonical_parent.display()
            )));
        }
    }

    let path_str = pub_path.to_string_lossy();
    let output = std::process::Command::new("ssh-keygen")
        .args(["-lf", &path_str])
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

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn rejects_path_traversal_names() {
        assert!(validate_key_name("../etc/passwd").is_err());
        assert!(validate_key_name("foo/bar").is_err());
        assert!(validate_key_name("foo\\bar").is_err());
        assert!(validate_key_name("foo\0bar").is_err());
        assert!(validate_key_name("..").is_err());
        assert!(validate_key_name("").is_err());
    }

    #[test]
    fn accepts_valid_key_names() {
        assert!(validate_key_name("id_ed25519").is_ok());
        assert!(validate_key_name("my-key").is_ok());
        assert!(validate_key_name("key_name.pem").is_ok());
        assert!(validate_key_name("my_key_2024").is_ok());
    }

    #[test]
    fn rejects_names_with_whitespace() {
        assert!(validate_key_name("my key").is_err());
        assert!(validate_key_name("key\tname").is_err());
        assert!(validate_key_name("key\nname").is_err());
    }

    #[test]
    fn parse_keygen_output_rsa() {
        let line = "2048 SHA256:abc123def456 user@host (RSA)";
        let (key_type, fingerprint) = parse_keygen_output(line).expect("parse");
        assert_eq!(key_type, "RSA");
        assert_eq!(fingerprint, "SHA256:abc123def456");
    }

    #[test]
    fn parse_keygen_output_ed25519() {
        let line = "256 SHA256:xyzXYZ789 mykey (ED25519)";
        let (key_type, fingerprint) = parse_keygen_output(line).expect("parse");
        assert_eq!(key_type, "ED25519");
        assert_eq!(fingerprint, "SHA256:xyzXYZ789");
    }

    #[test]
    fn parse_keygen_output_malformed_returns_error() {
        // No whitespace-separated tokens — can't extract fingerprint
        let line = "no-fingerprint-here";
        let result = parse_keygen_output(line);
        assert!(result.is_err(), "should fail on malformed output");
    }

    #[test]
    fn list_ssh_keys_nonexistent_dir_returns_empty() {
        let result = list_ssh_keys(std::path::Path::new("/nonexistent/ssh/dir"));
        assert!(result.is_ok());
        assert!(result.unwrap().is_empty());
    }
}
