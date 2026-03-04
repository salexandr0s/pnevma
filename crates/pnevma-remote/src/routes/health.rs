use axum::{http::StatusCode, response::IntoResponse, Json};
use serde_json::json;

/// GET /health — returns 200 OK with status info. No authentication required.
pub async fn health() -> impl IntoResponse {
    let version = env!("CARGO_PKG_VERSION");
    (StatusCode::OK, Json(json!({ "status": "ok", "version": version })))
}
