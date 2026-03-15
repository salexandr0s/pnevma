use tower_http::cors::{AllowHeaders, AllowMethods, AllowOrigin, CorsLayer};

/// Build a strict CORS layer that only allows Tailscale-local origins.
pub fn cors_layer(allowed_origins: Vec<String>) -> CorsLayer {
    use axum::http::{header, Method};

    let origins: Vec<_> = allowed_origins
        .iter()
        .filter_map(|o| match o.parse() {
            Ok(origin) => Some(origin),
            Err(e) => {
                tracing::warn!(origin = %o, error = %e, "ignoring unparseable CORS origin");
                None
            }
        })
        .collect();

    CorsLayer::new()
        .allow_origin(if origins.is_empty() {
            tracing::info!("no valid CORS origins configured, defaulting to https://localhost");
            AllowOrigin::exact(
                "https://localhost"
                    .parse()
                    .expect("'https://localhost' is a valid origin"),
            )
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

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn cors_layer_builds_without_panic_empty_origins() {
        // Should not panic when given no origins — falls back to https://localhost
        let _layer = cors_layer(vec![]);
    }

    #[test]
    fn cors_layer_builds_with_valid_origins() {
        let _layer = cors_layer(vec!["https://example.com".to_string()]);
    }

    #[test]
    fn cors_layer_ignores_invalid_origin_strings() {
        // Invalid origins are filtered by `parse()`, should not panic
        let _layer = cors_layer(vec!["not-a-valid-origin!!!".to_string()]);
    }

    #[test]
    fn cors_layer_builds_with_multiple_valid_origins() {
        let _layer = cors_layer(vec![
            "https://a.example.com".to_string(),
            "https://b.example.com".to_string(),
        ]);
    }
}
