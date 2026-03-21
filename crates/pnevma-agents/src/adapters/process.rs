//! Shared process-lifecycle state for adapters that manage an OS subprocess
//! per agent (claude, codex). Extracts the duplicated `interrupt`, `stop`,
//! and `events` logic into one place.

use crate::error::AgentError;
use crate::model::{AgentEvent, AgentHandle, AgentStatus};
use std::collections::HashMap;
use std::sync::Arc;
use tokio::sync::{broadcast, RwLock};
use uuid::Uuid;

/// Manages broadcast channels, per-handle configs, and OS process IDs.
///
/// Both `ClaudeCodeAdapter` and `CodexAdapter` embed this struct to share
/// the identical `interrupt`, `stop`, and `events` implementations.
pub(crate) struct ProcessState<C: Clone + Send + Sync + 'static> {
    pub channels: Arc<RwLock<HashMap<Uuid, broadcast::Sender<AgentEvent>>>>,
    pub configs: Arc<RwLock<HashMap<Uuid, C>>>,
    pub processes: Arc<RwLock<HashMap<Uuid, u32>>>,
    pub costs: Arc<RwLock<HashMap<Uuid, crate::model::CostRecord>>>,
}

impl<C: Clone + Send + Sync + 'static> Default for ProcessState<C> {
    fn default() -> Self {
        Self {
            channels: Arc::new(RwLock::new(HashMap::new())),
            configs: Arc::new(RwLock::new(HashMap::new())),
            processes: Arc::new(RwLock::new(HashMap::new())),
            costs: Arc::new(RwLock::new(HashMap::new())),
        }
    }
}

impl<C: Clone + Send + Sync + 'static> ProcessState<C> {
    /// Send SIGINT to the agent's process group and mark it as Paused.
    // libc::kill for process group signaling
    #[allow(unsafe_code)]
    pub async fn interrupt(&self, handle: &AgentHandle) -> Result<(), AgentError> {
        let pid_found = if let Some(&pid) = self.processes.read().await.get(&handle.id) {
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
            if let Some(tx) = self.channels.read().await.get(&handle.id) {
                let _ = tx.send(AgentEvent::StatusChange(AgentStatus::Paused));
            }
            Ok(())
        } else {
            Err(AgentError::Unavailable("no process found for agent".into()))
        }
    }

    /// Send SIGTERM, then SIGKILL after 5 seconds if still alive.
    // libc::kill for process group signaling
    #[allow(unsafe_code)]
    pub async fn stop(&self, handle: &AgentHandle) -> Result<(), AgentError> {
        let pid_found = if let Some(&pid) = self.processes.read().await.get(&handle.id) {
            // SAFETY: PID max (4,194,304) is well below i32::MAX; negation targets the process group.
            let ret = unsafe { libc::kill(-(pid as i32), libc::SIGTERM) };
            if ret != 0 {
                tracing::warn!(pid, error = %std::io::Error::last_os_error(), "kill(SIGTERM) failed");
            }
            let processes = self.processes.clone();
            let agent_id = handle.id;
            tokio::spawn(async move {
                tokio::time::sleep(std::time::Duration::from_secs(5)).await;
                // Probe if the process group is still alive before sending SIGKILL.
                // Using kill(pid, 0) avoids PID-reuse races — if the original process
                // exited and the PID was reassigned, the new process won't be in our
                // process group, so kill(-pgid, 0) will fail with ESRCH.
                let still_alive = unsafe { libc::kill(-(pid as i32), 0) } == 0;
                if still_alive {
                    let ret = unsafe { libc::kill(-(pid as i32), libc::SIGKILL) };
                    if ret != 0 {
                        tracing::warn!(pid, error = %std::io::Error::last_os_error(), "kill(SIGKILL) failed");
                    }
                }
                processes.write().await.remove(&agent_id);
            });
            true
        } else {
            false
        };
        if pid_found {
            if let Some(tx) = self.channels.read().await.get(&handle.id) {
                let _ = tx.send(AgentEvent::StatusChange(AgentStatus::Completed));
            }
            Ok(())
        } else {
            Err(AgentError::Unavailable("no process found for agent".into()))
        }
    }

    /// Subscribe to the event channel for this agent, or return an error receiver
    /// if the handle is missing.
    ///
    /// Uses `try_read()` because this is called from a sync context (trait
    /// requirement). Under write contention, callers retry on the next poll cycle.
    pub fn events(&self, handle: &AgentHandle) -> broadcast::Receiver<AgentEvent> {
        if let Ok(guard) = self.channels.try_read() {
            if let Some(tx) = guard.get(&handle.id) {
                return tx.subscribe();
            }
        }
        let (tx, rx) = broadcast::channel(4);
        let _ = tx.send(AgentEvent::Error("missing handle".to_string()));
        rx
    }
}
