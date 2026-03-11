pub mod auth;
pub mod config;
pub mod error;
pub mod middleware;
pub mod routes;
pub mod server;
pub mod tailscale;
pub mod tls;

use std::{net::SocketAddr, path::PathBuf, sync::Arc};

use async_trait::async_trait;
use serde_json::Value;
use tokio::sync::{broadcast, oneshot};
use tokio_rustls::TlsAcceptor;
use tracing::info;

pub use auth::TokenStore;
pub use config::RemoteAccessConfig;
pub use error::RemoteError;

#[derive(Debug, Clone)]
pub struct RemoteEventEnvelope {
    pub event: String,
    pub payload: Value,
}

/// Trait that abstracts routing commands to the application control plane.
/// The `pnevma-app` crate implements this to bridge `route_method()`.
#[async_trait]
pub trait CommandRouter: Send + Sync + 'static {
    async fn route(&self, method: &str, params: &Value) -> Result<Value, String>;
}

/// Handle to the running remote server, used to trigger a graceful shutdown.
pub struct RemoteServerHandle {
    shutdown_tx: oneshot::Sender<()>,
    _join: tokio::task::JoinHandle<()>,
}

impl RemoteServerHandle {
    /// Signal the server to shut down gracefully.
    pub fn shutdown(self) {
        let _ = self.shutdown_tx.send(());
    }
}

/// Start the remote access server.
///
/// Binds to `config.port` on the Tailscale interface (or all interfaces as fallback),
/// sets up TLS, and serves the router.
///
/// Returns a `RemoteServerHandle` that can be used to stop the server.
pub async fn start_remote_server(
    config: RemoteAccessConfig,
    command_router: Arc<dyn CommandRouter>,
    remote_events: broadcast::Sender<RemoteEventEnvelope>,
    password: &str,
    frontend_dir: Option<PathBuf>,
) -> Result<RemoteServerHandle, RemoteError> {
    let token_store = Arc::new(TokenStore::new(
        password.to_string(),
        config.token_ttl_hours,
    )?);
    token_store.spawn_cleanup();

    // Determine bind address — Tailscale is required; no insecure fallback.
    let ts_ip = match tailscale::get_tailscale_self_ip().await {
        Ok(ip) => {
            info!(tailscale_ip = %ip, "Binding to Tailscale interface");
            ip
        }
        Err(e) => {
            return Err(RemoteError::NoTailscale(format!(
                "{e}. Remote access requires Tailscale."
            )));
        }
    };
    let bind_addr = SocketAddr::from((ts_ip, config.port));

    let (tls_config, tls_fingerprint) = tls::load_tls_config(
        &config.tls_mode,
        Some(std::net::IpAddr::V4(ts_ip)),
        config.tls_allow_self_signed_fallback,
    )
    .await?;
    let acceptor = TlsAcceptor::from(Arc::new(tls_config));

    let app = server::build_router(
        &config,
        command_router,
        remote_events,
        token_store,
        frontend_dir,
        tls_fingerprint,
    )
    .await;

    let listener = tokio::net::TcpListener::bind(bind_addr)
        .await
        .map_err(|e| RemoteError::Server(format!("Failed to bind {bind_addr}: {e}")))?;

    info!(addr = %bind_addr, "pnevma-remote listening");

    let (shutdown_tx, shutdown_rx) = oneshot::channel::<()>();

    let join = tokio::spawn(async move {
        axum_serve_tls(listener, acceptor, app, shutdown_rx).await;
    });

    Ok(RemoteServerHandle {
        shutdown_tx,
        _join: join,
    })
}

/// Run an axum app over TLS by manually accepting connections.
async fn axum_serve_tls(
    listener: tokio::net::TcpListener,
    acceptor: TlsAcceptor,
    app: axum::Router,
    mut shutdown_rx: oneshot::Receiver<()>,
) {
    use axum::extract::connect_info::IntoMakeServiceWithConnectInfo;
    use hyper::server::conn::http1;
    use hyper_util::rt::TokioIo;
    use std::net::SocketAddr;
    use tower::Service;

    let mut make_service: IntoMakeServiceWithConnectInfo<axum::Router, SocketAddr> =
        app.into_make_service_with_connect_info::<SocketAddr>();

    loop {
        tokio::select! {
            result = listener.accept() => {
                let (stream, remote_addr) = match result {
                    Ok(pair) => pair,
                    Err(e) => {
                        tracing::error!("TCP accept error: {e}");
                        continue;
                    }
                };

                let acceptor = acceptor.clone();
                let tower_service = match make_service.call(remote_addr).await {
                    Ok(svc) => svc,
                    Err(e) => {
                        tracing::error!("Service creation error: {e:?}");
                        continue;
                    }
                };

                tokio::spawn(async move {
                    let tls_stream = match acceptor.accept(stream).await {
                        Ok(s) => s,
                        Err(e) => {
                            tracing::debug!("TLS handshake failed from {remote_addr}: {e}");
                            return;
                        }
                    };

                    let io = TokioIo::new(tls_stream);
                    let hyper_service = hyper::service::service_fn(move |req| {
                        let mut svc = tower_service.clone();
                        async move { svc.call(req).await }
                    });

                    if let Err(e) = http1::Builder::new()
                        .serve_connection(io, hyper_service)
                        .with_upgrades() // required for WebSocket
                        .await
                    {
                        tracing::debug!("Connection error from {remote_addr}: {e}");
                    }
                });
            }
            _ = &mut shutdown_rx => {
                info!("pnevma-remote shutting down");
                break;
            }
        }
    }
}
