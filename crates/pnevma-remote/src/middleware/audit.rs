use std::time::Instant;

use axum::{body::Body, extract::ConnectInfo, http::Request, middleware::Next, response::Response};
use std::net::SocketAddr;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum AuthTokenSource {
    AuthorizationHeader,
    QueryParam,
}

#[derive(Debug, Clone)]
pub struct AuditAuthContext {
    pub auth_event: &'static str,
    pub subject: String,
    pub token_id: Option<String>,
    pub token_source: Option<AuthTokenSource>,
}

impl AuditAuthContext {
    pub fn token_issued(subject: String, token_id: String) -> Self {
        Self {
            auth_event: "token_issued",
            subject,
            token_id: Some(token_id),
            token_source: None,
        }
    }

    pub fn token_revoked(subject: String, token_id: String) -> Self {
        Self {
            auth_event: "token_revoked",
            subject,
            token_id: Some(token_id),
            token_source: None,
        }
    }

    pub fn authenticated_request(
        subject: String,
        token_id: String,
        token_source: AuthTokenSource,
    ) -> Self {
        Self {
            auth_event: "authenticated_request",
            subject,
            token_id: Some(token_id),
            token_source: Some(token_source),
        }
    }

    pub fn websocket_authenticated(
        subject: String,
        token_id: String,
        token_source: AuthTokenSource,
    ) -> Self {
        Self {
            auth_event: "websocket_authenticated",
            subject,
            token_id: Some(token_id),
            token_source: Some(token_source),
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
    let user_agent = req
        .headers()
        .get(axum::http::header::USER_AGENT)
        .and_then(|v| v.to_str().ok())
        .unwrap_or("-")
        .to_string();
    let content_length = req
        .headers()
        .get(axum::http::header::CONTENT_LENGTH)
        .and_then(|v| v.to_str().ok())
        .unwrap_or("-")
        .to_string();
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
            user_agent = %user_agent,
            content_length = %content_length,
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
            user_agent = %user_agent,
            content_length = %content_length,
            "request"
        );
    }

    response
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn audit_auth_context_token_issued() {
        let ctx = AuditAuthContext::token_issued("user1".to_string(), "tid1".to_string());
        assert_eq!(ctx.auth_event, "token_issued");
        assert_eq!(ctx.subject, "user1");
        assert_eq!(ctx.token_id.as_deref(), Some("tid1"));
        assert!(ctx.token_source.is_none());
    }

    #[test]
    fn audit_auth_context_token_revoked() {
        let ctx = AuditAuthContext::token_revoked("user2".to_string(), "tid2".to_string());
        assert_eq!(ctx.auth_event, "token_revoked");
        assert_eq!(ctx.subject, "user2");
        assert_eq!(ctx.token_id.as_deref(), Some("tid2"));
        assert!(ctx.token_source.is_none());
    }

    #[test]
    fn audit_auth_context_authenticated_request() {
        let ctx = AuditAuthContext::authenticated_request(
            "user3".to_string(),
            "tid3".to_string(),
            AuthTokenSource::AuthorizationHeader,
        );
        assert_eq!(ctx.auth_event, "authenticated_request");
        assert_eq!(ctx.subject, "user3");
        assert_eq!(ctx.token_id.as_deref(), Some("tid3"));
        assert_eq!(ctx.token_source, Some(AuthTokenSource::AuthorizationHeader));
    }

    #[test]
    fn audit_auth_context_websocket_authenticated() {
        let ctx = AuditAuthContext::websocket_authenticated(
            "user4".to_string(),
            "tid4".to_string(),
            AuthTokenSource::QueryParam,
        );
        assert_eq!(ctx.auth_event, "websocket_authenticated");
        assert_eq!(ctx.subject, "user4");
        assert_eq!(ctx.token_id.as_deref(), Some("tid4"));
        assert_eq!(ctx.token_source, Some(AuthTokenSource::QueryParam));
    }
}
