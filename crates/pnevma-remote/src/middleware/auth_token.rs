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
    // Fall back to query param
    query_token.map(|t| t.to_string())
}
