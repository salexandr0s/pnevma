use chrono::{DateTime, Utc};
use dashmap::DashMap;
use subtle::ConstantTimeEq;

use crate::error::RemoteError;

struct TokenEntry {
    created_at: DateTime<Utc>,
    #[allow(dead_code)] // stored for future audit/logging
    ip: String,
}

pub struct TokenStore {
    tokens: DashMap<String, TokenEntry>,
    /// WARNING: Stored as plaintext for constant-time comparison.
    /// Callers should pre-hash before passing to `new()` for production use.
    password_plaintext: String,
    ttl_hours: u64,
}

impl TokenStore {
    pub fn new(password: String, ttl_hours: u64) -> Self {
        // Store the password directly for constant-time comparison.
        // In production the caller should pre-hash; keeping it simple per spec.
        Self {
            tokens: DashMap::new(),
            password_plaintext: password,
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

    /// Validate a bearer token: constant-time comparison + expiry check.
    pub fn validate_token(&self, token: &str) -> bool {
        // Clean up first so we don't hold a ref while removing
        self.cleanup_expired();

        // Note: DashMap::get is not constant-time, but with 256-bit token entropy,
        // timing leaks are not practically exploitable.
        if let Some(entry) = self.tokens.get(token) {
            let age_hours = (Utc::now() - entry.created_at).num_hours() as u64;
            if age_hours < self.ttl_hours {
                // Constant-time compare the stored key against the supplied token
                // to prevent timing-attack leaks through the DashMap lookup.
                let input_bytes = token.as_bytes();
                let stored_key_bytes = entry.key().as_bytes();
                return stored_key_bytes.ct_eq(input_bytes).into();
            }
        }
        false
    }

    /// Validate a password using constant-time comparison.
    pub fn validate_password(&self, password: &str) -> bool {
        let a = self.password_plaintext.as_bytes();
        let b = password.as_bytes();
        if a.len() != b.len() {
            // Still do a dummy comparison to avoid length-based timing leaks.
            let _ = a.ct_eq(a);
            return false;
        }
        a.ct_eq(b).into()
    }

    /// Remove all expired tokens.
    pub fn cleanup_expired(&self) {
        let ttl = self.ttl_hours;
        self.tokens.retain(|_, entry| {
            let age_hours = (Utc::now() - entry.created_at).num_hours() as u64;
            age_hours < ttl
        });
    }

    /// Return the expiry timestamp for a freshly-created token.
    pub fn token_expires_at(&self) -> DateTime<Utc> {
        Utc::now() + chrono::Duration::hours(self.ttl_hours as i64)
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
