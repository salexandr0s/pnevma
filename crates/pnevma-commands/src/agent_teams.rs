use crate::commands::{
    append_event, create_remote_managed_session, current_redaction_secrets, redact_text,
    session_row_from_meta, session_row_to_event_payload, ssh_profile_from_remote_target,
    CreateRemoteManagedSessionInput, SessionRemoteTargetInput,
};
use crate::control::resolve_control_plane_settings;
use crate::event_emitter::EventEmitter;
use crate::state::AppState;
use pnevma_agents::{
    prepare_claude_team_environment, with_tmux_pane_token, AgentTeamConfig as AdapterTeamConfig,
};
use pnevma_core::{GlobalConfig, ProjectConfig};
use pnevma_db::SessionRow;
use pnevma_db::{Db, PaneRow};
use pnevma_session::SessionSupervisor;
use serde::{Deserialize, Serialize};
use serde_json::json;
use std::collections::HashMap;
use std::path::Path;
use std::sync::Arc;
use tokio::sync::RwLock;
use uuid::Uuid;

const LEADER_PANE_TOKEN: &str = "%0";
const MAX_MEMBER_COMMAND_BYTES: usize = 16 * 1024;
const SCROLLBACK_SUMMARY_BYTES: usize = 16 * 1024;

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct AgentTeamConfigInput {
    pub team_id: String,
    pub provider: String,
    pub leader_session_id: String,
    pub leader_pane_id: String,
    pub working_dir: String,
    pub control_socket_path: String,
    #[serde(default)]
    pub base_env: Vec<(String, String)>,
    #[serde(default)]
    pub remote_target: Option<SessionRemoteTargetInput>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct AgentTeamMemberView {
    pub team_id: String,
    pub provider: String,
    pub session_id: String,
    pub pane_id: String,
    pub pane_token: String,
    pub member_index: usize,
    pub title: String,
    pub command: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct AgentTeamSnapshot {
    pub team_id: String,
    pub provider: String,
    pub leader_session_id: String,
    pub leader_pane_id: String,
    pub leader_pane_token: String,
    pub main_vertical: bool,
    #[serde(default)]
    pub remote_target: Option<SessionRemoteTargetInput>,
    pub members: Vec<AgentTeamMemberView>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct AgentTeamSpawnInput {
    pub team_id: String,
    pub command: String,
    #[serde(default)]
    pub title: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct AgentTeamCloseInput {
    pub team_id: String,
    pub session_id: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct AgentTeamSpawnResult {
    pub team_id: String,
    pub provider: String,
    pub leader_session_id: String,
    pub leader_pane_id: String,
    pub leader_pane_token: String,
    pub member: AgentTeamMemberView,
}

#[derive(Debug, Clone)]
struct AgentTeamState {
    team_id: String,
    provider: String,
    leader_session_id: String,
    leader_pane_id: String,
    working_dir: String,
    control_socket_path: String,
    base_env: Vec<(String, String)>,
    remote_target: Option<SessionRemoteTargetInput>,
    main_vertical: bool,
    next_member_index: usize,
    members: Vec<AgentTeamMemberView>,
}

#[derive(Debug, Clone)]
struct RehydratedAgentTeam {
    config: AgentTeamConfigInput,
    main_vertical: bool,
    members: Vec<AgentTeamMemberView>,
}

#[derive(Debug, Clone, Deserialize)]
struct PersistedAgentTeamEnvelope {
    #[serde(default)]
    agent_team: Option<PersistedAgentTeamMetadata>,
    #[serde(default)]
    remote_target: Option<SessionRemoteTargetInput>,
}

#[derive(Debug, Clone, Deserialize)]
struct PersistedAgentTeamMetadata {
    team_id: String,
    leader_session_id: String,
    provider: String,
    role: String,
    #[serde(default)]
    member_index: usize,
}

#[derive(Debug, Clone)]
struct ParsedAgentTeamMetadata {
    team_id: String,
    leader_session_id: String,
    provider: String,
    role: String,
    member_index: usize,
    remote_target: Option<SessionRemoteTargetInput>,
}

#[derive(Debug, Clone, Default)]
pub struct AgentTeamStore {
    teams: HashMap<String, AgentTeamState>,
    member_sessions: HashMap<String, String>,
}

impl AgentTeamStore {
    pub fn start(&mut self, input: AgentTeamConfigInput) -> AgentTeamSnapshot {
        let state = self
            .teams
            .entry(input.team_id.clone())
            .or_insert_with(|| AgentTeamState {
                team_id: input.team_id.clone(),
                provider: input.provider.clone(),
                leader_session_id: input.leader_session_id.clone(),
                leader_pane_id: input.leader_pane_id.clone(),
                working_dir: input.working_dir.clone(),
                control_socket_path: input.control_socket_path.clone(),
                base_env: input.base_env.clone(),
                remote_target: input.remote_target.clone(),
                main_vertical: true,
                next_member_index: 1,
                members: Vec::new(),
            });
        state.provider = input.provider;
        state.leader_session_id = input.leader_session_id;
        state.leader_pane_id = input.leader_pane_id;
        state.working_dir = input.working_dir;
        state.control_socket_path = input.control_socket_path;
        state.base_env = input.base_env;
        state.remote_target = input.remote_target;
        snapshot_from_state(state)
    }

    pub fn snapshot(&self, team_id: &str) -> Option<AgentTeamSnapshot> {
        self.teams.get(team_id).map(snapshot_from_state)
    }

    fn provider_for_team(&self, team_id: &str) -> Option<String> {
        self.teams.get(team_id).map(|team| team.provider.clone())
    }

    fn config_for_team(&self, team_id: &str) -> Option<AgentTeamConfigInput> {
        self.teams.get(team_id).map(|team| AgentTeamConfigInput {
            team_id: team.team_id.clone(),
            provider: team.provider.clone(),
            leader_session_id: team.leader_session_id.clone(),
            leader_pane_id: team.leader_pane_id.clone(),
            working_dir: team.working_dir.clone(),
            control_socket_path: team.control_socket_path.clone(),
            base_env: team.base_env.clone(),
            remote_target: team.remote_target.clone(),
        })
    }

    fn register_member(
        &mut self,
        team_id: &str,
        session_id: String,
        pane_id: String,
        command: String,
        title: String,
    ) -> Option<AgentTeamSpawnResult> {
        let team = self.teams.get_mut(team_id)?;
        let member_index = team.next_member_index;
        team.next_member_index += 1;
        let pane_token = format!("%{member_index}");
        let member = AgentTeamMemberView {
            team_id: team.team_id.clone(),
            provider: team.provider.clone(),
            session_id: session_id.clone(),
            pane_id,
            pane_token,
            member_index,
            title,
            command,
        };
        self.member_sessions
            .insert(session_id.clone(), team.team_id.clone());
        team.members.push(member.clone());
        Some(AgentTeamSpawnResult {
            team_id: team.team_id.clone(),
            provider: team.provider.clone(),
            leader_session_id: team.leader_session_id.clone(),
            leader_pane_id: team.leader_pane_id.clone(),
            leader_pane_token: LEADER_PANE_TOKEN.to_string(),
            member,
        })
    }

    fn remove_member(&mut self, team_id: &str, session_id: &str) -> Option<AgentTeamSpawnResult> {
        let team = self.teams.get_mut(team_id)?;
        let idx = team
            .members
            .iter()
            .position(|member| member.session_id == session_id)?;
        let member = team.members.remove(idx);
        self.member_sessions.remove(session_id);
        Some(AgentTeamSpawnResult {
            team_id: team.team_id.clone(),
            provider: team.provider.clone(),
            leader_session_id: team.leader_session_id.clone(),
            leader_pane_id: team.leader_pane_id.clone(),
            leader_pane_token: LEADER_PANE_TOKEN.to_string(),
            member,
        })
    }

    fn remove_member_by_session(&mut self, session_id: &str) -> Option<AgentTeamSpawnResult> {
        let team_id = self.member_sessions.get(session_id)?.clone();
        self.remove_member(&team_id, session_id)
    }

    fn set_main_vertical(&mut self, team_id: &str, enabled: bool) -> Option<AgentTeamSnapshot> {
        let team = self.teams.get_mut(team_id)?;
        team.main_vertical = enabled;
        Some(snapshot_from_state(team))
    }

    fn rehydrate(
        &mut self,
        input: AgentTeamConfigInput,
        main_vertical: bool,
        members: Vec<AgentTeamMemberView>,
    ) -> AgentTeamSnapshot {
        let next_member_index = members
            .iter()
            .map(|member| member.member_index)
            .max()
            .unwrap_or(0)
            + 1;
        for member in &members {
            self.member_sessions
                .insert(member.session_id.clone(), input.team_id.clone());
        }
        let state = AgentTeamState {
            team_id: input.team_id.clone(),
            provider: input.provider,
            leader_session_id: input.leader_session_id,
            leader_pane_id: input.leader_pane_id,
            working_dir: input.working_dir,
            control_socket_path: input.control_socket_path,
            base_env: input.base_env,
            remote_target: input.remote_target,
            main_vertical,
            next_member_index,
            members,
        };
        let snapshot = snapshot_from_state(&state);
        self.teams.insert(input.team_id, state);
        snapshot
    }

    pub fn clear(&mut self) {
        self.teams.clear();
        self.member_sessions.clear();
    }
}

fn snapshot_from_state(state: &AgentTeamState) -> AgentTeamSnapshot {
    AgentTeamSnapshot {
        team_id: state.team_id.clone(),
        provider: state.provider.clone(),
        leader_session_id: state.leader_session_id.clone(),
        leader_pane_id: state.leader_pane_id.clone(),
        leader_pane_token: LEADER_PANE_TOKEN.to_string(),
        main_vertical: state.main_vertical,
        remote_target: state.remote_target.clone(),
        members: state.members.clone(),
    }
}

pub async fn start_team(
    input: AgentTeamConfigInput,
    emitter: &Arc<dyn EventEmitter>,
    state: &AppState,
) -> Result<AgentTeamSnapshot, String> {
    let project_id = state
        .with_project("agent_team.start", |ctx| ctx.project_id)
        .await?;
    let snapshot = {
        let mut guard = state.agent_teams.write().await;
        guard.start(input)
    };
    emitter.emit(
        "agent_team_started",
        json!({
            "project_id": project_id,
            "team": snapshot,
        }),
    );
    Ok(snapshot)
}

pub async fn snapshot_team(team_id: &str, state: &AppState) -> Result<AgentTeamSnapshot, String> {
    snapshot_team_from_store(team_id, &state.agent_teams).await
}

pub async fn rehydrate_all_teams(state: &AppState) -> Result<Vec<AgentTeamSnapshot>, String> {
    let (db, project_id, project_path, project_config, global_config) = state
        .with_project("agent_team.rehydrate_all", |ctx| {
            (
                ctx.db.clone(),
                ctx.project_id,
                ctx.project_path.clone(),
                ctx.config.clone(),
                ctx.global_config.clone(),
            )
        })
        .await?;
    rehydrate_all_teams_with_runtime(
        &db,
        project_id,
        &project_path,
        &project_config,
        &global_config,
        &state.agent_teams,
        &state.emitter,
    )
    .await
}

pub async fn set_team_main_vertical(
    team_id: &str,
    enabled: bool,
    emitter: &Arc<dyn EventEmitter>,
    state: &AppState,
) -> Result<AgentTeamSnapshot, String> {
    let project_id = state
        .with_project("agent_team.set_main_vertical", |ctx| ctx.project_id)
        .await?;
    let snapshot = {
        let mut guard = state.agent_teams.write().await;
        guard
            .set_main_vertical(team_id, enabled)
            .ok_or_else(|| format!("agent team not found: {team_id}"))?
    };
    emitter.emit(
        "agent_team_layout_changed",
        json!({
            "project_id": project_id,
            "team": snapshot,
        }),
    );
    Ok(snapshot)
}

pub async fn spawn_member(
    input: AgentTeamSpawnInput,
    emitter: &Arc<dyn EventEmitter>,
    state: &AppState,
) -> Result<AgentTeamSpawnResult, String> {
    let (db, project_id, sessions, redaction_secrets) = state
        .with_project("agent_team.spawn_member", |ctx| {
            (
                ctx.db.clone(),
                ctx.project_id,
                ctx.sessions.clone(),
                Arc::clone(&ctx.redaction_secrets),
            )
        })
        .await?;
    spawn_member_with_runtime(
        input,
        &db,
        project_id,
        &sessions,
        &redaction_secrets,
        &state.agent_teams,
        emitter,
    )
    .await
}

pub async fn close_member(
    input: AgentTeamCloseInput,
    emitter: &Arc<dyn EventEmitter>,
    state: &AppState,
) -> Result<AgentTeamSpawnResult, String> {
    let (db, project_id, sessions) = state
        .with_project("agent_team.close_member", |ctx| {
            (ctx.db.clone(), ctx.project_id, ctx.sessions.clone())
        })
        .await?;
    close_member_with_runtime(
        input,
        &db,
        project_id,
        &sessions,
        &state.agent_teams,
        emitter,
    )
    .await
}

pub async fn handle_member_session_exit(
    session_id: &str,
    emitter: &Arc<dyn EventEmitter>,
    db: &Db,
    project_id: Uuid,
    agent_teams: &Arc<RwLock<AgentTeamStore>>,
) {
    let result = {
        let mut guard = agent_teams.write().await;
        guard.remove_member_by_session(session_id)
    };
    let Some(result) = result else {
        return;
    };
    let _ = db.remove_pane(&result.member.pane_id).await;
    emitter.emit(
        "agent_team_member_closed",
        json!({
            "project_id": project_id,
            "team_id": result.team_id,
            "leader_session_id": result.leader_session_id,
            "leader_pane_id": result.leader_pane_id,
            "member": result.member,
            "equalize_orientation": "vertical",
            "preserve_focus": true,
        }),
    );
    append_event(
        db,
        project_id,
        None,
        Some(Uuid::parse_str(session_id).unwrap_or_else(|_| Uuid::nil())),
        "agent_team",
        "AgentTeamMemberExited",
        json!({
            "team_id": result.team_id,
            "session_id": session_id,
        }),
    )
    .await;
}

pub async fn collect_member_result(
    team_id: &str,
    session_id: &str,
    state: &AppState,
) -> Result<serde_json::Value, String> {
    let (sessions, project_path, redaction_secrets) = state
        .with_project("agent_team.collect_member_result", |ctx| {
            (
                ctx.sessions.clone(),
                ctx.project_path.clone(),
                Arc::clone(&ctx.redaction_secrets),
            )
        })
        .await?;
    collect_member_result_with_runtime(
        team_id,
        session_id,
        &sessions,
        &project_path,
        &redaction_secrets,
        &state.agent_teams,
    )
    .await
}

pub async fn snapshot_team_from_store(
    team_id: &str,
    agent_teams: &Arc<RwLock<AgentTeamStore>>,
) -> Result<AgentTeamSnapshot, String> {
    let guard = agent_teams.read().await;
    guard
        .snapshot(team_id)
        .ok_or_else(|| format!("agent team not found: {team_id}"))
}

pub async fn rehydrate_all_teams_with_runtime(
    db: &Db,
    project_id: Uuid,
    project_path: &Path,
    project_config: &ProjectConfig,
    global_config: &GlobalConfig,
    agent_teams: &Arc<RwLock<AgentTeamStore>>,
    emitter: &Arc<dyn EventEmitter>,
) -> Result<Vec<AgentTeamSnapshot>, String> {
    let sessions = db
        .list_sessions(&project_id.to_string())
        .await
        .map_err(|e| e.to_string())?;
    let panes = db
        .list_panes(&project_id.to_string())
        .await
        .map_err(|e| e.to_string())?;
    let teams =
        collect_rehydrated_teams(sessions, panes, project_path, project_config, global_config)?;

    let snapshots = {
        let mut guard = agent_teams.write().await;
        guard.clear();
        teams
            .into_iter()
            .map(|team| guard.rehydrate(team.config, team.main_vertical, team.members))
            .collect::<Vec<_>>()
    };

    for snapshot in &snapshots {
        emitter.emit(
            "agent_team_rehydrated",
            json!({
                "project_id": project_id.to_string(),
                "team": snapshot,
            }),
        );
        append_event(
            db,
            project_id,
            None,
            Uuid::parse_str(&snapshot.leader_session_id).ok(),
            "agent_team",
            "AgentTeamRehydrated",
            json!({
                "team_id": snapshot.team_id,
                "provider": snapshot.provider,
                "member_count": snapshot.members.len(),
            }),
        )
        .await;
    }

    Ok(snapshots)
}

pub async fn spawn_member_with_runtime(
    input: AgentTeamSpawnInput,
    db: &Db,
    project_id: Uuid,
    sessions: &SessionSupervisor,
    redaction_secrets: &Arc<RwLock<Vec<String>>>,
    agent_teams: &Arc<RwLock<AgentTeamStore>>,
    emitter: &Arc<dyn EventEmitter>,
) -> Result<AgentTeamSpawnResult, String> {
    if input.command.trim().is_empty() {
        return Err("team member command must not be empty".to_string());
    }
    if input.command.len() > MAX_MEMBER_COMMAND_BYTES {
        return Err(format!(
            "team member command exceeds {MAX_MEMBER_COMMAND_BYTES} bytes"
        ));
    }
    if input.command.contains('\0') {
        return Err("team member command contains a NUL byte".to_string());
    }

    let team_config = {
        let guard = agent_teams.read().await;
        guard
            .config_for_team(&input.team_id)
            .ok_or_else(|| format!("agent team not found: {}", input.team_id))?
    };

    let member_index = {
        let guard = agent_teams.read().await;
        guard
            .snapshot(&input.team_id)
            .map(|snapshot| snapshot.members.len() + 1)
            .unwrap_or(1)
    };
    let pane_token = format!("%{member_index}");
    let title = input
        .title
        .unwrap_or_else(|| format!("{} teammate {}", team_config.provider, member_index));
    let session_name = format!("{} teammate {}", team_config.provider, member_index);
    let base_env = with_tmux_pane_token(&team_config.base_env, &pane_token);
    let wrapped_command = wrap_command_with_env(&base_env, &input.command);
    let row = if let Some(remote_target) = team_config.remote_target.as_ref() {
        let profile = ssh_profile_from_remote_target(remote_target)?;
        create_remote_managed_session(CreateRemoteManagedSessionInput {
            db,
            project_id,
            name: session_name,
            session_type: Some("terminal".to_string()),
            profile: &profile,
            connection_id: remote_target.ssh_profile_id.clone(),
            cwd: team_config.working_dir.clone(),
            command: Some(wrapped_command.clone()),
        })
        .await?
    } else {
        let meta = sessions
            .spawn_shell(
                project_id,
                session_name,
                team_config.working_dir.clone(),
                wrapped_command.clone(),
            )
            .await
            .map_err(|e| e.to_string())?;
        let row = session_row_from_meta(&meta);
        db.upsert_session(&row).await.map_err(|e| e.to_string())?;
        row
    };

    let pane_id = Uuid::new_v4().to_string();
    let pane = PaneRow {
        id: pane_id.clone(),
        project_id: project_id.to_string(),
        session_id: Some(row.id.clone()),
        r#type: "terminal".to_string(),
        position: position_for_team_member(db, project_id, &team_config.leader_pane_id).await?,
        label: title.clone(),
        metadata_json: Some(team_pane_metadata_json(
            &input.team_id,
            &team_config.leader_session_id,
            &team_config.provider,
            member_index,
            team_config.remote_target.as_ref(),
        )?),
    };
    db.upsert_pane(&pane).await.map_err(|e| e.to_string())?;

    let result = {
        let mut guard = agent_teams.write().await;
        guard
            .register_member(
                &input.team_id,
                row.id.clone(),
                pane_id,
                input.command.clone(),
                title,
            )
            .ok_or_else(|| format!("agent team not found: {}", input.team_id))?
    };

    emitter.emit(
        "agent_team_member_spawned",
        json!({
            "project_id": project_id,
            "team_id": result.team_id,
            "provider": result.provider,
            "leader_session_id": result.leader_session_id,
            "leader_pane_id": result.leader_pane_id,
            "leader_pane_token": result.leader_pane_token,
            "member": result.member,
            "session": session_row_to_event_payload(&row),
            "equalize_orientation": "vertical",
            "preserve_focus": true,
        }),
    );
    append_event(
        db,
        project_id,
        None,
        Uuid::parse_str(&row.id).ok(),
        "agent_team",
        "AgentTeamMemberSpawned",
        json!({
            "team_id": input.team_id,
            "provider": team_config.provider,
            "member_index": member_index,
            "pane_token": pane_token,
            "command": redact_text(&input.command, &current_redaction_secrets(redaction_secrets).await),
        }),
    )
    .await;

    Ok(result)
}

pub async fn close_member_with_runtime(
    input: AgentTeamCloseInput,
    db: &Db,
    project_id: Uuid,
    sessions: &SessionSupervisor,
    agent_teams: &Arc<RwLock<AgentTeamStore>>,
    emitter: &Arc<dyn EventEmitter>,
) -> Result<AgentTeamSpawnResult, String> {
    let session_row = db
        .get_session(&project_id.to_string(), &input.session_id)
        .await
        .map_err(|e| e.to_string())?;
    let team_config = {
        let guard = agent_teams.read().await;
        guard
            .config_for_team(&input.team_id)
            .ok_or_else(|| format!("agent team not found: {}", input.team_id))?
    };

    if let Some(row) = session_row.as_ref() {
        if row.backend.eq_ignore_ascii_case("remote_ssh_durable") {
            if let Some(remote_target) = team_config.remote_target.as_ref() {
                let profile = ssh_profile_from_remote_target(remote_target)?;
                let remote_session_id = row.remote_session_id.as_deref().unwrap_or(row.id.as_str());
                pnevma_ssh::terminate_remote_session(&profile, remote_session_id)
                    .await
                    .map_err(|e| e.to_string())?;
            }
        } else if let Ok(session_uuid) = Uuid::parse_str(&input.session_id) {
            let _ = sessions.kill_session_backend(session_uuid).await;
        }
    } else if let Ok(session_uuid) = Uuid::parse_str(&input.session_id) {
        let _ = sessions.kill_session_backend(session_uuid).await;
    }

    let result = {
        let mut guard = agent_teams.write().await;
        guard
            .remove_member(&input.team_id, &input.session_id)
            .ok_or_else(|| {
                format!(
                    "team member not found: {} in team {}",
                    input.session_id, input.team_id
                )
            })?
    };
    db.remove_pane(&result.member.pane_id)
        .await
        .map_err(|e| e.to_string())?;
    if let Some(mut row) = session_row {
        row.status = "complete".to_string();
        row.lifecycle_state = "exited".to_string();
        row.last_heartbeat = chrono::Utc::now();
        row.last_error = None;
        row.ended_at = Some(chrono::Utc::now().to_rfc3339());
        db.upsert_session(&row).await.map_err(|e| e.to_string())?;
    }
    emitter.emit(
        "agent_team_member_closed",
        json!({
            "project_id": project_id,
            "team_id": result.team_id,
            "leader_session_id": result.leader_session_id,
            "leader_pane_id": result.leader_pane_id,
            "member": result.member,
            "equalize_orientation": "vertical",
            "preserve_focus": true,
        }),
    );
    append_event(
        db,
        project_id,
        None,
        Uuid::parse_str(&input.session_id).ok(),
        "agent_team",
        "AgentTeamMemberClosed",
        json!({
            "team_id": input.team_id,
            "session_id": input.session_id,
        }),
    )
    .await;
    Ok(result)
}

pub async fn collect_member_result_with_runtime(
    team_id: &str,
    session_id: &str,
    sessions: &SessionSupervisor,
    project_path: &Path,
    redaction_secrets: &Arc<RwLock<Vec<String>>>,
    agent_teams: &Arc<RwLock<AgentTeamStore>>,
) -> Result<serde_json::Value, String> {
    let guard = agent_teams.read().await;
    let provider = guard
        .provider_for_team(team_id)
        .ok_or_else(|| format!("agent team not found: {team_id}"))?;
    let remote_target = guard
        .config_for_team(team_id)
        .and_then(|config| config.remote_target);
    drop(guard);

    let scrollback = if let Some(remote_target) = remote_target.as_ref() {
        let profile = ssh_profile_from_remote_target(remote_target)?;
        let contents =
            pnevma_ssh::read_remote_scrollback_tail(&profile, session_id, SCROLLBACK_SUMMARY_BYTES)
                .await
                .map_err(|e| e.to_string())?;
        let secrets = current_redaction_secrets(redaction_secrets).await;
        if secrets.is_empty() {
            contents
        } else {
            redact_text(&contents, &secrets)
        }
    } else {
        let session_uuid = Uuid::parse_str(session_id).map_err(|e| e.to_string())?;
        match sessions
            .read_scrollback_tail(session_uuid, SCROLLBACK_SUMMARY_BYTES)
            .await
        {
            Ok(slice) => slice.data,
            Err(_) => {
                let path = project_path
                    .join(".pnevma/data/scrollback")
                    .join(format!("{session_id}.log"));
                let contents = std::fs::read_to_string(&path).unwrap_or_default();
                let secrets = current_redaction_secrets(redaction_secrets).await;
                if secrets.is_empty() {
                    contents
                } else {
                    redact_text(&contents, &secrets)
                }
            }
        }
    };
    let project_path_value = remote_target
        .as_ref()
        .map(|target| target.remote_path.clone())
        .unwrap_or_else(|| project_path.display().to_string());

    Ok(json!({
        "success": true,
        "team_id": team_id,
        "session_id": session_id,
        "provider": provider,
        "project_path": project_path_value,
        "transcript_tail": trim_for_json(&scrollback, SCROLLBACK_SUMMARY_BYTES),
    }))
}

fn collect_rehydrated_teams(
    sessions: Vec<SessionRow>,
    panes: Vec<PaneRow>,
    project_path: &Path,
    project_config: &ProjectConfig,
    global_config: &GlobalConfig,
) -> Result<Vec<RehydratedAgentTeam>, String> {
    let control_socket_path =
        resolve_control_plane_settings(project_path, project_config, global_config)
            .map(|settings| settings.socket_path.to_string_lossy().to_string())
            .unwrap_or_else(|_| {
                project_path
                    .join(&project_config.automation.socket_path)
                    .to_string_lossy()
                    .to_string()
            });
    let live_sessions = sessions
        .into_iter()
        .filter(session_row_is_rehydratable)
        .map(|session| (session.id.clone(), session))
        .collect::<HashMap<_, _>>();

    #[derive(Clone)]
    struct PartialTeam {
        team_id: String,
        provider: String,
        leader_session_id: String,
        leader_pane_id: String,
        working_dir: String,
        remote_target: Option<SessionRemoteTargetInput>,
        members: Vec<AgentTeamMemberView>,
    }

    let mut partials: HashMap<String, PartialTeam> = HashMap::new();
    for pane in panes {
        let Some(metadata) = parse_agent_team_metadata(pane.metadata_json.as_deref()) else {
            continue;
        };
        let Some(session_id) = pane.session_id.clone() else {
            continue;
        };
        let Some(session) = live_sessions.get(&session_id) else {
            continue;
        };
        match metadata.role.as_str() {
            "leader" => {
                partials
                    .entry(metadata.team_id.clone())
                    .and_modify(|team| {
                        team.provider = metadata.provider.clone();
                        team.leader_session_id = session.id.clone();
                        team.leader_pane_id = pane.id.clone();
                        team.working_dir = session.cwd.clone();
                        team.remote_target = metadata.remote_target.clone();
                    })
                    .or_insert_with(|| PartialTeam {
                        team_id: metadata.team_id.clone(),
                        provider: metadata.provider.clone(),
                        leader_session_id: session.id.clone(),
                        leader_pane_id: pane.id.clone(),
                        working_dir: session.cwd.clone(),
                        remote_target: metadata.remote_target.clone(),
                        members: Vec::new(),
                    });
            }
            "member" => {
                let member = AgentTeamMemberView {
                    team_id: metadata.team_id.clone(),
                    provider: metadata.provider.clone(),
                    session_id: session.id.clone(),
                    pane_id: pane.id.clone(),
                    pane_token: format!("%{}", metadata.member_index),
                    member_index: metadata.member_index,
                    title: pane.label.clone(),
                    command: session.command.clone(),
                };
                partials
                    .entry(metadata.team_id.clone())
                    .and_modify(|team| team.members.push(member.clone()))
                    .or_insert_with(|| PartialTeam {
                        team_id: metadata.team_id.clone(),
                        provider: metadata.provider.clone(),
                        leader_session_id: metadata.leader_session_id.clone(),
                        leader_pane_id: String::new(),
                        working_dir: session.cwd.clone(),
                        remote_target: metadata.remote_target.clone(),
                        members: vec![member],
                    });
            }
            _ => {}
        }
    }

    let mut teams = partials
        .into_values()
        .filter(|team| !team.leader_pane_id.is_empty())
        .map(|mut team| {
            team.members.sort_by_key(|member| member.member_index);
            let config = build_rehydrated_team_config(
                &team.team_id,
                &team.provider,
                &team.leader_session_id,
                &team.leader_pane_id,
                &team.working_dir,
                &control_socket_path,
                team.remote_target.as_ref(),
            )?;
            Ok(RehydratedAgentTeam {
                config,
                main_vertical: true,
                members: team.members,
            })
        })
        .collect::<Result<Vec<_>, String>>()?;
    teams.sort_by(|lhs, rhs| lhs.config.team_id.cmp(&rhs.config.team_id));
    Ok(teams)
}

fn session_row_is_rehydratable(row: &SessionRow) -> bool {
    row.ended_at.is_none() && !matches!(row.status.as_str(), "complete" | "error")
}

fn build_rehydrated_team_config(
    team_id: &str,
    provider: &str,
    leader_session_id: &str,
    leader_pane_id: &str,
    working_dir: &str,
    control_socket_path: &str,
    remote_target: Option<&SessionRemoteTargetInput>,
) -> Result<AgentTeamConfigInput, String> {
    let seed = AdapterTeamConfig {
        team_id: team_id.to_string(),
        provider: provider.to_string(),
        leader_session_id: leader_session_id.to_string(),
        leader_pane_id: leader_pane_id.to_string(),
        control_socket_path: control_socket_path.to_string(),
        working_dir: working_dir.to_string(),
        base_env: Vec::new(),
    };
    let base_env = if provider == "claude-code" {
        prepare_claude_team_environment(&seed, LEADER_PANE_TOKEN)?
    } else {
        Vec::new()
    };
    Ok(AgentTeamConfigInput {
        team_id: team_id.to_string(),
        provider: provider.to_string(),
        leader_session_id: leader_session_id.to_string(),
        leader_pane_id: leader_pane_id.to_string(),
        working_dir: working_dir.to_string(),
        control_socket_path: control_socket_path.to_string(),
        base_env,
        remote_target: remote_target.cloned(),
    })
}

fn parse_agent_team_metadata(metadata_json: Option<&str>) -> Option<ParsedAgentTeamMetadata> {
    let json = metadata_json?;
    let decoded = serde_json::from_str::<PersistedAgentTeamEnvelope>(json).ok()?;
    let metadata = decoded.agent_team?;
    Some(ParsedAgentTeamMetadata {
        team_id: metadata.team_id,
        leader_session_id: metadata.leader_session_id,
        provider: metadata.provider,
        role: metadata.role,
        member_index: metadata.member_index,
        remote_target: decoded.remote_target,
    })
}

async fn position_for_team_member(
    db: &Db,
    project_id: Uuid,
    leader_pane_id: &str,
) -> Result<String, String> {
    let panes = db
        .list_panes(&project_id.to_string())
        .await
        .map_err(|e| e.to_string())?;
    let last_team_pane = panes
        .iter()
        .rev()
        .find(|pane| {
            pane.metadata_json.as_ref().is_some_and(|metadata| {
                metadata.contains("\"agent_team\"") || metadata.contains("\"team_id\"")
            })
        })
        .map(|pane| pane.id.clone());
    Ok(format!(
        "after:{}",
        last_team_pane.unwrap_or_else(|| leader_pane_id.to_string())
    ))
}

fn team_pane_metadata_json(
    team_id: &str,
    leader_session_id: &str,
    provider: &str,
    member_index: usize,
    remote_target: Option<&SessionRemoteTargetInput>,
) -> Result<String, String> {
    serde_json::to_string(&json!({
        "read_only": true,
        "remote_target": remote_target,
        "agent_team": {
            "team_id": team_id,
            "leader_session_id": leader_session_id,
            "provider": provider,
            "role": "member",
            "member_index": member_index,
        }
    }))
    .map_err(|e| e.to_string())
}

pub fn leader_team_pane_metadata_json(
    team_id: &str,
    leader_session_id: &str,
    provider: &str,
    remote_target: Option<&SessionRemoteTargetInput>,
) -> Result<String, String> {
    serde_json::to_string(&json!({
        "read_only": true,
        "remote_target": remote_target,
        "agent_team": {
            "team_id": team_id,
            "leader_session_id": leader_session_id,
            "provider": provider,
            "role": "leader",
            "member_index": 0,
        }
    }))
    .map_err(|e| e.to_string())
}

fn wrap_command_with_env(env: &[(String, String)], command: &str) -> String {
    let mut script = String::new();
    for (key, value) in env {
        script.push_str("export ");
        script.push_str(key);
        script.push('=');
        script.push_str(&pnevma_ssh::shell_escape_arg(value));
        script.push_str("; ");
    }
    script.push_str("exec ");
    script.push_str(command);
    script
}

fn trim_for_json(text: &str, max_bytes: usize) -> String {
    if text.len() <= max_bytes {
        return text.to_string();
    }
    text[text.len().saturating_sub(max_bytes)..].to_string()
}

#[cfg(test)]
mod tests {
    use super::*;
    use chrono::{TimeZone, Utc};
    use pnevma_core::config::{
        AgentsSection, AutomationSection, BranchesSection, PathSection, ProjectSection,
        RedactionSection, RemoteSection, RetentionSection, TrackerSection,
    };

    fn project_config() -> ProjectConfig {
        ProjectConfig {
            project: ProjectSection {
                name: "test-project".to_string(),
                brief: String::new(),
            },
            agents: AgentsSection {
                default_provider: "claude-code".to_string(),
                max_concurrent: 1,
                claude_code: None,
                codex: None,
            },
            automation: AutomationSection::default(),
            retention: RetentionSection::default(),
            branches: BranchesSection {
                target: "main".to_string(),
                naming: "task/{slug}".to_string(),
            },
            rules: PathSection::default(),
            conventions: PathSection::default(),
            remote: RemoteSection::default(),
            redaction: RedactionSection::default(),
            tracker: TrackerSection::default(),
        }
    }

    fn session(id: &str, status: &str, cwd: &str, command: &str) -> SessionRow {
        SessionRow {
            id: id.to_string(),
            project_id: Uuid::nil().to_string(),
            name: format!("session-{id}"),
            r#type: Some("terminal".to_string()),
            backend: "tmux_compat".to_string(),
            durability: "durable".to_string(),
            lifecycle_state: "attached".to_string(),
            status: status.to_string(),
            pid: None,
            cwd: cwd.to_string(),
            command: command.to_string(),
            branch: None,
            worktree_id: None,
            connection_id: None,
            remote_session_id: None,
            controller_id: None,
            started_at: Utc.timestamp_opt(0, 0).single().unwrap(),
            last_heartbeat: Utc.timestamp_opt(0, 0).single().unwrap(),
            last_output_at: None,
            detached_at: None,
            last_error: None,
            restore_status: None,
            exit_code: None,
            ended_at: None,
        }
    }

    fn pane(id: &str, session_id: &str, metadata_json: &str, label: &str) -> PaneRow {
        PaneRow {
            id: id.to_string(),
            project_id: Uuid::nil().to_string(),
            session_id: Some(session_id.to_string()),
            r#type: "terminal".to_string(),
            position: "root".to_string(),
            label: label.to_string(),
            metadata_json: Some(metadata_json.to_string()),
        }
    }

    #[test]
    fn collect_rehydrated_teams_ignores_orphan_members_and_sorts_members() {
        let global_config = GlobalConfig::default();
        let sessions = vec![
            session("leader-1", "running", "/tmp/project", "claude-code"),
            session("member-2", "waiting", "/tmp/project", "echo 2"),
            session("member-1", "running", "/tmp/project", "echo 1"),
            session("orphan", "running", "/tmp/project", "echo orphan"),
        ];
        let panes = vec![
            pane(
                "leader-pane",
                "leader-1",
                r#"{"agent_team":{"team_id":"team-1","leader_session_id":"leader-1","provider":"claude-code","role":"leader","member_index":0}}"#,
                "Leader",
            ),
            pane(
                "member-pane-2",
                "member-2",
                r#"{"agent_team":{"team_id":"team-1","leader_session_id":"leader-1","provider":"claude-code","role":"member","member_index":2}}"#,
                "Claude teammate 2",
            ),
            pane(
                "member-pane-1",
                "member-1",
                r#"{"agent_team":{"team_id":"team-1","leader_session_id":"leader-1","provider":"claude-code","role":"member","member_index":1}}"#,
                "Claude teammate 1",
            ),
            pane(
                "orphan-pane",
                "orphan",
                r#"{"agent_team":{"team_id":"team-orphan","leader_session_id":"missing","provider":"claude-code","role":"member","member_index":1}}"#,
                "Orphan",
            ),
        ];

        let teams = collect_rehydrated_teams(
            sessions,
            panes,
            Path::new("/tmp/project"),
            &project_config(),
            &global_config,
        )
        .expect("rehydrated teams");

        assert_eq!(teams.len(), 1);
        let team = &teams[0];
        assert_eq!(team.config.team_id, "team-1");
        assert_eq!(team.members.len(), 2);
        assert_eq!(team.members[0].member_index, 1);
        assert_eq!(team.members[1].member_index, 2);
        assert!(team
            .config
            .base_env
            .iter()
            .any(|(key, _)| key == "CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS"));
    }

    #[test]
    fn store_rehydrate_restores_next_member_index() {
        let mut store = AgentTeamStore::default();
        let snapshot = store.rehydrate(
            AgentTeamConfigInput {
                team_id: "team-1".to_string(),
                provider: "codex-v2".to_string(),
                leader_session_id: "leader".to_string(),
                leader_pane_id: "leader-pane".to_string(),
                working_dir: "/tmp/project".to_string(),
                control_socket_path: "/tmp/control.sock".to_string(),
                base_env: Vec::new(),
                remote_target: None,
            },
            true,
            vec![
                AgentTeamMemberView {
                    team_id: "team-1".to_string(),
                    provider: "codex-v2".to_string(),
                    session_id: "member-2".to_string(),
                    pane_id: "pane-2".to_string(),
                    pane_token: "%2".to_string(),
                    member_index: 2,
                    title: "Codex teammate 2".to_string(),
                    command: "codex".to_string(),
                },
                AgentTeamMemberView {
                    team_id: "team-1".to_string(),
                    provider: "codex-v2".to_string(),
                    session_id: "member-5".to_string(),
                    pane_id: "pane-5".to_string(),
                    pane_token: "%5".to_string(),
                    member_index: 5,
                    title: "Codex teammate 5".to_string(),
                    command: "codex".to_string(),
                },
            ],
        );

        assert_eq!(snapshot.members.len(), 2);
        let spawned = store
            .register_member(
                "team-1",
                "member-6".to_string(),
                "pane-6".to_string(),
                "codex".to_string(),
                "Codex teammate 6".to_string(),
            )
            .expect("register member");
        assert_eq!(spawned.member.member_index, 6);
        assert_eq!(spawned.member.pane_token, "%6");
    }

    #[test]
    fn collect_rehydrated_teams_preserves_remote_target_metadata() {
        let global_config = GlobalConfig::default();
        let sessions = vec![SessionRow {
            connection_id: Some("ssh-profile-1".to_string()),
            backend: "remote_ssh_durable".to_string(),
            ..session("leader-1", "running", "~/project", "claude-code")
        }];
        let panes = vec![pane(
            "leader-pane",
            "leader-1",
            r#"{"remote_target":{"ssh_profile_id":"ssh-profile-1","ssh_profile_name":"Remote Host","host":"remote.example.com","port":22,"user":"pnevma","identity_file":"~/.ssh/id_ed25519","proxy_jump":"jump.example.com","remote_path":"~/project"},"agent_team":{"team_id":"team-remote","leader_session_id":"leader-1","provider":"claude-code","role":"leader","member_index":0}}"#,
            "Leader",
        )];

        let teams = collect_rehydrated_teams(
            sessions,
            panes,
            Path::new("/tmp/project"),
            &project_config(),
            &global_config,
        )
        .expect("rehydrated teams");

        assert_eq!(teams.len(), 1);
        let remote = teams[0]
            .config
            .remote_target
            .as_ref()
            .expect("remote target");
        assert_eq!(remote.host, "remote.example.com");
        assert_eq!(remote.remote_path, "~/project");
        assert!(teams[0]
            .config
            .base_env
            .iter()
            .any(|(key, _)| key == "CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS"));
    }
}
