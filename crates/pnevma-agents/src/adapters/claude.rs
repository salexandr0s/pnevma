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

        let mut child = Command::new("claude")
            .current_dir(&cfg.working_dir)
            .envs(cfg.env.iter().cloned())
            .args(&args)
            .stdout(std::process::Stdio::piped())
            .stderr(std::process::Stdio::piped())
            .spawn()
            .map_err(|e| AgentError::Spawn(e.to_string()))?;

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
        if let Some(tx) = self
            .channels
            .read()
            .expect("channel lock poisoned")
            .get(&handle.id)
        {
            let _ = tx.send(AgentEvent::StatusChange(AgentStatus::Paused));
            Ok(())
        } else {
            Err(AgentError::Unavailable(
                "agent handle not found".to_string(),
            ))
        }
    }

    async fn stop(&self, handle: &AgentHandle) -> Result<(), AgentError> {
        if let Some(tx) = self
            .channels
            .read()
            .expect("channel lock poisoned")
            .get(&handle.id)
        {
            let _ = tx.send(AgentEvent::StatusChange(AgentStatus::Completed));
            Ok(())
        } else {
            Err(AgentError::Unavailable(
                "agent handle not found".to_string(),
            ))
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

    if !input.constraints.is_empty() {
        let items: Vec<String> = input.constraints.iter().map(|c| format!("- {c}")).collect();
        sections.push(format!("## Constraints\n\n{}", items.join("\n")));
    }

    if !input.acceptance_checks.is_empty() {
        let items: Vec<String> = input
            .acceptance_checks
            .iter()
            .map(|c| format!("- {c}"))
            .collect();
        sections.push(format!("## Acceptance Checks\n\n{}", items.join("\n")));
    }

    if !input.project_rules.is_empty() {
        let items: Vec<String> = input
            .project_rules
            .iter()
            .map(|r| format!("- {r}"))
            .collect();
        sections.push(format!("## Rules\n\n{}", items.join("\n")));
    }

    if !input.relevant_file_paths.is_empty() {
        let items: Vec<String> = input
            .relevant_file_paths
            .iter()
            .map(|p| format!("- {p}"))
            .collect();
        sections.push(format!("## Relevant Files\n\n{}", items.join("\n")));
    }

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
