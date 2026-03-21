use std::collections::HashMap;
use std::sync::Arc;
use std::time::Duration;

use tokio::sync::broadcast;

use crate::protocol::RpcNotification;
use crate::HelperRuntime;

const POLL_INTERVAL: Duration = Duration::from_secs(2);

pub fn spawn_session_watcher(
    runtime: Arc<HelperRuntime>,
    tx: broadcast::Sender<RpcNotification>,
) -> tokio::task::JoinHandle<()> {
    tokio::spawn(async move {
        poll_loop(runtime, tx).await;
    })
}

async fn poll_loop(runtime: Arc<HelperRuntime>, tx: broadcast::Sender<RpcNotification>) {
    let mut cached_states: HashMap<String, String> = HashMap::new();
    loop {
        tokio::time::sleep(POLL_INTERVAL).await;
        let sessions = match tokio::task::spawn_blocking({
            let rt = runtime.clone();
            move || rt.list_sessions()
        })
        .await
        {
            Ok(Ok(sessions)) => sessions,
            _ => continue,
        };

        // Detect removed sessions.
        let current_ids: std::collections::HashSet<String> =
            sessions.iter().map(|s| s.session_id.clone()).collect();
        cached_states.retain(|id, _| current_ids.contains(id));

        for session in sessions {
            let prev = cached_states.get(&session.session_id);
            if prev.map(String::as_str) != Some(&session.state) {
                let _ = tx.send(RpcNotification {
                    method: "session.state_changed".to_string(),
                    params: serde_json::to_value(&session).unwrap_or_default(),
                });
                cached_states.insert(session.session_id.clone(), session.state.clone());
            }
        }
    }
}
