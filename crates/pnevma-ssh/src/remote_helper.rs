use crate::{shell_escape_arg, SshError, SshProfile};
use serde::Deserialize;
use serde_json;
use sha2::{Digest, Sha256};
use std::collections::HashMap;
use std::fs;
use std::path::{Path, PathBuf};
use std::process::Stdio;
use tokio::io::AsyncWriteExt;
use tokio::process::Command;

const REMOTE_HELPER_REMOTE_PATH: &str = "$HOME/.local/share/pnevma/bin/pnevma-remote-helper";
const REMOTE_INSTALL_COMMAND: &str = "umask 077; mkdir -p \"$HOME/.local/share/pnevma/bin\"; cat > \"$HOME/.local/share/pnevma/bin/pnevma-remote-helper\"; chmod 700 \"$HOME/.local/share/pnevma/bin/pnevma-remote-helper\"";
const REMOTE_INSTALL_METADATA_COMMAND: &str = "umask 077; mkdir -p \"$HOME/.local/share/pnevma/bin\"; cat > \"$HOME/.local/share/pnevma/bin/pnevma-remote-helper.metadata\"; chmod 600 \"$HOME/.local/share/pnevma/bin/pnevma-remote-helper.metadata\"";
const REMOTE_HELPER_SCRIPT: &str = include_str!("remote_helper.sh");
#[cfg(test)]
const REMOTE_HELPER_BINARY_NAME: &str = "pnevma-remote-helper";
const REMOTE_HELPER_MANIFEST_NAME: &str = "manifest.json";
const REMOTE_HELPER_PROTOCOL_VERSION: &str = "1";
const REMOTE_HELPER_MANIFEST_SCHEMA_VERSION: u32 = 1;
const REMOTE_HELPER_ARTIFACT_ROOT: &str = "remote-helper";
const SUPPORTED_REMOTE_HELPER_TARGETS: &[&str] = &[
    "x86_64-unknown-linux-musl",
    "aarch64-unknown-linux-musl",
    "x86_64-apple-darwin",
    "aarch64-apple-darwin",
];

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct RemoteHelperHealth {
    pub version: String,
    pub protocol_version: String,
    pub helper_kind: String,
    pub helper_path: String,
    pub state_root: String,
    pub controller_id: String,
    pub healthy: bool,
    pub target_triple: Option<String>,
    pub artifact_source: Option<String>,
    pub artifact_sha256: Option<String>,
    pub protocol_compatible: bool,
    pub missing_dependencies: Vec<String>,
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

#[derive(Debug, Clone, PartialEq, Eq)]
enum RemoteHelperArtifactSource {
    EnvOverride,
    ArtifactDir,
    BundleDir,
    BundleRelative,
    RepoArtifacts,
    ShellCompat,
}

impl RemoteHelperArtifactSource {
    fn as_str(&self) -> &'static str {
        match self {
            Self::EnvOverride => "env_override",
            Self::ArtifactDir => "artifact_dir",
            Self::BundleDir => "bundle_dir",
            Self::BundleRelative => "bundle_relative",
            Self::RepoArtifacts => "repo_artifacts",
            Self::ShellCompat => "shell_compat",
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
struct ResolvedRemoteHelperArtifact {
    path: PathBuf,
    target_triple: String,
    artifact_source: RemoteHelperArtifactSource,
    artifact_sha256: String,
    artifact_size: u64,
    protocol_version: String,
    package_version: String,
}

#[derive(Debug, Clone, PartialEq, Eq)]
enum RemoteHelperInstallPlan {
    Artifact(ResolvedRemoteHelperArtifact),
    ShellCompat { target_triple: String },
}

#[derive(Debug, Clone, PartialEq, Eq)]
struct RemoteHelperInstallMetadata {
    target_triple: String,
    artifact_source: String,
    artifact_sha256: String,
}

#[derive(Debug, Deserialize)]
struct RemoteHelperArtifactManifest {
    schema_version: u32,
    package_version: String,
    protocol_version: String,
    artifacts: Vec<RemoteHelperArtifactManifestEntry>,
}

#[derive(Debug, Deserialize)]
struct RemoteHelperArtifactManifestEntry {
    target_triple: String,
    relative_path: String,
    sha256: String,
    size: u64,
}

pub fn build_remote_attach_command(
    profile: &SshProfile,
    session_id: &str,
) -> Result<String, crate::SshError> {
    let mut args = ssh_args_without_binary(profile, crate::SshKeepAliveMode::Interactive)?;
    args.insert(0, "-tt".to_string());
    args.insert(0, ssh_binary_path().to_string_lossy().to_string());
    args.push(remote_command_arg(&format!(
        "exec {} session attach --session-id {}",
        REMOTE_HELPER_REMOTE_PATH,
        shell_escape_arg(session_id)
    )));
    Ok(args
        .iter()
        .map(|arg| shell_escape_arg(arg))
        .collect::<Vec<_>>()
        .join(" "))
}

pub async fn ensure_remote_helper(
    profile: &SshProfile,
) -> Result<RemoteHelperEnsureResult, SshError> {
    let platform = probe_remote_helper_platform(profile).await?;
    let plan = resolve_remote_helper_install_plan(&platform)?;
    let expected_version = expected_remote_helper_version();

    if let Ok(health) = remote_helper_health_for_platform(profile, &platform).await {
        if helper_satisfies_install_plan(&health, &plan, &expected_version) {
            return Ok(RemoteHelperEnsureResult {
                health,
                installed: false,
                install_kind: RemoteHelperInstallKind::Existing,
            });
        }
    }

    let install_kind = install_remote_helper(profile, &plan).await?;
    let mut health = remote_helper_health_for_platform(profile, &platform).await?;
    enrich_health_from_install_plan(&mut health, &plan);
    validate_remote_helper_health(&health, &plan)?;

    Ok(RemoteHelperEnsureResult {
        health,
        installed: true,
        install_kind,
    })
}

pub async fn remote_helper_health(profile: &SshProfile) -> Result<RemoteHelperHealth, SshError> {
    let platform = probe_remote_helper_platform(profile).await?;
    remote_helper_health_for_platform(profile, &platform).await
}

pub async fn create_remote_session(
    profile: &SshProfile,
    session_id: &str,
    cwd: &str,
    command: Option<&str>,
) -> Result<RemoteSessionCreateResult, SshError> {
    if let Some(client) = crate::rpc_pool::rpc_pool().get_or_connect(profile).await {
        let params = serde_json::json!({
            "session_id": session_id,
            "cwd": cwd,
            "command": command,
        });
        if let Ok(result) = client.call("session.create", params).await {
            return parse_create_result_from_json(result);
        }
    }
    create_remote_session_via_ssh(profile, session_id, cwd, command).await
}

async fn create_remote_session_via_ssh(
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
    let output = run_ssh_with_tty(
        profile,
        &format!(
            "exec {} session create --session-id {} --cwd {}{} --json",
            REMOTE_HELPER_REMOTE_PATH,
            shell_escape_arg(session_id),
            shell_escape_arg(cwd),
            command_clause,
        ),
        None,
        true,
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
    if let Some(client) = crate::rpc_pool::rpc_pool().get_or_connect(profile).await {
        let params = serde_json::json!({"session_id": session_id});
        if let Ok(result) = client.call("session.status", params).await {
            return parse_status_from_json(result);
        }
    }
    remote_session_status_via_ssh(profile, session_id).await
}

async fn remote_session_status_via_ssh(
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
    if let Some(client) = crate::rpc_pool::rpc_pool().get_or_connect(profile).await {
        let params = serde_json::json!({"session_id": session_id, "signal": signal});
        if client.call("session.signal", params).await.is_ok() {
            return Ok(());
        }
    }
    signal_remote_session_via_ssh(profile, session_id, signal).await
}

async fn signal_remote_session_via_ssh(
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
    if let Some(client) = crate::rpc_pool::rpc_pool().get_or_connect(profile).await {
        let params = serde_json::json!({"session_id": session_id});
        if client.call("session.terminate", params).await.is_ok() {
            return Ok(());
        }
    }
    terminate_remote_session_via_ssh(profile, session_id).await
}

async fn terminate_remote_session_via_ssh(
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

pub async fn list_remote_sessions(
    profile: &SshProfile,
) -> Result<Vec<RemoteSessionStatus>, SshError> {
    if let Some(client) = crate::rpc_pool::rpc_pool().get_or_connect(profile).await {
        let result = client.call("session.list", serde_json::json!({})).await?;
        let sessions = result
            .get("sessions")
            .and_then(|v| v.as_array())
            .ok_or_else(|| SshError::Parse("missing sessions array".to_string()))?;
        return sessions
            .iter()
            .map(|v| parse_status_from_json(v.clone()))
            .collect();
    }
    Err(SshError::Command(
        "RPC not available; session.list requires the serve mode control socket".to_string(),
    ))
}

pub async fn start_remote_serve_mode(profile: &SshProfile) -> Result<(), SshError> {
    // Check if serve mode is already reachable via the pool.
    if let Some(client) = crate::rpc_pool::rpc_pool().get_or_connect(profile).await {
        if client.call("health", serde_json::json!({})).await.is_ok() {
            return Ok(());
        }
    }
    // Start serve in background on the remote host.
    let _ = run_ssh(
        profile,
        &format!(
            "nohup {} serve >/dev/null 2>&1 &",
            REMOTE_HELPER_REMOTE_PATH,
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

/// Read a file from the remote host via SSH command execution.
pub async fn read_remote_file(
    profile: &SshProfile,
    path: &str,
    limit: Option<usize>,
) -> Result<Vec<u8>, SshError> {
    let limit_arg = limit.map(|l| format!(" | head -c {l}")).unwrap_or_default();
    let output = run_ssh(
        profile,
        &format!("cat -- {} {}", shell_escape_arg(path), limit_arg),
        None,
    )
    .await?;
    Ok(output.stdout.into_bytes())
}

/// List a remote directory via SSH, returning entries as JSON.
pub async fn list_remote_directory(
    profile: &SshProfile,
    path: &str,
) -> Result<Vec<RemoteDirEntry>, SshError> {
    let output = run_ssh(
        profile,
        &format!("ls -1pa -- {}", shell_escape_arg(path),),
        None,
    )
    .await?;

    let entries = output
        .stdout
        .lines()
        .filter(|line| !line.is_empty())
        .map(|line| {
            let is_dir = line.ends_with('/');
            let name = if is_dir {
                line.trim_end_matches('/').to_string()
            } else {
                line.to_string()
            };
            RemoteDirEntry { name, is_dir }
        })
        .collect();

    Ok(entries)
}

/// A single entry in a remote directory listing.
#[derive(Debug, Clone, serde::Serialize, serde::Deserialize)]
pub struct RemoteDirEntry {
    pub name: String,
    pub is_dir: bool,
}

async fn remote_helper_health_for_platform(
    profile: &SshProfile,
    platform: &RemoteHelperPlatform,
) -> Result<RemoteHelperHealth, SshError> {
    let output = run_ssh(
        profile,
        &format!("exec {} health", REMOTE_HELPER_REMOTE_PATH),
        None,
    )
    .await?;
    let map = parse_kv_output(&output.stdout)?;
    let protocol_version = map
        .get("protocol_version")
        .cloned()
        .unwrap_or_else(|| REMOTE_HELPER_PROTOCOL_VERSION.to_string());
    let missing_dependencies = optional_value(&map, "missing_dependencies")
        .map(|value| {
            value
                .split(',')
                .map(str::trim)
                .filter(|entry| !entry.is_empty())
                .map(ToOwned::to_owned)
                .collect::<Vec<_>>()
        })
        .unwrap_or_default();
    let healthy = map
        .get("healthy")
        .map(String::as_str)
        .unwrap_or("true")
        .eq_ignore_ascii_case("true");

    Ok(RemoteHelperHealth {
        version: required_value(&map, "version")?.to_string(),
        protocol_version: protocol_version.clone(),
        helper_kind: map
            .get("helper_kind")
            .cloned()
            .unwrap_or_else(|| "shell_compat".to_string()),
        helper_path: required_value(&map, "helper_path")?.to_string(),
        state_root: required_value(&map, "state_root")?.to_string(),
        controller_id: required_value(&map, "controller_id")?.to_string(),
        healthy,
        target_triple: optional_value(&map, "target_triple")
            .map(ToOwned::to_owned)
            .or_else(|| Some(platform.target_triple.clone())),
        artifact_source: optional_value(&map, "artifact_source").map(ToOwned::to_owned),
        artifact_sha256: optional_value(&map, "artifact_sha256").map(ToOwned::to_owned),
        protocol_compatible: protocol_version == REMOTE_HELPER_PROTOCOL_VERSION,
        missing_dependencies,
    })
}

async fn install_remote_helper(
    profile: &SshProfile,
    plan: &RemoteHelperInstallPlan,
) -> Result<RemoteHelperInstallKind, SshError> {
    match plan {
        RemoteHelperInstallPlan::Artifact(artifact) => {
            let bytes = fs::read(&artifact.path)?;
            validate_artifact_bytes(artifact, &bytes)?;
            run_ssh(profile, REMOTE_INSTALL_COMMAND, Some(&bytes)).await?;
            install_remote_helper_metadata(
                profile,
                &RemoteHelperInstallMetadata {
                    target_triple: artifact.target_triple.clone(),
                    artifact_source: artifact.artifact_source.as_str().to_string(),
                    artifact_sha256: artifact.artifact_sha256.clone(),
                },
            )
            .await?;
            Ok(RemoteHelperInstallKind::BinaryArtifact)
        }
        RemoteHelperInstallPlan::ShellCompat { target_triple } => {
            run_ssh(
                profile,
                REMOTE_INSTALL_COMMAND,
                Some(REMOTE_HELPER_SCRIPT.as_bytes()),
            )
            .await?;
            install_remote_helper_metadata(
                profile,
                &RemoteHelperInstallMetadata {
                    target_triple: target_triple.clone(),
                    artifact_source: RemoteHelperArtifactSource::ShellCompat.as_str().to_string(),
                    artifact_sha256: sha256_hex(REMOTE_HELPER_SCRIPT.as_bytes()),
                },
            )
            .await?;
            Ok(RemoteHelperInstallKind::ShellCompat)
        }
    }
}

async fn install_remote_helper_metadata(
    profile: &SshProfile,
    metadata: &RemoteHelperInstallMetadata,
) -> Result<(), SshError> {
    let body = format!(
        "target_triple={}\nartifact_source={}\nartifact_sha256={}\n",
        metadata.target_triple, metadata.artifact_source, metadata.artifact_sha256
    );
    let _ = run_ssh(
        profile,
        REMOTE_INSTALL_METADATA_COMMAND,
        Some(body.as_bytes()),
    )
    .await?;
    Ok(())
}

fn resolve_remote_helper_install_plan(
    platform: &RemoteHelperPlatform,
) -> Result<RemoteHelperInstallPlan, SshError> {
    if is_supported_remote_helper_target(&platform.target_triple) {
        match resolve_remote_helper_artifact_for_platform(platform, None)? {
            Some(artifact) => Ok(RemoteHelperInstallPlan::Artifact(artifact)),
            None if allow_shell_compat_fallback() => Ok(RemoteHelperInstallPlan::ShellCompat {
                target_triple: platform.target_triple.clone(),
            }),
            None => Err(SshError::MissingRemoteHelperArtifact(format!(
                "no packaged remote helper artifact available for {} (supported targets: {})",
                platform.target_triple,
                supported_target_matrix()
            ))),
        }
    } else if allow_shell_compat_fallback() {
        Ok(RemoteHelperInstallPlan::ShellCompat {
            target_triple: platform.target_triple.clone(),
        })
    } else {
        Err(SshError::UnsupportedRemoteHelperPlatform(format!(
            "{} / {} -> {} (supported targets: {}; set PNEVMA_REMOTE_HELPER_ALLOW_SHELL_COMPAT=1 for compatibility mode)",
            platform.os,
            platform.arch,
            platform.target_triple,
            supported_target_matrix()
        )))
    }
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
    current_exe_override: Option<&Path>,
) -> Result<Option<ResolvedRemoteHelperArtifact>, SshError> {
    let explicit_key = format!(
        "PNEVMA_REMOTE_HELPER_ARTIFACT_{}",
        artifact_env_suffix(&platform.target_triple)
    );
    if let Some(path) = std::env::var_os(&explicit_key) {
        let path = PathBuf::from(path);
        if !path.exists() {
            return Err(SshError::NotFound(format!(
                "remote helper artifact override not found for {}: {}",
                platform.target_triple,
                path.display()
            )));
        }
        let metadata = fs::metadata(&path)?;
        return Ok(Some(ResolvedRemoteHelperArtifact {
            artifact_sha256: sha256_hex(&fs::read(&path)?),
            artifact_size: metadata.len(),
            artifact_source: RemoteHelperArtifactSource::EnvOverride,
            package_version: env!("CARGO_PKG_VERSION").to_string(),
            path,
            protocol_version: REMOTE_HELPER_PROTOCOL_VERSION.to_string(),
            target_triple: platform.target_triple.clone(),
        }));
    }

    if let Some(dir) = std::env::var_os("PNEVMA_REMOTE_HELPER_ARTIFACT_DIR") {
        return resolve_remote_helper_manifest_root(
            &PathBuf::from(dir),
            platform,
            RemoteHelperArtifactSource::ArtifactDir,
            true,
        );
    }

    if let Some(dir) = std::env::var_os("PNEVMA_REMOTE_HELPER_BUNDLE_DIR") {
        return resolve_remote_helper_manifest_root(
            &PathBuf::from(dir),
            platform,
            RemoteHelperArtifactSource::BundleDir,
            true,
        );
    }

    if let Some(bundle_root) = current_exe_override
        .and_then(bundle_artifact_root_from_current_exe)
        .or_else(current_exe_bundle_artifact_root)
    {
        if let Some(artifact) = resolve_remote_helper_manifest_root(
            &bundle_root,
            platform,
            RemoteHelperArtifactSource::BundleRelative,
            false,
        )? {
            return Ok(Some(artifact));
        }
    }

    resolve_remote_helper_manifest_root(
        &repo_artifact_root(),
        platform,
        RemoteHelperArtifactSource::RepoArtifacts,
        false,
    )
}

fn resolve_remote_helper_manifest_root(
    root: &Path,
    platform: &RemoteHelperPlatform,
    source: RemoteHelperArtifactSource,
    require_manifest: bool,
) -> Result<Option<ResolvedRemoteHelperArtifact>, SshError> {
    let manifest_path = root.join(REMOTE_HELPER_MANIFEST_NAME);
    if !manifest_path.exists() {
        if require_manifest {
            return Err(SshError::MissingRemoteHelperArtifact(format!(
                "remote helper manifest not found at {} for {}",
                manifest_path.display(),
                platform.target_triple
            )));
        }
        return Ok(None);
    }

    let manifest_bytes = fs::read(&manifest_path)?;
    let manifest: RemoteHelperArtifactManifest =
        serde_json::from_slice(&manifest_bytes).map_err(|error| {
            SshError::Parse(format!(
                "failed to parse remote helper manifest {}: {}",
                manifest_path.display(),
                error
            ))
        })?;

    if manifest.schema_version != REMOTE_HELPER_MANIFEST_SCHEMA_VERSION {
        return Err(SshError::Parse(format!(
            "unsupported remote helper manifest schema {} at {}",
            manifest.schema_version,
            manifest_path.display()
        )));
    }
    if manifest.package_version != env!("CARGO_PKG_VERSION") {
        return Err(SshError::RemoteHelperVersionMismatch(format!(
            "manifest {} targets package version {}, expected {}",
            manifest_path.display(),
            manifest.package_version,
            env!("CARGO_PKG_VERSION")
        )));
    }
    if manifest.protocol_version != REMOTE_HELPER_PROTOCOL_VERSION {
        return Err(SshError::RemoteHelperProtocolMismatch(format!(
            "manifest {} declares protocol {}, expected {}",
            manifest_path.display(),
            manifest.protocol_version,
            REMOTE_HELPER_PROTOCOL_VERSION
        )));
    }

    let entry = manifest
        .artifacts
        .into_iter()
        .find(|entry| entry.target_triple == platform.target_triple);
    let Some(entry) = entry else {
        return Err(SshError::MissingRemoteHelperArtifact(format!(
            "remote helper manifest {} does not contain an artifact for {}",
            manifest_path.display(),
            platform.target_triple
        )));
    };

    let artifact_path = root.join(&entry.relative_path);
    if !artifact_path.exists() {
        return Err(SshError::MissingRemoteHelperArtifact(format!(
            "remote helper artifact {} referenced by {} is missing",
            artifact_path.display(),
            manifest_path.display()
        )));
    }

    Ok(Some(ResolvedRemoteHelperArtifact {
        path: artifact_path,
        target_triple: entry.target_triple,
        artifact_source: source,
        artifact_sha256: entry.sha256,
        artifact_size: entry.size,
        protocol_version: manifest.protocol_version,
        package_version: manifest.package_version,
    }))
}

fn bundle_artifact_root_from_current_exe(exe_path: &Path) -> Option<PathBuf> {
    let macos_dir = exe_path.parent()?;
    let contents_dir = macos_dir.parent()?;
    Some(
        contents_dir
            .join("Resources")
            .join(REMOTE_HELPER_ARTIFACT_ROOT),
    )
}

fn current_exe_bundle_artifact_root() -> Option<PathBuf> {
    std::env::current_exe()
        .ok()
        .as_deref()
        .and_then(bundle_artifact_root_from_current_exe)
}

fn repo_artifact_root() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../../artifacts/remote-helper")
}

fn allow_shell_compat_fallback() -> bool {
    std::env::var("PNEVMA_REMOTE_HELPER_ALLOW_SHELL_COMPAT")
        .map(|value| value == "1")
        .unwrap_or(false)
}

fn expected_remote_helper_version() -> String {
    format!("pnevma-remote-helper/{}", env!("CARGO_PKG_VERSION"))
}

fn helper_satisfies_install_plan(
    health: &RemoteHelperHealth,
    plan: &RemoteHelperInstallPlan,
    expected_version: &str,
) -> bool {
    if !health.protocol_compatible || !health.healthy || !health.missing_dependencies.is_empty() {
        return false;
    }

    match plan {
        RemoteHelperInstallPlan::Artifact(artifact) => {
            health.helper_kind == "binary"
                && health.version == expected_version
                && health.target_triple.as_deref() == Some(artifact.target_triple.as_str())
                && health.artifact_source.as_deref() == Some(artifact.artifact_source.as_str())
                && health.artifact_sha256.as_deref() == Some(artifact.artifact_sha256.as_str())
        }
        RemoteHelperInstallPlan::ShellCompat { .. } => health.helper_kind == "shell_compat",
    }
}

fn enrich_health_from_install_plan(
    health: &mut RemoteHelperHealth,
    plan: &RemoteHelperInstallPlan,
) {
    match plan {
        RemoteHelperInstallPlan::Artifact(artifact) => {
            if health.target_triple.is_none() {
                health.target_triple = Some(artifact.target_triple.clone());
            }
            if health.artifact_source.is_none() {
                health.artifact_source = Some(artifact.artifact_source.as_str().to_string());
            }
            if health.artifact_sha256.is_none() {
                health.artifact_sha256 = Some(artifact.artifact_sha256.clone());
            }
        }
        RemoteHelperInstallPlan::ShellCompat { target_triple } => {
            if health.target_triple.is_none() {
                health.target_triple = Some(target_triple.clone());
            }
            if health.artifact_source.is_none() {
                health.artifact_source =
                    Some(RemoteHelperArtifactSource::ShellCompat.as_str().to_string());
            }
            if health.artifact_sha256.is_none() {
                health.artifact_sha256 = Some(sha256_hex(REMOTE_HELPER_SCRIPT.as_bytes()));
            }
        }
    }
}

fn validate_remote_helper_health(
    health: &RemoteHelperHealth,
    plan: &RemoteHelperInstallPlan,
) -> Result<(), SshError> {
    if !health.protocol_compatible {
        return Err(SshError::RemoteHelperProtocolMismatch(format!(
            "expected protocol {}, got {}",
            REMOTE_HELPER_PROTOCOL_VERSION, health.protocol_version
        )));
    }
    if !health.missing_dependencies.is_empty() {
        return Err(SshError::RemoteHelperDependency(format!(
            "missing remote helper dependencies: {}",
            health.missing_dependencies.join(", ")
        )));
    }
    if !health.healthy {
        return Err(SshError::Command(
            "remote helper health check returned unhealthy".to_string(),
        ));
    }

    match plan {
        RemoteHelperInstallPlan::Artifact(artifact) => {
            if health.helper_kind != "binary" {
                return Err(SshError::Command(format!(
                    "expected packaged binary helper for {}, got {}",
                    artifact.target_triple, health.helper_kind
                )));
            }
            let expected_version = expected_remote_helper_version();
            if health.version != expected_version {
                return Err(SshError::RemoteHelperVersionMismatch(format!(
                    "expected remote helper version {}, got {}",
                    expected_version, health.version
                )));
            }
            if health.target_triple.as_deref() != Some(artifact.target_triple.as_str()) {
                return Err(SshError::Command(format!(
                    "expected remote helper target {}, got {}",
                    artifact.target_triple,
                    health.target_triple.as_deref().unwrap_or("<unknown>")
                )));
            }
            if health.artifact_source.as_deref() != Some(artifact.artifact_source.as_str()) {
                return Err(SshError::Command(format!(
                    "expected remote helper artifact source {}, got {}",
                    artifact.artifact_source.as_str(),
                    health.artifact_source.as_deref().unwrap_or("<unknown>")
                )));
            }
            if health.artifact_sha256.as_deref() != Some(artifact.artifact_sha256.as_str()) {
                return Err(SshError::RemoteHelperDigestMismatch(format!(
                    "expected remote helper sha256 {}, got {}",
                    artifact.artifact_sha256,
                    health.artifact_sha256.as_deref().unwrap_or("<unknown>")
                )));
            }
        }
        RemoteHelperInstallPlan::ShellCompat { target_triple } => {
            if health.helper_kind != "shell_compat" {
                return Err(SshError::Command(format!(
                    "expected shell compatibility helper for {}, got {}",
                    target_triple, health.helper_kind
                )));
            }
        }
    }

    Ok(())
}

fn validate_artifact_bytes(
    artifact: &ResolvedRemoteHelperArtifact,
    bytes: &[u8],
) -> Result<(), SshError> {
    let actual_sha = sha256_hex(bytes);
    if actual_sha != artifact.artifact_sha256 {
        return Err(SshError::RemoteHelperDigestMismatch(format!(
            "{} expected sha256 {}, got {}",
            artifact.path.display(),
            artifact.artifact_sha256,
            actual_sha
        )));
    }
    if bytes.len() as u64 != artifact.artifact_size {
        return Err(SshError::RemoteHelperDigestMismatch(format!(
            "{} expected size {}, got {}",
            artifact.path.display(),
            artifact.artifact_size,
            bytes.len()
        )));
    }
    if artifact.protocol_version != REMOTE_HELPER_PROTOCOL_VERSION {
        return Err(SshError::RemoteHelperProtocolMismatch(format!(
            "artifact {} declares protocol {}, expected {}",
            artifact.path.display(),
            artifact.protocol_version,
            REMOTE_HELPER_PROTOCOL_VERSION
        )));
    }
    if artifact.package_version != env!("CARGO_PKG_VERSION") {
        return Err(SshError::RemoteHelperVersionMismatch(format!(
            "artifact {} targets package version {}, expected {}",
            artifact.path.display(),
            artifact.package_version,
            env!("CARGO_PKG_VERSION")
        )));
    }
    Ok(())
}

fn is_supported_remote_helper_target(target_triple: &str) -> bool {
    SUPPORTED_REMOTE_HELPER_TARGETS.contains(&target_triple)
}

fn supported_target_matrix() -> String {
    SUPPORTED_REMOTE_HELPER_TARGETS.join(", ")
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
            continue;
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

fn sha256_hex(bytes: &[u8]) -> String {
    format!("{:x}", Sha256::digest(bytes))
}

fn parse_status_from_json(value: serde_json::Value) -> Result<RemoteSessionStatus, SshError> {
    Ok(RemoteSessionStatus {
        session_id: value
            .get("session_id")
            .and_then(|v| v.as_str())
            .ok_or_else(|| SshError::Parse("missing session_id".to_string()))?
            .to_string(),
        controller_id: value
            .get("controller_id")
            .and_then(|v| v.as_str())
            .ok_or_else(|| SshError::Parse("missing controller_id".to_string()))?
            .to_string(),
        state: value
            .get("state")
            .and_then(|v| v.as_str())
            .ok_or_else(|| SshError::Parse("missing state".to_string()))?
            .to_string(),
        pid: value.get("pid").and_then(|v| v.as_u64()).map(|v| v as u32),
        exit_code: value
            .get("exit_code")
            .and_then(|v| v.as_i64())
            .map(|v| v as i32),
        total_bytes: value
            .get("total_bytes")
            .and_then(|v| v.as_u64())
            .unwrap_or(0),
        last_output_at_epoch: value.get("last_output_at_epoch").and_then(|v| v.as_i64()),
    })
}

fn parse_create_result_from_json(
    value: serde_json::Value,
) -> Result<RemoteSessionCreateResult, SshError> {
    Ok(RemoteSessionCreateResult {
        session_id: value
            .get("session_id")
            .and_then(|v| v.as_str())
            .ok_or_else(|| SshError::Parse("missing session_id".to_string()))?
            .to_string(),
        controller_id: value
            .get("controller_id")
            .and_then(|v| v.as_str())
            .ok_or_else(|| SshError::Parse("missing controller_id".to_string()))?
            .to_string(),
        state: value
            .get("state")
            .and_then(|v| v.as_str())
            .ok_or_else(|| SshError::Parse("missing state".to_string()))?
            .to_string(),
        pid: value.get("pid").and_then(|v| v.as_u64()).map(|v| v as u32),
        log_path: value
            .get("log_path")
            .and_then(|v| v.as_str())
            .map(ToOwned::to_owned),
    })
}

async fn run_ssh(
    profile: &SshProfile,
    remote_command: &str,
    stdin_bytes: Option<&[u8]>,
) -> Result<SshCommandOutput, SshError> {
    run_ssh_with_tty(profile, remote_command, stdin_bytes, false).await
}

async fn run_ssh_with_tty(
    profile: &SshProfile,
    remote_command: &str,
    stdin_bytes: Option<&[u8]>,
    request_tty: bool,
) -> Result<SshCommandOutput, SshError> {
    let keepalive = if request_tty {
        crate::SshKeepAliveMode::Interactive
    } else {
        crate::SshKeepAliveMode::Background
    };
    // Ensure control socket directory exists (best-effort, non-fatal).
    let _ = crate::ensure_control_socket_dir();
    let mut command = Command::new(ssh_binary_path());
    if request_tty {
        command.arg("-tt");
    }
    command
        .args(ssh_args_without_binary(profile, keepalive)?)
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

/// Resolve the SSH binary to use for remote connections.
///
/// # Security note
///
/// The `PNEVMA_SSH_BIN` environment variable allows overriding the SSH binary
/// path. This is intended for testing. In production, the binary is resolved
/// from a hardcoded search path. A compromised environment variable could
/// redirect SSH operations to a malicious binary.
pub(crate) fn ssh_binary_path() -> PathBuf {
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

fn ssh_args_without_binary(
    profile: &SshProfile,
    keepalive: crate::SshKeepAliveMode,
) -> Result<Vec<String>, crate::SshError> {
    let mut args = crate::build_ssh_command(profile, keepalive)?;
    if !args.is_empty() {
        args.remove(0);
    }
    Ok(args)
}

#[cfg(test)]
mod tests {
    use super::*;
    use chrono::Utc;
    use std::os::unix::fs::PermissionsExt;
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
            use_control_master: None,
        }
    }

    fn env_lock() -> &'static Mutex<()> {
        static LOCK: OnceLock<Mutex<()>> = OnceLock::new();
        LOCK.get_or_init(|| Mutex::new(()))
    }

    fn write_executable(path: &Path, body: &str) {
        std::fs::write(path, body).expect("write executable");
        std::fs::set_permissions(path, std::fs::Permissions::from_mode(0o755))
            .expect("chmod executable");
    }

    fn write_fake_ssh(root: &Path, fake_home: &Path, platform_output: &str) -> PathBuf {
        let fake_bin = root.join("fake-bin");
        std::fs::create_dir_all(&fake_bin).expect("create fake bin");
        write_executable(
            &fake_bin.join("sh"),
            "#!/bin/sh\nset -eu\nif [ \"$#\" -ge 2 ] && [ \"$1\" = \"-lc\" ]; then\n  shift\n  exec /bin/sh -c \"$1\"\nfi\nexec /bin/sh \"$@\"\n",
        );
        write_executable(
            &fake_bin.join("uname"),
            &format!(
                "#!/bin/sh\nset -eu\nif [ \"$#\" -eq 1 ] && [ \"$1\" = \"-sm\" ]; then\n  printf '%s\\n' '{}'\nelse\n  /usr/bin/uname \"$@\"\nfi\n",
                platform_output
            ),
        );

        let fake_ssh = root.join("fake-ssh.sh");
        write_executable(
            &fake_ssh,
            &format!(
                "#!/bin/sh\nset -eu\nexport HOME={}\nexport PATH={}:$PATH\nremote_cmd=\"\"\nfor arg in \"$@\"; do remote_cmd=\"$arg\"; done\nexec sh -lc \"$remote_cmd\"\n",
                shell_escape_arg(fake_home.to_string_lossy().as_ref()),
                shell_escape_arg(fake_bin.to_string_lossy().as_ref())
            ),
        );
        fake_ssh
    }

    fn write_helper_script(path: &Path, version: &str, protocol_version: &str, helper_kind: &str) {
        write_executable(
            path,
            &format!(
                "#!/bin/sh\nset -eu\nprintf 'version={}\\n'\nprintf 'protocol_version={}\\n'\nprintf 'helper_kind={}\\n'\nprintf 'helper_path=%s\\n' \"$0\"\nprintf 'state_root=%s/.local/state/pnevma/remote\\n' \"$HOME\"\nprintf 'controller_id=controller-{}\\n'\nprintf 'healthy=true\\n'\nprintf 'missing_dependencies=\\n'\n",
                version, protocol_version, helper_kind, helper_kind
            ),
        );
    }

    fn write_manifest_bundle(root: &Path, artifacts: &[(&str, &Path, Option<&str>, Option<&str>)]) {
        let mut rows = Vec::new();
        for (target_triple, artifact_path, sha_override, relative_override) in artifacts {
            let relative_path = relative_override
                .map(ToOwned::to_owned)
                .unwrap_or_else(|| format!("{}/{}", target_triple, REMOTE_HELPER_BINARY_NAME));
            let bundle_path = root.join(&relative_path);
            if let Some(parent) = bundle_path.parent() {
                std::fs::create_dir_all(parent).expect("create bundle dir");
            }
            std::fs::copy(artifact_path, &bundle_path).expect("copy artifact");
            let bytes = std::fs::read(&bundle_path).expect("read bundle artifact");
            rows.push(serde_json::json!({
                "target_triple": target_triple,
                "relative_path": relative_path,
                "sha256": sha_override.unwrap_or(&sha256_hex(&bytes)),
                "size": bytes.len(),
            }));
        }
        std::fs::write(
            root.join(REMOTE_HELPER_MANIFEST_NAME),
            serde_json::to_vec_pretty(&serde_json::json!({
                "schema_version": REMOTE_HELPER_MANIFEST_SCHEMA_VERSION,
                "package_version": env!("CARGO_PKG_VERSION"),
                "protocol_version": REMOTE_HELPER_PROTOCOL_VERSION,
                "artifacts": rows,
            }))
            .expect("manifest json"),
        )
        .expect("write manifest");
    }

    #[test]
    fn build_remote_attach_command_includes_helper_attach() {
        let command = build_remote_attach_command(&sample_profile(), "session-1").unwrap();
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
    fn parse_kv_output_ignores_ssh_banner_noise() {
        let values = parse_kv_output(
            "Last login: Thu Mar 19 18:47:11 from 100.123.35.49\r\n\
             /Users/savorgserver/.profile: line 1: missing\r\n\
             session_id=session-1\r\n\
             controller_id=controller-1\r\n\
             state=detached\r\n\
             Connection to savorgserver closed.\r\n",
        )
        .expect("parse output with ssh noise");
        assert_eq!(
            values.get("session_id").map(String::as_str),
            Some("session-1")
        );
        assert_eq!(
            values.get("controller_id").map(String::as_str),
            Some("controller-1")
        );
        assert_eq!(values.get("state").map(String::as_str), Some("detached"));
    }

    #[test]
    fn parse_remote_helper_platform_maps_known_targets() {
        let linux = parse_remote_helper_platform("Linux x86_64\n").expect("linux platform");
        assert_eq!(linux.target_triple, "x86_64-unknown-linux-musl");

        let darwin = parse_remote_helper_platform("Darwin arm64\n").expect("darwin platform");
        assert_eq!(darwin.target_triple, "aarch64-apple-darwin");
    }

    #[test]
    fn bundle_artifact_root_maps_pnevma_app_layout() {
        let path = PathBuf::from("/tmp/Pnevma.app/Contents/MacOS/Pnevma");
        let root =
            bundle_artifact_root_from_current_exe(&path).expect("bundle artifact root should map");
        assert_eq!(
            root,
            PathBuf::from("/tmp/Pnevma.app/Contents/Resources/remote-helper")
        );
    }

    #[test]
    fn manifest_resolution_maps_supported_targets() {
        let temp = tempdir().expect("tempdir");
        let bundle_root = temp.path().join("bundle");
        std::fs::create_dir_all(&bundle_root).expect("bundle root");

        let linux_x64 = temp.path().join("linux-x64.sh");
        let linux_arm64 = temp.path().join("linux-arm64.sh");
        let darwin_x64 = temp.path().join("darwin-x64.sh");
        let darwin_arm64 = temp.path().join("darwin-arm64.sh");
        write_helper_script(&linux_x64, "x64", REMOTE_HELPER_PROTOCOL_VERSION, "binary");
        write_helper_script(
            &linux_arm64,
            "arm64",
            REMOTE_HELPER_PROTOCOL_VERSION,
            "binary",
        );
        write_helper_script(
            &darwin_x64,
            "darwin-x64",
            REMOTE_HELPER_PROTOCOL_VERSION,
            "binary",
        );
        write_helper_script(
            &darwin_arm64,
            "darwin-arm64",
            REMOTE_HELPER_PROTOCOL_VERSION,
            "binary",
        );
        write_manifest_bundle(
            &bundle_root,
            &[
                ("x86_64-unknown-linux-musl", &linux_x64, None, None),
                ("aarch64-unknown-linux-musl", &linux_arm64, None, None),
                ("x86_64-apple-darwin", &darwin_x64, None, None),
                ("aarch64-apple-darwin", &darwin_arm64, None, None),
            ],
        );

        let linux = parse_remote_helper_platform("Linux x86_64\n").expect("linux platform");
        let resolved = resolve_remote_helper_manifest_root(
            &bundle_root,
            &linux,
            RemoteHelperArtifactSource::RepoArtifacts,
            true,
        )
        .expect("resolve manifest root")
        .expect("artifact");
        assert_eq!(resolved.target_triple, "x86_64-unknown-linux-musl");

        let arm = parse_remote_helper_platform("Linux arm64\n").expect("linux arm64 platform");
        let resolved = resolve_remote_helper_manifest_root(
            &bundle_root,
            &arm,
            RemoteHelperArtifactSource::RepoArtifacts,
            true,
        )
        .expect("resolve manifest root")
        .expect("artifact");
        assert_eq!(resolved.target_triple, "aarch64-unknown-linux-musl");

        let darwin_x64_platform =
            parse_remote_helper_platform("Darwin x86_64\n").expect("darwin x64 platform");
        let resolved = resolve_remote_helper_manifest_root(
            &bundle_root,
            &darwin_x64_platform,
            RemoteHelperArtifactSource::RepoArtifacts,
            true,
        )
        .expect("resolve manifest root")
        .expect("artifact");
        assert_eq!(resolved.target_triple, "x86_64-apple-darwin");

        let darwin_arm64_platform =
            parse_remote_helper_platform("Darwin arm64\n").expect("darwin arm64 platform");
        let resolved = resolve_remote_helper_manifest_root(
            &bundle_root,
            &darwin_arm64_platform,
            RemoteHelperArtifactSource::RepoArtifacts,
            true,
        )
        .expect("resolve manifest root")
        .expect("artifact");
        assert_eq!(resolved.target_triple, "aarch64-apple-darwin");
    }

    #[test]
    fn bundle_relative_lookup_works_without_env_overrides() {
        let _guard = env_lock().blocking_lock();
        let previous_artifact_dir = std::env::var_os("PNEVMA_REMOTE_HELPER_ARTIFACT_DIR");
        let previous_bundle_dir = std::env::var_os("PNEVMA_REMOTE_HELPER_BUNDLE_DIR");
        let previous_ssh_bin = std::env::var_os("PNEVMA_SSH_BIN");
        let previous_shell_compat = std::env::var_os("PNEVMA_REMOTE_HELPER_ALLOW_SHELL_COMPAT");
        std::env::remove_var("PNEVMA_REMOTE_HELPER_ARTIFACT_DIR");
        std::env::remove_var("PNEVMA_REMOTE_HELPER_BUNDLE_DIR");
        std::env::remove_var("PNEVMA_SSH_BIN");
        std::env::remove_var("PNEVMA_REMOTE_HELPER_ALLOW_SHELL_COMPAT");

        let temp = tempdir().expect("tempdir");
        let app_root = temp.path().join("Pnevma.app");
        let exe_path = app_root.join("Contents/MacOS/Pnevma");
        let bundle_root = app_root.join("Contents/Resources/remote-helper");
        std::fs::create_dir_all(exe_path.parent().expect("exe parent")).expect("create exe dir");
        std::fs::create_dir_all(&bundle_root).expect("create bundle dir");

        let artifact = temp.path().join("artifact.sh");
        write_helper_script(
            &artifact,
            "bundle",
            REMOTE_HELPER_PROTOCOL_VERSION,
            "binary",
        );
        write_manifest_bundle(
            &bundle_root,
            &[("x86_64-unknown-linux-musl", &artifact, None, None)],
        );

        let platform = parse_remote_helper_platform("Linux x86_64\n").expect("linux platform");
        let resolved = resolve_remote_helper_artifact_for_platform(&platform, Some(&exe_path))
            .expect("resolve artifact")
            .expect("artifact");
        assert_eq!(
            resolved.artifact_source,
            RemoteHelperArtifactSource::BundleRelative
        );
        assert_eq!(resolved.target_triple, "x86_64-unknown-linux-musl");

        if let Some(value) = previous_artifact_dir {
            std::env::set_var("PNEVMA_REMOTE_HELPER_ARTIFACT_DIR", value);
        }
        if let Some(value) = previous_bundle_dir {
            std::env::set_var("PNEVMA_REMOTE_HELPER_BUNDLE_DIR", value);
        }
        if let Some(value) = previous_ssh_bin {
            std::env::set_var("PNEVMA_SSH_BIN", value);
        }
        if let Some(value) = previous_shell_compat {
            std::env::set_var("PNEVMA_REMOTE_HELPER_ALLOW_SHELL_COMPAT", value);
        }
    }

    #[test]
    fn bundle_relative_lookup_works_for_supported_darwin_targets() {
        let _guard = env_lock().blocking_lock();
        let previous_artifact_dir = std::env::var_os("PNEVMA_REMOTE_HELPER_ARTIFACT_DIR");
        let previous_bundle_dir = std::env::var_os("PNEVMA_REMOTE_HELPER_BUNDLE_DIR");
        let previous_ssh_bin = std::env::var_os("PNEVMA_SSH_BIN");
        let previous_shell_compat = std::env::var_os("PNEVMA_REMOTE_HELPER_ALLOW_SHELL_COMPAT");
        std::env::remove_var("PNEVMA_REMOTE_HELPER_ARTIFACT_DIR");
        std::env::remove_var("PNEVMA_REMOTE_HELPER_BUNDLE_DIR");
        std::env::remove_var("PNEVMA_SSH_BIN");
        std::env::remove_var("PNEVMA_REMOTE_HELPER_ALLOW_SHELL_COMPAT");

        let temp = tempdir().expect("tempdir");
        let app_root = temp.path().join("Pnevma.app");
        let exe_path = app_root.join("Contents/MacOS/Pnevma");
        let bundle_root = app_root.join("Contents/Resources/remote-helper");
        std::fs::create_dir_all(exe_path.parent().expect("exe parent")).expect("create exe dir");
        std::fs::create_dir_all(&bundle_root).expect("create bundle dir");

        let artifact = temp.path().join("darwin-artifact.sh");
        write_helper_script(
            &artifact,
            "darwin-bundle",
            REMOTE_HELPER_PROTOCOL_VERSION,
            "binary",
        );
        write_manifest_bundle(
            &bundle_root,
            &[("aarch64-apple-darwin", &artifact, None, None)],
        );

        let platform = parse_remote_helper_platform("Darwin arm64\n").expect("darwin platform");
        let resolved = resolve_remote_helper_artifact_for_platform(&platform, Some(&exe_path))
            .expect("resolve artifact")
            .expect("artifact");
        assert_eq!(
            resolved.artifact_source,
            RemoteHelperArtifactSource::BundleRelative
        );
        assert_eq!(resolved.target_triple, "aarch64-apple-darwin");

        if let Some(value) = previous_artifact_dir {
            std::env::set_var("PNEVMA_REMOTE_HELPER_ARTIFACT_DIR", value);
        }
        if let Some(value) = previous_bundle_dir {
            std::env::set_var("PNEVMA_REMOTE_HELPER_BUNDLE_DIR", value);
        }
        if let Some(value) = previous_ssh_bin {
            std::env::set_var("PNEVMA_SSH_BIN", value);
        }
        if let Some(value) = previous_shell_compat {
            std::env::set_var("PNEVMA_REMOTE_HELPER_ALLOW_SHELL_COMPAT", value);
        }
    }

    #[tokio::test]
    async fn ensure_remote_helper_installs_manifest_artifact_when_available() {
        let _guard = env_lock().lock().await;
        let temp = tempdir().expect("tempdir");
        let fake_home = temp.path().join("home");
        std::fs::create_dir_all(&fake_home).expect("create fake home");
        let fake_ssh = write_fake_ssh(temp.path(), &fake_home, "Linux x86_64");

        let artifact_dir = temp.path().join("artifacts");
        std::fs::create_dir_all(&artifact_dir).expect("artifact dir");
        let artifact = temp.path().join("binary-artifact.sh");
        write_helper_script(
            &artifact,
            &expected_remote_helper_version(),
            REMOTE_HELPER_PROTOCOL_VERSION,
            "binary",
        );
        write_manifest_bundle(
            &artifact_dir,
            &[("x86_64-unknown-linux-musl", &artifact, None, None)],
        );

        std::env::set_var("PNEVMA_SSH_BIN", &fake_ssh);
        std::env::set_var("PNEVMA_REMOTE_HELPER_ARTIFACT_DIR", &artifact_dir);
        std::env::remove_var("PNEVMA_REMOTE_HELPER_ALLOW_SHELL_COMPAT");

        let result = ensure_remote_helper(&sample_profile())
            .await
            .expect("ensure remote helper");
        assert!(result.health.healthy);
        assert!(result.installed);
        assert_eq!(result.install_kind, RemoteHelperInstallKind::BinaryArtifact);
        assert_eq!(result.health.helper_kind, "binary");
        assert_eq!(
            result.health.target_triple.as_deref(),
            Some("x86_64-unknown-linux-musl")
        );
        assert_eq!(
            result.health.artifact_source.as_deref(),
            Some(RemoteHelperArtifactSource::ArtifactDir.as_str())
        );
        assert!(result.health.protocol_compatible);
        assert!(result.health.missing_dependencies.is_empty());

        let metadata_path = fake_home.join(".local/share/pnevma/bin/pnevma-remote-helper.metadata");
        let metadata = fs::read_to_string(&metadata_path)
            .await
            .expect("metadata should exist");
        assert!(metadata.contains("target_triple=x86_64-unknown-linux-musl"));
        assert!(metadata.contains("artifact_source=artifact_dir"));

        std::env::remove_var("PNEVMA_REMOTE_HELPER_ARTIFACT_DIR");
        std::env::remove_var("PNEVMA_SSH_BIN");
    }

    #[tokio::test]
    async fn ensure_remote_helper_installs_manifest_artifact_for_supported_darwin_target() {
        let _guard = env_lock().lock().await;
        let temp = tempdir().expect("tempdir");
        let fake_home = temp.path().join("home");
        std::fs::create_dir_all(&fake_home).expect("create fake home");
        let fake_ssh = write_fake_ssh(temp.path(), &fake_home, "Darwin arm64");

        let artifact_dir = temp.path().join("artifacts");
        std::fs::create_dir_all(&artifact_dir).expect("artifact dir");
        let artifact = temp.path().join("darwin-binary-artifact.sh");
        write_helper_script(
            &artifact,
            &expected_remote_helper_version(),
            REMOTE_HELPER_PROTOCOL_VERSION,
            "binary",
        );
        write_manifest_bundle(
            &artifact_dir,
            &[("aarch64-apple-darwin", &artifact, None, None)],
        );

        std::env::set_var("PNEVMA_SSH_BIN", &fake_ssh);
        std::env::set_var("PNEVMA_REMOTE_HELPER_ARTIFACT_DIR", &artifact_dir);
        std::env::remove_var("PNEVMA_REMOTE_HELPER_ALLOW_SHELL_COMPAT");

        let result = ensure_remote_helper(&sample_profile())
            .await
            .expect("ensure remote helper");
        assert!(result.health.healthy);
        assert!(result.installed);
        assert_eq!(result.install_kind, RemoteHelperInstallKind::BinaryArtifact);
        assert_eq!(result.health.helper_kind, "binary");
        assert_eq!(
            result.health.target_triple.as_deref(),
            Some("aarch64-apple-darwin")
        );
        assert_eq!(
            result.health.artifact_source.as_deref(),
            Some(RemoteHelperArtifactSource::ArtifactDir.as_str())
        );
        assert!(result.health.protocol_compatible);
        assert!(result.health.missing_dependencies.is_empty());

        let metadata_path = fake_home.join(".local/share/pnevma/bin/pnevma-remote-helper.metadata");
        let metadata = fs::read_to_string(&metadata_path)
            .await
            .expect("metadata should exist");
        assert!(metadata.contains("target_triple=aarch64-apple-darwin"));
        assert!(metadata.contains("artifact_source=artifact_dir"));

        std::env::remove_var("PNEVMA_REMOTE_HELPER_ARTIFACT_DIR");
        std::env::remove_var("PNEVMA_SSH_BIN");
    }

    #[tokio::test]
    async fn ensure_remote_helper_fails_for_missing_supported_artifact_without_compat() {
        let _guard = env_lock().lock().await;
        let temp = tempdir().expect("tempdir");
        let fake_home = temp.path().join("home");
        std::fs::create_dir_all(&fake_home).expect("create fake home");
        let fake_ssh = write_fake_ssh(temp.path(), &fake_home, "Linux x86_64");
        let missing_dir = temp.path().join("missing-artifacts");
        std::fs::create_dir_all(&missing_dir).expect("missing dir");

        std::env::set_var("PNEVMA_SSH_BIN", &fake_ssh);
        std::env::set_var("PNEVMA_REMOTE_HELPER_ARTIFACT_DIR", &missing_dir);
        std::env::remove_var("PNEVMA_REMOTE_HELPER_ALLOW_SHELL_COMPAT");

        let error = ensure_remote_helper(&sample_profile())
            .await
            .expect_err("missing artifact should fail");
        assert!(matches!(error, SshError::MissingRemoteHelperArtifact(_)));

        std::env::remove_var("PNEVMA_REMOTE_HELPER_ARTIFACT_DIR");
        std::env::remove_var("PNEVMA_SSH_BIN");
    }

    #[tokio::test]
    async fn ensure_remote_helper_fails_for_missing_supported_darwin_artifact_without_compat() {
        let _guard = env_lock().lock().await;
        let temp = tempdir().expect("tempdir");
        let fake_home = temp.path().join("home");
        std::fs::create_dir_all(&fake_home).expect("create fake home");
        let fake_ssh = write_fake_ssh(temp.path(), &fake_home, "Darwin arm64");
        let missing_dir = temp.path().join("missing-darwin-artifacts");
        std::fs::create_dir_all(&missing_dir).expect("missing dir");

        std::env::set_var("PNEVMA_SSH_BIN", &fake_ssh);
        std::env::set_var("PNEVMA_REMOTE_HELPER_ARTIFACT_DIR", &missing_dir);
        std::env::remove_var("PNEVMA_REMOTE_HELPER_ALLOW_SHELL_COMPAT");

        let error = ensure_remote_helper(&sample_profile())
            .await
            .expect_err("missing darwin artifact should fail");
        assert!(matches!(error, SshError::MissingRemoteHelperArtifact(_)));

        std::env::remove_var("PNEVMA_REMOTE_HELPER_ARTIFACT_DIR");
        std::env::remove_var("PNEVMA_SSH_BIN");
    }

    #[tokio::test]
    async fn ensure_remote_helper_fails_for_unsupported_targets_without_compat() {
        let _guard = env_lock().lock().await;
        let temp = tempdir().expect("tempdir");
        let fake_home = temp.path().join("home");
        std::fs::create_dir_all(&fake_home).expect("create fake home");
        let fake_ssh = write_fake_ssh(temp.path(), &fake_home, "FreeBSD amd64");

        std::env::set_var("PNEVMA_SSH_BIN", &fake_ssh);
        std::env::remove_var("PNEVMA_REMOTE_HELPER_ALLOW_SHELL_COMPAT");

        let error = ensure_remote_helper(&sample_profile())
            .await
            .expect_err("unsupported platform should fail");
        assert!(matches!(
            error,
            SshError::UnsupportedRemoteHelperPlatform(_)
        ));

        std::env::remove_var("PNEVMA_SSH_BIN");
    }

    #[tokio::test]
    async fn ensure_remote_helper_uses_shell_fallback_when_opted_in() {
        let _guard = env_lock().lock().await;
        let temp = tempdir().expect("tempdir");
        let fake_home = temp.path().join("home");
        std::fs::create_dir_all(&fake_home).expect("create fake home");
        let fake_ssh = write_fake_ssh(temp.path(), &fake_home, "FreeBSD amd64");

        std::env::set_var("PNEVMA_SSH_BIN", &fake_ssh);
        std::env::set_var("PNEVMA_REMOTE_HELPER_ALLOW_SHELL_COMPAT", "1");

        let result = ensure_remote_helper(&sample_profile())
            .await
            .expect("ensure remote helper");
        assert!(result.installed);
        assert_eq!(result.install_kind, RemoteHelperInstallKind::ShellCompat);
        assert_eq!(result.health.helper_kind, "shell_compat");
        assert_eq!(
            result.health.artifact_source.as_deref(),
            Some(RemoteHelperArtifactSource::ShellCompat.as_str())
        );

        std::env::remove_var("PNEVMA_REMOTE_HELPER_ALLOW_SHELL_COMPAT");
        std::env::remove_var("PNEVMA_SSH_BIN");
    }

    #[tokio::test]
    async fn ensure_remote_helper_does_not_fallback_after_digest_mismatch() {
        let _guard = env_lock().lock().await;
        let temp = tempdir().expect("tempdir");
        let fake_home = temp.path().join("home");
        std::fs::create_dir_all(&fake_home).expect("create fake home");
        let fake_ssh = write_fake_ssh(temp.path(), &fake_home, "Darwin arm64");

        let artifact_dir = temp.path().join("artifacts");
        std::fs::create_dir_all(&artifact_dir).expect("artifact dir");
        let artifact = temp.path().join("digest-mismatch.sh");
        write_helper_script(
            &artifact,
            &expected_remote_helper_version(),
            REMOTE_HELPER_PROTOCOL_VERSION,
            "binary",
        );
        write_manifest_bundle(
            &artifact_dir,
            &[("aarch64-apple-darwin", &artifact, Some("deadbeef"), None)],
        );

        std::env::set_var("PNEVMA_SSH_BIN", &fake_ssh);
        std::env::set_var("PNEVMA_REMOTE_HELPER_ARTIFACT_DIR", &artifact_dir);
        std::env::set_var("PNEVMA_REMOTE_HELPER_ALLOW_SHELL_COMPAT", "1");

        let error = ensure_remote_helper(&sample_profile())
            .await
            .expect_err("digest mismatch should fail");
        assert!(matches!(error, SshError::RemoteHelperDigestMismatch(_)));

        std::env::remove_var("PNEVMA_REMOTE_HELPER_ALLOW_SHELL_COMPAT");
        std::env::remove_var("PNEVMA_REMOTE_HELPER_ARTIFACT_DIR");
        std::env::remove_var("PNEVMA_SSH_BIN");
    }

    #[tokio::test]
    async fn ensure_remote_helper_does_not_fallback_after_protocol_mismatch() {
        let _guard = env_lock().lock().await;
        let temp = tempdir().expect("tempdir");
        let fake_home = temp.path().join("home");
        std::fs::create_dir_all(&fake_home).expect("create fake home");
        let fake_ssh = write_fake_ssh(temp.path(), &fake_home, "Darwin arm64");

        let artifact_dir = temp.path().join("artifacts");
        std::fs::create_dir_all(&artifact_dir).expect("artifact dir");
        let artifact = temp.path().join("protocol-mismatch.sh");
        write_helper_script(
            &artifact,
            &expected_remote_helper_version(),
            "999",
            "binary",
        );
        write_manifest_bundle(
            &artifact_dir,
            &[("aarch64-apple-darwin", &artifact, None, None)],
        );

        std::env::set_var("PNEVMA_SSH_BIN", &fake_ssh);
        std::env::set_var("PNEVMA_REMOTE_HELPER_ARTIFACT_DIR", &artifact_dir);
        std::env::set_var("PNEVMA_REMOTE_HELPER_ALLOW_SHELL_COMPAT", "1");

        let error = ensure_remote_helper(&sample_profile())
            .await
            .expect_err("protocol mismatch should fail");
        assert!(matches!(error, SshError::RemoteHelperProtocolMismatch(_)));

        std::env::remove_var("PNEVMA_REMOTE_HELPER_ALLOW_SHELL_COMPAT");
        std::env::remove_var("PNEVMA_REMOTE_HELPER_ARTIFACT_DIR");
        std::env::remove_var("PNEVMA_SSH_BIN");
    }
}
