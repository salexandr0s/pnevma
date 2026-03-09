use crate::error::AgentError;
use crate::model::{
    AgentAdapter, AgentConfig, AgentEvent, AgentHandle, AgentStatus, CostRecord, DynamicToolDef,
    TaskPayload,
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
    channels: Arc<std::sync::RwLock<HashMap<Uuid, broadcast::Sender<AgentEvent>>>>,
    configs: Arc<std::sync::RwLock<HashMap<Uuid, AgentConfig>>>,
    connections: Arc<RwLock<HashMap<Uuid, AppServerConnection>>>,
    costs: Arc<std::sync::RwLock<HashMap<Uuid, CostRecord>>>,
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
        let request = JsonRpcRequest {
            jsonrpc: "2.0",
            id,
            method: method.to_string(),
            params,
        };
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
}

#[async_trait]
impl AgentAdapter for CodexV2Adapter {
    async fn spawn(&self, config: AgentConfig) -> Result<AgentHandle, AgentError> {
        let id = Uuid::new_v4();
        let (event_tx, _) = broadcast::channel(2048);

        self.channels
            .write()
            .expect("channel lock poisoned")
            .insert(id, event_tx.clone());
        self.configs
            .write()
            .expect("config lock poisoned")
            .insert(id, config.clone());

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
                            if let Ok(mut costs) = costs_clone.write() {
                                costs.insert(
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

        // Build tool list for thread.start
        let tools_param: Vec<serde_json::Value> = config
            .dynamic_tools
            .iter()
            .map(|t: &DynamicToolDef| {
                serde_json::json!({
                    "name": t.name,
                    "description": t.description,
                    "parameters": t.parameters_schema,
                })
            })
            .collect();

        let mut params = serde_json::json!({});
        if !tools_param.is_empty() {
            params["tools"] = serde_json::Value::Array(tools_param);
        }
        if let Some(ref tid) = config.thread_id {
            params["thread_id"] = serde_json::Value::String(tid.clone());
        }

        let result = Self::rpc_call(
            &stdin_tx,
            &conn.next_id,
            &pending,
            "thread.start",
            Some(params),
        )
        .await?;
        let thread_id = result
            .get("thread_id")
            .and_then(|v| v.as_str())
            .map(|s| s.to_string());

        *conn.thread_id.write().await = thread_id.clone();

        if let Some(ref tid) = thread_id {
            let _ = event_tx.send(AgentEvent::ThreadStarted {
                thread_id: tid.clone(),
            });
        }

        self.connections.write().await.insert(id, conn);

        let _ = event_tx.send(AgentEvent::StatusChange(AgentStatus::Running));

        Ok(AgentHandle {
            id,
            provider: "codex-v2".to_string(),
            task_id: Uuid::nil(),
            thread_id,
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

        let prompt = format!(
            "{}\n\nConstraints:\n{}\n\nChecks:\n{}\n\nRules:\n{}",
            &input.objective,
            input
                .constraints
                .iter()
                .map(|c| format!("- {c}"))
                .collect::<Vec<_>>()
                .join("\n"),
            input
                .acceptance_checks
                .iter()
                .map(|c| format!("- {c}"))
                .collect::<Vec<_>>()
                .join("\n"),
            input
                .project_rules
                .iter()
                .map(|r| format!("- {r}"))
                .collect::<Vec<_>>()
                .join("\n"),
        );

        let params = serde_json::json!({
            "thread_id": thread_id,
            "message": prompt,
        });

        let result = Self::rpc_call(
            &conn.stdin_tx,
            &conn.next_id,
            &conn.pending,
            "turn.start",
            Some(params),
        )
        .await?;

        let turn_id = result
            .get("turn_id")
            .and_then(|v| v.as_str())
            .map(|s| s.to_string());

        *conn.turn_id.write().await = turn_id.clone();

        if let Some(ref tid) = turn_id {
            if let Some(tx) = self
                .channels
                .read()
                .expect("channel lock poisoned")
                .get(&handle.id)
            {
                let _ = tx.send(AgentEvent::TurnStarted {
                    turn_id: tid.clone(),
                    thread_id: thread_id.clone(),
                });
            }
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

        let params = serde_json::json!({
            "thread_id": thread_id,
            "turn_id": turn_id,
        });

        Self::rpc_call(
            &conn.stdin_tx,
            &conn.next_id,
            &conn.pending,
            "turn.interrupt",
            Some(params),
        )
        .await?;

        if let Some(tx) = self
            .channels
            .read()
            .expect("channel lock poisoned")
            .get(&handle.id)
        {
            let _ = tx.send(AgentEvent::StatusChange(AgentStatus::Paused));
        }

        Ok(())
    }

    async fn stop(&self, handle: &AgentHandle) -> Result<(), AgentError> {
        let mut conns = self.connections.write().await;
        if let Some(conn) = conns.remove(&handle.id) {
            // Try graceful thread.shutdown
            if let Some(tid) = conn.thread_id.read().await.clone() {
                let _ = Self::rpc_call(
                    &conn.stdin_tx,
                    &conn.next_id,
                    &conn.pending,
                    "thread.shutdown",
                    Some(serde_json::json!({"thread_id": tid})),
                )
                .await;
            }

            // SAFETY: PID max (4,194,304) is well below i32::MAX; negation targets process group.
            if let Some(pid) = conn.child.id() {
                unsafe { libc::kill(-(pid as i32), libc::SIGTERM) };
                tokio::spawn(async move {
                    tokio::time::sleep(std::time::Duration::from_secs(5)).await;
                    unsafe { libc::kill(-(pid as i32), libc::SIGKILL) };
                });
            }

            conn.stdout_task.abort();
            conn.stdin_task.abort();
        }

        if let Some(tx) = self
            .channels
            .read()
            .expect("channel lock poisoned")
            .get(&handle.id)
        {
            let _ = tx.send(AgentEvent::StatusChange(AgentStatus::Completed));
        }

        Ok(())
    }

    fn events(&self, handle: &AgentHandle) -> broadcast::Receiver<AgentEvent> {
        if let Some(tx) = self
            .channels
            .read()
            .expect("channel lock poisoned")
            .get(&handle.id)
        {
            tx.subscribe()
        } else {
            let (tx, rx) = broadcast::channel(4);
            let _ = tx.send(AgentEvent::Error("missing handle".to_string()));
            rx
        }
    }

    async fn parse_usage(&self, handle: &AgentHandle) -> Result<CostRecord, AgentError> {
        let costs = self.costs.read().expect("costs lock poisoned");
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
        "error" => {
            let msg = params.get("message")?.as_str()?.to_string();
            Some(AgentEvent::Error(msg))
        }
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

    fn make_config() -> AgentConfig {
        AgentConfig {
            provider: "codex-v2".to_string(),
            model: None,
            env: vec![],
            working_dir: "/tmp".to_string(),
            timeout_minutes: 30,
            auto_approve: false,
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
        assert!(adapter.channels.read().unwrap().is_empty());
        assert!(adapter.configs.read().unwrap().is_empty());
        assert!(adapter.costs.read().unwrap().is_empty());
    }

    #[test]
    fn default_creates_empty_adapter() {
        let adapter = CodexV2Adapter::default();
        assert!(adapter.channels.read().unwrap().is_empty());
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
}
