use std::{path::PathBuf, sync::Arc};

use axum::{
    middleware,
    routing::{delete, get, post},
    Router,
};
use tower_http::limit::RequestBodyLimitLayer;

use crate::{
    auth::TokenStore,
    config::RemoteAccessConfig,
    middleware::{
        audit::audit_log, auth_token::auth_token, cors::cors_layer, rate_limit::RateLimitState,
        tailscale_guard::tailscale_guard,
    },
    routes::{
        api, auth_routes,
        health::health,
        ws::{ws_handler, WsConnectionCounts, WsState},
    },
    CommandRouter, RemoteEventEnvelope,
};

pub async fn build_router(
    config: &RemoteAccessConfig,
    router: Arc<dyn CommandRouter>,
    remote_events: tokio::sync::broadcast::Sender<RemoteEventEnvelope>,
    token_store: Arc<TokenStore>,
    frontend_dir: Option<PathBuf>,
) -> Router {
    let api_rate_limit = RateLimitState::new(config.rate_limit_rpm);
    let auth_rate_limit = RateLimitState::new(5); // 5 req/min for auth

    // Spawn background cleanup to prevent unbounded rate-limiter growth.
    api_rate_limit.spawn_cleanup();
    auth_rate_limit.spawn_cleanup();

    // Auth route (rate-limited separately, no bearer token required)
    let auth_router = Router::new()
        .route("/api/auth/token", post(auth_routes::create_token))
        .route("/api/auth/token", delete(auth_routes::revoke_token))
        .with_state(token_store.clone())
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
    };

    // WebSocket route — needs its own state because ws_handler extracts WsState.
    let ws_router = Router::new()
        .route("/api/ws", get(ws_handler))
        .with_state(ws_state);

    // Protected API routes
    let api_router = Router::new()
        .route("/api/project/status", get(api::project_status))
        .route("/api/project/daily-brief", get(api::project_daily_brief))
        .route("/api/project/search", post(api::project_search))
        .route("/api/tasks", get(api::task_list))
        .route("/api/tasks", post(api::task_create))
        .route("/api/tasks/:id/dispatch", post(api::task_dispatch))
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
            "/api/workflows/instances/:id",
            get(api::workflow_get_instance),
        )
        .route("/api/workflows/dispatch", post(api::workflow_dispatch))
        .route("/api/workflows/:id", get(api::workflow_get))
        .route("/api/rpc", post(api::rpc))
        .merge(ws_router)
        .with_state(router)
        .layer(middleware::from_fn_with_state(token_store, auth_token))
        .layer(middleware::from_fn_with_state(
            api_rate_limit,
            crate::middleware::rate_limit::rate_limit,
        ));

    // Health check (no auth, no rate limit)
    let health_router = Router::new().route("/health", get(health));

    let mut app = Router::new()
        .merge(health_router)
        .merge(auth_router)
        .merge(api_router)
        .layer(middleware::from_fn(audit_log))
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

    app
}
