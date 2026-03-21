use std::collections::HashSet;

const BASE_ENV_VARS: &[&str] = &[
    "PATH", "HOME", "SHELL", "TERM", "USER", "LANG", "LC_ALL", "TMPDIR",
];
const BLOCKED_PREFIXES: &[&str] = &["DYLD_", "LD_"];
const BLOCKED_EXACT_NAMES: &[&str] = &[
    "APPLE_SIGNING_IDENTITY",
    "APPLE_NOTARY_PROFILE",
    "APP_STORE_CONNECT_API_KEY",
    "APP_STORE_CONNECT_API_KEY_ID",
    "APP_STORE_CONNECT_ISSUER_ID",
    "AC_PASSWORD",
    "AC_USERNAME",
    "NOTARYTOOL_KEY",
    "NOTARYTOOL_KEY_ID",
    "NOTARYTOOL_ISSUER",
    "GITHUB_TOKEN",
    "GH_TOKEN",
    "ANTHROPIC_API_KEY",
    "OPENAI_API_KEY",
    // Shell/runtime code execution vectors
    "BASH_ENV",
    "ENV",
    "CDPATH",
    "PERL5OPT",
    "PERL5LIB",
    "PYTHONSTARTUP",
    "PYTHONPATH",
    "RUBYOPT",
    "NODE_OPTIONS",
    "NODE_EXTRA_CA_CERTS",
    // Additional credential leakage prevention
    "GITLAB_TOKEN",
    "GITLAB_ACCESS_TOKEN",
    "STRIPE_API_KEY",
    "STRIPE_SECRET_KEY",
    "AWS_SECRET_ACCESS_KEY",
    "AWS_SESSION_TOKEN",
];

/// Allowlist of extra env names that may reach agent processes at spawn time.
const ALLOWED_EXTRA_ENV_NAMES: &[&str] = &[
    "PNEVMA_LOG_LEVEL",
    "PNEVMA_DEBUG",
    "NODE_ENV",
    "RUST_LOG",
    "RUST_BACKTRACE",
    "FORCE_COLOR",
    "NO_COLOR",
    "CI",
    "DATABASE_URL",
    "REDIS_URL",
    "API_ENDPOINT",
    "API_BASE_URL",
    "SUPABASE_URL",
    "NEXT_PUBLIC_SUPABASE_URL",
];

/// Prefixes that are allowed in addition to the exact names above.
const ALLOWED_EXTRA_ENV_PREFIXES: &[&str] = &["TEST_", "STAGING_", "NEXT_PUBLIC_", "VITE_"];

pub const MAX_AGENT_ENV_NAME_BYTES: usize = 128;
pub const MAX_AGENT_ENV_VALUE_BYTES: usize = 16 * 1024;

fn default_base_env_value(name: &str) -> Option<&'static str> {
    match name {
        "PATH" => Some("/usr/bin:/bin:/usr/sbin:/sbin"),
        "SHELL" => Some("/bin/zsh"),
        "TERM" => Some("xterm-256color"),
        "LANG" | "LC_ALL" => Some("en_US.UTF-8"),
        _ => None,
    }
}

fn normalize_env_name(name: &str) -> String {
    name.to_ascii_uppercase()
}

fn reserved_agent_env_names() -> &'static [&'static str] {
    BASE_ENV_VARS
}

pub fn is_reserved_agent_env_name(name: &str) -> bool {
    let normalized = normalize_env_name(name);
    reserved_agent_env_names()
        .iter()
        .any(|candidate| normalized == *candidate)
}

pub fn is_blocked_agent_env_name(name: &str) -> bool {
    let normalized = normalize_env_name(name);
    if BLOCKED_EXACT_NAMES
        .iter()
        .any(|candidate| normalized == *candidate)
    {
        return true;
    }
    if BLOCKED_PREFIXES
        .iter()
        .any(|prefix| normalized.starts_with(prefix))
    {
        return true;
    }
    if normalized.starts_with("PNEVMA_") {
        let sensitive_suffixes = [
            "_PASSWORD",
            "_SECRET",
            "_TOKEN",
            "_API_KEY",
            "_KEY",
            "_CREDENTIAL",
        ];
        if sensitive_suffixes.iter().any(|s| normalized.ends_with(s)) {
            return true;
        }
    }
    false
}

pub fn validate_agent_env_name(name: &str) -> Result<(), String> {
    if name.is_empty() {
        return Err("environment variable name must not be empty".to_string());
    }
    if name.len() > MAX_AGENT_ENV_NAME_BYTES {
        return Err(format!(
            "environment variable name exceeds {MAX_AGENT_ENV_NAME_BYTES} bytes"
        ));
    }

    let mut chars = name.chars();
    let Some(first) = chars.next() else {
        return Err("environment variable name must not be empty".to_string());
    };
    if !(first.is_ascii_alphabetic() || first == '_') {
        return Err("environment variable name must start with an ASCII letter or '_'".to_string());
    }
    if !chars.all(|ch| ch.is_ascii_alphanumeric() || ch == '_') {
        return Err(
            "environment variable name must contain only ASCII letters, digits, or '_'".to_string(),
        );
    }
    if is_reserved_agent_env_name(name) {
        return Err(format!(
            "environment variable name {name:?} is reserved by the runtime"
        ));
    }
    if is_blocked_agent_env_name(name) {
        return Err(format!(
            "environment variable name {name:?} is blocked by the agent sandbox policy"
        ));
    }
    // Allowlist gate: only permitted names/prefixes reach agent processes.
    // Denylist above is retained as defense-in-depth.
    if !is_allowed_extra_env_name(name) {
        return Err(format!(
            "environment variable name {name:?} is not in the agent environment allowlist"
        ));
    }
    Ok(())
}

/// Check if a name matches the agent environment allowlist.
fn is_allowed_extra_env_name(name: &str) -> bool {
    let normalized = normalize_env_name(name);
    if ALLOWED_EXTRA_ENV_NAMES
        .iter()
        .any(|allowed| normalized == *allowed)
    {
        return true;
    }
    ALLOWED_EXTRA_ENV_PREFIXES
        .iter()
        .any(|prefix| normalized.starts_with(prefix))
}

/// Registration-time name validation: shape + denylist checks only (no allowlist).
/// Use this when storing secrets — the allowlist is enforced at spawn time, not registration.
pub fn validate_agent_env_name_for_registration(name: &str) -> Result<(), String> {
    if name.is_empty() {
        return Err("environment variable name must not be empty".to_string());
    }
    if name.len() > MAX_AGENT_ENV_NAME_BYTES {
        return Err(format!(
            "environment variable name exceeds {MAX_AGENT_ENV_NAME_BYTES} bytes"
        ));
    }

    let mut chars = name.chars();
    let Some(first) = chars.next() else {
        return Err("environment variable name must not be empty".to_string());
    };
    if !(first.is_ascii_alphabetic() || first == '_') {
        return Err("environment variable name must start with an ASCII letter or '_'".to_string());
    }
    if !chars.all(|ch| ch.is_ascii_alphanumeric() || ch == '_') {
        return Err(
            "environment variable name must contain only ASCII letters, digits, or '_'".to_string(),
        );
    }
    if is_reserved_agent_env_name(name) {
        return Err(format!(
            "environment variable name {name:?} is reserved by the runtime"
        ));
    }
    if is_blocked_agent_env_name(name) {
        return Err(format!(
            "environment variable name {name:?} is blocked by the agent sandbox policy"
        ));
    }
    Ok(())
}

/// Registration-time entry validation: shape + denylist + value checks (no allowlist).
pub fn validate_agent_env_entry_for_registration(name: &str, value: &str) -> Result<(), String> {
    validate_agent_env_name_for_registration(name)?;
    if value.len() > MAX_AGENT_ENV_VALUE_BYTES {
        return Err(format!(
            "environment variable {name:?} exceeds {MAX_AGENT_ENV_VALUE_BYTES} bytes"
        ));
    }
    if value.contains('\0') {
        return Err(format!("environment variable {name:?} contains a NUL byte"));
    }
    Ok(())
}

pub fn validate_agent_env_entry(name: &str, value: &str) -> Result<(), String> {
    validate_agent_env_name(name)?;
    if value.len() > MAX_AGENT_ENV_VALUE_BYTES {
        return Err(format!(
            "environment variable {name:?} exceeds {MAX_AGENT_ENV_VALUE_BYTES} bytes"
        ));
    }
    if value.contains('\0') {
        return Err(format!("environment variable {name:?} contains a NUL byte"));
    }
    Ok(())
}

fn read_base_env_value(name: &str) -> Option<String> {
    let value = std::env::var(name)
        .ok()
        .filter(|value| !value.is_empty() && !value.contains('\0'))
        .or_else(|| default_base_env_value(name).map(ToString::to_string))?;
    if value.len() > MAX_AGENT_ENV_VALUE_BYTES {
        tracing::warn!(
            name,
            "skipping oversized runtime environment variable while spawning agent"
        );
        return None;
    }
    Some(value)
}

pub fn build_agent_environment(extra_env: &[(String, String)]) -> Vec<(String, String)> {
    let mut out = Vec::new();
    let mut seen = HashSet::new();

    for name in BASE_ENV_VARS {
        if let Some(value) = read_base_env_value(name) {
            seen.insert((*name).to_string());
            out.push(((*name).to_string(), value));
        }
    }

    for (name, value) in extra_env {
        match validate_agent_env_entry(name, value) {
            Ok(()) => {}
            Err(ref error) if error.contains("not in the agent environment allowlist") => {
                tracing::warn!(
                    name,
                    %error,
                    "registered secret skipped at spawn time — name is not in the agent environment allowlist"
                );
                continue;
            }
            Err(error) => {
                tracing::warn!(name, %error, "skipping unsafe agent environment variable");
                continue;
            }
        }

        if !seen.insert(name.clone()) {
            tracing::warn!(name, "skipping duplicate agent environment variable");
            continue;
        }

        out.push((name.clone(), value.clone()));
    }

    out
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn rejects_blocked_and_reserved_names() {
        assert!(validate_agent_env_name("DYLD_INSERT_LIBRARIES").is_err());
        assert!(validate_agent_env_name("LD_PRELOAD").is_err());
        assert!(validate_agent_env_name("PNEVMA_REMOTE_PASSWORD").is_err());
        assert!(validate_agent_env_name("APPLE_NOTARY_PROFILE").is_err());
        assert!(validate_agent_env_name("PATH").is_err());
        assert!(validate_agent_env_name("GITHUB_TOKEN").is_err());
        assert!(validate_agent_env_name("GH_TOKEN").is_err());
        assert!(validate_agent_env_name("ANTHROPIC_API_KEY").is_err());
        assert!(validate_agent_env_name("OPENAI_API_KEY").is_err());
        // Shell/runtime code execution vectors
        assert!(is_blocked_agent_env_name("BASH_ENV"));
        assert!(is_blocked_agent_env_name("NODE_OPTIONS"));
        assert!(is_blocked_agent_env_name("PYTHONSTARTUP"));
        // Additional credential leakage prevention
        assert!(is_blocked_agent_env_name("AWS_SECRET_ACCESS_KEY"));
    }

    #[test]
    fn rejects_pnevma_sensitive_suffixes() {
        assert!(validate_agent_env_name("PNEVMA_REMOTE_PASSWORD").is_err());
        assert!(validate_agent_env_name("PNEVMA_DB_SECRET").is_err());
        assert!(validate_agent_env_name("PNEVMA_AUTH_TOKEN").is_err());
        assert!(validate_agent_env_name("PNEVMA_LINEAR_API_KEY").is_err());
        assert!(validate_agent_env_name("PNEVMA_SIGNING_KEY").is_err());
        assert!(validate_agent_env_name("PNEVMA_SERVICE_CREDENTIAL").is_err());
        // Non-sensitive PNEVMA_ vars should still pass
        assert!(validate_agent_env_name("PNEVMA_LOG_LEVEL").is_ok());
        assert!(validate_agent_env_name("PNEVMA_DEBUG").is_ok());
    }

    #[test]
    fn rejects_invalid_name_shapes() {
        assert!(validate_agent_env_name("").is_err());
        assert!(validate_agent_env_name("1BAD").is_err());
        assert!(validate_agent_env_name("BAD-NAME").is_err());
        assert!(validate_agent_env_name("BAD.NAME").is_err());
    }

    #[test]
    fn rejects_invalid_values() {
        let oversized = "x".repeat(MAX_AGENT_ENV_VALUE_BYTES + 1);
        assert!(validate_agent_env_entry("NODE_ENV", &oversized).is_err());
        assert!(validate_agent_env_entry("NODE_ENV", "abc\0def").is_err());
    }

    // ── Allowlist tests ─────────────────────────────────────────────────────

    #[test]
    fn allowlisted_name_passes() {
        assert!(validate_agent_env_name("NODE_ENV").is_ok());
        assert!(validate_agent_env_name("PNEVMA_LOG_LEVEL").is_ok());
        assert!(validate_agent_env_name("PNEVMA_DEBUG").is_ok());
        assert!(validate_agent_env_name("CI").is_ok());
        assert!(validate_agent_env_name("RUST_LOG").is_ok());
        assert!(validate_agent_env_name("DATABASE_URL").is_ok());
        assert!(validate_agent_env_name("FORCE_COLOR").is_ok());
        assert!(validate_agent_env_name("NO_COLOR").is_ok());
    }

    #[test]
    fn allowlisted_prefix_passes() {
        assert!(validate_agent_env_name("TEST_DB_URL").is_ok());
        assert!(validate_agent_env_name("STAGING_API_KEY_NAME").is_ok());
        assert!(validate_agent_env_name("NEXT_PUBLIC_APP_URL").is_ok());
        assert!(validate_agent_env_name("VITE_API_URL").is_ok());
    }

    #[test]
    fn unknown_extra_name_fails() {
        assert!(validate_agent_env_name("MY_CUSTOM_VAR").is_err());
        assert!(validate_agent_env_name("RANDOM_THING").is_err());
        assert!(validate_agent_env_name("FOO_BAR").is_err());
    }

    #[test]
    fn registration_permits_non_allowlisted_names() {
        // Registration-time: shape + denylist only, no allowlist
        assert!(validate_agent_env_name_for_registration("MY_CUSTOM_VAR").is_ok());
        assert!(validate_agent_env_name_for_registration("RANDOM_THING").is_ok());
        // But denylist still blocks
        assert!(validate_agent_env_name_for_registration("ANTHROPIC_API_KEY").is_err());
        assert!(validate_agent_env_name_for_registration("GITHUB_TOKEN").is_err());
        // And spawn-time blocks non-allowlisted
        assert!(validate_agent_env_name("MY_CUSTOM_VAR").is_err());
    }

    #[test]
    fn builds_safe_agent_environment() {
        let env = build_agent_environment(&[
            ("NODE_ENV".to_string(), "production".to_string()),
            ("PATH".to_string(), "/tmp/bin".to_string()),
            (
                "DYLD_INSERT_LIBRARIES".to_string(),
                "/tmp/libhack.dylib".to_string(),
            ),
            ("OPENAI_API_KEY".to_string(), "sk-test".to_string()),
            ("GITHUB_TOKEN".to_string(), "ghp_abc".to_string()),
            ("MY_CUSTOM_VAR".to_string(), "hello".to_string()),
        ]);

        assert!(env.iter().any(|(name, _)| name == "PATH"));
        assert!(env
            .iter()
            .any(|(name, value)| name == "NODE_ENV" && value == "production"));
        assert!(!env.iter().any(|(name, _)| name == "DYLD_INSERT_LIBRARIES"));
        assert!(!env.iter().any(|(name, _)| name == "OPENAI_API_KEY"));
        assert!(!env.iter().any(|(name, _)| name == "GITHUB_TOKEN"));
        // MY_CUSTOM_VAR is not allowlisted — should be skipped
        assert!(!env.iter().any(|(name, _)| name == "MY_CUSTOM_VAR"));
        assert_eq!(env.iter().filter(|(name, _)| name == "PATH").count(), 1);
    }

    #[test]
    fn duplicate_names_skipped() {
        let env = build_agent_environment(&[
            ("NODE_ENV".to_string(), "production".to_string()),
            ("NODE_ENV".to_string(), "development".to_string()),
        ]);
        assert_eq!(env.iter().filter(|(name, _)| name == "NODE_ENV").count(), 1);
        // First value wins
        assert!(env
            .iter()
            .any(|(name, value)| name == "NODE_ENV" && value == "production"));
    }

    #[test]
    fn oversized_values_fail() {
        let oversized = "x".repeat(MAX_AGENT_ENV_VALUE_BYTES + 1);
        assert!(validate_agent_env_entry_for_registration("NODE_ENV", &oversized).is_err());
    }
}
