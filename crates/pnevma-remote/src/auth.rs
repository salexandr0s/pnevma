use crate::error::RemoteError;
use argon2::{
    self,
    password_hash::{rand_core::OsRng, SaltString},
    Argon2, PasswordHasher, PasswordVerifier,
};
use chrono::{DateTime, Utc};
use dashmap::DashMap;

struct TokenEntry {
    created_at: DateTime<Utc>,
    #[allow(dead_code)] // stored for future audit/logging
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

    /// Validate a bearer token: existence check + expiry check.
    ///
    /// NOTE: The DashMap lookup is not constant-time, but with 256-bit random
    /// tokens the timing difference is not practically exploitable — an attacker
    /// cannot meaningfully narrow the key space via timing.
    pub fn validate_token(&self, token: &str) -> bool {
        // Clean up first so we don't hold a ref while removing
        self.cleanup_expired();

        if let Some(entry) = self.tokens.get(token) {
            let age_hours = (Utc::now() - entry.created_at).num_hours() as u64;
            return age_hours < self.ttl_hours;
        }
        false
    }

    /// Validate a password using Argon2id verification (constant-time).
    pub fn validate_password(&self, password: &str) -> bool {
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
