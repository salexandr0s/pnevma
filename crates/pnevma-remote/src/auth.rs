use crate::error::RemoteError;
use argon2::{
    self,
    password_hash::{rand_core::OsRng, SaltString},
    Argon2, PasswordHasher, PasswordVerifier,
};
use chrono::{DateTime, Utc};
use dashmap::DashMap;
use std::sync::Arc;

struct TokenEntry {
    created_at: DateTime<Utc>,
    ip: String,
}

pub struct TokenStore {
    tokens: DashMap<String, TokenEntry>,
    /// Password stored as an Argon2id PHC string. Verification is constant-time
    /// via the argon2 crate's `verify_password`.
    password_hash: String,
    ttl_hours: u64,
}

impl TokenStore {
    pub fn new(password: String, ttl_hours: u64) -> Self {
        let salt = SaltString::generate(&mut OsRng);
        let argon2 = Argon2::default();
        let password_hash = argon2
            .hash_password(password.as_bytes(), &salt)
            .expect("failed to hash password")
            .to_string();
        Self {
            tokens: DashMap::new(),
            password_hash,
            ttl_hours,
        }
    }

    /// Generate a 256-bit random hex token, store it, and return it.
    pub fn create_token(&self, ip: &str) -> String {
        use rand::RngCore;
        let mut bytes = [0u8; 32];
        rand::thread_rng().fill_bytes(&mut bytes);
        let token = hex::encode(bytes);
        self.tokens.insert(
            token.clone(),
            TokenEntry {
                created_at: Utc::now(),
                ip: ip.to_string(),
            },
        );
        token
    }

    /// Validate a bearer token: existence check + expiry check + IP binding.
    ///
    /// NOTE: The DashMap lookup is not constant-time, but with 256-bit random
    /// tokens the timing difference is not practically exploitable — an attacker
    /// cannot meaningfully narrow the key space via timing.
    pub fn validate_token(&self, token: &str, request_ip: &str) -> bool {
        if let Some(entry) = self.tokens.get(token) {
            let age_secs = (Utc::now() - entry.created_at).num_seconds();
            let ttl_secs = self.ttl_hours as i64 * 3600;
            if age_secs >= ttl_secs {
                return false;
            }
            if entry.ip != request_ip {
                tracing::warn!(
                    token_ip = %entry.ip,
                    request_ip = %request_ip,
                    "token used from different IP than it was created from"
                );
                return false;
            }
            return true;
        }
        false
    }

    /// Validate a password using Argon2id verification (constant-time).
    pub fn validate_password(&self, password: &str) -> bool {
        const MAX_PASSWORD_LEN: usize = 128;
        if password.len() > MAX_PASSWORD_LEN {
            tracing::warn!(
                "password exceeds maximum length of {} bytes",
                MAX_PASSWORD_LEN
            );
            return false;
        }
        use argon2::PasswordHash;
        let parsed_hash = match PasswordHash::new(&self.password_hash) {
            Ok(h) => h,
            Err(_) => return false,
        };
        Argon2::default()
            .verify_password(password.as_bytes(), &parsed_hash)
            .is_ok()
    }

    /// Remove all expired tokens.
    pub fn cleanup_expired(&self) {
        let ttl_secs = self.ttl_hours as i64 * 3600;
        self.tokens.retain(|_, entry| {
            let age_secs = (Utc::now() - entry.created_at).num_seconds();
            age_secs < ttl_secs
        });
    }

    /// Spawn a background task that evicts expired tokens every 5 minutes.
    pub fn spawn_cleanup(self: &Arc<Self>) {
        let store = Arc::clone(self);
        tokio::spawn(async move {
            let mut interval = tokio::time::interval(std::time::Duration::from_secs(300));
            loop {
                interval.tick().await;
                store.cleanup_expired();
            }
        });
    }

    /// Revoke a token by removing it from the store.
    /// Returns `true` if the token existed and was removed.
    pub fn revoke_token(&self, token: &str) -> bool {
        self.tokens.remove(token).is_some()
    }

    /// Return the expiry timestamp for a freshly-created token.
    pub fn token_expires_at(&self) -> DateTime<Utc> {
        Utc::now() + chrono::Duration::hours(self.ttl_hours as i64)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn store() -> TokenStore {
        TokenStore::new("correcthorsebatterystaple".to_string(), 24)
    }

    #[test]
    fn valid_token_validates() {
        let ts = store();
        let token = ts.create_token("127.0.0.1");
        assert!(ts.validate_token(&token, "127.0.0.1"));
    }

    #[test]
    fn unknown_token_is_rejected() {
        let ts = store();
        assert!(!ts.validate_token("notarealtoken", "127.0.0.1"));
    }

    #[test]
    fn revoked_token_is_rejected() {
        let ts = store();
        let token = ts.create_token("127.0.0.1");
        assert!(ts.revoke_token(&token));
        assert!(!ts.validate_token(&token, "127.0.0.1"));
    }

    #[test]
    fn revoke_nonexistent_token_returns_false() {
        let ts = store();
        assert!(!ts.revoke_token("doesnotexist"));
    }

    #[test]
    fn correct_password_validates() {
        let ts = store();
        assert!(ts.validate_password("correcthorsebatterystaple"));
    }

    #[test]
    fn wrong_password_is_rejected() {
        let ts = store();
        assert!(!ts.validate_password("wrongpassword"));
    }

    #[test]
    fn expired_token_ttl_zero_is_rejected() {
        // TTL of 0 hours means tokens expire immediately.
        let ts = TokenStore::new("pass".to_string(), 0);
        let token = ts.create_token("127.0.0.1");
        // age_secs (0) >= ttl_secs (0), so token is invalid
        assert!(!ts.validate_token(&token, "127.0.0.1"));
    }

    #[test]
    fn token_expires_at_is_in_future() {
        let ts = store();
        assert!(ts.token_expires_at() > Utc::now());
    }

    #[test]
    fn cleanup_expired_removes_zero_ttl_tokens() {
        let ts = TokenStore::new("pass".to_string(), 0);
        let token = ts.create_token("127.0.0.1");
        ts.cleanup_expired();
        assert!(!ts.tokens.contains_key(&token));
    }

    #[test]
    fn multiple_tokens_can_coexist() {
        let ts = store();
        let t1 = ts.create_token("10.0.0.1");
        let t2 = ts.create_token("10.0.0.2");
        assert!(ts.validate_token(&t1, "10.0.0.1"));
        assert!(ts.validate_token(&t2, "10.0.0.2"));
        assert_ne!(t1, t2);
    }

    #[test]
    fn token_rejected_from_different_ip() {
        let ts = store();
        let token = ts.create_token("10.0.0.1");
        assert!(ts.validate_token(&token, "10.0.0.1"));
        assert!(!ts.validate_token(&token, "192.168.1.1"));
    }

    #[test]
    fn oversized_password_is_rejected() {
        let ts = store();
        let long_password = "a".repeat(129);
        assert!(!ts.validate_password(&long_password));
    }

    #[test]
    fn max_length_password_is_accepted() {
        // Create a store with a 128-char password
        let password = "b".repeat(128);
        let ts = TokenStore::new(password.clone(), 24);
        assert!(ts.validate_password(&password));
    }
}

/// Error returned by token validation middleware.
#[derive(Debug)]
pub struct AuthError(pub String);

impl std::fmt::Display for AuthError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "auth error: {}", self.0)
    }
}

impl From<AuthError> for RemoteError {
    fn from(e: AuthError) -> Self {
        RemoteError::Auth(e.0)
    }
}
