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
            .insert(id, tx.clone());
        self.configs
            .write()
            .expect("config lock poisoned")
            .insert(id, config.clone());
        let _ = tx.send(AgentEvent::StatusChange(AgentStatus::Running));
        let _ = tx.send(AgentEvent::OutputChunk(format!(
            "[codex] spawned in {}",
            config.working_dir
        )));

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
            input.objective,
            input
                .constraints
                .iter()
                .map(|line| format!("- {line}"))
                .collect::<Vec<_>>()
                .join("\n"),
            input
                .acceptance_checks
                .iter()
                .map(|line| format!("- {line}"))
                .collect::<Vec<_>>()
                .join("\n"),
            input
                .project_rules
                .iter()
                .map(|line| format!("- {line}"))
                .collect::<Vec<_>>()
                .join("\n"),
        );

        // SAFETY: setpgid(0,0) creates a new process group so we can signal the
        // entire tree on interrupt/stop.
        let mut child = unsafe {
            Command::new("codex")
                .current_dir(&cfg.working_dir)
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
            self.processes.write().expect("process lock poisoned").insert(handle.id, pid);
        }

        if let Some(stdin) = child.stdin.as_mut() {
            stdin
                .write_all(prompt.as_bytes())
                .await
                .map_err(AgentError::Io)?;
            stdin.write_all(b"\n").await.map_err(AgentError::Io)?;
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
        let costs = self.costs.clone();

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
        let usage_re_err = usage_re.clone();
        let cost_re_err = cost_re.clone();
        let err_task = tokio::spawn(async move {
            let mut lines = BufReader::new(stderr).lines();
            while let Ok(Some(line)) = lines.next_line().await {
                let _ = tx_err.send(AgentEvent::OutputChunk(format!("{line}\n")));
                if let Some(cap) = usage_re_err.captures(&line) {
                    let tokens_in = cap
                        .get(2)
                        .and_then(|m| m.as_str().parse::<u64>().ok())
                        .unwrap_or(0);
                    let cost = cost_re_err
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

        let status = child.wait().await.map_err(AgentError::Io)?;
        // Remove PID from tracking — process has exited.
        self.processes
            .write()
            .expect("process lock poisoned")
            .remove(&handle_id);
        let out_result = out_task.await;
        let _ = err_task.await;

        // Store cost record from parsed output.
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
                    task_id: input.task_id,
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
            return Ok(());
        }

        let _ = tx.send(AgentEvent::Complete {
            summary: "Codex run completed".to_string(),
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
            Err(AgentError::Unavailable(
                "no process found for agent".into(),
            ))
        }
    }

    async fn stop(&self, handle: &AgentHandle) -> Result<(), AgentError> {
        // Send SIGTERM, then SIGKILL after 5 seconds if still alive.
        let pid_found = if let Some(&pid) = self.processes.read().expect("process lock poisoned").get(&handle.id) {
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
            Err(AgentError::Unavailable(
                "no process found for agent".into(),
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
