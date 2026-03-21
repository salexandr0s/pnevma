use std::path::{Path, PathBuf};
use std::time::Duration;

use sha2::{Digest, Sha256};
use tokio::process::Command;

use crate::{SshError, SshKeepAliveMode, SshProfile};

const RPC_SOCKET_DIR: &str = ".pnevma/ssh/rpc";
const REMOTE_CONTROL_SOCKET: &str = "$HOME/.local/state/pnevma/remote/control.sock";
const TUNNEL_CONNECT_TIMEOUT: Duration = Duration::from_secs(5);
const TUNNEL_POLL_INTERVAL: Duration = Duration::from_millis(100);

pub struct RpcTunnel {
    child: tokio::process::Child,
    local_socket: PathBuf,
}

impl RpcTunnel {
    pub async fn open(profile: &SshProfile) -> Result<Self, SshError> {
        let local_socket = local_tunnel_socket_path(profile)?;

        // Ensure parent directory exists.
        if let Some(parent) = local_socket.parent() {
            std::fs::create_dir_all(parent)?;
            #[cfg(unix)]
            {
                use std::os::unix::fs::PermissionsExt;
                std::fs::set_permissions(parent, std::fs::Permissions::from_mode(0o700))?;
            }
        }

        // Remove stale socket if present.
        let _ = std::fs::remove_file(&local_socket);

        let ssh_args = ssh_args_for_tunnel(profile);
        let forward_spec = format!("{}:{}", local_socket.display(), REMOTE_CONTROL_SOCKET);

        let mut child = Command::new(super::remote_helper::ssh_binary_path())
            .args(&ssh_args)
            .arg("-N") // No remote command.
            .arg("-L")
            .arg(&forward_spec)
            .stdin(std::process::Stdio::null())
            .stdout(std::process::Stdio::null())
            .stderr(std::process::Stdio::piped())
            .spawn()?;

        // Wait for the local socket to appear, but fail fast if SSH exits.
        let deadline = tokio::time::Instant::now() + TUNNEL_CONNECT_TIMEOUT;
        loop {
            if local_socket.exists() {
                break;
            }
            // Check if SSH process has exited (fail fast instead of waiting full timeout).
            if let Some(status) = child.try_wait()? {
                return Err(SshError::Command(format!(
                    "SSH tunnel process exited with {status} before socket was ready"
                )));
            }
            if tokio::time::Instant::now() >= deadline {
                let _ = child.start_kill();
                return Err(SshError::Command(
                    "timeout waiting for RPC tunnel socket".to_string(),
                ));
            }
            tokio::time::sleep(TUNNEL_POLL_INTERVAL).await;
        }

        Ok(Self {
            child,
            local_socket,
        })
    }

    pub fn local_socket_path(&self) -> &Path {
        &self.local_socket
    }
}

impl Drop for RpcTunnel {
    fn drop(&mut self) {
        let _ = self.child.start_kill();
        let _ = std::fs::remove_file(&self.local_socket);
    }
}

fn local_tunnel_socket_path(profile: &SshProfile) -> Result<PathBuf, SshError> {
    let home = std::env::var("HOME").map_err(|_| SshError::Command("HOME not set".to_string()))?;
    let key = format!(
        "rpc:{}@{}:{}",
        profile.user.as_deref().unwrap_or("_"),
        profile.host,
        profile.port,
    );
    let hash = sha256_short(&key);
    Ok(PathBuf::from(home)
        .join(RPC_SOCKET_DIR)
        .join(format!("{hash}.sock")))
}

fn sha256_short(input: &str) -> String {
    let digest = Sha256::digest(input.as_bytes());
    format!("{:x}", digest)[..16].to_string()
}

fn ssh_args_for_tunnel(profile: &SshProfile) -> Vec<String> {
    let mut args = crate::build_ssh_command(profile, SshKeepAliveMode::Background);
    // Remove the "ssh" binary name — we supply it separately.
    if !args.is_empty() {
        args.remove(0);
    }
    args
}
