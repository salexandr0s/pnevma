use crate::error::AgentError;
use crate::model::{
    AgentAdapter, AgentConfig, AgentEvent, AgentHandle, AgentStatus, CostRecord, TaskPayload,
};
use async_trait::async_trait;
use chrono::Utc;
use std::collections::HashMap;
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::Arc;
use tokio::io::{AsyncBufReadExt, AsyncWriteExt, BufReader};
use tokio::process::{Child, Command};
use tokio::sync::{broadcast, oneshot, RwLock};
use uuid::Uuid;

// ── JSON-RPC types ──────────────────────────────────────

#[derive(Debug, serde::Serialize)]
struct JsonRpcRequest {
    jsonrpc: &'static str,
    id: u64,
    method: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    params: Option<serde_json::Value>,
}

const RPC_INITIALIZE: &str = "initialize";
const RPC_INITIALIZED: &str = "initialized";
const RPC_THREAD_START: &str = "thread/start";
const RPC_TURN_START: &str = "turn/start";
const RPC_TURN_INTERRUPT: &str = "turn/interrupt";
const RPC_THREAD_ARCHIVE: &str = "thread/archive";

fn build_rpc_request(id: u64, method: &str, params: Option<serde_json::Value>) -> JsonRpcRequest {
    JsonRpcRequest {
        jsonrpc: "2.0",
        id,
        method: method.to_string(),
        params,
    }
}

fn build_initialize_params() -> serde_json::Value {
    serde_json::json!({
        "clientInfo": { "name": "pnevma", "version": env!("CARGO_PKG_VERSION") },
        "capabilities": {}
    })
}

fn build_thread_start_params(config: &AgentConfig) -> serde_json::Value {
    let sandbox = if config.auto_approve {
        tracing::warn!(
            agent_id = %config.working_dir,
            "Codex v2 auto_approve enabled — using danger-full-access sandbox (unrestricted system access)"
        );
        "danger-full-access"
    } else {
        "workspace-write"
    };

    serde_json::json!({
        "cwd": config.working_dir,
        "approvalPolicy": "never",
        "sandbox": sandbox,
        "experimentalRawEvents": false,
        "persistExtendedHistory": false,
    })
}

fn build_turn_start_params(thread_id: &str, prompt: String) -> serde_json::Value {
    serde_json::json!({
        "threadId": thread_id,
        "input": [
            {
                "type": "text",
                "text": prompt,
                "text_elements": [],
            }
        ],
    })
}

fn build_thread_archive_params(thread_id: &str) -> serde_json::Value {
    serde_json::json!({ "threadId": thread_id })
}

fn build_turn_interrupt_params(thread_id: &str, turn_id: &str) -> serde_json::Value {
    serde_json::json!({
        "threadId": thread_id,
        "turnId": turn_id,
    })
}

fn extract_thread_id(result: &serde_json::Value) -> Option<String> {
    result
        .get("thread")
        .and_then(|thread| thread.get("id"))
        .and_then(|id| id.as_str())
        .map(|id| id.to_string())
        .or_else(|| {
            result
                .get("thread_id")
                .and_then(|id| id.as_str())
                .map(|id| id.to_string())
        })
}

fn extract_turn_id(result: &serde_json::Value) -> Option<String> {
    result
        .get("turn")
        .and_then(|turn| turn.get("id"))
        .and_then(|id| id.as_str())
        .map(|id| id.to_string())
        .or_else(|| {
            result
                .get("turn_id")
                .and_then(|id| id.as_str())
                .map(|id| id.to_string())
        })
}

fn turn_status_string(turn: &serde_json::Value) -> Option<String> {
    match turn.get("status")? {
        serde_json::Value::String(status) => Some(status.clone()),
        serde_json::Value::Object(status) => status
            .get("type")
            .and_then(|value| value.as_str())
            .map(|value| value.to_string()),
        _ => None,
    }
}

fn serialize_rpc_notification_line(
    method: &str,
    params: Option<serde_json::Value>,
) -> Result<Vec<u8>, AgentError> {
    let request = serde_json::json!({
        "jsonrpc": "2.0",
        "method": method,
        "params": params.unwrap_or(serde_json::Value::Null),
    });
    let mut line =
        serde_json::to_string(&request).map_err(|e| AgentError::Protocol(e.to_string()))?;
    line.push('\n');
    Ok(line.into_bytes())
}

#[derive(Debug, serde::Deserialize)]
struct JsonRpcResponse {
    id: Option<u64>,
    result: Option<serde_json::Value>,
    error: Option<JsonRpcError>,
}

#[derive(Debug, serde::Deserialize)]
struct JsonRpcError {
    code: i64,
    message: String,
    #[allow(dead_code)]
    data: Option<serde_json::Value>,
}

#[derive(Debug, serde::Deserialize)]
struct JsonRpcNotification {
    method: String,
    params: Option<serde_json::Value>,
}

// ── Connection state ────────────────────────────────────

struct AppServerConnection {
    child: Child,
    stdin_tx: tokio::sync::mpsc::Sender<Vec<u8>>,
    next_id: AtomicU64,
    pending: Arc<dashmap::DashMap<u64, oneshot::Sender<JsonRpcResponse>>>,
    thread_id: RwLock<Option<String>>,
    turn_id: RwLock<Option<String>>,
    stdout_task: tokio::task::JoinHandle<()>,
    stdin_task: tokio::task::JoinHandle<()>,
}

// ── Adapter ─────────────────────────────────────────────

#[derive(Default)]
pub struct CodexV2Adapter {
    channels: Arc<RwLock<HashMap<Uuid, broadcast::Sender<AgentEvent>>>>,
    configs: Arc<RwLock<HashMap<Uuid, AgentConfig>>>,
    connections: Arc<RwLock<HashMap<Uuid, AppServerConnection>>>,
    costs: Arc<RwLock<HashMap<Uuid, CostRecord>>>,
}

impl CodexV2Adapter {
    pub fn new() -> Self {
        Self::default()
    }

    async fn start_server(
        config: &AgentConfig,
    ) -> Result<
        (
            Child,
            tokio::process::ChildStdin,
            tokio::process::ChildStdout,
        ),
        AgentError,
    > {
        // SAFETY: setpgid(0,0) creates a new process group so we can signal the
        // entire tree on interrupt/stop.
        let mut child = unsafe {
            Command::new("codex")
                .args(["app-server", "--listen", "stdio://"])
                .current_dir(&config.working_dir)
                .env_clear()
                .envs(crate::env::build_agent_environment(&config.env))
                .stdin(std::process::Stdio::piped())
                .stdout(std::process::Stdio::piped())
                .stderr(std::process::Stdio::null())
                .pre_exec(|| {
                    if libc::setpgid(0, 0) != 0 {
                        return Err(std::io::Error::last_os_error());
                    }
                    Ok(())
                })
                .spawn()
                .map_err(|e| AgentError::Spawn(e.to_string()))?
        };

        let stdin = child
            .stdin
            .take()
            .ok_or_else(|| AgentError::Spawn("missing stdin".to_string()))?;
        let stdout = child
            .stdout
            .take()
            .ok_or_else(|| AgentError::Spawn("missing stdout".to_string()))?;

        Ok((child, stdin, stdout))
    }

    async fn rpc_call(
        stdin_tx: &tokio::sync::mpsc::Sender<Vec<u8>>,
        next_id: &AtomicU64,
        pending: &Arc<dashmap::DashMap<u64, oneshot::Sender<JsonRpcResponse>>>,
        method: &str,
        params: Option<serde_json::Value>,
    ) -> Result<serde_json::Value, AgentError> {
        let id = next_id.fetch_add(1, Ordering::Relaxed);
        let request = build_rpc_request(id, method, params);
        let mut line =
            serde_json::to_string(&request).map_err(|e| AgentError::Protocol(e.to_string()))?;
        line.push('\n');

        let (tx, rx) = oneshot::channel();
        pending.insert(id, tx);

        stdin_tx
            .send(line.into_bytes())
            .await
            .map_err(|_| AgentError::Protocol("stdin channel closed".into()))?;

        let response = tokio::time::timeout(std::time::Duration::from_secs(30), rx)
            .await
            .map_err(|_| AgentError::Protocol("RPC timeout".into()))?
            .map_err(|_| AgentError::Protocol("response channel dropped".into()))?;

        if let Some(err) = response.error {
            return Err(AgentError::Protocol(format!(
                "{}: {}",
                err.code, err.message
            )));
        }

        Ok(response.result.unwrap_or(serde_json::Value::Null))
    }

    async fn rpc_notify(
        stdin_tx: &tokio::sync::mpsc::Sender<Vec<u8>>,
        method: &str,
        params: Option<serde_json::Value>,
    ) -> Result<(), AgentError> {
        stdin_tx
            .send(serialize_rpc_notification_line(method, params)?)
            .await
            .map_err(|_| AgentError::Protocol("stdin channel closed".into()))
    }
}

#[async_trait]
impl AgentAdapter for CodexV2Adapter {
    async fn spawn(&self, config: AgentConfig) -> Result<AgentHandle, AgentError> {
        let id = Uuid::new_v4();
        let (event_tx, _) = broadcast::channel(2048);

        self.channels.write().await.insert(id, event_tx.clone());
        self.configs.write().await.insert(id, config.clone());

        let (child, stdin, stdout) = Self::start_server(&config).await?;

        let pending: Arc<dashmap::DashMap<u64, oneshot::Sender<JsonRpcResponse>>> =
            Arc::new(dashmap::DashMap::new());

        // Spawn stdin writer task
        let (stdin_tx, mut stdin_rx) = tokio::sync::mpsc::channel::<Vec<u8>>(256);
        let stdin_task = tokio::spawn(async move {
            let mut stdin = stdin;
            while let Some(data) = stdin_rx.recv().await {
                if stdin.write_all(&data).await.is_err() {
                    break;
                }
                if stdin.flush().await.is_err() {
                    break;
                }
            }
        });

        // Spawn stdout reader task — dispatches responses and notifications
        let pending_clone = Arc::clone(&pending);
        let event_tx_clone = event_tx.clone();
        let costs_clone = Arc::clone(&self.costs);
        let handle_id = id;
        let stdout_task = tokio::spawn(async move {
            let mut lines = BufReader::new(stdout).lines();
            while let Ok(Some(line)) = lines.next_line().await {
                // Try response first (has both "id" and ("result" or "error"))
                if let Ok(resp) = serde_json::from_str::<JsonRpcResponse>(&line) {
                    if let Some(resp_id) = resp.id {
                        if let Some((_, tx)) = pending_clone.remove(&resp_id) {
                            let _ = tx.send(resp);
                            continue;
                        }
                    }
                }
                // Treat as notification
                if let Ok(notif) = serde_json::from_str::<JsonRpcNotification>(&line) {
                    if let Some(event) = map_notification(&notif) {
                        // Write cost record on UsageUpdate so parse_usage returns real data.
                        if let AgentEvent::UsageUpdate {
                            tokens_in,
                            tokens_out,
                            cost_usd,
                        } = &event
                        {
                            costs_clone.write().await.insert(
                                handle_id,
                                CostRecord {
                                    provider: "codex-v2".to_string(),
                                    model: None,
                                    tokens_in: *tokens_in,
                                    tokens_out: *tokens_out,
                                    estimated_cost_usd: *cost_usd,
                                    timestamp: Utc::now(),
                                    task_id: Uuid::nil(),
                                    session_id: handle_id,
                                },
                            );
                        }
                        let _ = event_tx_clone.send(event);
                    }
                }
            }
        });

        let conn = AppServerConnection {
            child,
            stdin_tx: stdin_tx.clone(),
            next_id: AtomicU64::new(1),
            pending: Arc::clone(&pending),
            thread_id: RwLock::new(None),
            turn_id: RwLock::new(None),
            stdout_task,
            stdin_task,
        };

        let initialize_result = Self::rpc_call(
            &stdin_tx,
            &conn.next_id,
            &pending,
            RPC_INITIALIZE,
            Some(build_initialize_params()),
        )
        .await?;
        let _ = initialize_result;
        Self::rpc_notify(&stdin_tx, RPC_INITIALIZED, None).await?;

        let result = Self::rpc_call(
            &stdin_tx,
            &conn.next_id,
            &pending,
            RPC_THREAD_START,
            Some(build_thread_start_params(&config)),
        )
        .await?;
        let thread_id = extract_thread_id(&result).ok_or_else(|| {
            AgentError::Protocol("thread/start response missing thread id".into())
        })?;

        *conn.thread_id.write().await = Some(thread_id.clone());

        let _ = event_tx.send(AgentEvent::ThreadStarted {
            thread_id: thread_id.clone(),
        });

        self.connections.write().await.insert(id, conn);

        let _ = event_tx.send(AgentEvent::StatusChange(AgentStatus::Running));

        Ok(AgentHandle {
            id,
            provider: "codex-v2".to_string(),
            task_id: Uuid::nil(),
            thread_id: Some(thread_id),
            turn_id: None,
        })
    }

    async fn send(&self, handle: &AgentHandle, input: TaskPayload) -> Result<(), AgentError> {
        let conns = self.connections.read().await;
        let conn = conns
            .get(&handle.id)
            .ok_or_else(|| AgentError::Unavailable("no connection for agent".into()))?;

        let thread_id = conn
            .thread_id
            .read()
            .await
            .clone()
            .ok_or_else(|| AgentError::Protocol("no thread_id".into()))?;

        let sanitize = crate::adapters::claude::sanitize_prompt_field;
        let prompt = format!(
            "{}\n\nConstraints:\n{}\n\nChecks:\n{}\n\nRules:\n{}",
            sanitize(&input.objective),
            input
                .constraints
                .iter()
                .map(|c| format!("- {}", sanitize(c)))
                .collect::<Vec<_>>()
                .join("\n"),
            input
                .acceptance_checks
                .iter()
                .map(|c| format!("- {}", sanitize(c)))
                .collect::<Vec<_>>()
                .join("\n"),
            input
                .project_rules
                .iter()
                .map(|r| format!("- {}", sanitize(r)))
                .collect::<Vec<_>>()
                .join("\n"),
        );

        let result = Self::rpc_call(
            &conn.stdin_tx,
            &conn.next_id,
            &conn.pending,
            RPC_TURN_START,
            Some(build_turn_start_params(&thread_id, prompt)),
        )
        .await?;

        let turn_id = extract_turn_id(&result)
            .ok_or_else(|| AgentError::Protocol("turn/start response missing turn id".into()))?;

        *conn.turn_id.write().await = Some(turn_id.clone());

        if let Some(tx) = self.channels.read().await.get(&handle.id) {
            let _ = tx.send(AgentEvent::TurnStarted {
                turn_id,
                thread_id: thread_id.clone(),
            });
        }

        Ok(())
    }

    async fn interrupt(&self, handle: &AgentHandle) -> Result<(), AgentError> {
        let conns = self.connections.read().await;
        let conn = conns
            .get(&handle.id)
            .ok_or_else(|| AgentError::Unavailable("no connection".into()))?;

        let thread_id = conn
            .thread_id
            .read()
            .await
            .clone()
            .ok_or_else(|| AgentError::Protocol("no thread_id".into()))?;
        let turn_id = conn
            .turn_id
            .read()
            .await
            .clone()
            .ok_or_else(|| AgentError::Protocol("no turn_id".into()))?;

        Self::rpc_call(
            &conn.stdin_tx,
            &conn.next_id,
            &conn.pending,
            RPC_TURN_INTERRUPT,
            Some(build_turn_interrupt_params(&thread_id, &turn_id)),
        )
        .await?;

        if let Some(tx) = self.channels.read().await.get(&handle.id) {
            let _ = tx.send(AgentEvent::StatusChange(AgentStatus::Paused));
        }

        Ok(())
    }

    async fn stop(&self, handle: &AgentHandle) -> Result<(), AgentError> {
        let mut conns = self.connections.write().await;
        if let Some(conn) = conns.remove(&handle.id) {
            // Try graceful thread/archive
            if let Some(tid) = conn.thread_id.read().await.clone() {
                let _ = Self::rpc_call(
                    &conn.stdin_tx,
                    &conn.next_id,
                    &conn.pending,
                    RPC_THREAD_ARCHIVE,
                    Some(build_thread_archive_params(&tid)),
                )
                .await;
            }

            conn.stdout_task.abort();
            conn.stdin_task.abort();

            // SAFETY: PID max (4,194,304) is well below i32::MAX; negation targets process group.
            let mut child = conn.child;
            if let Some(pid) = child.id() {
                unsafe { libc::kill(-(pid as i32), libc::SIGTERM) };
                tokio::spawn(async move {
                    tokio::time::sleep(std::time::Duration::from_secs(5)).await;
                    // Only send SIGKILL if the process is still running.
                    // Avoids killing a reused PID after the original has exited.
                    match child.try_wait() {
                        Ok(None) => {
                            // Still running — force kill.
                            unsafe { libc::kill(-(pid as i32), libc::SIGKILL) };
                        }
                        _ => {
                            // Already exited or error checking — skip SIGKILL.
                        }
                    }
                });
            }
        }

        if let Some(tx) = self.channels.read().await.get(&handle.id) {
            let _ = tx.send(AgentEvent::StatusChange(AgentStatus::Completed));
        }

        // Clean up state maps now that the connection is torn down.
        self.channels.write().await.remove(&handle.id);
        self.configs.write().await.remove(&handle.id);
        self.costs.write().await.remove(&handle.id);

        Ok(())
    }

    fn events(&self, handle: &AgentHandle) -> broadcast::Receiver<AgentEvent> {
        if let Ok(guard) = self.channels.try_read() {
            if let Some(tx) = guard.get(&handle.id) {
                return tx.subscribe();
            }
        }
        let (tx, rx) = broadcast::channel(4);
        let _ = tx.send(AgentEvent::Error("missing handle".to_string()));
        rx
    }

    async fn parse_usage(&self, handle: &AgentHandle) -> Result<CostRecord, AgentError> {
        let costs = self.costs.read().await;
        Ok(costs.get(&handle.id).cloned().unwrap_or(CostRecord {
            provider: "codex-v2".to_string(),
            model: None,
            tokens_in: 0,
            tokens_out: 0,
            estimated_cost_usd: 0.0,
            timestamp: Utc::now(),
            task_id: Uuid::nil(),
            session_id: handle.id,
        }))
    }

    async fn send_tool_result(
        &self,
        handle: &AgentHandle,
        call_id: &str,
        result: serde_json::Value,
    ) -> Result<(), AgentError> {
        let conns = self.connections.read().await;
        let conn = conns
            .get(&handle.id)
            .ok_or_else(|| AgentError::Unavailable("no connection".into()))?;

        let params = serde_json::json!({
            "call_id": call_id,
            "result": result,
        });

        Self::rpc_call(
            &conn.stdin_tx,
            &conn.next_id,
            &conn.pending,
            "tool.result",
            Some(params),
        )
        .await?;
        Ok(())
    }
}

/// Map a JSON-RPC notification to an AgentEvent.
fn map_notification(notif: &JsonRpcNotification) -> Option<AgentEvent> {
    let params = notif.params.as_ref()?;
    match notif.method.as_str() {
        "thread/started" => Some(AgentEvent::ThreadStarted {
            thread_id: params.get("thread")?.get("id")?.as_str()?.to_string(),
        }),
        "turn/started" => Some(AgentEvent::TurnStarted {
            turn_id: params.get("turn")?.get("id")?.as_str()?.to_string(),
            thread_id: params.get("threadId")?.as_str()?.to_string(),
        }),
        "turn/completed" => {
            let turn = params.get("turn")?;
            let turn_id = turn.get("id")?.as_str()?.to_string();
            let thread_id = params.get("threadId")?.as_str()?.to_string();
            let finish_reason = turn_status_string(turn).unwrap_or_else(|| "completed".to_string());
            if finish_reason == "failed" {
                let error = turn
                    .get("error")
                    .and_then(|value| value.as_str())
                    .or_else(|| {
                        turn.get("error")
                            .and_then(|value| value.get("message"))
                            .and_then(|value| value.as_str())
                    })
                    .unwrap_or("codex turn failed")
                    .to_string();
                return Some(AgentEvent::Error(error));
            }
            Some(AgentEvent::TurnCompleted {
                turn_id,
                thread_id,
                finish_reason,
            })
        }
        "item/agentMessage/delta" => Some(AgentEvent::OutputChunk(
            params.get("delta")?.as_str()?.to_string(),
        )),
        "thread/tokenUsage/updated" => Some(AgentEvent::UsageUpdate {
            tokens_in: params
                .get("tokenUsage")?
                .get("total")?
                .get("inputTokens")
                .and_then(|value| value.as_u64())
                .unwrap_or(0),
            tokens_out: params
                .get("tokenUsage")?
                .get("total")?
                .get("outputTokens")
                .and_then(|value| value.as_u64())
                .unwrap_or(0),
            cost_usd: 0.0,
        }),
        "codex/event/agent_message_delta" | "codex/event/agent_message_content_delta" => Some(
            AgentEvent::OutputChunk(params.get("msg")?.get("delta")?.as_str()?.to_string()),
        ),
        "codex/event/token_count" => Some(AgentEvent::UsageUpdate {
            tokens_in: params
                .get("msg")?
                .get("info")?
                .get("total_token_usage")?
                .get("input_tokens")
                .and_then(|value| value.as_u64())
                .unwrap_or(0),
            tokens_out: params
                .get("msg")?
                .get("info")?
                .get("total_token_usage")?
                .get("output_tokens")
                .and_then(|value| value.as_u64())
                .unwrap_or(0),
            cost_usd: 0.0,
        }),
        "codex/event/task_complete" => Some(AgentEvent::Complete {
            summary: params
                .get("msg")
                .and_then(|msg| msg.get("last_agent_message"))
                .and_then(|value| value.as_str())
                .unwrap_or("Codex v2 run completed")
                .to_string(),
        }),
        "turn.completed" => Some(AgentEvent::TurnCompleted {
            turn_id: params.get("turn_id")?.as_str()?.to_string(),
            thread_id: params.get("thread_id")?.as_str()?.to_string(),
            finish_reason: params
                .get("finish_reason")
                .and_then(|v| v.as_str())
                .unwrap_or("stop")
                .to_string(),
        }),
        "output.chunk" => {
            let text = params.get("text")?.as_str()?.to_string();
            Some(AgentEvent::OutputChunk(text))
        }
        "tool.use" => Some(AgentEvent::ToolUse {
            name: params.get("name")?.as_str()?.to_string(),
            input: params
                .get("input")
                .map(|v| v.to_string())
                .unwrap_or_default(),
            output: params
                .get("output")
                .map(|v| v.to_string())
                .unwrap_or_default(),
        }),
        "usage.update" => Some(AgentEvent::UsageUpdate {
            tokens_in: params
                .get("tokens_in")
                .and_then(|v| v.as_u64())
                .unwrap_or(0),
            tokens_out: params
                .get("tokens_out")
                .and_then(|v| v.as_u64())
                .unwrap_or(0),
            cost_usd: params
                .get("cost_usd")
                .and_then(|v| v.as_f64())
                .unwrap_or(0.0),
        }),
        "error" => Some(AgentEvent::Error(
            params
                .get("message")
                .and_then(|value| value.as_str())
                .or_else(|| params.get("error").and_then(|value| value.as_str()))
                .unwrap_or("codex app-server error")
                .to_string(),
        )),
        "complete" | "thread.completed" => {
            let summary = params
                .get("summary")
                .and_then(|v| v.as_str())
                .unwrap_or("Codex v2 run completed")
                .to_string();
            Some(AgentEvent::Complete { summary })
        }
        "heartbeat" | "semantic.heartbeat" => {
            let thread_id = params.get("thread_id")?.as_str()?.to_string();
            Some(AgentEvent::SemanticHeartbeat {
                thread_id,
                timestamp: Utc::now(),
            })
        }
        "tool.call" | "dynamic_tool.call" => Some(AgentEvent::DynamicToolCall {
            call_id: params.get("call_id")?.as_str()?.to_string(),
            tool_name: params.get("tool_name")?.as_str()?.to_string(),
            params: params
                .get("params")
                .cloned()
                .unwrap_or(serde_json::Value::Null),
        }),
        "rate_limit" => Some(AgentEvent::RateLimitUpdated {
            remaining: params
                .get("remaining")
                .and_then(|v| v.as_u64())
                .unwrap_or(0) as u32,
            reset_at: params
                .get("reset_at")
                .and_then(|v| v.as_str())
                .and_then(|s| s.parse().ok()),
        }),
        _ => None,
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::DynamicToolDef;

    fn make_config() -> AgentConfig {
        AgentConfig {
            provider: "codex-v2".to_string(),
            model: None,
            env: vec![],
            working_dir: "/tmp".to_string(),
            timeout_minutes: 30,
            auto_approve: false,
            allow_npx: false,
            output_format: "stream-json".to_string(),
            context_file: None,
            thread_id: None,
            dynamic_tools: vec![],
        }
    }

    fn make_handle() -> AgentHandle {
        AgentHandle {
            id: Uuid::new_v4(),
            provider: "codex-v2".to_string(),
            task_id: Uuid::new_v4(),
            thread_id: None,
            turn_id: None,
        }
    }

    #[test]
    fn new_creates_empty_adapter() {
        let adapter = CodexV2Adapter::new();
        assert!(adapter.channels.blocking_read().is_empty());
        assert!(adapter.configs.blocking_read().is_empty());
        assert!(adapter.costs.blocking_read().is_empty());
    }

    #[test]
    fn default_creates_empty_adapter() {
        let adapter = CodexV2Adapter::default();
        assert!(adapter.channels.blocking_read().is_empty());
    }

    #[test]
    fn config_has_new_fields() {
        let config = make_config();
        assert!(config.thread_id.is_none());
        assert!(config.dynamic_tools.is_empty());
    }

    #[tokio::test]
    async fn parse_usage_returns_zero_when_no_record() {
        let adapter = CodexV2Adapter::new();
        let handle = make_handle();
        let cost = adapter.parse_usage(&handle).await.expect("parse_usage");
        assert_eq!(cost.provider, "codex-v2");
        assert_eq!(cost.tokens_in, 0);
        assert_eq!(cost.tokens_out, 0);
        assert_eq!(cost.estimated_cost_usd, 0.0);
        assert!(cost.model.is_none());
    }

    #[tokio::test]
    async fn events_missing_handle_emits_error() {
        let adapter = CodexV2Adapter::new();
        let handle = make_handle();
        let mut rx = adapter.events(&handle);
        let event = rx.recv().await.unwrap();
        assert!(
            matches!(event, AgentEvent::Error(ref msg) if msg.contains("missing handle")),
            "expected Error event, got {event:?}"
        );
    }

    #[test]
    fn map_notification_output_chunk() {
        let notif = JsonRpcNotification {
            method: "output.chunk".to_string(),
            params: Some(serde_json::json!({"text": "hello world"})),
        };
        let event = map_notification(&notif).expect("event");
        assert!(matches!(event, AgentEvent::OutputChunk(ref t) if t == "hello world"));
    }

    #[test]
    fn map_notification_turn_completed() {
        let notif = JsonRpcNotification {
            method: "turn.completed".to_string(),
            params: Some(serde_json::json!({
                "turn_id": "t1",
                "thread_id": "th1",
                "finish_reason": "stop",
            })),
        };
        let event = map_notification(&notif).expect("event");
        assert!(
            matches!(event, AgentEvent::TurnCompleted { ref turn_id, ref thread_id, ref finish_reason }
                if turn_id == "t1" && thread_id == "th1" && finish_reason == "stop")
        );
    }

    #[test]
    fn map_notification_unknown_returns_none() {
        let notif = JsonRpcNotification {
            method: "unknown.method".to_string(),
            params: Some(serde_json::json!({})),
        };
        assert!(map_notification(&notif).is_none());
    }

    #[test]
    fn map_notification_rate_limit() {
        let notif = JsonRpcNotification {
            method: "rate_limit".to_string(),
            params: Some(serde_json::json!({"remaining": 5})),
        };
        let event = map_notification(&notif).expect("event");
        assert!(matches!(
            event,
            AgentEvent::RateLimitUpdated { remaining: 5, .. }
        ));
    }

    #[test]
    fn map_notification_dynamic_tool_call() {
        let notif = JsonRpcNotification {
            method: "tool.call".to_string(),
            params: Some(serde_json::json!({
                "call_id": "c1",
                "tool_name": "my_tool",
                "params": {"x": 1},
            })),
        };
        let event = map_notification(&notif).expect("event");
        assert!(
            matches!(event, AgentEvent::DynamicToolCall { ref call_id, ref tool_name, .. }
                if call_id == "c1" && tool_name == "my_tool")
        );
    }

    #[test]
    fn rpc_method_names_match_current_codex_protocol() {
        assert_eq!(RPC_INITIALIZE, "initialize");
        assert_eq!(RPC_INITIALIZED, "initialized");
        assert_eq!(RPC_THREAD_START, "thread/start");
        assert_eq!(RPC_TURN_START, "turn/start");
        assert_eq!(RPC_TURN_INTERRUPT, "turn/interrupt");
        assert_eq!(RPC_THREAD_ARCHIVE, "thread/archive");
    }

    #[test]
    fn initialize_handshake_serializes_current_protocol_messages() {
        let request = build_rpc_request(7, RPC_INITIALIZE, Some(build_initialize_params()));
        let request_json = serde_json::to_value(&request).expect("serialize request");
        assert_eq!(request_json["method"], RPC_INITIALIZE);
        assert_eq!(request_json["params"]["clientInfo"]["name"], "pnevma");
        assert_eq!(
            request_json["params"]["clientInfo"]["version"],
            env!("CARGO_PKG_VERSION")
        );
        assert_eq!(
            request_json["params"]["capabilities"],
            serde_json::json!({})
        );

        let notification = serialize_rpc_notification_line(RPC_INITIALIZED, None)
            .expect("serialize initialized notification");
        let notification_json: serde_json::Value =
            serde_json::from_slice(&notification).expect("parse initialized notification");
        assert_eq!(notification_json["method"], RPC_INITIALIZED);
        assert_eq!(notification_json["params"], serde_json::Value::Null);
    }

    #[test]
    fn thread_start_and_archive_payloads_use_current_protocol_shape() {
        let mut config = make_config();
        config.thread_id = Some("thread_existing".to_string());
        config.dynamic_tools = vec![DynamicToolDef {
            name: "review_pack".to_string(),
            description: "Generate a review pack".to_string(),
            parameters_schema: serde_json::json!({
                "type": "object",
                "properties": {
                    "task_id": { "type": "string" }
                }
            }),
        }];

        let thread_start = build_thread_start_params(&config);
        assert_eq!(thread_start["cwd"], "/tmp");
        assert_eq!(thread_start["approvalPolicy"], "never");
        assert_eq!(thread_start["sandbox"], "workspace-write");
        assert_eq!(thread_start["experimentalRawEvents"], false);
        assert_eq!(thread_start["persistExtendedHistory"], false);

        let archive_request = build_rpc_request(
            11,
            RPC_THREAD_ARCHIVE,
            Some(build_thread_archive_params("thread_existing")),
        );
        let archive_json = serde_json::to_value(&archive_request).expect("serialize archive");
        assert_eq!(archive_json["method"], RPC_THREAD_ARCHIVE);
        assert_eq!(archive_json["params"]["threadId"], "thread_existing");
    }

    #[test]
    fn turn_start_payload_uses_current_protocol_shape() {
        let params = build_turn_start_params("thread_123", "hello".to_string());
        assert_eq!(params["threadId"], "thread_123");
        assert_eq!(params["input"][0]["type"], "text");
        assert_eq!(params["input"][0]["text"], "hello");
        assert_eq!(params["input"][0]["text_elements"], serde_json::json!([]));
    }

    #[test]
    fn extract_ids_from_current_protocol_responses() {
        let thread_result = serde_json::json!({
            "thread": { "id": "thread_123" }
        });
        let turn_result = serde_json::json!({
            "turn": { "id": "turn_456" }
        });

        assert_eq!(
            extract_thread_id(&thread_result).as_deref(),
            Some("thread_123")
        );
        assert_eq!(extract_turn_id(&turn_result).as_deref(), Some("turn_456"));
    }

    #[test]
    fn map_current_protocol_notifications() {
        let delta = JsonRpcNotification {
            method: "item/agentMessage/delta".to_string(),
            params: Some(serde_json::json!({
                "threadId": "th_1",
                "turnId": "tu_1",
                "itemId": "msg_1",
                "delta": "OK",
            })),
        };
        assert!(matches!(
            map_notification(&delta),
            Some(AgentEvent::OutputChunk(ref chunk)) if chunk == "OK"
        ));

        let usage = JsonRpcNotification {
            method: "thread/tokenUsage/updated".to_string(),
            params: Some(serde_json::json!({
                "threadId": "th_1",
                "turnId": "tu_1",
                "tokenUsage": {
                    "total": {
                        "inputTokens": 10,
                        "outputTokens": 2,
                        "cachedInputTokens": 0,
                        "reasoningOutputTokens": 0,
                        "totalTokens": 12
                    }
                }
            })),
        };
        assert!(matches!(
            map_notification(&usage),
            Some(AgentEvent::UsageUpdate {
                tokens_in: 10,
                tokens_out: 2,
                ..
            })
        ));

        let complete = JsonRpcNotification {
            method: "codex/event/task_complete".to_string(),
            params: Some(serde_json::json!({
                "msg": { "last_agent_message": "done" }
            })),
        };
        assert!(matches!(
            map_notification(&complete),
            Some(AgentEvent::Complete { ref summary }) if summary == "done"
        ));
    }
}
