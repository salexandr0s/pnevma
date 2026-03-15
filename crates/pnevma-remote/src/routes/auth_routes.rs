use std::net::IpAddr;
use std::sync::Arc;
use std::time::{Duration, Instant};

use axum::{
    extract::State,
    http::{HeaderMap, StatusCode},
    response::IntoResponse,
    Json,
};
use dashmap::DashMap;
use serde::{Deserialize, Serialize};

use crate::{
    auth::{TokenRole, TokenStore, SHARED_PASSWORD_SUBJECT},
    middleware::audit::AuditAuthContext,
};

// ---------------------------------------------------------------------------
// Login lockout constants
// ---------------------------------------------------------------------------

const LOCKOUT_THRESHOLD: u32 = 5;
const MAX_LOCKOUT_MINUTES: u64 = 15;
const LOCKOUT_EVICT_AFTER_MINS: u64 = 30;

// ---------------------------------------------------------------------------
// LoginLockoutState
// ---------------------------------------------------------------------------

#[derive(Clone)]
pub struct LoginLockoutState {
    attempts: Arc<DashMap<IpAddr, (u32, Instant)>>,
}

impl Default for LoginLockoutState {
    fn default() -> Self {
        Self::new()
    }
}

impl LoginLockoutState {
    pub fn new() -> Self {
        Self {
            attempts: Arc::new(DashMap::new()),
        }
    }

    /// Returns `Some(remaining_seconds)` if the IP is locked out.
    pub fn check_locked(&self, ip: IpAddr) -> Option<u64> {
        let entry = self.attempts.get(&ip)?;
        let (fails, last) = entry.value();
        if *fails < LOCKOUT_THRESHOLD {
            return None;
        }
        // Clamp exponent at 4 (where the cap kicks in) to avoid overflow.
        let exponent = (*fails - LOCKOUT_THRESHOLD).min(4);
        let lockout_secs = ((1u64 << exponent) * 60).min(MAX_LOCKOUT_MINUTES * 60);
        let elapsed = last.elapsed().as_secs();
        if elapsed < lockout_secs {
            Some(lockout_secs - elapsed)
        } else {
            None
        }
    }

    /// Atomically check lockout and record failure in one DashMap operation.
    ///
    /// Returns `Some(remaining_seconds)` if the IP was already locked out
    /// (failure NOT recorded), or `None` if the failure was recorded (not yet
    /// locked, or lockout expired).
    pub fn check_and_record_failure(&self, ip: IpAddr) -> Option<u64> {
        let now = Instant::now();
        let mut entry = self.attempts.entry(ip).or_insert((0, now));
        let (count, last) = entry.value_mut();

        // Reset if stale
        if last.elapsed().as_secs() > LOCKOUT_EVICT_AFTER_MINS * 60 {
            *count = 0;
        }

        // Check if currently locked out
        if *count >= LOCKOUT_THRESHOLD {
            let exponent = (*count - LOCKOUT_THRESHOLD).min(4);
            let lockout_secs = ((1u64 << exponent) * 60).min(MAX_LOCKOUT_MINUTES * 60);
            let elapsed = last.elapsed().as_secs();
            if elapsed < lockout_secs {
                return Some(lockout_secs - elapsed);
            }
            // Lockout expired — reset and allow this attempt
            *count = 0;
        }

        // Record the failure
        *count = count.saturating_add(1);
        *last = now;
        None
    }

    pub fn record_success(&self, ip: IpAddr) {
        self.attempts.remove(&ip);
    }

    pub fn spawn_cleanup(&self, mut shutdown: tokio::sync::watch::Receiver<bool>) {
        let attempts = self.attempts.clone();
        tokio::spawn(async move {
            let mut interval = tokio::time::interval(Duration::from_secs(300));
            loop {
                tokio::select! {
                    _ = interval.tick() => {
                        attempts.retain(|_, (_, last)| {
                            last.elapsed().as_secs() < LOCKOUT_EVICT_AFTER_MINS * 60
                        });
                    }
                    _ = shutdown.changed() => {
                        break;
                    }
                }
            }
        });
    }
}

// ---------------------------------------------------------------------------
// AuthState — composite state for auth routes
// ---------------------------------------------------------------------------

#[derive(Clone)]
pub struct AuthState {
    pub token_store: Arc<TokenStore>,
    pub lockout: LoginLockoutState,
}

impl axum::extract::FromRef<AuthState> for Arc<TokenStore> {
    fn from_ref(state: &AuthState) -> Self {
        state.token_store.clone()
    }
}

impl axum::extract::FromRef<AuthState> for LoginLockoutState {
    fn from_ref(state: &AuthState) -> Self {
        state.lockout.clone()
    }
}

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
///
/// Implements login-attempt lockout: after [`LOCKOUT_THRESHOLD`] consecutive
/// failures from the same IP, further attempts are rejected with 429 and a
/// `Retry-After` header. The password check always runs first to prevent a
/// timing oracle.
pub async fn create_token(
    State(store): State<Arc<TokenStore>>,
    State(lockout): State<LoginLockoutState>,
    axum::extract::ConnectInfo(addr): axum::extract::ConnectInfo<std::net::SocketAddr>,
    Json(body): Json<TokenRequest>,
) -> impl IntoResponse {
    // Always run the password check to prevent timing oracle.
    let password_valid = store.validate_password(&body.password);

    // Atomic check-and-record if password is wrong.
    if !password_valid {
        if let Some(retry_after) = lockout.check_and_record_failure(addr.ip()) {
            tracing::warn!(remote_ip = %addr.ip(), "Login attempt blocked by lockout");
            return (
                StatusCode::TOO_MANY_REQUESTS,
                [("retry-after", retry_after.to_string())],
                Json(serde_json::json!({ "error": "too many failed attempts" })),
            )
                .into_response();
        }
        tracing::warn!(remote_ip = %addr.ip(), "Failed authentication attempt");
        return (
            StatusCode::UNAUTHORIZED,
            Json(serde_json::json!({ "error": "invalid password" })),
        )
            .into_response();
    }

    // Password is correct — but check if IP is locked out first.
    if let Some(retry_after) = lockout.check_locked(addr.ip()) {
        tracing::warn!(remote_ip = %addr.ip(), "Correct password but IP is locked out");
        return (
            StatusCode::TOO_MANY_REQUESTS,
            [("retry-after", retry_after.to_string())],
            Json(serde_json::json!({ "error": "too many failed attempts" })),
        )
            .into_response();
    }

    lockout.record_success(addr.ip());

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

    fn test_auth_state(password: &str) -> AuthState {
        AuthState {
            token_store: Arc::new(TokenStore::new(password.to_string(), 24).unwrap()),
            lockout: LoginLockoutState::new(),
        }
    }

    #[tokio::test]
    async fn create_token_response_sets_audit_context() {
        let state = test_auth_state("correcthorsebatterystaple");
        let app = Router::new()
            .route("/api/auth/token", post(create_token))
            .with_state(state);

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
        let state = test_auth_state("correcthorsebatterystaple");
        let issued = state.token_store.create_token(
            "127.0.0.1",
            SHARED_PASSWORD_SUBJECT,
            TokenRole::Operator,
        );
        let app = Router::new()
            .route("/api/auth/token", delete(revoke_token))
            .with_state(state);

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

    // -----------------------------------------------------------------------
    // Lockout unit tests
    // -----------------------------------------------------------------------

    #[tokio::test]
    async fn lockout_blocks_after_threshold_failures() {
        let lockout = LoginLockoutState::new();
        let ip: IpAddr = "10.0.0.42".parse().unwrap();
        for _ in 0..4 {
            assert!(lockout.check_and_record_failure(ip).is_none());
        }
        // 5th failure triggers lockout
        assert!(lockout.check_and_record_failure(ip).is_none());
        // Now locked — next attempt returns remaining seconds
        assert!(lockout.check_and_record_failure(ip).is_some());
    }

    #[tokio::test]
    async fn lockout_success_resets_counter() {
        let lockout = LoginLockoutState::new();
        let ip: IpAddr = "10.0.0.43".parse().unwrap();
        for _ in 0..4 {
            lockout.check_and_record_failure(ip);
        }
        lockout.record_success(ip);
        lockout.check_and_record_failure(ip);
        assert!(lockout.check_locked(ip).is_none());
    }

    #[tokio::test]
    async fn lockout_ips_are_independent() {
        let lockout = LoginLockoutState::new();
        let ip1: IpAddr = "10.0.0.1".parse().unwrap();
        let ip2: IpAddr = "10.0.0.2".parse().unwrap();
        for _ in 0..6 {
            lockout.check_and_record_failure(ip1);
        }
        assert!(lockout.check_locked(ip1).is_some());
        assert!(lockout.check_locked(ip2).is_none());
    }

    #[tokio::test]
    async fn lockout_blocks_even_correct_password() {
        let state = test_auth_state("correcthorsebatterystaple");
        let app = Router::new()
            .route("/api/auth/token", post(create_token))
            .with_state(state.clone());
        let client_addr = SocketAddr::from(([10, 0, 0, 50], 1234));
        for _ in 0..6 {
            state.lockout.check_and_record_failure(client_addr.ip());
        }
        let response = app
            .oneshot(
                Request::builder()
                    .method("POST")
                    .uri("/api/auth/token")
                    .header(header::CONTENT_TYPE, "application/json")
                    .extension(ConnectInfo(client_addr))
                    .body(Body::from(r#"{"password":"correcthorsebatterystaple"}"#))
                    .expect("request"),
            )
            .await
            .expect("route response");
        assert_eq!(response.status(), StatusCode::TOO_MANY_REQUESTS);
        assert!(response.headers().get("retry-after").is_some());
    }
}
