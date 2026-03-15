use std::sync::Arc;

use axum::{
    extract::State,
    http::{HeaderMap, StatusCode},
    response::IntoResponse,
    Json,
};
use serde::{Deserialize, Serialize};

use crate::{
    auth::{TokenRole, TokenStore, SHARED_PASSWORD_SUBJECT},
    middleware::audit::AuditAuthContext,
};

#[derive(Debug, Deserialize)]
pub struct TokenRequest {
    pub password: String,
    /// Optional role for the issued token. Defaults to `ReadOnly`.
    #[serde(default)]
    pub role: Option<TokenRole>,
}

#[derive(Debug, Serialize)]
pub struct TokenResponse {
    pub token: String,
    pub expires_at: String,
}

/// POST /api/auth/token — validates password and returns a bearer token.
pub async fn create_token(
    State(store): State<Arc<TokenStore>>,
    axum::extract::ConnectInfo(addr): axum::extract::ConnectInfo<std::net::SocketAddr>,
    Json(body): Json<TokenRequest>,
) -> impl IntoResponse {
    if !store.validate_password(&body.password) {
        tracing::warn!(remote_ip = %addr.ip(), "Failed authentication attempt");
        return (
            StatusCode::UNAUTHORIZED,
            Json(serde_json::json!({ "error": "invalid password" })),
        )
            .into_response();
    }

    let role = body.role.unwrap_or(TokenRole::ReadOnly);
    let issued = store.create_token(&addr.ip().to_string(), SHARED_PASSWORD_SUBJECT, role);

    tracing::info!(
        remote_ip = %addr.ip(),
        subject = %issued.audit.subject,
        token_id = %issued.audit.token_id,
        "Token issued"
    );

    let mut response = (
        StatusCode::OK,
        Json(serde_json::json!({
            "token": issued.token,
            "expires_at": issued.expires_at.to_rfc3339(),
            "role": role,
        })),
    )
        .into_response();
    response
        .extensions_mut()
        .insert(AuditAuthContext::token_issued(
            issued.audit.subject,
            issued.audit.token_id,
        ));
    response
}

/// DELETE /api/auth/token — revokes the bearer token in the Authorization header.
pub async fn revoke_token(
    State(store): State<Arc<TokenStore>>,
    headers: HeaderMap,
) -> impl IntoResponse {
    let token = headers
        .get("authorization")
        .and_then(|v| v.to_str().ok())
        .and_then(|v| v.strip_prefix("Bearer "));

    match token {
        Some(t) => match store.revoke_token(t) {
            Some(audit) => {
                let mut response =
                    (StatusCode::OK, Json(serde_json::json!({ "revoked": true }))).into_response();
                response
                    .extensions_mut()
                    .insert(AuditAuthContext::token_revoked(
                        audit.subject,
                        audit.token_id,
                    ));
                response
            }
            None => (
                StatusCode::NOT_FOUND,
                Json(serde_json::json!({ "error": "token not found" })),
            )
                .into_response(),
        },
        None => (
            StatusCode::BAD_REQUEST,
            Json(serde_json::json!({ "error": "missing Authorization: Bearer <token>" })),
        )
            .into_response(),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use axum::{
        body::{to_bytes, Body},
        extract::ConnectInfo,
        http::{header, Request},
        routing::{delete, post},
        Router,
    };
    use std::net::SocketAddr;
    use tower::ServiceExt;

    fn loopback() -> ConnectInfo<SocketAddr> {
        ConnectInfo(SocketAddr::from(([127, 0, 0, 1], 4242)))
    }

    #[tokio::test]
    async fn create_token_response_sets_audit_context() {
        let store = Arc::new(TokenStore::new("correcthorsebatterystaple".to_string(), 24).unwrap());
        let app = Router::new()
            .route("/api/auth/token", post(create_token))
            .with_state(Arc::clone(&store));

        let response = app
            .oneshot(
                Request::builder()
                    .method("POST")
                    .uri("/api/auth/token")
                    .header(header::CONTENT_TYPE, "application/json")
                    .extension(loopback())
                    .body(Body::from(r#"{"password":"correcthorsebatterystaple"}"#))
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
        assert_eq!(audit.auth_event, "token_issued");
        assert_eq!(audit.subject, SHARED_PASSWORD_SUBJECT);
        assert!(audit.token_id.is_some());

        let body = to_bytes(response.into_body(), usize::MAX)
            .await
            .expect("read body");
        let payload: serde_json::Value = serde_json::from_slice(&body).expect("json body");
        assert!(payload["token"].as_str().is_some());
        assert!(payload["expires_at"].as_str().is_some());
    }

    #[tokio::test]
    async fn revoke_token_response_sets_audit_context() {
        let store = Arc::new(TokenStore::new("correcthorsebatterystaple".to_string(), 24).unwrap());
        let issued = store.create_token("127.0.0.1", SHARED_PASSWORD_SUBJECT, TokenRole::Operator);
        let app = Router::new()
            .route("/api/auth/token", delete(revoke_token))
            .with_state(Arc::clone(&store));

        let response = app
            .oneshot(
                Request::builder()
                    .method("DELETE")
                    .uri("/api/auth/token")
                    .header(header::AUTHORIZATION, format!("Bearer {}", issued.token))
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
        assert_eq!(audit.auth_event, "token_revoked");
        assert_eq!(audit.subject, SHARED_PASSWORD_SUBJECT);
        assert_eq!(
            audit.token_id.as_deref(),
            Some(issued.audit.token_id.as_str())
        );
    }
}
