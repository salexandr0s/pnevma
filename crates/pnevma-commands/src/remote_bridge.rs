use crate::control::route_method;
use crate::state::AppState;
use async_trait::async_trait;
use pnevma_remote::CommandRouter;
use serde_json::Value;
use std::sync::Arc;

/// Bridge from pnevma-remote's `CommandRouter` trait to `route_method()`.
pub struct AppStateCommandRouter {
    state: Arc<AppState>,
}

impl AppStateCommandRouter {
    pub fn new(state: Arc<AppState>) -> Arc<Self> {
        Arc::new(Self { state })
    }
}

#[async_trait]
impl CommandRouter for AppStateCommandRouter {
    async fn route(&self, method: &str, params: &Value) -> Result<Value, String> {
        route_method(&self.state, method, params)
            .await
            .map_err(|(_code, msg)| msg)
    }
}

/// Start the remote access server if enabled in project config.
pub async fn maybe_start_remote(state: Arc<AppState>) {
    let config = {
        let current = state.current.lock().await;
        match current.as_ref() {
            Some(ctx) => ctx.config.remote.clone(),
            None => return,
        }
    };

    if !config.enabled {
        tracing::info!("remote access disabled in project config");
        return;
    }

    let password = std::env::var("PNEVMA_REMOTE_PASSWORD")
        .ok()
        .or_else(|| {
            let home = std::env::var("HOME").unwrap_or_else(|_| ".".to_string());
            let path = std::path::PathBuf::from(home).join(".config/pnevma/remote-password");
            std::fs::read_to_string(path)
                .ok()
                .map(|s| s.trim().to_string())
        })
        .filter(|p| !p.is_empty());

    let Some(password) = password else {
        tracing::warn!("remote access enabled but no password configured (set PNEVMA_REMOTE_PASSWORD or ~/.config/pnevma/remote-password)");
        return;
    };

    let router = AppStateCommandRouter::new(Arc::clone(&state));
    let remote_config = pnevma_remote::RemoteAccessConfig {
        enabled: true,
        port: config.port,
        tls_mode: config.tls_mode,
        token_ttl_hours: config.token_ttl_hours,
        rate_limit_rpm: config.rate_limit_rpm,
        max_ws_per_ip: config.max_ws_per_ip,
        serve_frontend: config.serve_frontend,
        allowed_origins: config.allowed_origins.clone(),
        tls_allow_self_signed_fallback: config.tls_allow_self_signed_fallback,
    };

    match pnevma_remote::start_remote_server(remote_config, router, &password, None).await {
        Ok(handle) => {
            tracing::info!(port = config.port, "remote access server started");
            *state.remote_handle.lock().await = Some(handle);
        }
        Err(e) => {
            tracing::error!(error = %e, "failed to start remote access server");
        }
    }
}
