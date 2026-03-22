use crate::auth_secret::load_remote_password;
use crate::control::route_method;
use crate::state::AppState;
use async_trait::async_trait;
use pnevma_remote::CommandRouter;
use secrecy::ExposeSecret;
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
pub async fn maybe_start_remote(state: Arc<AppState>) -> Option<pnevma_remote::RemoteServerHandle> {
    let config = {
        let current = state.current.lock().await;
        match current.as_ref() {
            Some(ctx) => ctx.config.remote.clone(),
            None => return None,
        }
    };

    if !config.enabled {
        tracing::info!("remote access disabled in project config");
        return None;
    }

    let password = match load_remote_password() {
        Ok(password) => password,
        Err(err) => {
            tracing::error!(error = %err, "remote access password source is invalid");
            return None;
        }
    };

    let Some(password) = password else {
        tracing::warn!(
            "remote access enabled but no password configured (set PNEVMA_REMOTE_PASSWORD, store Keychain item {}/{}, or create ~/.config/pnevma/remote-password with mode 0600)",
            crate::auth_secret::REMOTE_KEYCHAIN_SERVICE,
            crate::auth_secret::REMOTE_KEYCHAIN_ACCOUNT
        );
        return None;
    };

    let router = AppStateCommandRouter::new(Arc::clone(&state));
    let remote_config = pnevma_remote::RemoteAccessConfig {
        enabled: true,
        port: config.port,
        tls_mode: config.tls_mode.to_string(),
        token_ttl_hours: config.token_ttl_hours,
        rate_limit_rpm: config.rate_limit_rpm,
        max_ws_per_ip: config.max_ws_per_ip,
        serve_frontend: config.serve_frontend,
        allowed_origins: config.allowed_origins.clone(),
        tls_allow_self_signed_fallback: config.tls_allow_self_signed_fallback,
        allow_session_input: config.allow_session_input,
        ..Default::default()
    };

    match pnevma_remote::start_remote_server(
        remote_config,
        router,
        state.remote_events.clone(),
        password.expose_secret(),
        None,
    )
    .await
    {
        Ok(handle) => {
            tracing::info!(port = config.port, "remote access server started");
            Some(handle)
        }
        Err(e) => {
            tracing::error!(error = %e, "failed to start remote access server");
            None
        }
    }
}
