use std::{net::SocketAddr, sync::Arc};

use axum::{
    body::Body,
    extract::{ConnectInfo, Query},
    http::{Request, StatusCode},
    middleware::Next,
    response::{IntoResponse, Response},
};
use serde::Deserialize;

use crate::{
    auth::TokenStore,
    middleware::audit::{AuditAuthContext, AuthTokenSource},
};

#[derive(Debug, Deserialize)]
pub struct TokenQuery {
    pub token: Option<String>,
}

/// Extract a Bearer token from the Authorization header or `?token=` query param.
pub async fn auth_token(
    Query(query): Query<TokenQuery>,
    axum::extract::State(store): axum::extract::State<Arc<TokenStore>>,
    ConnectInfo(addr): ConnectInfo<SocketAddr>,
    req: Request<Body>,
    next: Next,
) -> Response {
    let token = extract_token(&req, query.token.as_deref());
    let request_ip = addr.ip().to_string();
    let websocket_upgrade = is_websocket_upgrade(&req);

    match token {
        Some((t, token_source)) => match store.validate_token(&t, &request_ip) {
            Some(audit) => {
                let audit_ctx = if websocket_upgrade {
                    AuditAuthContext::websocket_authenticated(
                        audit.subject,
                        audit.token_id,
                        token_source,
                    )
                } else {
                    AuditAuthContext::authenticated_request(
                        audit.subject,
                        audit.token_id,
                        token_source,
                    )
                };
                let mut req = req;
                req.extensions_mut().insert(audit_ctx.clone());
                let mut response = next.run(req).await;
                response.extensions_mut().insert(audit_ctx);
                response
            }
            None => {
                tracing::warn!(
                    path = %req.uri().path(),
                    "Unauthorized request — missing or invalid token"
                );
                StatusCode::UNAUTHORIZED.into_response()
            }
        },
        _ => {
            tracing::warn!(
                path = %req.uri().path(),
                "Unauthorized request — missing or invalid token"
            );
            StatusCode::UNAUTHORIZED.into_response()
        }
    }
}

fn extract_token(
    req: &Request<Body>,
    query_token: Option<&str>,
) -> Option<(String, AuthTokenSource)> {
    // Try Authorization: Bearer <token> first
    if let Some(header_val) = req.headers().get(axum::http::header::AUTHORIZATION) {
        if let Ok(val) = header_val.to_str() {
            if let Some(token) = val.strip_prefix("Bearer ") {
                return Some((token.to_string(), AuthTokenSource::AuthorizationHeader));
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
            return Some((t.to_string(), AuthTokenSource::QueryParam));
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
    use crate::auth::SHARED_PASSWORD_SUBJECT;
    use axum::{extract::ConnectInfo, http::HeaderValue, middleware, routing::get, Router};
    use tower::ServiceExt;

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
        assert_eq!(
            token,
            Some((
                "mytoken123".to_string(),
                AuthTokenSource::AuthorizationHeader
            ))
        );
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
        assert_eq!(
            token,
            Some(("wstoken".to_string(), AuthTokenSource::QueryParam))
        );

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
        assert_eq!(
            token,
            Some((
                "headertoken".to_string(),
                AuthTokenSource::AuthorizationHeader
            ))
        );
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

    #[tokio::test]
    async fn middleware_sets_authenticated_request_audit_context() {
        let store = Arc::new(TokenStore::new("correcthorsebatterystaple".to_string(), 24).unwrap());
        let issued = store.create_token("127.0.0.1", "operator-a");
        let app = Router::new()
            .route("/api/status", get(|| async { StatusCode::OK }))
            .route_layer(middleware::from_fn_with_state(
                Arc::clone(&store),
                auth_token,
            ));

        let response = app
            .oneshot(
                Request::builder()
                    .uri("/api/status")
                    .header(
                        axum::http::header::AUTHORIZATION,
                        format!("Bearer {}", issued.token),
                    )
                    .extension(ConnectInfo(SocketAddr::from(([127, 0, 0, 1], 4242))))
                    .body(Body::empty())
                    .expect("request"),
            )
            .await
            .expect("route response");

        assert_eq!(response.status(), StatusCode::OK);
        let audit = response
            .extensions()
            .get::<AuditAuthContext>()
            .cloned()
            .expect("audit context");
        assert_eq!(audit.auth_event, "authenticated_request");
        assert_eq!(audit.subject, "operator-a");
        assert_eq!(
            audit.token_id.as_deref(),
            Some(issued.audit.token_id.as_str())
        );
        assert_eq!(
            audit.token_source,
            Some(AuthTokenSource::AuthorizationHeader)
        );
    }

    #[tokio::test]
    async fn middleware_sets_websocket_audit_context_for_query_token() {
        let store = Arc::new(TokenStore::new("correcthorsebatterystaple".to_string(), 24).unwrap());
        let issued = store.create_token("127.0.0.1", SHARED_PASSWORD_SUBJECT);
        let app = Router::new()
            .route("/api/ws", get(|| async { StatusCode::OK }))
            .route_layer(middleware::from_fn_with_state(
                Arc::clone(&store),
                auth_token,
            ));

        let response = app
            .oneshot(
                Request::builder()
                    .uri(format!("/api/ws?token={}", issued.token))
                    .header(axum::http::header::UPGRADE, "websocket")
                    .extension(ConnectInfo(SocketAddr::from(([127, 0, 0, 1], 4242))))
                    .body(Body::empty())
                    .expect("request"),
            )
            .await
            .expect("route response");

        assert_eq!(response.status(), StatusCode::OK);
        let audit = response
            .extensions()
            .get::<AuditAuthContext>()
            .cloned()
            .expect("audit context");
        assert_eq!(audit.auth_event, "websocket_authenticated");
        assert_eq!(audit.subject, SHARED_PASSWORD_SUBJECT);
        assert_eq!(
            audit.token_id.as_deref(),
            Some(issued.audit.token_id.as_str())
        );
        assert_eq!(audit.token_source, Some(AuthTokenSource::QueryParam));
    }
}
