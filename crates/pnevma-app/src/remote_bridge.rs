use crate::control::route_method;
use crate::state::AppState;
use async_trait::async_trait;
use pnevma_remote::CommandRouter;
use serde_json::Value;
use std::sync::Arc;
use tauri::{AppHandle, Manager};

/// Bridge from pnevma-remote's `CommandRouter` trait to the Tauri `route_method()`.
pub struct TauriCommandRouter {
    app: AppHandle,
}

impl TauriCommandRouter {
    pub fn new(app: AppHandle) -> Arc<Self> {
        Arc::new(Self { app })
    }
}

#[async_trait]
impl CommandRouter for TauriCommandRouter {
    async fn route(&self, method: &str, params: &Value) -> Result<Value, String> {
        route_method(&self.app, method, params)
            .await
            .map_err(|(_code, msg)| msg)
    }
}

/// Start the remote access server if enabled in project config.
pub async fn maybe_start_remote(app: AppHandle) {
    let config = {
        let state = app.state::<AppState>();
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

    let router = TauriCommandRouter::new(app.clone());
    let remote_config = pnevma_remote::RemoteAccessConfig {
        enabled: true,
        port: config.port,
        tls_mode: config.tls_mode,
        token_ttl_hours: config.token_ttl_hours,
        rate_limit_rpm: config.rate_limit_rpm,
        max_ws_per_ip: config.max_ws_per_ip,
        serve_frontend: config.serve_frontend,
    };

    match pnevma_remote::start_remote_server(remote_config, router, &password, None).await {
        Ok(handle) => {
            tracing::info!(port = config.port, "remote access server started");
            let state = app.state::<AppState>();
            *state.remote_handle.lock().await = Some(handle);
        }
        Err(e) => {
            tracing::error!(error = %e, "failed to start remote access server");
        }
    }
}
