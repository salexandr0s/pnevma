use crate::error::RemoteError;
use argon2::{
    self,
    password_hash::{rand_core::OsRng, SaltString},
    Argon2, PasswordHasher, PasswordVerifier,
};
use chrono::{DateTime, Utc};
use dashmap::DashMap;
use sha2::{Digest, Sha256};
use std::sync::Arc;

pub const SHARED_PASSWORD_SUBJECT: &str = "shared-password";

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct TokenAuditMetadata {
    pub subject: String,
    pub token_id: String,
}

#[derive(Debug, Clone)]
pub struct IssuedToken {
    pub token: String,
    pub expires_at: DateTime<Utc>,
    pub audit: TokenAuditMetadata,
}

struct TokenEntry {
    created_at: DateTime<Utc>,
    ip: String,
    subject: String,
    token_id: String,
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
    pub fn create_token(&self, ip: &str, subject: &str) -> IssuedToken {
        use rand::rngs::OsRng;
        use rand::RngCore;
        let mut bytes = [0u8; 32];
        OsRng.fill_bytes(&mut bytes);
        let token = hex::encode(bytes);
        let token_id = token_identifier(&token);
        self.tokens.insert(
            token.clone(),
            TokenEntry {
                created_at: Utc::now(),
                ip: ip.to_string(),
                subject: subject.to_string(),
                token_id: token_id.clone(),
            },
        );
        IssuedToken {
            token,
            expires_at: self.token_expires_at(),
            audit: TokenAuditMetadata {
                subject: subject.to_string(),
                token_id,
            },
        }
    }

    /// Validate a bearer token: existence check + expiry check + IP binding.
    ///
    /// NOTE: The DashMap lookup is not constant-time, but with 256-bit random
    /// tokens the timing difference is not practically exploitable — an attacker
    /// cannot meaningfully narrow the key space via timing.
    pub fn validate_token(&self, token: &str, request_ip: &str) -> Option<TokenAuditMetadata> {
        if let Some(entry) = self.tokens.get(token) {
            let age_secs = (Utc::now() - entry.created_at).num_seconds();
            let ttl_secs = self.ttl_hours as i64 * 3600;
            if age_secs >= ttl_secs {
                return None;
            }
            if entry.ip != request_ip {
                tracing::warn!(
                    token_ip = %entry.ip,
                    request_ip = %request_ip,
                    "token used from different IP than it was created from"
                );
                return None;
            }
            return Some(TokenAuditMetadata {
                subject: entry.subject.clone(),
                token_id: entry.token_id.clone(),
            });
        }
        None
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
    pub fn revoke_token(&self, token: &str) -> Option<TokenAuditMetadata> {
        self.tokens
            .remove(token)
            .map(|(_, entry)| TokenAuditMetadata {
                subject: entry.subject,
                token_id: entry.token_id,
            })
    }

    /// Revoke all tokens. Call this when the password is changed to ensure
    /// no previously-issued tokens remain valid.
    pub fn revoke_all_tokens(&self) {
        self.tokens.clear();
    }

    /// Return the expiry timestamp for a freshly-created token.
    pub fn token_expires_at(&self) -> DateTime<Utc> {
        Utc::now() + chrono::Duration::hours(self.ttl_hours as i64)
    }
}

fn token_identifier(token: &str) -> String {
    let digest = Sha256::digest(token.as_bytes());
    hex::encode(digest)[..12].to_string()
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
        let issued = ts.create_token("127.0.0.1", SHARED_PASSWORD_SUBJECT);
        let audit = ts
            .validate_token(&issued.token, "127.0.0.1")
            .expect("issued token must validate");
        assert_eq!(audit.subject, SHARED_PASSWORD_SUBJECT);
        assert_eq!(audit.token_id, issued.audit.token_id);
    }

    #[test]
    fn unknown_token_is_rejected() {
        let ts = store();
        assert!(ts.validate_token("notarealtoken", "127.0.0.1").is_none());
    }

    #[test]
    fn revoked_token_is_rejected() {
        let ts = store();
        let issued = ts.create_token("127.0.0.1", SHARED_PASSWORD_SUBJECT);
        let revoked = ts
            .revoke_token(&issued.token)
            .expect("token should be revoked");
        assert_eq!(revoked.token_id, issued.audit.token_id);
        assert!(ts.validate_token(&issued.token, "127.0.0.1").is_none());
    }

    #[test]
    fn revoke_nonexistent_token_returns_false() {
        let ts = store();
        assert!(ts.revoke_token("doesnotexist").is_none());
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
        let token = ts.create_token("127.0.0.1", SHARED_PASSWORD_SUBJECT);
        // age_secs (0) >= ttl_secs (0), so token is invalid
        assert!(ts.validate_token(&token.token, "127.0.0.1").is_none());
    }

    #[test]
    fn token_expires_at_is_in_future() {
        let ts = store();
        assert!(ts.token_expires_at() > Utc::now());
    }

    #[test]
    fn cleanup_expired_removes_zero_ttl_tokens() {
        let ts = TokenStore::new("pass".to_string(), 0);
        let token = ts.create_token("127.0.0.1", SHARED_PASSWORD_SUBJECT);
        ts.cleanup_expired();
        assert!(!ts.tokens.contains_key(&token.token));
    }

    #[test]
    fn multiple_tokens_can_coexist() {
        let ts = store();
        let t1 = ts.create_token("10.0.0.1", SHARED_PASSWORD_SUBJECT);
        let t2 = ts.create_token("10.0.0.2", SHARED_PASSWORD_SUBJECT);
        assert!(ts.validate_token(&t1.token, "10.0.0.1").is_some());
        assert!(ts.validate_token(&t2.token, "10.0.0.2").is_some());
        assert_ne!(t1.token, t2.token);
        assert_ne!(t1.audit.token_id, t2.audit.token_id);
    }

    #[test]
    fn token_rejected_from_different_ip() {
        let ts = store();
        let token = ts.create_token("10.0.0.1", SHARED_PASSWORD_SUBJECT);
        assert!(ts.validate_token(&token.token, "10.0.0.1").is_some());
        assert!(ts.validate_token(&token.token, "192.168.1.1").is_none());
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

    #[test]
    fn token_identifier_does_not_expose_raw_token_prefix() {
        let ts = store();
        let issued = ts.create_token("127.0.0.1", SHARED_PASSWORD_SUBJECT);
        assert_ne!(
            issued.audit.token_id,
            issued.token[..12].to_string(),
            "audit identifier should not be a raw token prefix"
        );
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
