use std::path::PathBuf;

use axum::Router;
use tower_http::services::{ServeDir, ServeFile};

/// Build a router that serves the built Vite SPA from the given directory.
/// Falls back to `index.html` for client-side routing (SPA mode).
pub fn static_files_router(frontend_dir: PathBuf) -> Router {
    let index = frontend_dir.join("index.html");
    let serve_dir = ServeDir::new(&frontend_dir).not_found_service(ServeFile::new(index));

    Router::new().fallback_service(serve_dir)
}
