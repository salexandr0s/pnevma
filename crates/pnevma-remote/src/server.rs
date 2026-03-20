use std::{path::PathBuf, sync::Arc};

use axum::{
    body::Body,
    extract::Request,
    middleware::{self, Next},
    routing::{delete, get, post},
    Router,
};
use tower_http::limit::RequestBodyLimitLayer;

use crate::{
    auth::TokenStore,
    config::RemoteAccessConfig,
    middleware::{
        audit::audit_log,
        auth_token::auth_token,
        cors::cors_layer,
        rate_limit::RateLimitState,
        security_headers::{security_headers, SecurityHeadersConfig},
        tailscale_guard::tailscale_guard,
    },
    routes::{
        api, auth_routes,
        health::health,
        ws::{
            ws_handler, WsConnectionCounts, WsState, DEFAULT_MAX_CONSECUTIVE_RATE_VIOLATIONS,
            DEFAULT_MAX_MESSAGES_PER_SECOND,
        },
    },
    CommandRouter, RemoteEventEnvelope,
};

pub async fn build_router(
    config: &RemoteAccessConfig,
    router: Arc<dyn CommandRouter>,
    remote_events: tokio::sync::broadcast::Sender<RemoteEventEnvelope>,
    token_store: Arc<TokenStore>,
    frontend_dir: Option<PathBuf>,
    tls_fingerprint: Option<String>,
    cleanup_shutdown_rx: tokio::sync::watch::Receiver<bool>,
) -> Router {
    let api_rate_limit = RateLimitState::new(config.rate_limit_rpm);
    let auth_rate_limit = RateLimitState::new(5); // 5 req/min for auth

    // Spawn background cleanup to prevent unbounded rate-limiter growth.
    api_rate_limit.spawn_cleanup(cleanup_shutdown_rx.clone());
    auth_rate_limit.spawn_cleanup(cleanup_shutdown_rx.clone());

    // Auth route (rate-limited separately, no bearer token required)
    let lockout = crate::routes::auth_routes::LoginLockoutState::new();
    lockout.spawn_cleanup(cleanup_shutdown_rx.clone());
    let auth_state = crate::routes::auth_routes::AuthState {
        token_store: token_store.clone(),
        lockout,
    };
    let auth_router = Router::new()
        .route("/api/auth/token", post(auth_routes::create_token))
        .route("/api/auth/token", delete(auth_routes::revoke_token))
        .with_state(auth_state)
        .layer(middleware::from_fn_with_state(
            auth_rate_limit,
            crate::middleware::rate_limit::rate_limit,
        ));

    // Per-IP WebSocket connection counter (shared across all WS upgrades).
    let ws_counts: WsConnectionCounts = std::sync::Arc::new(dashmap::DashMap::new());
    let ws_state = WsState {
        router: router.clone(),
        remote_events,
        connection_counts: ws_counts,
        max_ws_per_ip: config.max_ws_per_ip,
        max_messages_per_second: DEFAULT_MAX_MESSAGES_PER_SECOND,
        max_consecutive_rate_violations: DEFAULT_MAX_CONSECUTIVE_RATE_VIOLATIONS,
        allowed_origins: config.allowed_origins.clone(),
        allow_session_input: config.allow_session_input,
    };

    // WebSocket route — needs its own state because ws_handler extracts WsState.
    let ws_router = Router::new()
        .route("/api/ws", get(ws_handler))
        .with_state(ws_state);

    // Protected API routes
    let api_router = Router::new()
        .route("/api/fleet/snapshot", get(api::fleet_snapshot))
        .route("/api/fleet/action", post(api::fleet_action))
        .route("/api/project/status", get(api::project_status))
        .route("/api/project/daily-brief", get(api::project_daily_brief))
        .route("/api/project/automation", get(api::project_automation))
        .route("/api/project/search", post(api::project_search))
        .route("/api/tasks", get(api::task_list))
        .route("/api/tasks", post(api::task_create))
        .route("/api/tasks/{id}/dispatch", post(api::task_dispatch))
        // session.new is deliberately excluded from the RPC allowlist — no POST route.
        // session.send_input is excluded from RPC allowlist — no REST route either.
        .route("/api/sessions", get(api::session_list))
        .route("/api/workflows", get(api::workflow_list))
        .route("/api/workflows/defs", get(api::workflow_list_defs))
        .route(
            "/api/workflows/instances",
            get(api::workflow_list_instances),
        )
        .route("/api/workflows/instances", post(api::workflow_instantiate))
        .route(
            "/api/workflows/instances/{id}",
            get(api::workflow_get_instance),
        )
        .route("/api/workflows/dispatch", post(api::workflow_dispatch))
        .route("/api/workflows/{id}", get(api::workflow_get))
        .route("/api/rpc", post(api::rpc))
        .merge(ws_router)
        .with_state(router)
        .layer(middleware::from_fn_with_state(token_store, auth_token))
        .layer(middleware::from_fn_with_state(
            api_rate_limit,
            crate::middleware::rate_limit::rate_limit,
        ));

    // Health check (no auth, rate-limited separately)
    let health_rate_limit = RateLimitState::new(120); // 120 req/min
    health_rate_limit.spawn_cleanup(cleanup_shutdown_rx);
    let health_router =
        Router::new()
            .route("/health", get(health))
            .layer(middleware::from_fn_with_state(
                health_rate_limit,
                crate::middleware::rate_limit::rate_limit,
            ));

    let mut app = Router::new()
        .merge(health_router)
        .merge(auth_router)
        .merge(api_router)
        .layer(middleware::from_fn(audit_log))
        .layer(middleware::from_fn_with_state(
            SecurityHeadersConfig {
                hsts_max_age: config.hsts_max_age,
                tls_active: tls_fingerprint.is_some(),
                serve_frontend: config.serve_frontend,
            },
            security_headers,
        ))
        .layer(cors_layer(config.allowed_origins.clone()))
        .layer(RequestBodyLimitLayer::new(2_097_152))
        .layer(middleware::from_fn(tailscale_guard));

    // Optionally serve frontend SPA
    if config.serve_frontend {
        if let Some(dir) = frontend_dir {
            let static_router = crate::routes::static_files::static_files_router(dir);
            app = app.merge(static_router);
        }
    }

    if let Some(fp) = tls_fingerprint {
        let fingerprint_value = format!("sha256:{fp}");
        app = app.layer(middleware::from_fn(
            move |req: Request<Body>, next: Next| {
                let fp_value = fingerprint_value.clone();
                async move {
                    let mut response = next.run(req).await;
                    response.headers_mut().insert(
                        axum::http::HeaderName::from_static("x-tls-fingerprint"),
                        axum::http::HeaderValue::from_str(&fp_value)
                            .unwrap_or_else(|_| axum::http::HeaderValue::from_static("error")),
                    );
                    response
                }
            },
        ));
    }

    app
}

#[cfg(test)]
mod tests {
    use std::sync::Arc;

    use async_trait::async_trait;
    use serde_json::Value;
    use tokio::sync::broadcast;

    use super::*;
    use crate::CommandRouter;

    struct NoopRouter;

    #[async_trait]
    impl CommandRouter for NoopRouter {
        async fn route(&self, _method: &str, _params: &Value) -> Result<Value, String> {
            Ok(Value::Null)
        }
    }

    #[tokio::test]
    async fn build_router_accepts_current_route_syntax() {
        let config = RemoteAccessConfig::default();
        let token_store = Arc::new(TokenStore::new("password".to_string(), 24).unwrap());
        let (events_tx, _) = broadcast::channel(8);
        let (_shutdown_tx, shutdown_rx) = tokio::sync::watch::channel(false);

        let _router = build_router(
            &config,
            Arc::new(NoopRouter),
            events_tx,
            token_store,
            None,
            None,
            shutdown_rx,
        )
        .await;
    }

    #[tokio::test]
    async fn fingerprint_header_injected_when_self_signed() {
        use axum::{body::Body, extract::ConnectInfo, http::Request};
        use std::net::SocketAddr;
        use tower::ServiceExt;

        let config = RemoteAccessConfig::default();
        let token_store = Arc::new(TokenStore::new("password".to_string(), 24).unwrap());
        let (events_tx, _) = broadcast::channel(8);
        let (_shutdown_tx, shutdown_rx) = tokio::sync::watch::channel(false);

        let fp = "a".repeat(64); // fake 64-char hex fingerprint
        let app = build_router(
            &config,
            Arc::new(NoopRouter),
            events_tx,
            token_store,
            None,
            Some(fp.clone()),
            shutdown_rx,
        )
        .await;

        let response = app
            .oneshot(
                Request::builder()
                    .uri("/health")
                    .extension(ConnectInfo(SocketAddr::from(([127, 0, 0, 1], 4242))))
                    .body(Body::empty())
                    .expect("request"),
            )
            .await
            .expect("route response");

        let header = response
            .headers()
            .get("x-tls-fingerprint")
            .expect("X-TLS-Fingerprint header should be present");
        assert_eq!(header.to_str().unwrap(), format!("sha256:{fp}"),);
    }

    #[tokio::test]
    async fn no_fingerprint_header_when_none() {
        use axum::{body::Body, extract::ConnectInfo, http::Request};
        use std::net::SocketAddr;
        use tower::ServiceExt;

        let config = RemoteAccessConfig::default();
        let token_store = Arc::new(TokenStore::new("password".to_string(), 24).unwrap());
        let (events_tx, _) = broadcast::channel(8);
        let (_shutdown_tx, shutdown_rx) = tokio::sync::watch::channel(false);

        let app = build_router(
            &config,
            Arc::new(NoopRouter),
            events_tx,
            token_store,
            None,
            None,
            shutdown_rx,
        )
        .await;

        let response = app
            .oneshot(
                Request::builder()
                    .uri("/health")
                    .extension(ConnectInfo(SocketAddr::from(([127, 0, 0, 1], 4242))))
                    .body(Body::empty())
                    .expect("request"),
            )
            .await
            .expect("route response");

        assert!(
            response.headers().get("x-tls-fingerprint").is_none(),
            "X-TLS-Fingerprint header should not be present when fingerprint is None"
        );
    }
}
