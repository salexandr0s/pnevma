use axum::{body::Body, extract::State, http::Request, middleware::Next, response::Response};

/// Configuration for the security headers middleware.
#[derive(Clone)]
pub struct SecurityHeadersConfig {
    pub hsts_max_age: u64,
    pub tls_active: bool,
    pub serve_frontend: bool,
}

/// Add standard security headers to all responses.
pub async fn security_headers(
    State(config): State<SecurityHeadersConfig>,
    req: Request<Body>,
    next: Next,
) -> Response {
    let mut response = next.run(req).await;
    let headers = response.headers_mut();

    // Only set HSTS when TLS is active — sending it over plain HTTP is meaningless
    // and can confuse proxies.
    if config.tls_active {
        let hsts_value = format!("max-age={}; includeSubDomains", config.hsts_max_age);
        headers.insert(
            axum::http::header::STRICT_TRANSPORT_SECURITY,
            hsts_value.parse().expect("valid header value"),
        );
    }

    headers.insert(
        axum::http::header::X_CONTENT_TYPE_OPTIONS,
        "nosniff".parse().expect("valid header value"),
    );

    let csp = "default-src 'self'; script-src 'self'; style-src 'self'; connect-src 'self' wss:";
    headers.insert(
        axum::http::HeaderName::from_static("content-security-policy"),
        csp.parse().expect("valid header value"),
    );
    response
}

#[cfg(test)]
mod tests {
    use super::*;
    use axum::http::StatusCode;
    use axum::{routing::get, Router};
    use tower::ServiceExt;

    fn test_config(tls_active: bool, serve_frontend: bool) -> SecurityHeadersConfig {
        SecurityHeadersConfig {
            hsts_max_age: 86400,
            tls_active,
            serve_frontend,
        }
    }

    #[tokio::test]
    async fn security_headers_are_set_with_tls() {
        let config = test_config(true, false);
        let app = Router::new().route("/test", get(|| async { "ok" })).layer(
            axum::middleware::from_fn_with_state(config, security_headers),
        );

        let response = app
            .oneshot(Request::builder().uri("/test").body(Body::empty()).unwrap())
            .await
            .unwrap();

        assert_eq!(response.status(), StatusCode::OK);
        assert_eq!(
            response.headers().get("strict-transport-security").unwrap(),
            "max-age=86400; includeSubDomains"
        );
        assert_eq!(
            response.headers().get("x-content-type-options").unwrap(),
            "nosniff"
        );
        assert_eq!(
            response.headers().get("content-security-policy").unwrap(),
            "default-src 'self'; script-src 'self'; style-src 'self'; connect-src 'self' wss:"
        );
    }

    #[tokio::test]
    async fn hsts_omitted_when_tls_inactive() {
        let config = test_config(false, false);
        let app = Router::new().route("/test", get(|| async { "ok" })).layer(
            axum::middleware::from_fn_with_state(config, security_headers),
        );

        let response = app
            .oneshot(Request::builder().uri("/test").body(Body::empty()).unwrap())
            .await
            .unwrap();

        assert_eq!(response.status(), StatusCode::OK);
        assert!(
            response
                .headers()
                .get("strict-transport-security")
                .is_none(),
            "HSTS should not be set when TLS is inactive"
        );
        // Other headers should still be present
        assert_eq!(
            response.headers().get("x-content-type-options").unwrap(),
            "nosniff"
        );
    }

    #[tokio::test]
    async fn csp_uses_wss_only() {
        let config = test_config(true, true);
        let app = Router::new().route("/test", get(|| async { "ok" })).layer(
            axum::middleware::from_fn_with_state(config, security_headers),
        );

        let response = app
            .oneshot(Request::builder().uri("/test").body(Body::empty()).unwrap())
            .await
            .unwrap();

        let csp = response
            .headers()
            .get("content-security-policy")
            .unwrap()
            .to_str()
            .unwrap();
        assert!(csp.contains("wss:"), "CSP should include wss:: {csp}");
        // Ensure plain ws: is not allowed — only wss:
        let without_wss = csp.replace("wss:", "");
        assert!(
            !without_wss.contains("ws:"),
            "CSP should not include plain ws:: {csp}"
        );
    }
}
