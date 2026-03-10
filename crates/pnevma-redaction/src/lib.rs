use regex::Regex;
use serde_json::Value;
use std::collections::HashSet;
use std::sync::{OnceLock, RwLock};

const REDACTED: &str = "[REDACTED]";
const STREAM_REDACTION_TAIL_BYTES: usize = 256;

#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct RedactionConfig {
    pub extra_patterns: Vec<String>,
    pub enable_entropy_guard: bool,
}

#[derive(Debug, Clone, Default)]
struct RuntimeRedactionConfig {
    extra_patterns: Vec<Regex>,
    enable_entropy_guard: bool,
}

fn runtime_redaction_config() -> &'static RwLock<RuntimeRedactionConfig> {
    static CONFIG: OnceLock<RwLock<RuntimeRedactionConfig>> = OnceLock::new();
    CONFIG.get_or_init(|| RwLock::new(RuntimeRedactionConfig::default()))
}

fn compile_extra_patterns(patterns: &[String]) -> Result<Vec<Regex>, regex::Error> {
    patterns
        .iter()
        .map(|pattern| Regex::new(pattern))
        .collect::<Result<Vec<_>, _>>()
}

pub fn validate_runtime_redaction_config(config: &RedactionConfig) -> Result<(), regex::Error> {
    let _ = compile_extra_patterns(&config.extra_patterns)?;
    Ok(())
}

pub fn set_runtime_redaction_config(config: RedactionConfig) -> Result<(), regex::Error> {
    let compiled = compile_extra_patterns(&config.extra_patterns)?;
    *runtime_redaction_config()
        .write()
        .expect("redaction config lock poisoned") = RuntimeRedactionConfig {
        extra_patterns: compiled,
        enable_entropy_guard: config.enable_entropy_guard,
    };
    Ok(())
}

pub fn reset_runtime_redaction_config() {
    *runtime_redaction_config()
        .write()
        .expect("redaction config lock poisoned") = RuntimeRedactionConfig::default();
}

pub fn current_runtime_redaction_settings() -> RedactionConfig {
    let config = runtime_redaction_config()
        .read()
        .expect("redaction config lock poisoned")
        .clone();
    RedactionConfig {
        extra_patterns: config
            .extra_patterns
            .into_iter()
            .map(|regex| regex.as_str().to_string())
            .collect(),
        enable_entropy_guard: config.enable_entropy_guard,
    }
}

fn redaction_authorization_regex() -> &'static Regex {
    static RE: OnceLock<Regex> = OnceLock::new();
    RE.get_or_init(|| {
        Regex::new(r"(?i)(authorization\s*:\s*bearer\s+)[^\s]+")
            .expect("authorization redaction regex must compile")
    })
}

fn redaction_key_value_regex() -> &'static Regex {
    static RE: OnceLock<Regex> = OnceLock::new();
    RE.get_or_init(|| {
        Regex::new(
            r#"(?i)\b(api[_-]?key|token|secret|password)\b\s*[:=]\s*("[^"]*"|'[^']*'|[^\s,;]+)"#,
        )
        .expect("key-value redaction regex must compile")
    })
}

fn redaction_env_assignment_regex() -> &'static Regex {
    static RE: OnceLock<Regex> = OnceLock::new();
    RE.get_or_init(|| {
        Regex::new(
            r#"\b([A-Z][A-Z0-9_]*(?:TOKEN|PASSWORD|SECRET|API_KEY|PRIVATE_KEY|ACCESS_KEY|CLIENT_SECRET))\b\s*[:=]\s*("[^"]*"|'[^']*'|[^\s,;]+)"#,
        )
        .expect("env-assignment redaction regex must compile")
    })
}

fn redaction_aws_key_regex() -> &'static Regex {
    static RE: OnceLock<Regex> = OnceLock::new();
    RE.get_or_init(|| {
        Regex::new(r"AKIA[0-9A-Z]{16}").expect("AWS key redaction regex must compile")
    })
}

fn redaction_github_token_regex() -> &'static Regex {
    static RE: OnceLock<Regex> = OnceLock::new();
    RE.get_or_init(|| {
        Regex::new(r"(?:ghp_|gho_|ghu_|ghs_|ghr_|github_pat_)[A-Za-z0-9_]{36,255}")
            .expect("GitHub token redaction regex must compile")
    })
}

fn redaction_provider_token_regex() -> &'static Regex {
    static RE: OnceLock<Regex> = OnceLock::new();
    RE.get_or_init(|| {
        Regex::new(r"\bsk-[A-Za-z0-9][A-Za-z0-9_-]{19,}\b")
            .expect("provider token redaction regex must compile")
    })
}

fn redaction_slack_token_regex() -> &'static Regex {
    static RE: OnceLock<Regex> = OnceLock::new();
    RE.get_or_init(|| {
        Regex::new(r"xox[bpras]-[A-Za-z0-9\-]{10,}")
            .expect("Slack token redaction regex must compile")
    })
}

fn redaction_pem_regex() -> &'static Regex {
    static RE: OnceLock<Regex> = OnceLock::new();
    RE.get_or_init(|| {
        Regex::new(r"-----BEGIN (?:RSA |EC |DSA |OPENSSH )?PRIVATE KEY-----")
            .expect("PEM redaction regex must compile")
    })
}

fn redaction_connection_string_regex() -> &'static Regex {
    static RE: OnceLock<Regex> = OnceLock::new();
    RE.get_or_init(|| {
        Regex::new(r"://[^:]+:([^@]+)@").expect("connection string redaction regex must compile")
    })
}

fn redaction_entropy_assignment_regex() -> &'static Regex {
    static RE: OnceLock<Regex> = OnceLock::new();
    RE.get_or_init(|| {
        Regex::new(
            r#"(?i)\b([A-Z0-9_.-]*(?:key|token|secret|password)[A-Z0-9_.-]*)\b\s*[:=]\s*("[A-Za-z0-9+/=_-]{32,}"|'[A-Za-z0-9+/=_-]{32,}'|[A-Za-z0-9+/=_-]{32,})"#,
        )
        .expect("entropy-assignment redaction regex must compile")
    })
}

fn redaction_partial_authorization_regex() -> &'static Regex {
    static RE: OnceLock<Regex> = OnceLock::new();
    RE.get_or_init(|| {
        Regex::new(r"(?i)authorization\s*:\s*(?:(?:b|be|bea|bear|beare|bearer)(?:\s+[^\s]*)?)?$")
            .expect("partial authorization redaction regex must compile")
    })
}

fn redaction_partial_key_value_regex() -> &'static Regex {
    static RE: OnceLock<Regex> = OnceLock::new();
    RE.get_or_init(|| {
        Regex::new(
            r#"(?i)\b(api[_-]?key|token|secret|password)\b\s*[:=]\s*("[^"]*|'[^']*|[^\s,;]*)$"#,
        )
        .expect("partial key-value redaction regex must compile")
    })
}

fn redaction_partial_env_assignment_regex() -> &'static Regex {
    static RE: OnceLock<Regex> = OnceLock::new();
    RE.get_or_init(|| {
        Regex::new(
            r#"\b[A-Z][A-Z0-9_]*(?:TOKEN|PASSWORD|SECRET|API_KEY|PRIVATE_KEY|ACCESS_KEY|CLIENT_SECRET)\b\s*[:=]\s*("[^"]*|'[^']*|[^\s,;]*)$"#,
        )
        .expect("partial env-assignment redaction regex must compile")
    })
}

fn redaction_partial_aws_key_regex() -> &'static Regex {
    static RE: OnceLock<Regex> = OnceLock::new();
    RE.get_or_init(|| {
        Regex::new(r"AKIA[0-9A-Z]{0,15}$").expect("partial AWS key redaction regex must compile")
    })
}

fn redaction_partial_github_token_regex() -> &'static Regex {
    static RE: OnceLock<Regex> = OnceLock::new();
    RE.get_or_init(|| {
        Regex::new(r"(?:ghp_|gho_|ghu_|ghs_|ghr_|github_pat_)[A-Za-z0-9_]{0,255}$")
            .expect("partial GitHub token redaction regex must compile")
    })
}

fn redaction_partial_provider_token_regex() -> &'static Regex {
    static RE: OnceLock<Regex> = OnceLock::new();
    RE.get_or_init(|| {
        Regex::new(r"\bsk-[A-Za-z0-9_-]*$")
            .expect("partial provider token redaction regex must compile")
    })
}

fn redaction_partial_slack_token_regex() -> &'static Regex {
    static RE: OnceLock<Regex> = OnceLock::new();
    RE.get_or_init(|| {
        Regex::new(r"xox[bpras]-[A-Za-z0-9\-]*$")
            .expect("partial Slack token redaction regex must compile")
    })
}

fn redaction_partial_connection_string_regex() -> &'static Regex {
    static RE: OnceLock<Regex> = OnceLock::new();
    RE.get_or_init(|| {
        Regex::new(r"[A-Za-z][A-Za-z0-9+.-]*://[^:@\s]+:[^@\s]*$")
            .expect("partial connection string redaction regex must compile")
    })
}

fn redaction_partial_entropy_assignment_regex() -> &'static Regex {
    static RE: OnceLock<Regex> = OnceLock::new();
    RE.get_or_init(|| {
        Regex::new(
            r#"(?i)\b[A-Z0-9_.-]*(?:key|token|secret|password)[A-Z0-9_.-]*\b\s*[:=]\s*("[A-Za-z0-9+/=_-]*|'[A-Za-z0-9+/=_-]*|[A-Za-z0-9+/=_-]*)$"#,
        )
        .expect("partial entropy-assignment redaction regex must compile")
    })
}

fn current_runtime_redaction_config() -> RuntimeRedactionConfig {
    runtime_redaction_config()
        .read()
        .expect("redaction config lock poisoned")
        .clone()
}

fn redact_patterns(input: &str) -> String {
    let runtime_config = current_runtime_redaction_config();
    let mut result = redaction_authorization_regex()
        .replace_all(input, format!("$1{REDACTED}"))
        .to_string();
    result = redaction_key_value_regex()
        .replace_all(&result, format!("$1={REDACTED}"))
        .to_string();
    result = redaction_env_assignment_regex()
        .replace_all(&result, format!("$1={REDACTED}"))
        .to_string();
    result = redaction_aws_key_regex()
        .replace_all(&result, REDACTED)
        .to_string();
    result = redaction_github_token_regex()
        .replace_all(&result, REDACTED)
        .to_string();
    result = redaction_provider_token_regex()
        .replace_all(&result, REDACTED)
        .to_string();
    result = redaction_slack_token_regex()
        .replace_all(&result, REDACTED)
        .to_string();
    result = redaction_pem_regex()
        .replace_all(&result, REDACTED)
        .to_string();
    result = redaction_connection_string_regex()
        .replace_all(&result, format!("://{REDACTED}@"))
        .to_string();
    for regex in &runtime_config.extra_patterns {
        result = regex.replace_all(&result, REDACTED).to_string();
    }
    if runtime_config.enable_entropy_guard {
        result = redaction_entropy_assignment_regex()
            .replace_all(&result, format!("$1={REDACTED}"))
            .to_string();
    }
    result
}

fn partial_redaction_regexes(config: &RuntimeRedactionConfig) -> Vec<Regex> {
    let mut regexes = config.extra_patterns.clone();
    if config.enable_entropy_guard {
        regexes.push(redaction_partial_entropy_assignment_regex().clone());
    }
    regexes
}

pub fn redact_text(input: &str, secrets: &[String]) -> String {
    let mut redacted = redact_patterns(input);
    for secret in secrets {
        if secret.is_empty() {
            continue;
        }
        redacted = redacted.replace(secret, REDACTED);
    }
    redacted
}

pub fn normalize_secrets(secrets: &[String]) -> Vec<String> {
    let mut seen = HashSet::new();
    let mut normalized = secrets
        .iter()
        .filter(|secret| !secret.is_empty())
        .filter_map(|secret| {
            if seen.insert(secret.clone()) {
                Some(secret.clone())
            } else {
                None
            }
        })
        .collect::<Vec<_>>();
    normalized.sort_by(|a, b| b.len().cmp(&a.len()).then_with(|| a.cmp(b)));
    normalized
}

pub fn is_sensitive_json_key(key: &str) -> bool {
    let normalized = key.trim().replace('-', "_").to_ascii_lowercase();
    matches!(
        normalized.as_str(),
        "password"
            | "passphrase"
            | "token"
            | "access_token"
            | "refresh_token"
            | "bearer_token"
            | "secret"
            | "client_secret"
            | "secret_key"
            | "private_key"
            | "api_key"
            | "apikey"
            | "authorization"
    ) || normalized.ends_with("_token")
        || normalized.ends_with("_secret")
        || normalized.ends_with("_password")
        || normalized.ends_with("_api_key")
}

pub fn redact_json_value(value: Value, secrets: &[String]) -> Value {
    match value {
        Value::String(text) => Value::String(redact_text(&text, secrets)),
        Value::Array(items) => Value::Array(
            items
                .into_iter()
                .map(|item| redact_json_value(item, secrets))
                .collect(),
        ),
        Value::Object(map) => {
            let mut out = serde_json::Map::new();
            for (key, value) in map {
                if is_sensitive_json_key(&key) {
                    out.insert(key, Value::String(REDACTED.to_string()));
                } else {
                    out.insert(key, redact_json_value(value, secrets));
                }
            }
            Value::Object(out)
        }
        other => other,
    }
}

fn minimum_partial_match_bytes(literal: &str) -> usize {
    if literal.len() <= 4 {
        2
    } else {
        3
    }
}

fn partial_literal_start(
    input: &str,
    literal: &str,
    retain_full_match: bool,
    min_match_bytes: usize,
) -> Option<usize> {
    if input.is_empty() || literal.is_empty() {
        return None;
    }

    let mut retain_start = None;
    for (idx, _) in literal.char_indices().skip(1) {
        if idx < min_match_bytes {
            continue;
        }
        if input.ends_with(&literal[..idx]) {
            retain_start = Some(input.len() - idx);
        }
    }

    if retain_full_match && literal.len() >= min_match_bytes && input.ends_with(literal) {
        return Some(input.len() - literal.len());
    }

    retain_start
}

fn partial_redaction_start(input: &str, secrets: &[String]) -> Option<usize> {
    const PEM_PREFIX_MARKERS: &[&str] = &[
        "-----BEGIN ",
        "-----BEGIN RSA PRIVATE KEY-----",
        "-----BEGIN EC PRIVATE KEY-----",
        "-----BEGIN DSA PRIVATE KEY-----",
        "-----BEGIN OPENSSH PRIVATE KEY-----",
        "-----BEGIN PRIVATE KEY-----",
    ];

    let mut retain_start = None;

    for marker in PEM_PREFIX_MARKERS {
        let candidate =
            partial_literal_start(input, marker, false, minimum_partial_match_bytes(marker));
        if let Some(start) = candidate {
            retain_start = Some(retain_start.map_or(start, |current: usize| current.min(start)));
        }
    }

    for secret in secrets {
        if let Some(start) =
            partial_literal_start(input, secret, false, minimum_partial_match_bytes(secret))
        {
            retain_start = Some(retain_start.map_or(start, |current: usize| current.min(start)));
        }
    }

    for regex in [
        redaction_partial_authorization_regex(),
        redaction_partial_key_value_regex(),
        redaction_partial_env_assignment_regex(),
        redaction_partial_aws_key_regex(),
        redaction_partial_github_token_regex(),
        redaction_partial_provider_token_regex(),
        redaction_partial_slack_token_regex(),
        redaction_partial_connection_string_regex(),
    ] {
        if let Some(found) = regex.find(input) {
            retain_start = Some(
                retain_start.map_or(found.start(), |current: usize| current.min(found.start())),
            );
        }
    }

    let runtime_config = current_runtime_redaction_config();
    for regex in partial_redaction_regexes(&runtime_config) {
        if let Some(found) = regex.find(input) {
            retain_start = Some(
                retain_start.map_or(found.start(), |current: usize| current.min(found.start())),
            );
        }
    }

    retain_start
}

fn drain_to_retained_tail(input: &str, retain_bytes: usize) -> usize {
    if input.len() <= retain_bytes {
        return input.len();
    }

    let mut split_at = input.len() - retain_bytes;
    while split_at > 0 && !input.is_char_boundary(split_at) {
        split_at -= 1;
    }
    split_at
}

#[derive(Debug, Default, Clone)]
pub struct StreamRedactionBuffer {
    pending: String,
}

impl StreamRedactionBuffer {
    pub fn new() -> Self {
        Self::default()
    }

    pub fn push_chunk(&mut self, chunk: &str, secrets: &[String]) -> Option<String> {
        self.pending.push_str(chunk);
        self.drain(false, secrets)
    }

    pub fn finish(&mut self, secrets: &[String]) -> Option<String> {
        self.drain(true, secrets)
    }

    fn drain(&mut self, flush_all: bool, secrets: &[String]) -> Option<String> {
        if self.pending.is_empty() {
            return None;
        }

        let drain_to = if flush_all {
            self.pending.len()
        } else {
            let tail_boundary = drain_to_retained_tail(&self.pending, STREAM_REDACTION_TAIL_BYTES);
            partial_redaction_start(&self.pending, secrets).map_or(tail_boundary, |retain_start| {
                tail_boundary.min(retain_start)
            })
        };

        if drain_to == 0 {
            return None;
        }

        let chunk = self.pending[..drain_to].to_string();
        self.pending.replace_range(..drain_to, "");
        Some(redact_text(&chunk, secrets))
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::{Mutex, OnceLock};

    fn config_test_lock() -> &'static Mutex<()> {
        static LOCK: OnceLock<Mutex<()>> = OnceLock::new();
        LOCK.get_or_init(|| Mutex::new(()))
    }

    #[test]
    fn redacts_provider_token_standalone() {
        let input = "token sk-proj-abcdefghijklmnopqrstuvwxyz1234567890";
        let output = redact_text(input, &[]);
        assert!(!output.contains("sk-proj-"));
        assert!(output.contains(REDACTED));
    }

    #[test]
    fn redacts_anthropic_token_standalone() {
        let input = "token sk-ant-api03-abcdefghijklmnopqrstuvwxyz1234567890";
        let output = redact_text(input, &[]);
        assert!(!output.contains("sk-ant-api03-"));
        assert!(output.contains(REDACTED));
    }

    #[test]
    fn redacts_provider_env_assignment() {
        let input = r#"OPENAI_API_KEY="sk-ant-api03-abcdefghijklmnopqrstuvwxyz1234567890""#;
        let output = redact_text(input, &[]);
        assert!(!output.contains("sk-ant-api03-"));
        assert_eq!(output, "OPENAI_API_KEY=[REDACTED]");
    }

    #[test]
    fn redacts_json_string_values_and_sensitive_keys() {
        let output = redact_json_value(
            serde_json::json!({
                "message": "OPENAI_API_KEY=sk-proj-abcdefghijklmnopqrstuvwxyz1234567890",
                "token": "ghp_ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghij0123456789",
            }),
            &[],
        );
        let rendered = output.to_string();
        assert!(!rendered.contains("sk-proj-"));
        assert_eq!(output["token"], REDACTED);
    }

    #[test]
    fn stream_buffer_redacts_provider_token_split_across_chunks() {
        let mut buffer = StreamRedactionBuffer::new();

        let first = buffer
            .push_chunk("prefix sk-pr", &[])
            .expect("safe prefix should flush");
        assert_eq!(first, "prefix ");
        let second = buffer
            .push_chunk("oj-abcdefghijklmnopqrstuvwxyz1234567890 suffix", &[])
            .expect("provider token should flush once complete");
        assert_eq!(second, "[REDACTED] suffix");
    }

    #[test]
    fn stream_buffer_redacts_env_assignment_split_across_chunks() {
        let mut buffer = StreamRedactionBuffer::new();

        assert!(buffer
            .push_chunk(r#"OPENAI_API_KEY="sk-ant-api03-abcd"#, &[])
            .is_none());
        let second = buffer
            .push_chunk(r#"efghijklmnopqrstuvwxyz1234567890" done"#, &[])
            .expect("env assignment should flush once complete");
        assert_eq!(second, "OPENAI_API_KEY=[REDACTED] done");
    }

    #[test]
    fn stream_buffer_flushes_safe_text_immediately() {
        let mut buffer = StreamRedactionBuffer::new();
        let output = buffer
            .push_chunk("enter token\n", &[])
            .expect("safe text should flush");
        assert_eq!(output, "enter token\n");
    }

    #[test]
    fn normalize_secrets_prefers_longer_values_first() {
        let output =
            normalize_secrets(&["abc".to_string(), "abcdef".to_string(), "abc".to_string()]);
        assert_eq!(output, vec!["abcdef".to_string(), "abc".to_string()]);
    }

    #[test]
    fn short_provider_like_prefix_is_not_redacted() {
        let input = "debug value sk-proj-short";
        let output = redact_text(input, &[]);
        assert_eq!(output, input);
    }

    #[test]
    fn extra_patterns_redact_custom_secret_formats() {
        let _guard = config_test_lock().lock().unwrap();
        set_runtime_redaction_config(RedactionConfig {
            extra_patterns: vec![r"custom-secret-[A-Z0-9]{6}".to_string()],
            enable_entropy_guard: false,
        })
        .expect("config should compile");
        let output = redact_text("value=custom-secret-ABC123", &[]);
        assert_eq!(output, "value=[REDACTED]");
        reset_runtime_redaction_config();
    }

    #[test]
    fn entropy_guard_is_disabled_by_default() {
        let _guard = config_test_lock().lock().unwrap();
        reset_runtime_redaction_config();
        let input = "clientToken=ABCDEFGHIJKLMNOPQRSTUVWXYZ123456";
        assert_eq!(redact_text(input, &[]), input);
    }

    #[test]
    fn entropy_guard_redacts_long_token_assignments_when_enabled() {
        let _guard = config_test_lock().lock().unwrap();
        set_runtime_redaction_config(RedactionConfig {
            extra_patterns: vec![],
            enable_entropy_guard: true,
        })
        .expect("config should compile");
        let output = redact_text("clientToken=ABCDEFGHIJKLMNOPQRSTUVWXYZ123456", &[]);
        assert_eq!(output, "clientToken=[REDACTED]");
        reset_runtime_redaction_config();
    }
}
