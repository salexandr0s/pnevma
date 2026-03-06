use crate::error::AgentError;
use crate::model::{
    AgentAdapter, AgentConfig, AgentEvent, AgentHandle, AgentStatus, CostRecord, TaskPayload,
};
use async_trait::async_trait;
use chrono::Utc;
use regex::Regex;
use std::collections::HashMap;
use std::sync::Arc;
use std::sync::RwLock;
use tokio::io::{AsyncBufReadExt, AsyncWriteExt, BufReader};
use tokio::process::Command;
use tokio::sync::broadcast;
use uuid::Uuid;

#[derive(Default)]
pub struct CodexAdapter {
    channels: Arc<RwLock<HashMap<Uuid, broadcast::Sender<AgentEvent>>>>,
    configs: Arc<RwLock<HashMap<Uuid, AgentConfig>>>,
    /// Tracks PIDs of spawned agent subprocesses for lifecycle management.
    processes: Arc<RwLock<HashMap<Uuid, u32>>>,
    costs: Arc<RwLock<HashMap<Uuid, CostRecord>>>,
}

impl CodexAdapter {
    pub fn new() -> Self {
        Self::default()
    }
}

#[async_trait]
impl AgentAdapter for CodexAdapter {
    async fn spawn(&self, config: AgentConfig) -> Result<AgentHandle, AgentError> {
        let id = Uuid::new_v4();
        let (tx, _) = broadcast::channel(2048);
        self.channels
            .write()
            .expect("channel lock poisoned")
            .insert(id, tx);
        self.configs
            .write()
            .expect("config lock poisoned")
            .insert(id, config.clone());

        Ok(AgentHandle {
            id,
            provider: "codex".to_string(),
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

        let prompt = format!(
            "{}\n\nConstraints:\n{}\n\nChecks:\n{}\n\nRules:\n{}\n",
            super::claude::sanitize_prompt_field(&input.objective),
            input
                .constraints
                .iter()
                .map(|line| format!("- {}", super::claude::sanitize_prompt_field(line)))
                .collect::<Vec<_>>()
                .join("\n"),
            input
                .acceptance_checks
                .iter()
                .map(|line| format!("- {}", super::claude::sanitize_prompt_field(line)))
                .collect::<Vec<_>>()
                .join("\n"),
            input
                .project_rules
                .iter()
                .map(|line| format!("- {}", super::claude::sanitize_prompt_field(line)))
                .collect::<Vec<_>>()
                .join("\n"),
        );

        // SAFETY: setpgid(0,0) creates a new process group so we can signal the
        // entire tree on interrupt/stop.
        let mut child = unsafe {
            Command::new("codex")
                .current_dir(&cfg.working_dir)
                .env_clear()
                .env("PATH", std::env::var("PATH").unwrap_or_default())
                .env("HOME", std::env::var("HOME").unwrap_or_default())
                .env(
                    "SHELL",
                    std::env::var("SHELL").unwrap_or_else(|_| "/bin/zsh".to_string()),
                )
                .env(
                    "TERM",
                    std::env::var("TERM").unwrap_or_else(|_| "xterm-256color".to_string()),
                )
                .env("USER", std::env::var("USER").unwrap_or_default())
                .env(
                    "LANG",
                    std::env::var("LANG").unwrap_or_else(|_| "en_US.UTF-8".to_string()),
                )
                .env(
                    "LC_ALL",
                    std::env::var("LC_ALL").unwrap_or_else(|_| "en_US.UTF-8".to_string()),
                )
                .envs(cfg.env.iter().cloned())
                .stdin(std::process::Stdio::piped())
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

        if let Some(mut stdin) = child.stdin.take() {
            stdin
                .write_all(prompt.as_bytes())
                .await
                .map_err(AgentError::Io)?;
            stdin.write_all(b"\n").await.map_err(AgentError::Io)?;
            drop(stdin); // Close stdin so codex knows input is complete
        }

        let usage_re = Regex::new(r"(?i)(tokens|input_tokens|usage)[^0-9]*(\d+)")
            .map_err(|e| AgentError::Parse(e.to_string()))?;
        let cost_re = Regex::new(r"(?i)(cost|usd)[^0-9]*([0-9]+(?:\.[0-9]+)?)")
            .map_err(|e| AgentError::Parse(e.to_string()))?;

        let stdout = child
            .stdout
            .take()
            .ok_or_else(|| AgentError::Spawn("missing stdout".to_string()))?;
        let stderr = child
            .stderr
            .take()
            .ok_or_else(|| AgentError::Spawn("missing stderr".to_string()))?;

        let handle_id = handle.id;
        let task_id = input.task_id;
        let costs = self.costs.clone();
        let processes = self.processes.clone();
        let working_dir = cfg.working_dir.clone();

        let _ = tx.send(AgentEvent::StatusChange(AgentStatus::Running));
        let _ = tx.send(AgentEvent::OutputChunk(format!(
            "[codex] spawned in {working_dir}\n"
        )));

        tokio::spawn(async move {
            let tx_out = tx.clone();
            let usage_re_out = usage_re.clone();
            let cost_re_out = cost_re.clone();
            let out_task = tokio::spawn(async move {
                let mut lines = BufReader::new(stdout).lines();
                let mut last_tokens_in: u64 = 0;
                let mut last_cost: f64 = 0.0;
                while let Ok(Some(line)) = lines.next_line().await {
                    let _ = tx_out.send(AgentEvent::OutputChunk(format!("{line}\n")));
                    if let Some(cap) = usage_re_out.captures(&line) {
                        let tokens_in = cap
                            .get(2)
                            .and_then(|m| m.as_str().parse::<u64>().ok())
                            .unwrap_or(0);
                        let cost = cost_re_out
                            .captures(&line)
                            .and_then(|m| m.get(2))
                            .and_then(|m| m.as_str().parse::<f64>().ok())
                            .unwrap_or(0.0);
                        last_tokens_in = tokens_in;
                        last_cost = cost;
                        let _ = tx_out.send(AgentEvent::UsageUpdate {
                            tokens_in,
                            tokens_out: 0,
                            cost_usd: cost,
                        });
                    }
                }
                (last_tokens_in, last_cost)
            });

            let tx_err = tx.clone();
            let err_task = tokio::spawn(async move {
                let mut lines = BufReader::new(stderr).lines();
                while let Ok(Some(line)) = lines.next_line().await {
                    let _ = tx_err.send(AgentEvent::OutputChunk(format!("{line}\n")));
                    if let Some(cap) = usage_re.captures(&line) {
                        let tokens_in = cap
                            .get(2)
                            .and_then(|m| m.as_str().parse::<u64>().ok())
                            .unwrap_or(0);
                        let cost = cost_re
                            .captures(&line)
                            .and_then(|m| m.get(2))
                            .and_then(|m| m.as_str().parse::<f64>().ok())
                            .unwrap_or(0.0);
                        let _ = tx_err.send(AgentEvent::UsageUpdate {
                            tokens_in,
                            tokens_out: 0,
                            cost_usd: cost,
                        });
                    }
                }
            });

            let status = match child.wait().await {
                Ok(status) => status,
                Err(err) => {
                    let _ = tx.send(AgentEvent::Error(err.to_string()));
                    let _ = tx.send(AgentEvent::StatusChange(AgentStatus::Failed));
                    processes
                        .write()
                        .expect("process lock poisoned")
                        .remove(&handle_id);
                    return;
                }
            };

            processes
                .write()
                .expect("process lock poisoned")
                .remove(&handle_id);
            let out_result = out_task.await;
            let _ = err_task.await;

            if let Err(ref e) = out_result {
                tracing::warn!(error = %e, "stdout reader task failed; cost record unavailable");
            }
            if let Ok((tokens_in, cost_usd)) = out_result {
                costs.write().expect("cost lock poisoned").insert(
                    handle_id,
                    CostRecord {
                        provider: "codex".to_string(),
                        model: None,
                        tokens_in,
                        tokens_out: 0,
                        estimated_cost_usd: cost_usd,
                        timestamp: Utc::now(),
                        task_id,
                        session_id: handle_id,
                    },
                );
            }
            if !status.success() {
                let _ = tx.send(AgentEvent::Error(format!(
                    "codex exited with status {:?}",
                    status.code()
                )));
                let _ = tx.send(AgentEvent::StatusChange(AgentStatus::Failed));
                return;
            }

            let _ = tx.send(AgentEvent::Complete {
                summary: "Codex run completed".to_string(),
            });
            let _ = tx.send(AgentEvent::StatusChange(AgentStatus::Completed));
        });
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
                    // SAFETY: PID max (4,194,304) is well below i32::MAX; negation targets the process group.
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
        let costs = self.costs.read().expect("costs lock poisoned");
        Ok(costs.get(&handle.id).cloned().unwrap_or(CostRecord {
            provider: "codex".to_string(),
            model: None,
            tokens_in: 0,
            tokens_out: 0,
            estimated_cost_usd: 0.0,
            timestamp: Utc::now(),
            task_id: Uuid::nil(),
            session_id: handle.id,
        }))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn make_config() -> AgentConfig {
        AgentConfig {
            provider: "codex".to_string(),
            model: None,
            env: vec![],
            working_dir: "/tmp".to_string(),
            timeout_minutes: 30,
            auto_approve: false,
            output_format: "stream-json".to_string(),
            context_file: None,
        }
    }

    fn make_handle() -> AgentHandle {
        AgentHandle {
            id: Uuid::new_v4(),
            provider: "codex".to_string(),
            task_id: Uuid::new_v4(),
        }
    }

    // ── Construction ─────────────────────────────────────────────────────────

    #[test]
    fn new_creates_empty_adapter() {
        let adapter = CodexAdapter::new();
        assert!(adapter.channels.read().unwrap().is_empty());
        assert!(adapter.configs.read().unwrap().is_empty());
        assert!(adapter.processes.read().unwrap().is_empty());
        assert!(adapter.costs.read().unwrap().is_empty());
    }

    #[test]
    fn default_creates_empty_adapter() {
        let adapter = CodexAdapter::default();
        assert!(adapter.channels.read().unwrap().is_empty());
    }

    // ── Spawn registers channel and config ───────────────────────────────────

    #[tokio::test]
    async fn spawn_registers_handle_and_config() {
        let adapter = CodexAdapter::new();
        let config = make_config();

        // Subscribe to a temporary sender BEFORE spawning to capture events.
        // We pre-create channel and insert so spawn finds it. But spawn creates its own.
        // So instead we just verify the post-spawn state.
        let handle = adapter.spawn(config.clone()).await.expect("spawn");
        assert_eq!(handle.provider, "codex");

        // channel registered
        assert!(adapter.channels.read().unwrap().contains_key(&handle.id));
        // config stored
        let stored_cfg = adapter
            .configs
            .read()
            .unwrap()
            .get(&handle.id)
            .cloned()
            .expect("config stored");
        assert_eq!(stored_cfg.working_dir, "/tmp");
        assert_eq!(stored_cfg.provider, "codex");
    }

    // ── Parse usage defaults to zero ─────────────────────────────────────────

    #[tokio::test]
    async fn parse_usage_returns_zero_when_no_record() {
        let adapter = CodexAdapter::new();
        let handle = make_handle();

        let cost = adapter.parse_usage(&handle).await.expect("parse usage");
        assert_eq!(cost.provider, "codex");
        assert_eq!(cost.tokens_in, 0);
        assert_eq!(cost.tokens_out, 0);
        assert_eq!(cost.estimated_cost_usd, 0.0);
        assert!(cost.model.is_none());
    }

    // ── Config parsing ───────────────────────────────────────────────────────

    #[test]
    fn config_serialization_roundtrip() {
        let config = AgentConfig {
            provider: "codex".to_string(),
            model: Some("o3".to_string()),
            env: vec![("KEY".to_string(), "val".to_string())],
            working_dir: "/workspace".to_string(),
            timeout_minutes: 60,
            auto_approve: true,
            output_format: "text".to_string(),
            context_file: Some("/tmp/context.md".to_string()),
        };

        let json = serde_json::to_string(&config).expect("serialize");
        let deserialized: AgentConfig = serde_json::from_str(&json).expect("deserialize");
        assert_eq!(deserialized.provider, "codex");
        assert_eq!(deserialized.model.as_deref(), Some("o3"));
        assert_eq!(deserialized.working_dir, "/workspace");
        assert!(deserialized.auto_approve);
        assert_eq!(deserialized.output_format, "text");
        assert_eq!(
            deserialized.context_file.as_deref(),
            Some("/tmp/context.md")
        );
    }

    // ── Interrupt / stop without process ────────────────────────────────────

    #[tokio::test]
    async fn interrupt_no_process_returns_unavailable() {
        let adapter = CodexAdapter::new();
        let handle = make_handle();
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
        let adapter = CodexAdapter::new();
        let handle = make_handle();
        let (tx, _) = broadcast::channel(16);
        adapter.channels.write().unwrap().insert(handle.id, tx);

        let err = adapter.stop(&handle).await.unwrap_err();
        assert!(
            matches!(err, AgentError::Unavailable(_)),
            "expected Unavailable, got {err:?}"
        );
    }

    #[tokio::test]
    async fn events_missing_handle_emits_error() {
        let adapter = CodexAdapter::new();
        let handle = make_handle();
        // No channel registered — should return a receiver with an error event
        let mut rx = adapter.events(&handle);
        let event = rx.recv().await.unwrap();
        assert!(
            matches!(event, AgentEvent::Error(ref msg) if msg.contains("missing handle")),
            "expected Error event, got {event:?}"
        );
    }

    // ── Prompt format (inline in send; verify via cost record logic) ──────────

    #[test]
    fn task_payload_serialization_roundtrip() {
        let payload = TaskPayload {
            task_id: Uuid::new_v4(),
            objective: "Implement feature X".to_string(),
            constraints: vec!["no breaking changes".to_string()],
            project_rules: vec!["use strict mode".to_string()],
            worktree_path: "/tmp/worktree".to_string(),
            branch_name: "feat/x".to_string(),
            acceptance_checks: vec!["tests pass".to_string()],
            relevant_file_paths: vec!["src/lib.rs".to_string()],
            prior_context_summary: Some("prev context".to_string()),
        };

        let json = serde_json::to_string(&payload).expect("serialize payload");
        let d: TaskPayload = serde_json::from_str(&json).expect("deserialize payload");
        assert_eq!(d.objective, "Implement feature X");
        assert_eq!(d.constraints, vec!["no breaking changes"]);
        assert_eq!(d.prior_context_summary.as_deref(), Some("prev context"));
    }
}
