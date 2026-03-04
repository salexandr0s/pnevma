use crate::error::AgentError;
use crate::model::{
    AgentAdapter, AgentConfig, AgentEvent, AgentHandle, AgentStatus, CostRecord, TaskPayload,
};
use async_trait::async_trait;
use chrono::Utc;
use std::collections::HashMap;
use std::path::PathBuf;
use std::sync::Arc;
use std::sync::RwLock;
use tokio::io::AsyncBufReadExt;
use tokio::io::BufReader;
use tokio::process::Command;
use tokio::sync::broadcast;
use tracing::{debug, warn};
use uuid::Uuid;

#[derive(Default)]
pub struct ClaudeCodeAdapter {
    channels: Arc<RwLock<HashMap<Uuid, broadcast::Sender<AgentEvent>>>>,
    configs: Arc<RwLock<HashMap<Uuid, AgentConfig>>>,
    costs: Arc<RwLock<HashMap<Uuid, CostRecord>>>,
    /// Tracks PIDs of spawned agent subprocesses for lifecycle management.
    processes: Arc<RwLock<HashMap<Uuid, u32>>>,
}

impl ClaudeCodeAdapter {
    pub fn new() -> Self {
        Self::default()
    }
}

#[async_trait]
impl AgentAdapter for ClaudeCodeAdapter {
    async fn spawn(&self, config: AgentConfig) -> Result<AgentHandle, AgentError> {
        let id = Uuid::new_v4();
        let (tx, _) = broadcast::channel(2048);
        self.channels
            .write()
            .expect("channel lock poisoned")
            .insert(id, tx.clone());
        self.configs
            .write()
            .expect("config lock poisoned")
            .insert(id, config.clone());
        let _ = tx.send(AgentEvent::StatusChange(AgentStatus::Running));
        let _ = tx.send(AgentEvent::OutputChunk(format!(
            "[claude-code] spawned in {}",
            config.working_dir
        )));

        Ok(AgentHandle {
            id,
            provider: "claude-code".to_string(),
            task_id: Uuid::nil(),
        })
    }

    async fn send(&self, handle: &AgentHandle, input: TaskPayload) -> Result<(), AgentError> {
        let tx = self
            .channels
            .read()
            .expect("channel lock poisoned")
            .get(&handle.id)
            .cloned()
            .ok_or_else(|| AgentError::Unavailable("missing event channel".to_string()))?;
        let cfg = self
            .configs
            .read()
            .expect("config lock poisoned")
            .get(&handle.id)
            .cloned()
            .ok_or_else(|| AgentError::Unavailable("missing config".to_string()))?;

        let prompt = build_prompt(&input);

        // Write compiled context as CLAUDE.md in the worktree so the CLI auto-discovers it.
        if let Some(ref context_file) = cfg.context_file {
            if let Err(e) = inject_context_file(context_file, &cfg.working_dir).await {
                warn!(error = %e, "failed to inject context file into worktree");
            }
        }

        // Build CLI arguments.
        let mut args: Vec<String> = vec!["-p".into(), prompt];
        args.extend(["--output-format".into(), cfg.output_format.clone()]);

        if cfg.auto_approve {
            args.push("--dangerously-skip-permissions".into());
        }

        if let Some(ref model) = cfg.model {
            args.extend(["--model".into(), model.clone()]);
        }

        debug!(
            handle = %handle.id,
            args_count = args.len(),
            "spawning claude CLI"
        );

        // SAFETY: setpgid(0,0) creates a new process group so we can signal the
        // entire tree on interrupt/stop.
        let mut child = unsafe {
            Command::new("claude")
                .current_dir(&cfg.working_dir)
                .envs(cfg.env.iter().cloned())
                .args(&args)
                .stdout(std::process::Stdio::piped())
                .stderr(std::process::Stdio::piped())
                .pre_exec(|| {
                    if libc::setpgid(0, 0) != 0 {
                        return Err(std::io::Error::last_os_error());
                    }
                    Ok(())
                })
                .spawn()
                .map_err(|e| AgentError::Spawn(e.to_string()))?
        };

        // Store PID for interrupt/stop lifecycle management.
        if let Some(pid) = child.id() {
            self.processes
                .write()
                .expect("process lock poisoned")
                .insert(handle.id, pid);
        }

        let stdout = child
            .stdout
            .take()
            .ok_or_else(|| AgentError::Spawn("missing stdout".to_string()))?;
        let stderr = child
            .stderr
            .take()
            .ok_or_else(|| AgentError::Spawn("missing stderr".to_string()))?;

        let handle_id = handle.id;
        let costs = self.costs.clone();

        // Parse structured stream-json output from stdout.
        let tx_out = tx.clone();
        let use_stream_json = cfg.output_format == "stream-json";
        let out_task = tokio::spawn(async move {
            let mut lines = BufReader::new(stdout).lines();
            let mut total_tokens_in: u64 = 0;
            let mut total_tokens_out: u64 = 0;
            let mut total_cost: f64 = 0.0;
            let mut model_name: Option<String> = None;

            while let Ok(Some(line)) = lines.next_line().await {
                if line.trim().is_empty() {
                    continue;
                }

                if !use_stream_json {
                    let _ = tx_out.send(AgentEvent::OutputChunk(format!("{line}\n")));
                    continue;
                }

                let event: serde_json::Value = match serde_json::from_str(&line) {
                    Ok(v) => v,
                    Err(_) => {
                        // Not JSON — emit as raw output.
                        let _ = tx_out.send(AgentEvent::OutputChunk(format!("{line}\n")));
                        continue;
                    }
                };

                match event.get("type").and_then(|v| v.as_str()) {
                    Some("assistant") => {
                        if let Some(message) = event.get("message") {
                            // Capture model name.
                            if model_name.is_none() {
                                model_name = message
                                    .get("model")
                                    .and_then(|v| v.as_str())
                                    .map(|s| s.to_string());
                            }

                            // Extract content blocks: text and tool_use.
                            if let Some(content) = message.get("content").and_then(|v| v.as_array())
                            {
                                for block in content {
                                    match block.get("type").and_then(|v| v.as_str()) {
                                        Some("text") => {
                                            if let Some(text) =
                                                block.get("text").and_then(|v| v.as_str())
                                            {
                                                let _ = tx_out.send(AgentEvent::OutputChunk(
                                                    format!("{text}\n"),
                                                ));
                                            }
                                        }
                                        Some("tool_use") => {
                                            let name = block
                                                .get("name")
                                                .and_then(|v| v.as_str())
                                                .unwrap_or("unknown");
                                            let tool_input = block
                                                .get("input")
                                                .map(|v| v.to_string())
                                                .unwrap_or_default();
                                            let _ = tx_out.send(AgentEvent::ToolUse {
                                                name: name.to_string(),
                                                input: tool_input,
                                                output: String::new(),
                                            });
                                        }
                                        _ => {}
                                    }
                                }
                            }

                            // Accumulate token usage from message.usage.
                            if let Some(usage) = message.get("usage") {
                                let tin = usage
                                    .get("input_tokens")
                                    .and_then(|v| v.as_u64())
                                    .unwrap_or(0);
                                let tout = usage
                                    .get("output_tokens")
                                    .and_then(|v| v.as_u64())
                                    .unwrap_or(0);
                                total_tokens_in += tin;
                                total_tokens_out += tout;
                            }
                        }
                    }
                    Some("result") => {
                        // Final result event — extract cost and summary.
                        total_cost = event
                            .get("total_cost_usd")
                            .or_else(|| event.get("cost_usd"))
                            .and_then(|v| v.as_f64())
                            .unwrap_or(0.0);

                        let _ = tx_out.send(AgentEvent::UsageUpdate {
                            tokens_in: total_tokens_in,
                            tokens_out: total_tokens_out,
                            cost_usd: total_cost,
                        });

                        if let Some(result) = event.get("result").and_then(|v| v.as_str()) {
                            let _ = tx_out.send(AgentEvent::OutputChunk(format!(
                                "\n--- Result ---\n{result}\n"
                            )));
                        }
                    }
                    Some("system") => {
                        let _ = tx_out.send(AgentEvent::OutputChunk(
                            "[claude-code] session initialized\n".to_string(),
                        ));
                    }
                    _ => {
                        // Unknown event type — emit raw for debugging.
                        let _ = tx_out.send(AgentEvent::OutputChunk(format!("{line}\n")));
                    }
                }
            }

            (total_tokens_in, total_tokens_out, total_cost, model_name)
        });

        // Stream stderr as output chunks (warnings, progress info).
        let tx_err = tx.clone();
        let err_task = tokio::spawn(async move {
            let mut lines = BufReader::new(stderr).lines();
            while let Ok(Some(line)) = lines.next_line().await {
                let _ = tx_err.send(AgentEvent::OutputChunk(format!("[stderr] {line}\n")));
            }
        });

        let status = child.wait().await.map_err(AgentError::Io)?;
        // Remove PID from tracking — process has exited.
        self.processes
            .write()
            .expect("process lock poisoned")
            .remove(&handle_id);
        let out_result = out_task.await;
        let _ = err_task.await;

        // Store cost record from parsed output.
        if let Ok((tokens_in, tokens_out, cost_usd, model_name)) = out_result {
            costs.write().expect("cost lock poisoned").insert(
                handle_id,
                CostRecord {
                    provider: "claude-code".to_string(),
                    model: model_name,
                    tokens_in,
                    tokens_out,
                    estimated_cost_usd: cost_usd,
                    timestamp: Utc::now(),
                    task_id: input.task_id,
                    session_id: handle_id,
                },
            );
        }

        if !status.success() {
            let _ = tx.send(AgentEvent::Error(format!(
                "claude exited with status {:?}",
                status.code()
            )));
            let _ = tx.send(AgentEvent::StatusChange(AgentStatus::Failed));
            return Ok(());
        }

        let _ = tx.send(AgentEvent::Complete {
            summary: "Claude run completed".to_string(),
        });
        let _ = tx.send(AgentEvent::StatusChange(AgentStatus::Completed));
        Ok(())
    }

    async fn interrupt(&self, handle: &AgentHandle) -> Result<(), AgentError> {
        let pid_found = if let Some(&pid) = self
            .processes
            .read()
            .expect("process lock poisoned")
            .get(&handle.id)
        {
            // SAFETY: PID max (4,194,304) is well below i32::MAX; negation targets the process group.
            let ret = unsafe { libc::kill(-(pid as i32), libc::SIGINT) };
            if ret != 0 {
                tracing::warn!(pid, error = %std::io::Error::last_os_error(), "kill(SIGINT) failed");
            }
            true
        } else {
            false
        };
        if pid_found {
            if let Some(tx) = self
                .channels
                .read()
                .expect("channel lock poisoned")
                .get(&handle.id)
            {
                let _ = tx.send(AgentEvent::StatusChange(AgentStatus::Paused));
            }
            Ok(())
        } else {
            Err(AgentError::Unavailable("no process found for agent".into()))
        }
    }

    async fn stop(&self, handle: &AgentHandle) -> Result<(), AgentError> {
        // Send SIGTERM, then SIGKILL after 5 seconds if still alive.
        let pid_found = if let Some(&pid) = self
            .processes
            .read()
            .expect("process lock poisoned")
            .get(&handle.id)
        {
            // SAFETY: PID max (4,194,304) is well below i32::MAX; negation targets the process group.
            let ret = unsafe { libc::kill(-(pid as i32), libc::SIGTERM) };
            if ret != 0 {
                tracing::warn!(pid, error = %std::io::Error::last_os_error(), "kill(SIGTERM) failed");
            }
            let processes = self.processes.clone();
            let agent_id = handle.id;
            tokio::spawn(async move {
                tokio::time::sleep(std::time::Duration::from_secs(5)).await;
                let should_kill = {
                    let procs = processes.read().expect("process lock poisoned");
                    procs.get(&agent_id).copied() == Some(pid)
                };
                if should_kill {
                    let ret = unsafe { libc::kill(-(pid as i32), libc::SIGKILL) };
                    if ret != 0 {
                        tracing::warn!(pid, error = %std::io::Error::last_os_error(), "kill(SIGKILL) failed");
                    }
                    processes
                        .write()
                        .expect("process lock poisoned")
                        .remove(&agent_id);
                }
            });
            true
        } else {
            false
        };
        if pid_found {
            if let Some(tx) = self
                .channels
                .read()
                .expect("channel lock poisoned")
                .get(&handle.id)
            {
                let _ = tx.send(AgentEvent::StatusChange(AgentStatus::Completed));
            }
            Ok(())
        } else {
            Err(AgentError::Unavailable("no process found for agent".into()))
        }
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
        if let Some(record) = self
            .costs
            .read()
            .expect("cost lock poisoned")
            .get(&handle.id)
        {
            return Ok(record.clone());
        }

        Ok(CostRecord {
            provider: "claude-code".to_string(),
            model: None,
            tokens_in: 0,
            tokens_out: 0,
            estimated_cost_usd: 0.0,
            timestamp: Utc::now(),
            task_id: Uuid::nil(),
            session_id: handle.id,
        })
    }
}

/// Build the task prompt for the claude CLI `-p` argument.
fn build_prompt(input: &TaskPayload) -> String {
    let mut sections = Vec::new();

    sections.push(format!("# Task\n\n{}", input.objective));

    let bullet_section = |header: &str, items: &[String]| -> Option<String> {
        if items.is_empty() {
            return None;
        }
        let body = items
            .iter()
            .map(|s| format!("- {s}"))
            .collect::<Vec<_>>()
            .join("\n");
        Some(format!("## {header}\n\n{body}"))
    };
    sections.extend(bullet_section("Constraints", &input.constraints));
    sections.extend(bullet_section(
        "Acceptance Checks",
        &input.acceptance_checks,
    ));
    sections.extend(bullet_section("Rules", &input.project_rules));
    sections.extend(bullet_section("Relevant Files", &input.relevant_file_paths));

    if let Some(ref ctx) = input.prior_context_summary {
        if !ctx.is_empty() {
            sections.push(format!("## Prior Context\n\n{ctx}"));
        }
    }

    sections.push(format!(
        "## Working Directory\n\n`{}` (branch: `{}`)\n\nRead `.pnevma/task-context.md` for additional file context.",
        input.worktree_path, input.branch_name
    ));

    sections.join("\n\n")
}

/// Write compiled context into the worktree's CLAUDE.md for auto-discovery.
/// If an existing CLAUDE.md is present, append the task context below it.
async fn inject_context_file(context_file: &str, working_dir: &str) -> Result<(), String> {
    let context_content = tokio::fs::read_to_string(context_file)
        .await
        .map_err(|e| format!("read context file: {e}"))?;

    let claude_md_path = PathBuf::from(working_dir).join("CLAUDE.md");
    let existing = tokio::fs::read_to_string(&claude_md_path)
        .await
        .unwrap_or_default();

    let merged = if existing.is_empty() {
        context_content
    } else {
        format!(
            "{existing}\n\n---\n\n# Task Context (auto-injected by pnevma)\n\n{context_content}"
        )
    };

    tokio::fs::write(&claude_md_path, merged)
        .await
        .map_err(|e| format!("write CLAUDE.md: {e}"))?;

    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    fn make_adapter() -> ClaudeCodeAdapter {
        ClaudeCodeAdapter {
            channels: Arc::new(RwLock::new(HashMap::new())),
            configs: Arc::new(RwLock::new(HashMap::new())),
            costs: Arc::new(RwLock::new(HashMap::new())),
            processes: Arc::new(RwLock::new(HashMap::new())),
        }
    }

    fn make_handle() -> AgentHandle {
        AgentHandle {
            id: Uuid::new_v4(),
            provider: "claude-code".to_string(),
            task_id: Uuid::new_v4(),
        }
    }

    #[tokio::test]
    async fn interrupt_no_process_returns_unavailable() {
        let adapter = make_adapter();
        let handle = make_handle();
        // Insert a channel so the adapter knows the handle, but no PID
        let (tx, _) = broadcast::channel(16);
        adapter.channels.write().unwrap().insert(handle.id, tx);

        let err = adapter.interrupt(&handle).await.unwrap_err();
        assert!(
            matches!(err, AgentError::Unavailable(_)),
            "expected Unavailable, got {err:?}"
        );
    }

    #[tokio::test]
    async fn stop_no_process_returns_unavailable() {
        let adapter = make_adapter();
        let handle = make_handle();
        let (tx, _) = broadcast::channel(16);
        adapter.channels.write().unwrap().insert(handle.id, tx);

        let err = adapter.stop(&handle).await.unwrap_err();
        assert!(
            matches!(err, AgentError::Unavailable(_)),
            "expected Unavailable, got {err:?}"
        );
    }

    #[test]
    fn build_prompt_empty_optional_sections() {
        let payload = TaskPayload {
            task_id: Uuid::nil(),
            objective: "Do the thing".to_string(),
            constraints: vec![],
            project_rules: vec![],
            worktree_path: "/tmp/work".to_string(),
            branch_name: "feat/test".to_string(),
            acceptance_checks: vec![],
            relevant_file_paths: vec![],
            prior_context_summary: None,
        };
        let prompt = build_prompt(&payload);
        assert!(prompt.contains("# Task\n\nDo the thing"));
        assert!(!prompt.contains("## Constraints"));
        assert!(!prompt.contains("## Acceptance Checks"));
        assert!(!prompt.contains("## Rules"));
        assert!(!prompt.contains("## Relevant Files"));
        assert!(!prompt.contains("## Prior Context"));
        assert!(prompt.contains("## Working Directory"));
        assert!(prompt.contains("/tmp/work"));
        assert!(prompt.contains("feat/test"));
    }

    #[test]
    fn build_prompt_with_all_sections() {
        let payload = TaskPayload {
            task_id: Uuid::nil(),
            objective: "Implement feature X".to_string(),
            constraints: vec!["no breaking changes".to_string()],
            project_rules: vec!["use strict mode".to_string()],
            worktree_path: "/home/dev/project".to_string(),
            branch_name: "feat/x".to_string(),
            acceptance_checks: vec!["tests pass".to_string()],
            relevant_file_paths: vec!["src/main.rs".to_string()],
            prior_context_summary: Some("Previously did Y".to_string()),
        };
        let prompt = build_prompt(&payload);
        assert!(prompt.contains("# Task\n\nImplement feature X"));
        assert!(prompt.contains("## Constraints\n\n- no breaking changes"));
        assert!(prompt.contains("## Acceptance Checks\n\n- tests pass"));
        assert!(prompt.contains("## Rules\n\n- use strict mode"));
        assert!(prompt.contains("## Relevant Files\n\n- src/main.rs"));
        assert!(prompt.contains("## Prior Context\n\nPreviously did Y"));
        assert!(prompt.contains("/home/dev/project"));
    }

    #[test]
    fn build_prompt_empty_prior_context_omitted() {
        let payload = TaskPayload {
            task_id: Uuid::nil(),
            objective: "Test".to_string(),
            constraints: vec![],
            project_rules: vec![],
            worktree_path: "/tmp".to_string(),
            branch_name: "main".to_string(),
            acceptance_checks: vec![],
            relevant_file_paths: vec![],
            prior_context_summary: Some("".to_string()),
        };
        let prompt = build_prompt(&payload);
        assert!(!prompt.contains("## Prior Context"));
    }
}
