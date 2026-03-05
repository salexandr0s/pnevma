use std::sync::Arc;

use axum::{
    body::Body,
    extract::Query,
    http::{Request, StatusCode},
    middleware::Next,
    response::Response,
};
use serde::Deserialize;

use crate::auth::TokenStore;

#[derive(Debug, Deserialize)]
pub struct TokenQuery {
    pub token: Option<String>,
}

/// Extract a Bearer token from the Authorization header or `?token=` query param.
pub async fn auth_token(
    Query(query): Query<TokenQuery>,
    axum::extract::State(store): axum::extract::State<Arc<TokenStore>>,
    req: Request<Body>,
    next: Next,
) -> Result<Response, StatusCode> {
    let token = extract_token(&req, query.token.as_deref());

    match token {
        Some(t) if store.validate_token(&t) => Ok(next.run(req).await),
        _ => {
            tracing::warn!(
                path = %req.uri().path(),
                "Unauthorized request — missing or invalid token"
            );
            Err(StatusCode::UNAUTHORIZED)
        }
    }
}

fn extract_token(req: &Request<Body>, query_token: Option<&str>) -> Option<String> {
    // Try Authorization: Bearer <token> first
    if let Some(header_val) = req.headers().get(axum::http::header::AUTHORIZATION) {
        if let Ok(val) = header_val.to_str() {
            if let Some(token) = val.strip_prefix("Bearer ") {
                return Some(token.to_string());
            }
        }
    }
    // Fall back to query param — only permitted for WebSocket upgrade requests.
    if let Some(t) = query_token {
        if is_websocket_upgrade(req) {
            tracing::warn!(
                path = %req.uri().path(),
                "auth via ?token= query param (WebSocket upgrade)"
            );
            return Some(t.to_string());
        }
    }
    None
}

fn is_websocket_upgrade(req: &Request<Body>) -> bool {
    let upgrade = req
        .headers()
        .get(axum::http::header::UPGRADE)
        .and_then(|v| v.to_str().ok())
        .unwrap_or("");
    upgrade.eq_ignore_ascii_case("websocket")
}

#[cfg(test)]
mod tests {
    use super::*;
    use axum::http::HeaderValue;

    fn plain_request() -> Request<Body> {
        Request::builder()
            .uri("http://localhost/api/status")
            .body(Body::empty())
            .unwrap()
    }

    fn ws_request() -> Request<Body> {
        Request::builder()
            .uri("http://localhost/api/ws")
            .header(axum::http::header::UPGRADE, "websocket")
            .body(Body::empty())
            .unwrap()
    }

    fn bearer_request(token: &str) -> Request<Body> {
        Request::builder()
            .uri("http://localhost/api/status")
            .header(
                axum::http::header::AUTHORIZATION,
                HeaderValue::from_str(&format!("Bearer {token}")).unwrap(),
            )
            .body(Body::empty())
            .unwrap()
    }

    #[test]
    fn extract_bearer_from_auth_header() {
        let req = bearer_request("mytoken123");
        let token = extract_token(&req, None);
        assert_eq!(token.as_deref(), Some("mytoken123"));
    }

    #[test]
    fn extract_no_token_returns_none_for_plain_request() {
        let req = plain_request();
        let token = extract_token(&req, None);
        assert!(token.is_none());
    }

    #[test]
    fn query_token_allowed_only_for_websocket_upgrade() {
        let ws_req = ws_request();
        let token = extract_token(&ws_req, Some("wstoken"));
        assert_eq!(token.as_deref(), Some("wstoken"));

        let plain_req = plain_request();
        let token = extract_token(&plain_req, Some("wstoken"));
        assert!(
            token.is_none(),
            "query token must not work for non-WS requests"
        );
    }

    #[test]
    fn bearer_header_takes_priority_over_query_token() {
        let req = bearer_request("headertoken");
        let token = extract_token(&req, Some("querytoken"));
        assert_eq!(token.as_deref(), Some("headertoken"));
    }

    #[test]
    fn is_websocket_upgrade_is_case_insensitive() {
        for upgrade_value in &["websocket", "WebSocket", "WEBSOCKET", "Websocket"] {
            let req = Request::builder()
                .header(axum::http::header::UPGRADE, *upgrade_value)
                .body(Body::empty())
                .unwrap();
            assert!(is_websocket_upgrade(&req), "should match: {upgrade_value}");
        }
    }

    #[test]
    fn non_websocket_upgrade_not_matched() {
        let req = Request::builder()
            .header(axum::http::header::UPGRADE, "h2c")
            .body(Body::empty())
            .unwrap();
        assert!(!is_websocket_upgrade(&req));
    }
}
