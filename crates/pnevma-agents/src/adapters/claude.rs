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
pub struct ClaudeCodeAdapter {
    channels: Arc<RwLock<HashMap<Uuid, broadcast::Sender<AgentEvent>>>>,
    configs: Arc<RwLock<HashMap<Uuid, AgentConfig>>>,
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

        let prompt = format!(
            "{}\n\nConstraints:\n{}\n\nChecks:\n{}\n\nRules:\n{}\n\nRelevant files:\n{}\n",
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
            input
                .relevant_file_paths
                .iter()
                .map(|line| format!("- {line}"))
                .collect::<Vec<_>>()
                .join("\n"),
        );

        let mut child = Command::new("claude")
            .current_dir(&cfg.working_dir)
            .envs(cfg.env.iter().cloned())
            .stdin(std::process::Stdio::piped())
            .stdout(std::process::Stdio::piped())
            .stderr(std::process::Stdio::piped())
            .spawn()
            .map_err(|e| AgentError::Spawn(e.to_string()))?;

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

        let tx_out = tx.clone();
        let usage_re_out = usage_re.clone();
        let cost_re_out = cost_re.clone();
        let out_task = tokio::spawn(async move {
            let mut lines = BufReader::new(stdout).lines();
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
                    let _ = tx_out.send(AgentEvent::UsageUpdate {
                        tokens_in,
                        tokens_out: 0,
                        cost_usd: cost,
                    });
                }
            }
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
        let _ = out_task.await;
        let _ = err_task.await;
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
