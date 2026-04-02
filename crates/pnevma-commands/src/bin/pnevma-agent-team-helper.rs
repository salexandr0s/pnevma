use pnevma_commands::control::{send_request, ControlRequest};
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use std::path::PathBuf;
use std::process::ExitCode;
use uuid::Uuid;

#[derive(Debug, Clone, Deserialize)]
struct AgentTeamMemberView {
    session_id: String,
    pane_token: String,
    member_index: usize,
    title: String,
    command: String,
}

#[derive(Debug, Clone, Deserialize)]
struct AgentTeamSnapshot {
    provider: String,
    leader_session_id: String,
    leader_pane_token: String,
    members: Vec<AgentTeamMemberView>,
}

#[derive(Debug, Clone, Deserialize)]
struct AgentTeamSpawnResult {
    member: AgentTeamMemberView,
}

#[derive(Debug, Clone)]
struct PaneView {
    pane_token: String,
    session_id: String,
    title: String,
    command: String,
    member_index: usize,
    working_dir: String,
    is_leader: bool,
}

#[derive(Debug, Clone, Default, Serialize, Deserialize)]
struct TmuxCompatState {
    selected_pane: Option<String>,
    last_target: Option<String>,
}

#[tokio::main(flavor = "current_thread")]
async fn main() -> ExitCode {
    match run().await {
        Ok(output) => {
            if !output.is_empty() {
                print!("{output}");
            }
            ExitCode::SUCCESS
        }
        Err(error) => {
            eprintln!("pnevma-agent-team-helper: {error}");
            ExitCode::from(1)
        }
    }
}

async fn run() -> Result<String, String> {
    let mut args = std::env::args().skip(1).collect::<Vec<_>>();
    let Some(subcommand) = args.first().cloned() else {
        return Err("missing subcommand".to_string());
    };
    args.remove(0);

    match subcommand.as_str() {
        "tmux" => handle_tmux(args).await,
        other => Err(format!("unsupported subcommand: {other}")),
    }
}

async fn handle_tmux(args: Vec<String>) -> Result<String, String> {
    let invocation = parse_tmux_invocation(args)?;
    let team_id = required_env("PNEVMA_AGENT_TEAM_ID")?;
    let mut state = load_tmux_state(&team_id);
    let env_pane = std::env::var("TMUX_PANE").unwrap_or_else(|_| "%0".to_string());
    let current_pane = state
        .selected_pane
        .clone()
        .unwrap_or_else(|| env_pane.clone());
    let command = canonical_tmux_command(&invocation.command);

    let output = match command {
        "split-window" => {
            handle_split_window(&team_id, &invocation.args, &current_pane, &mut state).await
        }
        "select-layout" => handle_select_layout(&team_id, &invocation.args).await,
        "list-panes" => handle_list_panes(&team_id, &current_pane, &invocation.args).await,
        "display-message" => {
            handle_display_message(&team_id, &current_pane, &invocation.args, &mut state).await
        }
        "select-pane" => {
            handle_select_pane(&team_id, &current_pane, &invocation.args, &mut state).await
        }
        "resize-pane" => {
            handle_resize_pane(&team_id, &current_pane, &invocation.args, &mut state).await
        }
        "kill-pane" => {
            handle_kill_pane(&team_id, &current_pane, &invocation.args, &mut state).await
        }
        "has-session" => handle_has_session(&team_id).await,
        "list-windows" => handle_list_windows(&team_id, &invocation.args).await,
        other => Err(format!("unsupported tmux command: {other}")),
    }?;

    if state.selected_pane.is_none() {
        state.selected_pane = Some(current_pane);
    }
    save_tmux_state(&team_id, &state)?;
    Ok(output)
}

fn canonical_tmux_command(command: &str) -> &str {
    match command {
        "split-window" | "splitw" => "split-window",
        "select-layout" | "selectl" => "select-layout",
        "list-panes" | "listp" => "list-panes",
        "display-message" | "display" => "display-message",
        "select-pane" | "selectp" => "select-pane",
        "kill-pane" | "killp" => "kill-pane",
        "list-windows" | "listw" => "list-windows",
        other => other,
    }
}

struct ParsedTmuxInvocation {
    command: String,
    args: Vec<String>,
}

fn parse_tmux_invocation(args: Vec<String>) -> Result<ParsedTmuxInvocation, String> {
    let mut iter = args.into_iter();
    let mut command = None;
    let mut command_args = Vec::new();

    while let Some(arg) = iter.next() {
        if command.is_none() && arg.starts_with('-') {
            match arg.as_str() {
                "-L" | "-S" | "-f" => {
                    let _ = iter.next();
                }
                "-u" | "-2" | "-8" => {}
                _ => {
                    command = Some(arg);
                    command_args.extend(iter);
                    break;
                }
            }
        } else if command.is_none() {
            command = Some(arg);
            command_args.extend(iter);
            break;
        } else {
            command_args.push(arg);
        }
    }

    Ok(ParsedTmuxInvocation {
        command: command.ok_or_else(|| "missing tmux command".to_string())?,
        args: command_args,
    })
}

async fn handle_split_window(
    team_id: &str,
    args: &[String],
    current_pane: &str,
    state: &mut TmuxCompatState,
) -> Result<String, String> {
    let mut print_result = false;
    let mut detached = false;
    let mut format = "#{pane_id}".to_string();
    let mut title: Option<String> = None;
    let mut target: Option<String> = None;
    let mut command_parts = Vec::new();
    let mut after_double_dash = false;
    let mut i = 0;
    while i < args.len() {
        let arg = &args[i];
        if after_double_dash {
            command_parts.push(arg.clone());
            i += 1;
            continue;
        }
        match arg.as_str() {
            "--" => {
                after_double_dash = true;
            }
            "-P" | "-h" | "-v" => {}
            "-d" => {
                detached = true;
            }
            "-F" => {
                i += 1;
                format = args
                    .get(i)
                    .cloned()
                    .ok_or_else(|| "tmux split-window missing format after -F".to_string())?;
            }
            "-n" => {
                i += 1;
                title = args.get(i).cloned();
            }
            "-t" => {
                i += 1;
                target = args.get(i).cloned();
            }
            _ if arg.starts_with('-') => {}
            _ => command_parts.push(arg.clone()),
        }
        i += 1;
    }

    if args.iter().any(|arg| arg == "-P") {
        print_result = true;
    }

    let command = command_parts.join(" ").trim().to_string();
    if command.is_empty() {
        return Err("tmux split-window requires a shell command".to_string());
    }

    let snapshot_before = fetch_snapshot(team_id).await?;
    let panes_before = all_panes(&snapshot_before);
    if let Some(target) = target.as_deref() {
        let resolved = resolve_pane(
            &snapshot_before,
            &panes_before,
            Some(target),
            current_pane,
            state,
        )?;
        state.last_target = Some(resolved.pane_token.clone());
    }

    let result: AgentTeamSpawnResult = serde_json::from_value(
        control_call(
            "agent.team.spawn_member",
            json!({
                "team_id": team_id,
                "command": command,
                "title": title,
            }),
        )
        .await?,
    )
    .map_err(|e| e.to_string())?;
    if !detached {
        state.selected_pane = Some(result.member.pane_token.clone());
    }
    state.last_target = Some(result.member.pane_token.clone());

    if !print_result {
        return Ok(String::new());
    }

    let snapshot = fetch_snapshot(team_id).await?;
    let pane = pane_from_member(&snapshot, &result.member)?;
    Ok(format_pane_line(&snapshot, &pane, &format, &result.member.pane_token) + "\n")
}

async fn handle_select_layout(team_id: &str, args: &[String]) -> Result<String, String> {
    let layout = args
        .iter()
        .find(|arg| !arg.starts_with('-'))
        .ok_or_else(|| "tmux select-layout missing layout name".to_string())?;
    match layout.as_str() {
        "main-vertical" | "even-vertical" | "tiled" => {
            let _ = control_call(
                "agent.team.set_main_vertical",
                json!({"team_id": team_id, "enabled": true}),
            )
            .await?;
            Ok(String::new())
        }
        other => Err(format!("unsupported tmux layout: {other}")),
    }
}

async fn handle_list_panes(
    team_id: &str,
    current_pane: &str,
    args: &[String],
) -> Result<String, String> {
    let snapshot = fetch_snapshot(team_id).await?;
    let mut format = "#{pane_id}".to_string();
    let mut target: Option<String> = None;

    let mut i = 0;
    while i < args.len() {
        match args[i].as_str() {
            "-F" => {
                i += 1;
                format = args
                    .get(i)
                    .cloned()
                    .ok_or_else(|| "tmux list-panes missing format after -F".to_string())?;
            }
            "-t" => {
                i += 1;
                target = args.get(i).cloned();
            }
            _ => {}
        }
        i += 1;
    }

    let panes = all_panes(&snapshot);
    let selected = if let Some(target) = target {
        if is_window_target(target.as_str()) {
            panes
        } else {
            vec![resolve_pane(
                &snapshot,
                &panes,
                Some(target.as_str()),
                current_pane,
                &TmuxCompatState::default(),
            )?]
        }
    } else {
        panes
    };

    Ok(selected
        .iter()
        .map(|pane| format_pane_line(&snapshot, pane, &format, current_pane))
        .collect::<Vec<_>>()
        .join("\n")
        + "\n")
}

async fn handle_display_message(
    team_id: &str,
    current_pane: &str,
    args: &[String],
    state: &mut TmuxCompatState,
) -> Result<String, String> {
    let snapshot = fetch_snapshot(team_id).await?;
    let panes = all_panes(&snapshot);
    let mut target: Option<String> = None;
    let mut format = "#{pane_id}".to_string();
    let mut i = 0;
    while i < args.len() {
        match args[i].as_str() {
            "-p" => {}
            "-t" => {
                i += 1;
                target = args.get(i).cloned();
            }
            value if !value.starts_with('-') => {
                format = value.to_string();
            }
            _ => {}
        }
        i += 1;
    }

    let pane = resolve_pane(&snapshot, &panes, target.as_deref(), current_pane, state)?;
    Ok(format_pane_line(&snapshot, &pane, &format, current_pane) + "\n")
}

async fn handle_select_pane(
    team_id: &str,
    current_pane: &str,
    args: &[String],
    state: &mut TmuxCompatState,
) -> Result<String, String> {
    let snapshot = fetch_snapshot(team_id).await?;
    let panes = all_panes(&snapshot);
    let mut target: Option<String> = None;
    let mut i = 0;
    while i < args.len() {
        if args[i] == "-t" {
            i += 1;
            target = args.get(i).cloned();
        }
        i += 1;
    }
    let pane = resolve_pane(&snapshot, &panes, target.as_deref(), current_pane, state)?;
    state.selected_pane = Some(pane.pane_token.clone());
    state.last_target = Some(pane.pane_token.clone());
    Ok(String::new())
}

async fn handle_resize_pane(
    team_id: &str,
    current_pane: &str,
    args: &[String],
    state: &mut TmuxCompatState,
) -> Result<String, String> {
    let snapshot = fetch_snapshot(team_id).await?;
    let panes = all_panes(&snapshot);
    let mut target: Option<String> = None;
    let mut i = 0;
    while i < args.len() {
        if args[i] == "-t" {
            i += 1;
            target = args.get(i).cloned();
        }
        i += 1;
    }
    if let Some(target) = target.as_deref() {
        let pane = resolve_pane(&snapshot, &panes, Some(target), current_pane, state)?;
        state.last_target = Some(pane.pane_token);
    }
    Ok(String::new())
}

async fn handle_kill_pane(
    team_id: &str,
    current_pane: &str,
    args: &[String],
    state: &mut TmuxCompatState,
) -> Result<String, String> {
    let snapshot = fetch_snapshot(team_id).await?;
    let panes = all_panes(&snapshot);
    let mut target: Option<String> = None;
    let mut i = 0;
    while i < args.len() {
        if args[i] == "-t" {
            i += 1;
            target = args.get(i).cloned();
        }
        i += 1;
    }
    let pane = resolve_pane(&snapshot, &panes, target.as_deref(), current_pane, state)?;
    if pane.is_leader {
        return Err("refusing to kill the leader pane via tmux compat".to_string());
    }

    let _ = control_call(
        "agent.team.close_member",
        json!({
            "team_id": team_id,
            "session_id": pane.session_id,
        }),
    )
    .await?;
    if state.selected_pane.as_deref() == Some(&pane.pane_token) {
        state.selected_pane = Some(snapshot.leader_pane_token.clone());
    }
    state.last_target = Some(pane.pane_token);
    Ok(String::new())
}

async fn handle_has_session(team_id: &str) -> Result<String, String> {
    let _ = fetch_snapshot(team_id).await?;
    Ok(String::new())
}

async fn handle_list_windows(team_id: &str, args: &[String]) -> Result<String, String> {
    let snapshot = fetch_snapshot(team_id).await?;
    let mut format = "#{window_id}".to_string();
    let mut i = 0;
    while i < args.len() {
        if args[i] == "-F" {
            i += 1;
            format = args
                .get(i)
                .cloned()
                .ok_or_else(|| "tmux list-windows missing format after -F".to_string())?;
        }
        i += 1;
    }
    Ok(format_window_line(&snapshot, &format) + "\n")
}

async fn fetch_snapshot(team_id: &str) -> Result<AgentTeamSnapshot, String> {
    serde_json::from_value(control_call("agent.team.snapshot", json!({"team_id": team_id})).await?)
        .map_err(|e| e.to_string())
}

fn all_panes(snapshot: &AgentTeamSnapshot) -> Vec<PaneView> {
    let mut panes = Vec::with_capacity(snapshot.members.len() + 1);
    panes.push(PaneView {
        pane_token: snapshot.leader_pane_token.clone(),
        session_id: snapshot.leader_session_id.clone(),
        title: format!("{} leader", snapshot.provider),
        command: snapshot.provider.clone(),
        member_index: 0,
        working_dir: std::env::var("PWD").unwrap_or_default(),
        is_leader: true,
    });
    panes.extend(snapshot.members.iter().map(|member| PaneView {
        pane_token: member.pane_token.clone(),
        session_id: member.session_id.clone(),
        title: member.title.clone(),
        command: member.command.clone(),
        member_index: member.member_index,
        working_dir: std::env::var("PWD").unwrap_or_default(),
        is_leader: false,
    }));
    panes
}

fn resolve_pane(
    snapshot: &AgentTeamSnapshot,
    panes: &[PaneView],
    target: Option<&str>,
    current_pane: &str,
    state: &TmuxCompatState,
) -> Result<PaneView, String> {
    let target = normalize_target(
        target.unwrap_or(current_pane),
        snapshot,
        current_pane,
        state,
    );
    panes
        .iter()
        .find(|pane| {
            pane.pane_token == target
                || pane.member_index.to_string() == target
                || pane
                    .pane_token
                    .strip_prefix('%')
                    .is_some_and(|value| value == target)
        })
        .cloned()
        .or_else(|| {
            if target == snapshot.leader_pane_token {
                panes.iter().find(|pane| pane.is_leader).cloned()
            } else {
                None
            }
        })
        .ok_or_else(|| format!("unknown tmux pane target: {target}"))
}

fn pane_from_member(
    snapshot: &AgentTeamSnapshot,
    member: &AgentTeamMemberView,
) -> Result<PaneView, String> {
    resolve_pane(
        snapshot,
        &all_panes(snapshot),
        Some(&member.pane_token),
        &member.pane_token,
        &TmuxCompatState::default(),
    )
}

fn format_pane_line(
    snapshot: &AgentTeamSnapshot,
    pane: &PaneView,
    format: &str,
    current_pane: &str,
) -> String {
    let current_command = pane
        .command
        .split_whitespace()
        .next()
        .unwrap_or(snapshot.provider.as_str());
    let mut rendered = format.to_string();
    rendered = rendered.replace("#{pane_id}", &pane.pane_token);
    rendered = rendered.replace("#{pane_index}", &pane.member_index.to_string());
    rendered = rendered.replace("#{pane_title}", &pane.title);
    rendered = rendered.replace("#{pane_current_command}", current_command);
    rendered = rendered.replace("#{pane_current_path}", &pane.working_dir);
    rendered = rendered.replace("#{session_id}", &pane.session_id);
    rendered = rendered.replace("#{session_name}", &session_name(snapshot));
    rendered = rendered.replace(
        "#{pane_active}",
        if pane.pane_token == current_pane {
            "1"
        } else {
            "0"
        },
    );
    rendered = rendered.replace("#{window_active}", "1");
    rendered = rendered.replace("#{window_id}", "@0");
    rendered = rendered.replace("#{window_index}", "0");
    rendered = rendered.replace("#{window_name}", &snapshot.provider);
    rendered = rendered.replace("#{window_panes}", &(snapshot.members.len() + 1).to_string());
    rendered = rendered.replace("#{pane_dead}", "0");
    rendered
}

fn format_window_line(snapshot: &AgentTeamSnapshot, format: &str) -> String {
    let mut rendered = format.to_string();
    rendered = rendered.replace("#{window_id}", "@0");
    rendered = rendered.replace("#{window_index}", "0");
    rendered = rendered.replace("#{window_name}", &snapshot.provider);
    rendered = rendered.replace("#{window_active}", "1");
    rendered = rendered.replace("#{window_panes}", &(snapshot.members.len() + 1).to_string());
    rendered = rendered.replace("#{session_id}", &snapshot.leader_session_id);
    rendered = rendered.replace("#{session_name}", &session_name(snapshot));
    rendered
}

fn session_name(snapshot: &AgentTeamSnapshot) -> String {
    format!("{} team", snapshot.provider)
}

async fn control_call(method: &str, params: Value) -> Result<Value, String> {
    let socket_path = PathBuf::from(required_env("PNEVMA_AGENT_TEAM_CONTROL_SOCKET")?);
    let response = send_request(
        &socket_path,
        &ControlRequest {
            id: Uuid::new_v4().to_string(),
            method: method.to_string(),
            params,
            auth: None,
        },
    )
    .await?;

    if response.ok {
        Ok(response.result.unwrap_or(Value::Null))
    } else {
        let message = response
            .error
            .map(|error| error.message)
            .unwrap_or_else(|| format!("control request failed for {method}"));
        Err(message)
    }
}

fn required_env(name: &str) -> Result<String, String> {
    std::env::var(name).map_err(|_| format!("missing environment variable {name}"))
}

fn tmux_state_path(team_id: &str) -> PathBuf {
    std::env::temp_dir()
        .join("pnevma-agent-teams")
        .join(team_id)
        .join("tmux-state.json")
}

fn load_tmux_state(team_id: &str) -> TmuxCompatState {
    let path = tmux_state_path(team_id);
    std::fs::read(&path)
        .ok()
        .and_then(|bytes| serde_json::from_slice(&bytes).ok())
        .unwrap_or_default()
}

fn save_tmux_state(team_id: &str, state: &TmuxCompatState) -> Result<(), String> {
    let path = tmux_state_path(team_id);
    if let Some(parent) = path.parent() {
        std::fs::create_dir_all(parent).map_err(|e| e.to_string())?;
    }
    let bytes = serde_json::to_vec(state).map_err(|e| e.to_string())?;
    std::fs::write(path, bytes).map_err(|e| e.to_string())
}

fn is_window_target(target: &str) -> bool {
    target.starts_with('@')
}

fn normalize_target(
    target: &str,
    snapshot: &AgentTeamSnapshot,
    current_pane: &str,
    state: &TmuxCompatState,
) -> String {
    if target.is_empty() {
        return current_pane.to_string();
    }
    if target == "{last}" {
        return state
            .last_target
            .clone()
            .unwrap_or_else(|| current_pane.to_string());
    }
    if target == "{pane}" {
        return state
            .selected_pane
            .clone()
            .unwrap_or_else(|| current_pane.to_string());
    }
    if target == snapshot.leader_pane_token || target.starts_with('%') {
        return target.to_string();
    }
    if let Some((_, suffix)) = target.rsplit_once('.') {
        return suffix.to_string();
    }
    if let Some(stripped) = target.strip_prefix('@') {
        return stripped.to_string();
    }
    target.to_string()
}

#[cfg(test)]
mod tests {
    use super::*;

    fn snapshot() -> AgentTeamSnapshot {
        AgentTeamSnapshot {
            provider: "claude-code".to_string(),
            leader_session_id: "leader-session".to_string(),
            leader_pane_token: "%0".to_string(),
            members: vec![
                AgentTeamMemberView {
                    session_id: "member-1".to_string(),
                    pane_token: "%1".to_string(),
                    member_index: 1,
                    title: "Claude teammate 1".to_string(),
                    command: "claude".to_string(),
                },
                AgentTeamMemberView {
                    session_id: "member-2".to_string(),
                    pane_token: "%2".to_string(),
                    member_index: 2,
                    title: "Claude teammate 2".to_string(),
                    command: "claude".to_string(),
                },
            ],
        }
    }

    #[test]
    fn canonical_tmux_command_supports_aliases() {
        assert_eq!(canonical_tmux_command("splitw"), "split-window");
        assert_eq!(canonical_tmux_command("selectp"), "select-pane");
        assert_eq!(canonical_tmux_command("listw"), "list-windows");
    }

    #[test]
    fn resolve_pane_accepts_indices_and_window_qualified_targets() {
        let snapshot = snapshot();
        let panes = all_panes(&snapshot);
        let pane = resolve_pane(
            &snapshot,
            &panes,
            Some("0.2"),
            "%0",
            &TmuxCompatState::default(),
        )
        .expect("resolve pane");
        assert_eq!(pane.pane_token, "%2");

        let pane = resolve_pane(
            &snapshot,
            &panes,
            Some("1"),
            "%0",
            &TmuxCompatState::default(),
        )
        .expect("resolve pane by index");
        assert_eq!(pane.pane_token, "%1");
    }

    #[test]
    fn format_window_line_includes_single_window_tokens() {
        let snapshot = snapshot();
        let line = format_window_line(
            &snapshot,
            "#{window_id} #{window_index} #{window_name} #{window_panes} #{session_name}",
        );
        assert_eq!(line, "@0 0 claude-code 3 claude-code team");
    }
}
