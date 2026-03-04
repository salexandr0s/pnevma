use std::time::Instant;

use axum::{
    body::Body,
    extract::ConnectInfo,
    http::Request,
    middleware::Next,
    response::Response,
};
use std::net::SocketAddr;

/// Middleware that logs every request with method, path, IP, status, and timing.
pub async fn audit_log(
    ConnectInfo(addr): ConnectInfo<SocketAddr>,
    req: Request<Body>,
    next: Next,
) -> Response {
    let method = req.method().clone();
    let path = req.uri().path().to_string();
    let ip = addr.ip();
    let start = Instant::now();

    let response = next.run(req).await;

    let status = response.status().as_u16();
    let elapsed_ms = start.elapsed().as_millis();

    tracing::info!(
        method = %method,
        path = %path,
        remote_ip = %ip,
        status = status,
        elapsed_ms = elapsed_ms,
        "request"
    );

    response
}
