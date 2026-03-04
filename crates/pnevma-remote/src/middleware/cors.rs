use tower_http::cors::{AllowHeaders, AllowMethods, AllowOrigin, CorsLayer};

/// Build a strict CORS layer that only allows Tailscale-local origins.
pub fn cors_layer(allowed_origins: Vec<String>) -> CorsLayer {
    use axum::http::{header, Method};

    let origins: Vec<_> = allowed_origins
        .iter()
        .filter_map(|o| o.parse().ok())
        .collect();

    CorsLayer::new()
        .allow_origin(if origins.is_empty() {
            AllowOrigin::exact("https://localhost".parse().unwrap())
        } else {
            AllowOrigin::list(origins)
        })
        .allow_methods(AllowMethods::list([
            Method::GET,
            Method::POST,
            Method::PUT,
            Method::DELETE,
            Method::OPTIONS,
        ]))
        .allow_headers(AllowHeaders::list([
            header::AUTHORIZATION,
            header::CONTENT_TYPE,
            header::ACCEPT,
        ]))
        .allow_credentials(false)
}
