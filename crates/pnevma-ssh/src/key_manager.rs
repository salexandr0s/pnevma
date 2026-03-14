use std::path::Path;

use secrecy::{ExposeSecret, SecretString};
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
    if name.len() > 128 {
        return Err(SshError::Parse(
            "key name must not exceed 128 characters".to_string(),
        ));
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

fn validate_key_comment(comment: &str) -> Result<(), SshError> {
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
    Ok(())
}

fn generate_passphrase() -> SecretString {
    use rand::Rng;
    let mut rng = rand::thread_rng();
    let raw: String = (0..32)
        .map(|_| {
            let idx = rng.gen_range(0..62);
            match idx {
                0..=9 => (b'0' + idx) as char,
                10..=35 => (b'a' + idx - 10) as char,
                _ => (b'A' + idx - 36) as char,
            }
        })
        .collect();
    SecretString::from(raw)
}

fn store_passphrase_in_keychain(key_name: &str, passphrase: &SecretString) -> Result<(), SshError> {
    #[cfg(target_os = "macos")]
    {
        use security_framework::passwords::set_generic_password;

        set_generic_password(
            "pnevma-ssh-key",
            key_name,
            passphrase.expose_secret().as_bytes(),
        )
        .map_err(|e| SshError::Command(format!("failed to store passphrase in keychain: {e}")))
    }

    #[cfg(not(target_os = "macos"))]
    {
        let _ = (key_name, passphrase);
        Err(SshError::Command(
            "SSH passphrase keychain storage is only supported on macOS".to_string(),
        ))
    }
}

pub fn retrieve_passphrase_from_keychain(key_name: &str) -> Result<SecretString, SshError> {
    #[cfg(target_os = "macos")]
    {
        use security_framework::passwords::get_generic_password;

        let bytes = get_generic_password("pnevma-ssh-key", key_name).map_err(|e| {
            SshError::Command(format!("failed to retrieve passphrase from keychain: {e}"))
        })?;
        let raw = String::from_utf8(bytes)
            .map_err(|e| SshError::Parse(format!("invalid UTF-8 in stored passphrase: {e}")))?;
        Ok(SecretString::from(raw))
    }

    #[cfg(not(target_os = "macos"))]
    {
        let _ = key_name;
        Err(SshError::Command(
            "SSH passphrase keychain retrieval is only supported on macOS".to_string(),
        ))
    }
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

/// Async version of `list_ssh_keys` that uses `tokio::process::Command` for
/// fingerprinting and a `JoinSet` to limit concurrency to 10 tasks.
pub async fn list_ssh_keys_async(ssh_dir: &Path) -> Result<Vec<SshKeyInfo>, SshError> {
    let entries = match tokio::fs::read_dir(ssh_dir).await {
        Ok(e) => e,
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => return Ok(vec![]),
        Err(e) => return Err(SshError::Io(e)),
    };

    // Collect .pub paths first.
    let mut pub_paths: Vec<(String, std::path::PathBuf, String)> = Vec::new();
    let mut entries = entries;
    while let Some(entry) = entries.next_entry().await? {
        let file_name = entry.file_name();
        let name_str = file_name.to_string_lossy().to_string();
        if !name_str.ends_with(".pub") {
            continue;
        }
        let path = entry.path();
        let path_str = path.to_string_lossy().to_string();
        let name = name_str.trim_end_matches(".pub").to_string();
        pub_paths.push((name, path, path_str));
    }

    let ssh_dir_owned = ssh_dir.to_path_buf();
    let mut join_set = tokio::task::JoinSet::new();
    let semaphore = std::sync::Arc::new(tokio::sync::Semaphore::new(10));

    for (name, path, path_str) in pub_paths {
        let ssh_dir_clone = ssh_dir_owned.clone();
        let permit = semaphore.clone();
        join_set.spawn(async move {
            let _permit = permit.acquire().await.map_err(|_| {
                SshError::Command("semaphore closed during ssh key listing".to_string())
            })?;
            let (key_type, fingerprint) =
                fingerprint_key_async(&path, Some(&ssh_dir_clone)).await?;
            Ok::<SshKeyInfo, SshError>(SshKeyInfo {
                name,
                path: path_str,
                key_type,
                fingerprint,
            })
        });
    }

    let mut keys = Vec::new();
    while let Some(result) = join_set.join_next().await {
        match result {
            Ok(Ok(info)) => keys.push(info),
            Ok(Err(e)) => return Err(e),
            Err(e) => return Err(SshError::Command(format!("task join error: {e}"))),
        }
    }

    Ok(keys)
}

async fn fingerprint_key_async(
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
    let output = tokio::process::Command::new("ssh-keygen")
        .args(["-lf", &path_str])
        .output()
        .await?;

    if !output.status.success() {
        let stderr = String::from_utf8_lossy(&output.stderr);
        return Err(SshError::Command(stderr.to_string()));
    }

    let stdout = String::from_utf8_lossy(&output.stdout);
    parse_keygen_output(stdout.trim())
}

pub async fn generate_key(
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

    validate_key_comment(comment)?;

    let key_path_str = key_path.to_string_lossy().to_string();

    let passphrase = generate_passphrase();

    // Step 1: Generate key with an empty passphrase (no secret in process args).
    let mut args = vec![
        "-t",
        effective_type,
        "-f",
        &key_path_str,
        "-C",
        comment,
        "-N",
        "",
    ];
    if effective_type == "rsa" {
        args.extend(["-b", "4096"]);
    }
    let output = tokio::process::Command::new("ssh-keygen")
        .args(&args)
        .output()
        .await?;

    if !output.status.success() {
        let stderr = String::from_utf8_lossy(&output.stderr);
        return Err(SshError::Command(stderr.to_string()));
    }

    // Cleanup guard: remove unencrypted key files on any subsequent failure
    struct KeyCleanup<'a> {
        path: &'a str,
        armed: bool,
    }
    impl Drop for KeyCleanup<'_> {
        fn drop(&mut self) {
            if self.armed {
                let _ = std::fs::remove_file(self.path);
                let _ = std::fs::remove_file(format!("{}.pub", self.path));
            }
        }
    }
    let mut cleanup = KeyCleanup {
        path: &key_path_str,
        armed: true,
    };

    // Step 2: Re-encrypt with the real passphrase via stdin so it never
    // appears in `ps` output. `ssh-keygen -p -f <key>` in interactive mode
    // prompts for: new passphrase, confirm new passphrase (skips old when empty).
    {
        use std::process::Stdio;
        use tokio::io::AsyncWriteExt as _;

        let mut child = tokio::process::Command::new("ssh-keygen")
            .args(["-p", "-f", &key_path_str])
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::piped())
            .spawn()?;

        if let Some(mut stdin) = child.stdin.take() {
            // When the old passphrase is empty, ssh-keygen skips prompting
            // for it and goes straight to new + confirm.
            // New passphrase
            stdin
                .write_all(passphrase.expose_secret().as_bytes())
                .await?;
            stdin.write_all(b"\n").await?;
            // Confirm new passphrase
            stdin
                .write_all(passphrase.expose_secret().as_bytes())
                .await?;
            stdin.write_all(b"\n").await?;
        }

        let rekey_output = child.wait_with_output().await?;
        if !rekey_output.status.success() {
            let stderr = String::from_utf8_lossy(&rekey_output.stderr);
            return Err(SshError::PassphraseApplicationFailed(format!(
                "ssh-keygen -p failed: {stderr}"
            )));
        }
    }

    // Store passphrase in macOS Keychain.
    store_passphrase_in_keychain(name, &passphrase).map_err(|e| {
        SshError::PassphraseApplicationFailed(format!("keychain storage failed: {e}"))
    })?;

    cleanup.armed = false;

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
    fn rejects_overlong_key_names() {
        assert!(validate_key_name(&"k".repeat(129)).is_err());
    }

    #[test]
    fn rejects_names_with_whitespace() {
        assert!(validate_key_name("my key").is_err());
        assert!(validate_key_name("key\tname").is_err());
        assert!(validate_key_name("key\nname").is_err());
    }

    #[test]
    fn validates_key_comments() {
        assert!(validate_key_comment("user@host").is_ok());
        assert!(validate_key_comment("bad\ncomment").is_err());
        assert!(validate_key_comment("nul\0comment").is_err());
        assert!(validate_key_comment(&"x".repeat(257)).is_err());
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

    #[test]
    fn secret_string_passphrase_not_in_debug_output() {
        use secrecy::ExposeSecret;
        let passphrase = generate_passphrase();
        let raw_value = passphrase.expose_secret().to_string();
        let debug_output = format!("{:?}", passphrase);
        // SecretString's Debug impl should NOT expose the actual value
        assert!(
            !debug_output.contains(&raw_value),
            "debug output must not contain the actual passphrase"
        );
        // secrecy::SecretString prints "SecretString([REDACTED])" or similar
        assert!(
            debug_output.contains("Secret"),
            "debug output should indicate it's a secret type: {debug_output}"
        );
    }
}
