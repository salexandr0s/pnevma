use std::path::PathBuf;

use axum::{
    body::Body,
    extract::Request,
    http::StatusCode,
    middleware::Next,
    response::{IntoResponse, Response},
    Router,
};
use tower_http::services::{ServeDir, ServeFile};

const DENIED_EXTENSIONS: &[&str] = &[".env", ".map", ".pem", ".key", ".p12", ".pfx"];

async fn deny_sensitive_extensions(req: Request<Body>, next: Next) -> Response {
    let path = req.uri().path();
    for ext in DENIED_EXTENSIONS {
        if path.ends_with(ext) {
            return StatusCode::NOT_FOUND.into_response();
        }
    }
    next.run(req).await
}

/// Build a router that serves the built Vite SPA from the given directory.
/// Falls back to `index.html` for client-side routing (SPA mode).
pub fn static_files_router(frontend_dir: PathBuf) -> Router {
    let index = frontend_dir.join("index.html");
    let serve_dir = ServeDir::new(&frontend_dir).not_found_service(ServeFile::new(index));

    Router::new()
        .fallback_service(serve_dir)
        .layer(axum::middleware::from_fn(deny_sensitive_extensions))
}
