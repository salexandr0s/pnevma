use crate::model::AgentTeamConfig;
use std::path::{Path, PathBuf};

const CLAUDE_TEAM_ENV_FLAG: &str = "CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS";

pub fn prepare_claude_team_environment(
    team: &AgentTeamConfig,
    pane_token: &str,
) -> Result<Vec<(String, String)>, String> {
    let helper = resolve_agent_team_helper().ok_or_else(|| {
        "unable to locate pnevma-agent-team-helper (expected bundled helper or PATH binary)"
            .to_string()
    })?;
    let shim_dir = agent_team_shim_dir(&team.team_id);
    std::fs::create_dir_all(&shim_dir).map_err(|e| e.to_string())?;
    write_tmux_shim(&shim_dir, &helper)?;

    let inherited_path = std::env::var("PATH").unwrap_or_default();
    let path = if inherited_path.is_empty() {
        shim_dir.to_string_lossy().to_string()
    } else {
        format!("{}:{inherited_path}", shim_dir.to_string_lossy())
    };
    let tmux_socket = agent_team_tmux_socket_path(&team.team_id);
    if let Some(parent) = tmux_socket.parent() {
        std::fs::create_dir_all(parent).map_err(|e| e.to_string())?;
    }
    if !tmux_socket.exists() {
        let _ = std::fs::File::create(&tmux_socket).map_err(|e| e.to_string())?;
    }

    Ok(vec![
        (CLAUDE_TEAM_ENV_FLAG.to_string(), "1".to_string()),
        ("PNEVMA_AGENT_TEAM_ID".to_string(), team.team_id.clone()),
        (
            "PNEVMA_AGENT_TEAM_CONTROL_SOCKET".to_string(),
            team.control_socket_path.clone(),
        ),
        (
            "PNEVMA_AGENT_TEAM_PROVIDER".to_string(),
            team.provider.clone(),
        ),
        (
            "TMUX".to_string(),
            tmux_socket.to_string_lossy().to_string(),
        ),
        ("TMUX_PANE".to_string(), pane_token.to_string()),
        ("TERM".to_string(), "screen-256color".to_string()),
        ("PATH".to_string(), path),
    ])
}

pub fn with_tmux_pane_token(
    base_env: &[(String, String)],
    pane_token: &str,
) -> Vec<(String, String)> {
    let mut out = Vec::with_capacity(base_env.len() + 1);
    let mut replaced = false;
    for (key, value) in base_env {
        if key == "TMUX_PANE" {
            out.push((key.clone(), pane_token.to_string()));
            replaced = true;
        } else {
            out.push((key.clone(), value.clone()));
        }
    }
    if !replaced {
        out.push(("TMUX_PANE".to_string(), pane_token.to_string()));
    }
    out
}

fn resolve_agent_team_helper() -> Option<PathBuf> {
    if let Ok(explicit) = std::env::var("PNEVMA_AGENT_TEAM_HELPER_BIN") {
        let path = PathBuf::from(explicit);
        if path.is_file() {
            return Some(path);
        }
    }

    let current_exe = std::env::current_exe().ok();
    let mut candidates = Vec::new();
    if let Some(current_exe) = current_exe {
        if let Some(dir) = current_exe.parent() {
            candidates.push(dir.join("pnevma-agent-team-helper"));
            candidates.push(dir.join("../pnevma-agent-team-helper"));
            candidates.push(dir.join("../Helpers/pnevma-agent-team-helper"));
            candidates.push(dir.join("../../Helpers/pnevma-agent-team-helper"));
        }
    }
    candidates.push(PathBuf::from("pnevma-agent-team-helper"));

    candidates
        .into_iter()
        .find(|candidate| candidate.is_file() || which(candidate).is_some())
        .map(|candidate| which(&candidate).unwrap_or(candidate))
}

fn which(candidate: &Path) -> Option<PathBuf> {
    if candidate.is_absolute() && candidate.is_file() {
        return Some(candidate.to_path_buf());
    }
    let name = candidate.as_os_str();
    let path = std::env::var_os("PATH")?;
    std::env::split_paths(&path)
        .map(|dir| dir.join(name))
        .find(|path| path.is_file())
}

fn write_tmux_shim(dir: &Path, helper: &Path) -> Result<(), String> {
    let shim_path = dir.join("tmux");
    let helper_escaped = helper.to_string_lossy().replace('\'', "'\\''");
    let script = format!("#!/bin/sh\nexec '{helper_escaped}' tmux \"$@\"\n");
    std::fs::write(&shim_path, script).map_err(|e| e.to_string())?;
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        let mut perms = std::fs::metadata(&shim_path)
            .map_err(|e| e.to_string())?
            .permissions();
        perms.set_mode(0o755);
        std::fs::set_permissions(&shim_path, perms).map_err(|e| e.to_string())?;
    }
    Ok(())
}

fn agent_team_root(team_id: &str) -> PathBuf {
    std::env::temp_dir()
        .join("pnevma-agent-teams")
        .join(team_id)
}

fn agent_team_shim_dir(team_id: &str) -> PathBuf {
    agent_team_root(team_id).join("bin")
}

fn agent_team_tmux_socket_path(team_id: &str) -> PathBuf {
    agent_team_root(team_id).join("tmux.sock")
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::model::AgentTeamConfig;
    use std::time::{SystemTime, UNIX_EPOCH};

    fn unique_team_id() -> String {
        format!(
            "test-team-{}",
            SystemTime::now()
                .duration_since(UNIX_EPOCH)
                .expect("time")
                .as_nanos()
        )
    }

    #[test]
    fn with_tmux_pane_token_replaces_existing_value() {
        let updated = with_tmux_pane_token(
            &[
                ("TMUX_PANE".to_string(), "%0".to_string()),
                ("PATH".to_string(), "/usr/bin".to_string()),
            ],
            "%3",
        );
        assert_eq!(
            updated
                .iter()
                .find(|(key, _)| key == "TMUX_PANE")
                .map(|(_, value)| value.as_str()),
            Some("%3")
        );
    }

    #[test]
    fn prepare_claude_team_environment_creates_tmux_shim_and_env() {
        let helper_dir = tempfile::tempdir().expect("helper tempdir");
        let helper_path = helper_dir.path().join("pnevma-agent-team-helper");
        std::fs::write(&helper_path, b"#!/bin/sh\nexit 0\n").expect("write helper");
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            let mut perms = std::fs::metadata(&helper_path)
                .expect("helper metadata")
                .permissions();
            perms.set_mode(0o755);
            std::fs::set_permissions(&helper_path, perms).expect("set helper permissions");
        }

        std::env::set_var("PNEVMA_AGENT_TEAM_HELPER_BIN", &helper_path);
        let team_id = unique_team_id();
        let env = prepare_claude_team_environment(
            &AgentTeamConfig {
                team_id: team_id.clone(),
                provider: "claude-code".to_string(),
                leader_session_id: "leader-session".to_string(),
                leader_pane_id: "leader-pane".to_string(),
                control_socket_path: "/tmp/pnevma.sock".to_string(),
                working_dir: "/tmp/project".to_string(),
                base_env: Vec::new(),
            },
            "%0",
        )
        .expect("prepare env");
        std::env::remove_var("PNEVMA_AGENT_TEAM_HELPER_BIN");

        let shim_path = agent_team_shim_dir(&team_id).join("tmux");
        assert!(shim_path.is_file(), "tmux shim should be created");
        assert!(agent_team_tmux_socket_path(&team_id).exists());
        assert!(env
            .iter()
            .any(|(key, value)| key == "TMUX_PANE" && value == "%0"));
        assert!(env
            .iter()
            .any(|(key, _)| key == "CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS"));
    }
}
