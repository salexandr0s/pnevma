use axum::{
    body::Body,
    extract::ConnectInfo,
    http::{Request, StatusCode},
    middleware::Next,
    response::Response,
};
use std::net::SocketAddr;

use crate::tailscale::is_tailscale_ip;

/// Axum middleware that rejects connections from non-Tailscale IPs (non-100.64.0.0/10).
pub async fn tailscale_guard(
    ConnectInfo(addr): ConnectInfo<SocketAddr>,
    req: Request<Body>,
    next: Next,
) -> Result<Response, StatusCode> {
    if is_tailscale_ip(&addr.ip()) {
        Ok(next.run(req).await)
    } else {
        tracing::warn!(
            remote_ip = %addr.ip(),
            "Rejected non-Tailscale connection"
        );
        Err(StatusCode::FORBIDDEN)
    }
}
