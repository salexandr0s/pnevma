use crate::agent_teams::{self, AgentTeamCloseInput, AgentTeamSpawnInput, AgentTeamStore};
use crate::event_emitter::EventEmitter;
use pnevma_agents::DynamicToolDef;
use pnevma_db::Db;
use pnevma_session::{SessionEvent, SessionStatus, SessionSupervisor};
use serde_json::{json, Value};
use std::path::Path;
use std::sync::Arc;
use std::time::Duration;
use tokio::sync::RwLock;
use tracing::debug;
use uuid::Uuid;

const DEFAULT_MEMBER_WAIT_TIMEOUT_SECS: u64 = 20 * 60;

pub fn team_tool_defs() -> Vec<DynamicToolDef> {
    vec![
        DynamicToolDef {
            name: "team.spawn_member".to_string(),
            description: "Spawn a teammate terminal session in the current Pnevma agent team. By default this waits for the teammate to finish and returns its transcript tail.".to_string(),
            parameters_schema: json!({
                "type": "object",
                "properties": {
                    "prompt": { "type": "string", "description": "Instructions for the teammate." },
                    "title": { "type": "string", "description": "Optional teammate pane title." },
                    "provider": { "type": "string", "description": "Optional provider override. Currently only Codex exec teammates are supported here." },
                    "model": { "type": "string", "description": "Optional model override for the spawned Codex exec command." },
                    "wait_for_completion": { "type": "boolean", "description": "When true (default), wait for the teammate to exit and return its transcript tail." },
                    "timeout_seconds": { "type": "integer", "minimum": 1, "description": "Optional wait timeout when wait_for_completion is true." }
                },
                "required": ["prompt"]
            }),
        },
        DynamicToolDef {
            name: "team.list_members".to_string(),
            description: "List the current leader and teammate panes for this Pnevma agent team.".to_string(),
            parameters_schema: json!({
                "type": "object",
                "properties": {}
            }),
        },
        DynamicToolDef {
            name: "team.close_member".to_string(),
            description: "Close a teammate session by session_id.".to_string(),
            parameters_schema: json!({
                "type": "object",
                "properties": {
                    "session_id": { "type": "string", "description": "Session identifier for the teammate to close." }
                },
                "required": ["session_id"]
            }),
        },
    ]
}

#[allow(clippy::too_many_arguments)]
pub async fn handle_team_tool_call(
    call_id: &str,
    tool_name: &str,
    params: &Value,
    team_id: &str,
    current_provider: &str,
    project_id: Uuid,
    project_path: &Path,
    db: &Db,
    sessions: &SessionSupervisor,
    redaction_secrets: &Arc<RwLock<Vec<String>>>,
    agent_teams: &Arc<RwLock<AgentTeamStore>>,
    emitter: &Arc<dyn EventEmitter>,
) -> Value {
    debug!(
        call_id = %call_id,
        tool_name = %tool_name,
        team_id = %team_id,
        "handling team tool call"
    );

    match tool_name {
        "team.spawn_member" => {
            let prompt = match params.get("prompt").and_then(Value::as_str) {
                Some(prompt) if !prompt.trim().is_empty() => prompt.trim(),
                _ => {
                    return json!({
                        "success": false,
                        "error": "missing required parameter: prompt"
                    });
                }
            };
            let provider = params
                .get("provider")
                .and_then(Value::as_str)
                .unwrap_or(current_provider);
            let title = params
                .get("title")
                .and_then(Value::as_str)
                .map(ToOwned::to_owned);
            let wait_for_completion = params
                .get("wait_for_completion")
                .and_then(Value::as_bool)
                .unwrap_or(true);
            let timeout = params
                .get("timeout_seconds")
                .and_then(Value::as_u64)
                .unwrap_or(DEFAULT_MEMBER_WAIT_TIMEOUT_SECS);

            let command = match build_member_command(provider, prompt, params.get("model")) {
                Ok(command) => command,
                Err(error) => return json!({"success": false, "error": error}),
            };

            let spawned = match agent_teams::spawn_member_with_runtime(
                AgentTeamSpawnInput {
                    team_id: team_id.to_string(),
                    command,
                    title,
                },
                db,
                project_id,
                sessions,
                redaction_secrets,
                agent_teams,
                emitter,
            )
            .await
            {
                Ok(result) => result,
                Err(error) => return json!({"success": false, "error": error}),
            };

            if !wait_for_completion {
                return json!({
                    "success": true,
                    "team_id": team_id,
                    "member": spawned.member,
                    "waiting": false,
                });
            }

            match wait_for_member_exit(
                sessions,
                &spawned.member.session_id,
                Duration::from_secs(timeout),
            )
            .await
            {
                Ok(exit_code) => {
                    let completion = match agent_teams::collect_member_result_with_runtime(
                        team_id,
                        &spawned.member.session_id,
                        sessions,
                        project_path,
                        redaction_secrets,
                        agent_teams,
                    )
                    .await
                    {
                        Ok(result) => result,
                        Err(error) => json!({"success": false, "error": error}),
                    };
                    json!({
                        "success": true,
                        "team_id": team_id,
                        "member": spawned.member,
                        "waiting": true,
                        "exit_code": exit_code,
                        "completion": completion,
                    })
                }
                Err(error) => json!({
                    "success": false,
                    "team_id": team_id,
                    "member": spawned.member,
                    "error": error,
                }),
            }
        }
        "team.list_members" => {
            match agent_teams::snapshot_team_from_store(team_id, agent_teams).await {
                Ok(snapshot) => json!({"success": true, "team": snapshot}),
                Err(error) => json!({"success": false, "error": error}),
            }
        }
        "team.close_member" => {
            let session_id = match params.get("session_id").and_then(Value::as_str) {
                Some(session_id) if !session_id.trim().is_empty() => session_id.trim(),
                _ => {
                    return json!({
                        "success": false,
                        "error": "missing required parameter: session_id"
                    });
                }
            };
            match agent_teams::close_member_with_runtime(
                AgentTeamCloseInput {
                    team_id: team_id.to_string(),
                    session_id: session_id.to_string(),
                },
                db,
                project_id,
                sessions,
                agent_teams,
                emitter,
            )
            .await
            {
                Ok(result) => json!({"success": true, "member": result.member}),
                Err(error) => json!({"success": false, "error": error}),
            }
        }
        _ => json!({
            "success": false,
            "error": format!("unknown team tool: {tool_name}")
        }),
    }
}

fn build_member_command(
    provider: &str,
    prompt: &str,
    model: Option<&Value>,
) -> Result<String, String> {
    let model_flag = model
        .and_then(Value::as_str)
        .filter(|value| !value.trim().is_empty())
        .map(|value| format!(" -m {}", pnevma_ssh::shell_escape_arg(value.trim())))
        .unwrap_or_default();

    match provider {
        "codex" | "codex-v2" => Ok(format!(
            "codex exec --json --skip-git-repo-check --sandbox workspace-write -a never{model_flag} {}",
            pnevma_ssh::shell_escape_arg(prompt)
        )),
        other => Err(format!(
            "provider '{other}' is not supported for team.spawn_member dynamic tools; use codex/codex-v2"
        )),
    }
}

async fn wait_for_member_exit(
    sessions: &SessionSupervisor,
    session_id: &str,
    timeout: Duration,
) -> Result<Option<i32>, String> {
    let target = Uuid::parse_str(session_id).map_err(|e| e.to_string())?;
    if let Some(meta) = sessions.get(target).await {
        if matches!(meta.status, SessionStatus::Complete | SessionStatus::Error) {
            return Ok(meta.exit_code);
        }
    }
    let mut rx = sessions.subscribe();

    tokio::time::timeout(timeout, async move {
        loop {
            match rx.recv().await {
                Ok(SessionEvent::Exited { session_id, code }) if session_id == target => {
                    return Ok(code);
                }
                Ok(_) => continue,
                Err(tokio::sync::broadcast::error::RecvError::Lagged(_)) => continue,
                Err(tokio::sync::broadcast::error::RecvError::Closed) => {
                    return Err(
                        "session event stream closed while waiting for teammate".to_string()
                    );
                }
            }
        }
    })
    .await
    .map_err(|_| format!("timed out waiting for teammate session {session_id} to exit"))?
}
