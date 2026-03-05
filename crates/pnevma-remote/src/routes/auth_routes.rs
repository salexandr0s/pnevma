use std::sync::Arc;

use axum::{
    extract::State,
    http::{HeaderMap, StatusCode},
    response::IntoResponse,
    Json,
};
use serde::{Deserialize, Serialize};

use crate::auth::TokenStore;

#[derive(Debug, Deserialize)]
pub struct TokenRequest {
    pub password: String,
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

    let token = store.create_token(&addr.ip().to_string());
    let expires_at = store.token_expires_at().to_rfc3339();

    tracing::info!(remote_ip = %addr.ip(), "Token issued");

    (
        StatusCode::OK,
        Json(serde_json::json!({
            "token": token,
            "expires_at": expires_at,
        })),
    )
        .into_response()
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
        Some(t) if store.revoke_token(t) => {
            (StatusCode::OK, Json(serde_json::json!({ "revoked": true }))).into_response()
        }
        Some(_) => (
            StatusCode::NOT_FOUND,
            Json(serde_json::json!({ "error": "token not found" })),
        )
            .into_response(),
        None => (
            StatusCode::BAD_REQUEST,
            Json(serde_json::json!({ "error": "missing Authorization: Bearer <token>" })),
        )
            .into_response(),
    }
}
