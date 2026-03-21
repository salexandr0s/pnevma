use std::collections::HashMap;
use std::sync::Arc;

use tokio::sync::Mutex;

use crate::rpc_client::RpcClient;
use crate::rpc_tunnel::RpcTunnel;
use crate::SshProfile;

struct PoolEntry {
    client: Arc<RpcClient>,
    _tunnel: RpcTunnel,
}

pub struct RpcPool {
    entries: Mutex<HashMap<String, PoolEntry>>,
}

impl Default for RpcPool {
    fn default() -> Self {
        Self::new()
    }
}

impl RpcPool {
    pub fn new() -> Self {
        Self {
            entries: Mutex::new(HashMap::new()),
        }
    }

    pub async fn get_or_connect(&self, profile: &SshProfile) -> Option<Arc<RpcClient>> {
        let mut map = self.entries.lock().await;

        // Return existing connection if alive.
        if let Some(entry) = map.get(&profile.id) {
            if entry.client.is_alive() {
                return Some(entry.client.clone());
            }
            map.remove(&profile.id);
        }

        // Try to establish a new tunnel + client connection.
        let tunnel = match RpcTunnel::open(profile).await {
            Ok(t) => t,
            Err(_) => return None,
        };
        let client = match RpcClient::connect(tunnel.local_socket_path()).await {
            Ok(c) => Arc::new(c),
            Err(_) => return None,
        };

        let entry = PoolEntry {
            client: client.clone(),
            _tunnel: tunnel,
        };
        map.insert(profile.id.clone(), entry);
        Some(client)
    }
}

static RPC_POOL: std::sync::OnceLock<RpcPool> = std::sync::OnceLock::new();

pub fn rpc_pool() -> &'static RpcPool {
    RPC_POOL.get_or_init(RpcPool::new)
}
