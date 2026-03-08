use std::time::Instant;

use axum::{body::Body, extract::ConnectInfo, http::Request, middleware::Next, response::Response};
use std::net::SocketAddr;

#[derive(Debug, Clone)]
pub struct AuditAuthContext {
    pub auth_event: &'static str,
    pub subject: String,
    pub token_id: Option<String>,
}

impl AuditAuthContext {
    pub fn token_issued(subject: String, token_id: String) -> Self {
        Self {
            auth_event: "token_issued",
            subject,
            token_id: Some(token_id),
        }
    }

    pub fn token_revoked(subject: String, token_id: String) -> Self {
        Self {
            auth_event: "token_revoked",
            subject,
            token_id: Some(token_id),
        }
    }

    pub fn authenticated_request(subject: String, token_id: String) -> Self {
        Self {
            auth_event: "authenticated_request",
            subject,
            token_id: Some(token_id),
        }
    }

    pub fn websocket_authenticated(subject: String, token_id: String) -> Self {
        Self {
            auth_event: "websocket_authenticated",
            subject,
            token_id: Some(token_id),
        }
    }
}

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
    if let Some(auth) = response.extensions().get::<AuditAuthContext>() {
        tracing::info!(
            method = %method,
            path = %path,
            remote_ip = %ip,
            status = status,
            elapsed_ms = elapsed_ms,
            auth_event = auth.auth_event,
            subject = %auth.subject,
            token_id = auth.token_id.as_deref().unwrap_or("-"),
            "request"
        );
    } else {
        tracing::info!(
            method = %method,
            path = %path,
            remote_ip = %ip,
            status = status,
            elapsed_ms = elapsed_ms,
            "request"
        );
    }

    response
}
