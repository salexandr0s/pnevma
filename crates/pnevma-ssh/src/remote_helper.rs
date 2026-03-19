use crate::{shell_escape_arg, SshError, SshProfile};
use std::collections::HashMap;
use std::path::PathBuf;
use std::process::Stdio;
use tokio::io::AsyncWriteExt;
use tokio::process::Command;

const REMOTE_HELPER_REMOTE_PATH: &str = "$HOME/.local/share/pnevma/bin/pnevma-remote-helper";
const REMOTE_INSTALL_COMMAND: &str = "umask 077; mkdir -p \"$HOME/.local/share/pnevma/bin\"; cat > \"$HOME/.local/share/pnevma/bin/pnevma-remote-helper\"; chmod 700 \"$HOME/.local/share/pnevma/bin/pnevma-remote-helper\"";
const REMOTE_HELPER_SCRIPT: &str = include_str!("remote_helper.sh");
const REMOTE_HELPER_BINARY_NAME: &str = "pnevma-remote-helper";
const REMOTE_HELPER_PROTOCOL_VERSION: &str = "1";

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct RemoteHelperHealth {
    pub version: String,
    pub protocol_version: String,
    pub helper_kind: String,
    pub helper_path: String,
    pub state_root: String,
    pub controller_id: String,
    pub healthy: bool,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum RemoteHelperInstallKind {
    Existing,
    BinaryArtifact,
    ShellCompat,
}

impl RemoteHelperInstallKind {
    pub fn as_str(&self) -> &'static str {
        match self {
            Self::Existing => "existing",
            Self::BinaryArtifact => "binary_artifact",
            Self::ShellCompat => "shell_compat",
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct RemoteHelperEnsureResult {
    pub health: RemoteHelperHealth,
    pub installed: bool,
    pub install_kind: RemoteHelperInstallKind,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct RemoteSessionCreateResult {
    pub session_id: String,
    pub controller_id: String,
    pub state: String,
    pub pid: Option<u32>,
    pub log_path: Option<String>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct RemoteSessionStatus {
    pub session_id: String,
    pub controller_id: String,
    pub state: String,
    pub pid: Option<u32>,
    pub exit_code: Option<i32>,
    pub total_bytes: u64,
    pub last_output_at_epoch: Option<i64>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
struct SshCommandOutput {
    stdout: String,
}

#[derive(Debug, Clone, PartialEq, Eq)]
struct RemoteHelperPlatform {
    os: String,
    arch: String,
    target_triple: String,
}

pub fn build_remote_attach_command(profile: &SshProfile, session_id: &str) -> String {
    let mut args = ssh_args_without_binary(profile);
    args.insert(0, "-tt".to_string());
    args.insert(0, ssh_binary_name());
    args.push(remote_command_arg(&format!(
        "exec {} session attach --session-id {}",
        REMOTE_HELPER_REMOTE_PATH,
        shell_escape_arg(session_id)
    )));
    args.iter()
        .map(|arg| shell_escape_arg(arg))
        .collect::<Vec<_>>()
        .join(" ")
}

pub async fn ensure_remote_helper(
    profile: &SshProfile,
) -> Result<RemoteHelperEnsureResult, SshError> {
    match remote_helper_health(profile).await {
        Ok(health) => Ok(RemoteHelperEnsureResult {
            health,
            installed: false,
            install_kind: RemoteHelperInstallKind::Existing,
        }),
        Err(_) => {
            let install_kind = install_remote_helper(profile).await?;
            let health = remote_helper_health(profile).await?;
            Ok(RemoteHelperEnsureResult {
                health,
                installed: true,
                install_kind,
            })
        }
    }
}

pub async fn remote_helper_health(profile: &SshProfile) -> Result<RemoteHelperHealth, SshError> {
    let output = run_ssh(
        profile,
        &format!("exec {} health", REMOTE_HELPER_REMOTE_PATH),
        None,
    )
    .await?;
    let map = parse_kv_output(&output.stdout)?;
    Ok(RemoteHelperHealth {
        version: required_value(&map, "version")?.to_string(),
        protocol_version: map
            .get("protocol_version")
            .cloned()
            .unwrap_or_else(|| REMOTE_HELPER_PROTOCOL_VERSION.to_string()),
        helper_kind: map
            .get("helper_kind")
            .cloned()
            .unwrap_or_else(|| "shell_compat".to_string()),
        helper_path: required_value(&map, "helper_path")?.to_string(),
        state_root: required_value(&map, "state_root")?.to_string(),
        controller_id: required_value(&map, "controller_id")?.to_string(),
        healthy: map
            .get("healthy")
            .map(String::as_str)
            .unwrap_or("true")
            .eq_ignore_ascii_case("true"),
    })
}

pub async fn create_remote_session(
    profile: &SshProfile,
    session_id: &str,
    cwd: &str,
    command: Option<&str>,
) -> Result<RemoteSessionCreateResult, SshError> {
    let _ = ensure_remote_helper(profile).await?;
    let command = command.map(str::trim).filter(|value| !value.is_empty());
    let command_clause = command
        .map(|value| format!(" --command {}", shell_escape_arg(value)))
        .unwrap_or_default();
    let output = run_ssh(
        profile,
        &format!(
            "exec {} session create --session-id {} --cwd {}{} --json",
            REMOTE_HELPER_REMOTE_PATH,
            shell_escape_arg(session_id),
            shell_escape_arg(cwd),
            command_clause,
        ),
        None,
    )
    .await?;
    let map = parse_kv_output(&output.stdout)?;
    Ok(RemoteSessionCreateResult {
        session_id: required_value(&map, "session_id")?.to_string(),
        controller_id: required_value(&map, "controller_id")?.to_string(),
        state: required_value(&map, "state")?.to_string(),
        pid: optional_value(&map, "pid").and_then(|value| value.parse::<u32>().ok()),
        log_path: optional_value(&map, "log_path").map(ToOwned::to_owned),
    })
}

pub async fn remote_session_status(
    profile: &SshProfile,
    session_id: &str,
) -> Result<RemoteSessionStatus, SshError> {
    let output = run_ssh(
        profile,
        &format!(
            "exec {} session status --session-id {} --json",
            REMOTE_HELPER_REMOTE_PATH,
            shell_escape_arg(session_id)
        ),
        None,
    )
    .await?;
    let map = parse_kv_output(&output.stdout)?;
    Ok(RemoteSessionStatus {
        session_id: required_value(&map, "session_id")?.to_string(),
        controller_id: required_value(&map, "controller_id")?.to_string(),
        state: required_value(&map, "state")?.to_string(),
        pid: optional_value(&map, "pid").and_then(|value| value.parse::<u32>().ok()),
        exit_code: optional_value(&map, "exit_code").and_then(|value| value.parse::<i32>().ok()),
        total_bytes: optional_value(&map, "total_bytes")
            .and_then(|value| value.parse::<u64>().ok())
            .unwrap_or(0),
        last_output_at_epoch: optional_value(&map, "last_output_at")
            .and_then(|value| value.parse::<i64>().ok()),
    })
}

pub async fn signal_remote_session(
    profile: &SshProfile,
    session_id: &str,
    signal: &str,
) -> Result<(), SshError> {
    let _ = run_ssh(
        profile,
        &format!(
            "exec {} session signal --session-id {} --signal {} --json",
            REMOTE_HELPER_REMOTE_PATH,
            shell_escape_arg(session_id),
            shell_escape_arg(signal)
        ),
        None,
    )
    .await?;
    Ok(())
}

pub async fn terminate_remote_session(
    profile: &SshProfile,
    session_id: &str,
) -> Result<(), SshError> {
    let _ = run_ssh(
        profile,
        &format!(
            "exec {} session terminate --session-id {} --json",
            REMOTE_HELPER_REMOTE_PATH,
            shell_escape_arg(session_id)
        ),
        None,
    )
    .await?;
    Ok(())
}

pub async fn read_remote_scrollback_tail(
    profile: &SshProfile,
    session_id: &str,
    limit: usize,
) -> Result<String, SshError> {
    let output = run_ssh(
        profile,
        &format!(
            "exec {} session tail --session-id {} --limit {}",
            REMOTE_HELPER_REMOTE_PATH,
            shell_escape_arg(session_id),
            limit
        ),
        None,
    )
    .await?;
    Ok(output.stdout)
}

async fn install_remote_helper(profile: &SshProfile) -> Result<RemoteHelperInstallKind, SshError> {
    if let Some(artifact) = resolve_remote_helper_artifact(profile).await? {
        let bytes = std::fs::read(&artifact)?;
        run_ssh(profile, REMOTE_INSTALL_COMMAND, Some(&bytes)).await?;
        return Ok(RemoteHelperInstallKind::BinaryArtifact);
    }

    run_ssh(
        profile,
        REMOTE_INSTALL_COMMAND,
        Some(REMOTE_HELPER_SCRIPT.as_bytes()),
    )
    .await?;
    Ok(RemoteHelperInstallKind::ShellCompat)
}

async fn resolve_remote_helper_artifact(profile: &SshProfile) -> Result<Option<PathBuf>, SshError> {
    let platform = probe_remote_helper_platform(profile).await?;
    resolve_remote_helper_artifact_for_platform(&platform)
}

async fn probe_remote_helper_platform(
    profile: &SshProfile,
) -> Result<RemoteHelperPlatform, SshError> {
    let output = run_ssh(profile, "uname -sm", None).await?;
    parse_remote_helper_platform(&output.stdout)
}

fn parse_remote_helper_platform(output: &str) -> Result<RemoteHelperPlatform, SshError> {
    let mut parts = output.split_whitespace();
    let os = parts
        .next()
        .ok_or_else(|| SshError::Parse("missing remote platform os".to_string()))?;
    let arch = parts
        .next()
        .ok_or_else(|| SshError::Parse("missing remote platform arch".to_string()))?;
    let target_triple = match (
        os.to_ascii_lowercase().as_str(),
        arch.to_ascii_lowercase().as_str(),
    ) {
        ("linux", "x86_64") | ("linux", "amd64") => "x86_64-unknown-linux-musl",
        ("linux", "aarch64") | ("linux", "arm64") => "aarch64-unknown-linux-musl",
        ("darwin", "x86_64") | ("darwin", "amd64") => "x86_64-apple-darwin",
        ("darwin", "aarch64") | ("darwin", "arm64") => "aarch64-apple-darwin",
        _ => {
            return Ok(RemoteHelperPlatform {
                os: os.to_string(),
                arch: arch.to_string(),
                target_triple: format!("{}-{}", arch.to_ascii_lowercase(), os.to_ascii_lowercase()),
            })
        }
    };
    Ok(RemoteHelperPlatform {
        os: os.to_string(),
        arch: arch.to_string(),
        target_triple: target_triple.to_string(),
    })
}

fn resolve_remote_helper_artifact_for_platform(
    platform: &RemoteHelperPlatform,
) -> Result<Option<PathBuf>, SshError> {
    let explicit_key = format!(
        "PNEVMA_REMOTE_HELPER_ARTIFACT_{}",
        artifact_env_suffix(&platform.target_triple)
    );
    if let Some(path) = std::env::var_os(&explicit_key) {
        let path = PathBuf::from(path);
        if path.exists() {
            return Ok(Some(path));
        }
        return Err(SshError::NotFound(format!(
            "remote helper artifact override not found for {}: {}",
            platform.target_triple,
            path.display()
        )));
    }

    for candidate in artifact_search_paths(platform) {
        if candidate.exists() {
            return Ok(Some(candidate));
        }
    }
    Ok(None)
}

fn artifact_search_paths(platform: &RemoteHelperPlatform) -> Vec<PathBuf> {
    let mut candidates = Vec::new();
    if let Some(dir) = std::env::var_os("PNEVMA_REMOTE_HELPER_ARTIFACT_DIR") {
        candidates.push(
            PathBuf::from(dir)
                .join(&platform.target_triple)
                .join(REMOTE_HELPER_BINARY_NAME),
        );
    }
    if let Some(dir) = std::env::var_os("PNEVMA_REMOTE_HELPER_BUNDLE_DIR") {
        candidates.push(
            PathBuf::from(dir)
                .join(&platform.target_triple)
                .join(REMOTE_HELPER_BINARY_NAME),
        );
    }
    candidates.push(
        PathBuf::from(env!("CARGO_MANIFEST_DIR"))
            .join("../../artifacts/remote-helper")
            .join(&platform.target_triple)
            .join(REMOTE_HELPER_BINARY_NAME),
    );
    candidates
}

fn artifact_env_suffix(target_triple: &str) -> String {
    target_triple
        .chars()
        .map(|ch| {
            if ch.is_ascii_alphanumeric() {
                ch.to_ascii_uppercase()
            } else {
                '_'
            }
        })
        .collect()
}

fn parse_kv_output(output: &str) -> Result<HashMap<String, String>, SshError> {
    let mut values = HashMap::new();
    for line in output.lines() {
        let trimmed = line.trim();
        if trimmed.is_empty() {
            continue;
        }
        let Some((key, value)) = trimmed.split_once('=') else {
            return Err(SshError::Parse(format!(
                "invalid helper output line: {trimmed}"
            )));
        };
        values.insert(key.to_string(), value.to_string());
    }
    Ok(values)
}

fn required_value<'a>(map: &'a HashMap<String, String>, key: &str) -> Result<&'a str, SshError> {
    map.get(key)
        .map(String::as_str)
        .ok_or_else(|| SshError::Parse(format!("missing helper field: {key}")))
}

fn optional_value<'a>(map: &'a HashMap<String, String>, key: &str) -> Option<&'a str> {
    map.get(key)
        .map(String::as_str)
        .filter(|value| !value.trim().is_empty())
}

async fn run_ssh(
    profile: &SshProfile,
    remote_command: &str,
    stdin_bytes: Option<&[u8]>,
) -> Result<SshCommandOutput, SshError> {
    let mut command = Command::new(ssh_binary_path());
    command
        .args(ssh_args_without_binary(profile))
        .arg(remote_command_arg(remote_command))
        .stdout(Stdio::piped())
        .stderr(Stdio::piped());
    if stdin_bytes.is_some() {
        command.stdin(Stdio::piped());
    } else {
        command.stdin(Stdio::null());
    }

    let mut child = command.spawn()?;
    if let Some(stdin_bytes) = stdin_bytes {
        let mut stdin = child
            .stdin
            .take()
            .ok_or_else(|| SshError::Command("ssh stdin unavailable".to_string()))?;
        stdin.write_all(stdin_bytes).await?;
        stdin.shutdown().await?;
    }
    let output = child.wait_with_output().await?;
    if !output.status.success() {
        let stderr = String::from_utf8_lossy(&output.stderr).trim().to_string();
        return Err(SshError::Command(if stderr.is_empty() {
            format!("ssh command failed with status {}", output.status)
        } else {
            stderr
        }));
    }
    Ok(SshCommandOutput {
        stdout: String::from_utf8_lossy(&output.stdout).to_string(),
    })
}

fn remote_command_arg(remote_command: &str) -> String {
    format!("sh -lc {}", shell_escape_arg(remote_command))
}

fn ssh_binary_name() -> String {
    std::env::var("PNEVMA_SSH_NAME").unwrap_or_else(|_| "ssh".to_string())
}

fn ssh_binary_path() -> PathBuf {
    std::env::var_os("PNEVMA_SSH_BIN")
        .map(PathBuf::from)
        .unwrap_or_else(|| resolve_local_binary("ssh"))
}

fn resolve_local_binary(name: &str) -> PathBuf {
    for dir in ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin"] {
        let candidate = PathBuf::from(dir).join(name);
        if candidate.exists() {
            return candidate;
        }
    }
    PathBuf::from(name)
}

fn ssh_args_without_binary(profile: &SshProfile) -> Vec<String> {
    let mut args = crate::build_ssh_command(profile);
    if !args.is_empty() {
        args.remove(0);
    }
    args
}

#[cfg(test)]
mod tests {
    use super::*;
    use chrono::Utc;
    use std::sync::OnceLock;
    use tempfile::tempdir;
    use tokio::fs;
    use tokio::sync::Mutex;

    fn sample_profile() -> SshProfile {
        SshProfile {
            id: "profile-1".to_string(),
            name: "Sample".to_string(),
            host: "example.internal".to_string(),
            port: 22,
            user: Some("builder".to_string()),
            identity_file: Some("/tmp/id_ed25519".to_string()),
            proxy_jump: Some("jump.internal".to_string()),
            tags: Vec::new(),
            source: "manual".to_string(),
            created_at: Utc::now(),
            updated_at: Utc::now(),
        }
    }

    fn env_lock() -> &'static Mutex<()> {
        static LOCK: OnceLock<Mutex<()>> = OnceLock::new();
        LOCK.get_or_init(|| Mutex::new(()))
    }

    #[test]
    fn build_remote_attach_command_includes_helper_attach() {
        let command = build_remote_attach_command(&sample_profile(), "session-1");
        assert!(command.contains("pnevma-remote-helper session attach"));
        assert!(command.contains("session-1"));
        assert!(command.contains("-tt"));
    }

    #[test]
    fn parse_kv_output_parses_lines() {
        let values = parse_kv_output("version=v1\nhealthy=true\n").expect("parse output");
        assert_eq!(values.get("version").map(String::as_str), Some("v1"));
        assert_eq!(values.get("healthy").map(String::as_str), Some("true"));
    }

    #[test]
    fn parse_remote_helper_platform_maps_known_targets() {
        let linux = parse_remote_helper_platform("Linux x86_64\n").expect("linux platform");
        assert_eq!(linux.target_triple, "x86_64-unknown-linux-musl");

        let darwin = parse_remote_helper_platform("Darwin arm64\n").expect("darwin platform");
        assert_eq!(darwin.target_triple, "aarch64-apple-darwin");
    }

    #[tokio::test]
    async fn ensure_remote_helper_prefers_binary_artifact_when_available() {
        let _guard = env_lock().lock().await;
        let temp = tempdir().expect("tempdir");
        let fake_home = temp.path().join("home");
        std::fs::create_dir_all(&fake_home).expect("create fake home");
        let fake_ssh = temp.path().join("fake-ssh.sh");
        std::fs::write(
            &fake_ssh,
            format!(
                "#!/bin/sh\nset -eu\nexport HOME={}\nremote_cmd=\"\"\nfor arg in \"$@\"; do remote_cmd=\"$arg\"; done\nexec sh -lc \"$remote_cmd\"\n",
                shell_escape_arg(fake_home.to_string_lossy().as_ref())
            ),
        )
        .expect("write fake ssh");
        use std::os::unix::fs::PermissionsExt;
        std::fs::set_permissions(&fake_ssh, std::fs::Permissions::from_mode(0o755))
            .expect("chmod fake ssh");

        let fake_artifact = temp.path().join("pnevma-remote-helper-artifact");
        std::fs::write(
            &fake_artifact,
            "#!/bin/sh\nset -eu\nprintf 'version=binary-artifact\\n'\nprintf 'protocol_version=1\\n'\nprintf 'helper_kind=binary\\n'\nprintf 'helper_path=%s\\n' \"$0\"\nprintf 'state_root=%s/.local/state/pnevma/remote\\n' \"$HOME\"\nprintf 'controller_id=controller-binary\\n'\nprintf 'healthy=true\\n'\n",
        )
        .expect("write fake artifact");
        std::fs::set_permissions(&fake_artifact, std::fs::Permissions::from_mode(0o755))
            .expect("chmod fake artifact");

        let platform = parse_remote_helper_platform(
            &String::from_utf8(
                std::process::Command::new("uname")
                    .arg("-sm")
                    .output()
                    .expect("uname")
                    .stdout,
            )
            .expect("uname output"),
        )
        .expect("parse platform");
        let artifact_key = format!(
            "PNEVMA_REMOTE_HELPER_ARTIFACT_{}",
            artifact_env_suffix(&platform.target_triple)
        );

        std::env::set_var("PNEVMA_SSH_BIN", &fake_ssh);
        std::env::set_var(&artifact_key, &fake_artifact);
        let profile = sample_profile();
        let result = ensure_remote_helper(&profile)
            .await
            .expect("ensure remote helper");
        assert!(result.health.healthy);
        assert!(result.installed);
        assert_eq!(result.install_kind, RemoteHelperInstallKind::BinaryArtifact);
        assert_eq!(result.health.helper_kind, "binary");
        let helper_path = fake_home.join(".local/share/pnevma/bin/pnevma-remote-helper");
        let helper = fs::read_to_string(&helper_path)
            .await
            .expect("helper binary artifact should exist");
        assert!(helper.contains("controller-binary"));
        std::env::remove_var(&artifact_key);
        std::env::remove_var("PNEVMA_SSH_BIN");
    }

    #[tokio::test]
    async fn ensure_remote_helper_uses_script_fallback_when_artifact_missing() {
        let _guard = env_lock().lock().await;
        let temp = tempdir().expect("tempdir");
        let fake_home = temp.path().join("home");
        std::fs::create_dir_all(&fake_home).expect("create fake home");
        let fake_ssh = temp.path().join("fake-ssh.sh");
        std::fs::write(
            &fake_ssh,
            format!(
                "#!/bin/sh\nset -eu\nexport HOME={}\nremote_cmd=\"\"\nfor arg in \"$@\"; do remote_cmd=\"$arg\"; done\nexec sh -lc \"$remote_cmd\"\n",
                shell_escape_arg(fake_home.to_string_lossy().as_ref())
            ),
        )
        .expect("write fake ssh");
        use std::os::unix::fs::PermissionsExt;
        std::fs::set_permissions(&fake_ssh, std::fs::Permissions::from_mode(0o755))
            .expect("chmod fake ssh");

        std::env::set_var("PNEVMA_SSH_BIN", &fake_ssh);
        let profile = sample_profile();
        let result = ensure_remote_helper(&profile)
            .await
            .expect("ensure remote helper");
        assert!(result.health.healthy);
        assert!(result.installed);
        assert_eq!(result.install_kind, RemoteHelperInstallKind::ShellCompat);
        let helper_path = fake_home.join(".local/share/pnevma/bin/pnevma-remote-helper");
        let helper = fs::read_to_string(&helper_path)
            .await
            .expect("helper script should exist");
        assert!(helper.contains("pnevma-remote-helper-v1"));
        std::env::remove_var("PNEVMA_SSH_BIN");
    }
}
