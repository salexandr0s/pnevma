use crate::error::RemoteError;
use argon2::{
    self,
    password_hash::{rand_core::OsRng, SaltString},
    Argon2, PasswordHasher, PasswordVerifier,
};
use chrono::{DateTime, Utc};
use dashmap::DashMap;
use sha2::{Digest, Sha256};
use sqlx::SqlitePool;
use std::path::Path;
use std::sync::Arc;
use tokio::sync::OnceCell;

pub const SHARED_PASSWORD_SUBJECT: &str = "shared-password";

/// Access role assigned to a bearer token.
#[derive(Debug, Clone, Copy, PartialEq, Eq, serde::Serialize, serde::Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum TokenRole {
    /// Can read state but cannot mutate (create tasks, dispatch, etc.)
    ReadOnly,
    /// Full access to all allowed RPC methods.
    Operator,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct TokenAuditMetadata {
    pub subject: String,
    pub token_id: String,
    pub role: TokenRole,
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
    role: TokenRole,
}

pub struct TokenStore {
    tokens: DashMap<String, TokenEntry>,
    /// Password stored as an Argon2id PHC string. Verification is constant-time
    /// via the argon2 crate's `verify_password`.
    password_hash: String,
    ttl_hours: u64,
    /// Optional SQLite pool for persisting token lifecycle audit events.
    /// Initialized once at startup via `set_audit_db`.
    audit_db: OnceCell<SqlitePool>,
}

impl TokenStore {
    pub fn new(password: String, ttl_hours: u64) -> Result<Self, RemoteError> {
        let salt = SaltString::generate(&mut OsRng);
        let argon2 = Argon2::default();
        let password_hash = argon2
            .hash_password(password.as_bytes(), &salt)
            .map_err(|e| RemoteError::Auth(format!("failed to hash password: {e}")))?
            .to_string();
        Ok(Self {
            tokens: DashMap::new(),
            password_hash,
            ttl_hours,
            audit_db: OnceCell::new(),
        })
    }

    /// Set the audit DB pool. Can only be called once.
    pub async fn set_audit_db(&self, pool: SqlitePool) {
        let _ = self.audit_db.set(pool);
    }

    /// Fire-and-forget an audit insert.
    fn log_audit_event(
        &self,
        event: &str,
        token_id_hash: &str,
        subject: &str,
        ip: &str,
        role: TokenRole,
    ) {
        let Some(pool) = self.audit_db.get().cloned() else {
            return;
        };
        let event = event.to_string();
        let token_id_hash = token_id_hash.to_string();
        let subject = subject.to_string();
        let ip = ip.to_string();
        let role_str = format!("{role:?}");
        let timestamp = Utc::now().to_rfc3339();
        tokio::spawn(async move {
            let result = sqlx::query(
                "INSERT INTO token_audit_log (timestamp, event, token_id_hash, subject, ip, role) \
                 VALUES (?, ?, ?, ?, ?, ?)",
            )
            .bind(&timestamp)
            .bind(&event)
            .bind(&token_id_hash)
            .bind(&subject)
            .bind(&ip)
            .bind(&role_str)
            .execute(&pool)
            .await;
            if let Err(e) = result {
                tracing::warn!(error = %e, audit_event = %event, "failed to write token audit event");
            }
        });
    }

    /// Generate a 256-bit random hex token, store it, and return it.
    pub fn create_token(&self, ip: &str, subject: &str, role: TokenRole) -> IssuedToken {
        use rand::rngs::OsRng;
        use rand::RngCore;
        let mut bytes = [0u8; 32];
        OsRng.fill_bytes(&mut bytes);
        let token = hex::encode(bytes);
        let token_hash = token_lookup_key(&token);
        let token_id = token_identifier(&token_hash);
        self.tokens.insert(
            token_hash,
            TokenEntry {
                created_at: Utc::now(),
                ip: ip.to_string(),
                subject: subject.to_string(),
                token_id: token_id.clone(),
                role,
            },
        );
        self.log_audit_event("create", &token_id, subject, ip, role);
        IssuedToken {
            token,
            expires_at: self.token_expires_at(),
            audit: TokenAuditMetadata {
                subject: subject.to_string(),
                token_id,
                role,
            },
        }
    }

    /// Validate a bearer token: existence check + expiry check + IP binding.
    pub fn validate_token(&self, token: &str, request_ip: &str) -> Option<TokenAuditMetadata> {
        let token_key = token_lookup_key(token);
        if let Some(entry) = self.tokens.get(&token_key) {
            let age_secs = (Utc::now() - entry.created_at).num_seconds();
            let ttl_secs = self.ttl_hours as i64 * 3600;
            if age_secs >= ttl_secs {
                self.log_audit_event(
                    "validate_fail_expired",
                    &entry.token_id,
                    &entry.subject,
                    request_ip,
                    entry.role,
                );
                return None;
            }
            if entry.ip != request_ip {
                tracing::warn!(
                    token_ip = %entry.ip,
                    request_ip = %request_ip,
                    "token used from different IP than it was created from"
                );
                self.log_audit_event(
                    "validate_fail_ip",
                    &entry.token_id,
                    &entry.subject,
                    request_ip,
                    entry.role,
                );
                return None;
            }
            self.log_audit_event(
                "validate_ok",
                &entry.token_id,
                &entry.subject,
                request_ip,
                entry.role,
            );
            return Some(TokenAuditMetadata {
                subject: entry.subject.clone(),
                token_id: entry.token_id.clone(),
                role: entry.role,
            });
        }
        let probe_id = token_identifier(&token_key);
        self.log_audit_event(
            "validate_fail_unknown",
            &probe_id,
            "unknown",
            request_ip,
            TokenRole::ReadOnly,
        );
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
        let before = self.tokens.len();
        self.tokens.retain(|_, entry| {
            let age_secs = (Utc::now() - entry.created_at).num_seconds();
            age_secs < ttl_secs
        });
        let evicted = before.saturating_sub(self.tokens.len());
        if evicted > 0 {
            self.log_audit_event(
                "cleanup_expired",
                &format!("count:{evicted}"),
                "system",
                "",
                TokenRole::ReadOnly,
            );
        }
    }

    /// Spawn a background task that evicts expired tokens every 5 minutes.
    ///
    /// The task runs until `shutdown` is cancelled, allowing clean termination
    /// during server shutdown.
    pub fn spawn_cleanup(self: &Arc<Self>, shutdown: tokio::sync::watch::Receiver<bool>) {
        let store = Arc::clone(self);
        let mut shutdown = shutdown;
        tokio::spawn(async move {
            let mut interval = tokio::time::interval(std::time::Duration::from_secs(300));
            loop {
                tokio::select! {
                    _ = interval.tick() => {
                        store.cleanup_expired();
                    }
                    _ = shutdown.changed() => {
                        tracing::debug!("token cleanup task shutting down");
                        // Final cleanup before exit
                        store.cleanup_expired();
                        return;
                    }
                }
            }
        });
    }

    /// Revoke a token by removing it from the store.
    /// Returns `true` if the token existed and was removed.
    pub fn revoke_token(&self, token: &str) -> Option<TokenAuditMetadata> {
        let token_key = token_lookup_key(token);
        let removed = self
            .tokens
            .remove(&token_key)
            .map(|(_, entry)| TokenAuditMetadata {
                subject: entry.subject,
                token_id: entry.token_id,
                role: entry.role,
            });
        if let Some(ref audit) = removed {
            self.log_audit_event("revoke", &audit.token_id, &audit.subject, "", audit.role);
        }
        removed
    }

    /// Revoke all tokens. Call this when the password is changed to ensure
    /// no previously-issued tokens remain valid.
    pub fn revoke_all_tokens(&self) {
        let count = self.tokens.len();
        self.tokens.clear();
        if count > 0 {
            self.log_audit_event(
                "revoke_all",
                &format!("count:{count}"),
                "system",
                "",
                TokenRole::ReadOnly,
            );
        }
    }

    /// Return the expiry timestamp for a freshly-created token.
    pub fn token_expires_at(&self) -> DateTime<Utc> {
        Utc::now() + chrono::Duration::hours(self.ttl_hours as i64)
    }
}

fn token_lookup_key(token: &str) -> String {
    hex::encode(Sha256::digest(token.as_bytes()))
}

fn token_identifier(token_key: &str) -> String {
    token_key[..12].to_string()
}

/// Open (or create) a SQLite database for token audit logging.
pub async fn open_audit_db(path: &Path) -> Result<SqlitePool, RemoteError> {
    if let Some(parent) = path.parent() {
        tokio::fs::create_dir_all(parent)
            .await
            .map_err(|e| RemoteError::Database(format!("failed to create audit db dir: {e}")))?;
    }
    let url = format!("sqlite:{}?mode=rwc", path.display());
    let pool = sqlx::sqlite::SqlitePoolOptions::new()
        .max_connections(2)
        .connect(&url)
        .await
        .map_err(|e| RemoteError::Database(format!("failed to open audit db: {e}")))?;
    sqlx::query(
        "CREATE TABLE IF NOT EXISTS token_audit_log (\
             id INTEGER PRIMARY KEY, \
             timestamp TEXT NOT NULL, \
             event TEXT NOT NULL, \
             token_id_hash TEXT NOT NULL, \
             subject TEXT NOT NULL, \
             ip TEXT NOT NULL, \
             role TEXT NOT NULL\
         )",
    )
    .execute(&pool)
    .await
    .map_err(|e| RemoteError::Database(format!("failed to create audit table: {e}")))?;
    // Add indexes for common query patterns
    sqlx::query("CREATE INDEX IF NOT EXISTS idx_audit_token ON token_audit_log(token_id_hash)")
        .execute(&pool)
        .await
        .map_err(|e| RemoteError::Database(format!("failed to create audit index: {e}")))?;
    sqlx::query("CREATE INDEX IF NOT EXISTS idx_audit_ts ON token_audit_log(timestamp)")
        .execute(&pool)
        .await
        .map_err(|e| RemoteError::Database(format!("failed to create audit index: {e}")))?;
    Ok(pool)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn store() -> TokenStore {
        TokenStore::new("correcthorsebatterystaple".to_string(), 24).unwrap()
    }

    #[test]
    fn valid_token_validates() {
        let ts = store();
        let issued = ts.create_token("127.0.0.1", SHARED_PASSWORD_SUBJECT, TokenRole::Operator);
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
        let issued = ts.create_token("127.0.0.1", SHARED_PASSWORD_SUBJECT, TokenRole::Operator);
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
        let ts = TokenStore::new("pass".to_string(), 0).unwrap();
        let token = ts.create_token("127.0.0.1", SHARED_PASSWORD_SUBJECT, TokenRole::Operator);
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
        let ts = TokenStore::new("pass".to_string(), 0).unwrap();
        let token = ts.create_token("127.0.0.1", SHARED_PASSWORD_SUBJECT, TokenRole::Operator);
        ts.cleanup_expired();
        assert!(!ts.tokens.contains_key(&token_lookup_key(&token.token)));
    }

    #[test]
    fn multiple_tokens_can_coexist() {
        let ts = store();
        let t1 = ts.create_token("10.0.0.1", SHARED_PASSWORD_SUBJECT, TokenRole::Operator);
        let t2 = ts.create_token("10.0.0.2", SHARED_PASSWORD_SUBJECT, TokenRole::Operator);
        assert!(ts.validate_token(&t1.token, "10.0.0.1").is_some());
        assert!(ts.validate_token(&t2.token, "10.0.0.2").is_some());
        assert_ne!(t1.token, t2.token);
        assert_ne!(t1.audit.token_id, t2.audit.token_id);
    }

    #[test]
    fn token_rejected_from_different_ip() {
        let ts = store();
        let token = ts.create_token("10.0.0.1", SHARED_PASSWORD_SUBJECT, TokenRole::Operator);
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
        let ts = TokenStore::new(password.clone(), 24).unwrap();
        assert!(ts.validate_password(&password));
    }

    #[test]
    fn token_identifier_does_not_expose_raw_token_prefix() {
        let ts = store();
        let issued = ts.create_token("127.0.0.1", SHARED_PASSWORD_SUBJECT, TokenRole::Operator);
        assert_ne!(
            issued.audit.token_id,
            issued.token[..12].to_string(),
            "audit identifier should not be a raw token prefix"
        );
    }

    #[test]
    fn raw_token_is_not_used_as_store_key() {
        let ts = store();
        let issued = ts.create_token("127.0.0.1", SHARED_PASSWORD_SUBJECT, TokenRole::Operator);
        assert!(!ts.tokens.contains_key(&issued.token));
        assert!(ts.tokens.contains_key(&token_lookup_key(&issued.token)));
    }

    #[tokio::test]
    async fn audit_trail_persists_lifecycle_events() {
        let dir = tempfile::tempdir().unwrap();
        let db_path = dir.path().join("audit.db");
        let pool = open_audit_db(&db_path).await.unwrap();

        let ts = store();
        ts.set_audit_db(pool.clone()).await;

        let issued = ts.create_token("10.0.0.1", SHARED_PASSWORD_SUBJECT, TokenRole::Operator);
        ts.validate_token(&issued.token, "10.0.0.1");
        ts.validate_token(&issued.token, "10.0.0.99");
        ts.validate_token("bogustoken", "10.0.0.1");
        ts.revoke_token(&issued.token);

        // Give spawned tasks time to complete.
        tokio::time::sleep(std::time::Duration::from_millis(200)).await;

        let rows: Vec<(String, String, String)> =
            sqlx::query_as("SELECT event, token_id_hash, subject FROM token_audit_log ORDER BY id")
                .fetch_all(&pool)
                .await
                .unwrap();

        assert_eq!(
            rows.len(),
            5,
            "expected 5 audit events, got {}: {rows:?}",
            rows.len()
        );

        let events: Vec<&str> = rows.iter().map(|(e, _, _)| e.as_str()).collect();
        assert!(events.contains(&"create"), "missing create event");
        assert!(events.contains(&"validate_ok"), "missing validate_ok event");
        assert!(
            events.contains(&"validate_fail_ip"),
            "missing validate_fail_ip event"
        );
        assert!(
            events.contains(&"validate_fail_unknown"),
            "missing validate_fail_unknown event"
        );
        assert!(events.contains(&"revoke"), "missing revoke event");

        let unknown_row = rows
            .iter()
            .find(|(e, _, _)| e == "validate_fail_unknown")
            .unwrap();
        assert_eq!(unknown_row.2, "unknown");
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
