#![forbid(unsafe_code)]

use regex::Regex;
use serde_json::Value;
use std::borrow::Cow;
use std::collections::HashSet;
use std::sync::{OnceLock, RwLock};

const REDACTED: &str = "[REDACTED]";
const STREAM_REDACTION_TAIL_BYTES: usize = 8192;

/// Last time the built-in redaction patterns were reviewed and updated.
pub const PATTERNS_LAST_REVIEWED: &str = "2026-03-14";
const PEM_PRIVATE_KEY_LABELS: &[&str] = &[
    "RSA PRIVATE KEY",
    "EC PRIVATE KEY",
    "DSA PRIVATE KEY",
    "OPENSSH PRIVATE KEY",
    "ENCRYPTED PRIVATE KEY",
    "PRIVATE KEY",
];
const PEM_BEGIN_PREFIX: &str = "-----BEGIN ";
const PEM_END_PREFIX: &str = "-----END ";
const PEM_MARKER_SUFFIX: &str = "-----";
const PEM_KIND_REGEX_FRAGMENT: &str = "(?:RSA |EC |DSA |OPENSSH |ENCRYPTED )?";
const PEM_REGEX_SUFFIX: &str = "PRIVATE KEY-----";

#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct RedactionConfig {
    pub extra_patterns: Vec<String>,
    /// When `true`, assignments containing high-entropy strings (≥4.0 bits/char)
    /// are redacted even if they don't match a known pattern. Disabled by default
    /// to avoid false positives on legitimate high-entropy values (UUIDs, hashes,
    /// build IDs). Enable for environments where custom API token formats are in use.
    pub enable_entropy_guard: bool,
}

#[derive(Debug, Clone, Default)]
struct RuntimeRedactionConfig {
    extra_patterns: Vec<Regex>,
    /// When `true`, assignments containing high-entropy strings (≥4.0 bits/char)
    /// are redacted even if they don't match a known pattern. Disabled by default
    /// to avoid false positives on legitimate high-entropy values (UUIDs, hashes,
    /// build IDs). Enable for environments where custom API token formats are in use.
    enable_entropy_guard: bool,
}

fn runtime_redaction_config() -> &'static RwLock<RuntimeRedactionConfig> {
    static CONFIG: OnceLock<RwLock<RuntimeRedactionConfig>> = OnceLock::new();
    CONFIG.get_or_init(|| RwLock::new(RuntimeRedactionConfig::default()))
}

/// Max compiled regex size (64KB) to guard against ReDoS from user-supplied patterns.
const MAX_REGEX_SIZE_BYTES: usize = 1 << 16;

fn compile_extra_patterns(patterns: &[String]) -> Result<Vec<Regex>, regex::Error> {
    patterns
        .iter()
        .map(|pattern| {
            regex::RegexBuilder::new(pattern)
                .size_limit(MAX_REGEX_SIZE_BYTES)
                .build()
        })
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
        Regex::new(r"\b(?:sk[-_](?:live|test|proj|ant)[_-][A-Za-z0-9_-]{16,}|sk-[A-Za-z0-9][A-Za-z0-9_-]{19,}|rk_(?:live|test)_[A-Za-z0-9]{24,}|SK[0-9a-f]{32})\b")
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
        let pattern = format!(
            "(?s){}.*?{}",
            pem_private_key_regex(true),
            pem_private_key_regex(false)
        );
        Regex::new(&pattern).expect("PEM redaction regex must compile")
    })
}

/// Matches a PEM private-key BEGIN header that is not followed by the
/// matching END footer — i.e. an open (unterminated) block.  This covers
/// truncated content and stream chunks that have not yet received the footer.
fn redaction_pem_open_header_regex() -> &'static Regex {
    static RE: OnceLock<Regex> = OnceLock::new();
    RE.get_or_init(|| {
        Regex::new(&pem_private_key_regex(true))
            .expect("PEM open-header redaction regex must compile")
    })
}

fn redaction_connection_string_regex() -> &'static Regex {
    static RE: OnceLock<Regex> = OnceLock::new();
    RE.get_or_init(|| {
        Regex::new(r"://[^:@\s]*:([^@\s]+)@")
            .expect("connection string redaction regex must compile")
    })
}

fn redaction_connection_string_query_param_regex() -> &'static Regex {
    static RE: OnceLock<Regex> = OnceLock::new();
    RE.get_or_init(|| {
        Regex::new(r"(?i)([?&])(password|passwd|pwd|secret|token)=([^&\s]+)")
            .expect("connection string query param redaction regex must compile")
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
        Regex::new(r"\b(?:sk[-_][A-Za-z0-9_-]*|rk_(?:live|test)_[A-Za-z0-9]*|SK[0-9a-f]*)$")
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
        Regex::new(r"[A-Za-z][A-Za-z0-9+.-]*://[^:@\s]*:[^@\s]*$")
            .expect("partial connection string redaction regex must compile")
    })
}

fn redaction_partial_connection_string_query_param_regex() -> &'static Regex {
    static RE: OnceLock<Regex> = OnceLock::new();
    RE.get_or_init(|| {
        Regex::new(r"(?i)[?&](?:password|passwd|pwd|secret|token)=[^&\s]*$")
            .expect("partial connection string query param redaction regex must compile")
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

/// Apply a single regex replacement, only allocating when the pattern matches.
fn cow_replace_all<'a>(input: Cow<'a, str>, re: &Regex, rep: &str) -> Cow<'a, str> {
    if !re.is_match(&input) {
        return input;
    }
    Cow::Owned(re.replace_all(&input, rep).into_owned())
}

fn redact_patterns(input: &str) -> String {
    let runtime_config = current_runtime_redaction_config();

    // Use a Cow chain so that each regex pass only allocates when it actually
    // matches something.  When no patterns match (the common case for safe
    // text), this function performs zero heap allocations beyond the final
    // into_owned().
    let result: Cow<'_, str> = Cow::Borrowed(input);
    let result = cow_replace_all(
        result,
        redaction_authorization_regex(),
        &format!("$1{REDACTED}"),
    );
    let result = cow_replace_all(
        result,
        redaction_key_value_regex(),
        &format!("$1={REDACTED}"),
    );
    let result = cow_replace_all(
        result,
        redaction_env_assignment_regex(),
        &format!("$1={REDACTED}"),
    );
    let result = cow_replace_all(result, redaction_aws_key_regex(), REDACTED);
    let result = cow_replace_all(result, redaction_github_token_regex(), REDACTED);
    let result = cow_replace_all(result, redaction_provider_token_regex(), REDACTED);
    let result = cow_replace_all(result, redaction_slack_token_regex(), REDACTED);
    let result = cow_replace_all(result, redaction_pem_regex(), REDACTED);
    // Redact any remaining PEM private-key headers that were not covered by a
    // complete block match above (i.e. unterminated / truncated blocks).
    let result = cow_replace_all(result, redaction_pem_open_header_regex(), REDACTED);
    let result = cow_replace_all(
        result,
        redaction_connection_string_regex(),
        &format!("://{REDACTED}@"),
    );
    let mut result = cow_replace_all(
        result,
        redaction_connection_string_query_param_regex(),
        &format!("$1$2={REDACTED}"),
    );
    for regex in &runtime_config.extra_patterns {
        result = cow_replace_all(result, regex, REDACTED);
    }
    if runtime_config.enable_entropy_guard {
        result = cow_replace_all(
            result,
            redaction_entropy_assignment_regex(),
            &format!("$1={REDACTED}"),
        );
    }
    result.into_owned()
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

fn pem_marker(label: &str, begin: bool) -> String {
    let prefix = if begin {
        PEM_BEGIN_PREFIX
    } else {
        PEM_END_PREFIX
    };
    format!("{prefix}{label}{PEM_MARKER_SUFFIX}")
}

fn pem_private_key_regex(begin: bool) -> String {
    let prefix = if begin {
        PEM_BEGIN_PREFIX
    } else {
        PEM_END_PREFIX
    };
    format!("{prefix}{PEM_KIND_REGEX_FRAGMENT}{PEM_REGEX_SUFFIX}")
}

#[cfg(test)]
fn pem_block(label: &str, body: &str) -> String {
    format!(
        "{}\n{}\n{}",
        pem_marker(label, true),
        body,
        pem_marker(label, false)
    )
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

/// Returns the byte offset of the start of an open (unterminated) PEM private
/// key block within `input`, or `None` if no such block is present. An open
/// block is one where a BEGIN header has been seen but the matching END footer
/// has not yet arrived — meaning the body may be split across stream chunks.
fn open_pem_block_start(input: &str) -> Option<usize> {
    let mut earliest: Option<usize> = None;
    for label in PEM_PRIVATE_KEY_LABELS {
        let begin = pem_marker(label, true);
        let end = pem_marker(label, false);
        if let Some(begin_pos) = input.find(&begin) {
            // Only consider it open if the matching END is not yet present
            // anywhere after the BEGIN.
            let after_begin = &input[begin_pos..];
            if !after_begin.contains(&end) {
                earliest = Some(earliest.map_or(begin_pos, |e: usize| e.min(begin_pos)));
            }
        }
    }
    earliest
}

fn partial_redaction_start(input: &str, secrets: &[String]) -> Option<usize> {
    const PEM_PREFIX_MARKERS: &[&str] = &[PEM_BEGIN_PREFIX];

    let mut retain_start = None;

    // If the buffer contains an open PEM block (BEGIN seen but END not yet
    // arrived), hold everything from the BEGIN marker forward so the full
    // block can be redacted atomically once the END arrives.
    if let Some(start) = open_pem_block_start(input) {
        retain_start = Some(retain_start.map_or(start, |current: usize| current.min(start)));
    }

    for marker in PEM_PREFIX_MARKERS {
        let candidate =
            partial_literal_start(input, marker, false, minimum_partial_match_bytes(marker));
        if let Some(start) = candidate {
            retain_start = Some(retain_start.map_or(start, |current: usize| current.min(start)));
        }
    }

    for label in PEM_PRIVATE_KEY_LABELS {
        let begin_marker = pem_marker(label, true);
        let candidate = partial_literal_start(
            input,
            &begin_marker,
            false,
            minimum_partial_match_bytes(&begin_marker),
        );
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
        redaction_partial_connection_string_query_param_regex(),
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

const MAX_BUFFER_BYTES: usize = 64 * 1024; // 64 KB

impl StreamRedactionBuffer {
    pub fn new() -> Self {
        Self::default()
    }

    pub fn push_chunk(&mut self, chunk: &str, secrets: &[String]) -> Option<String> {
        self.pending.push_str(chunk);
        // Prevent unbounded buffer growth — force flush when exceeding limit.
        if self.pending.len() > MAX_BUFFER_BYTES {
            tracing::warn!(
                buffered = self.pending.len(),
                "redaction buffer exceeded {}B, force flushing",
                MAX_BUFFER_BYTES
            );
            return self.drain(true, secrets);
        }
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

    fn provider_token(prefix: &str) -> String {
        format!("{prefix}{}", "abcdefghijklmnopqrstuvwxyz1234567890")
    }

    fn quoted_assignment(name: &str, value: &str) -> String {
        format!(r#"{name}="{value}""#)
    }

    #[test]
    fn redacts_provider_token_standalone() {
        let token = provider_token("sk-proj-");
        let input = format!("token {token}");
        let output = redact_text(&input, &[]);
        assert!(!output.contains("sk-proj-"));
        assert!(output.contains(REDACTED));
    }

    #[test]
    fn redacts_anthropic_token_standalone() {
        let token = provider_token("sk-ant-api03-");
        let input = format!("token {token}");
        let output = redact_text(&input, &[]);
        assert!(!output.contains("sk-ant-api03-"));
        assert!(output.contains(REDACTED));
    }

    #[test]
    fn redacts_provider_env_assignment() {
        let token = provider_token("sk-ant-api03-");
        let input = quoted_assignment("OPENAI_API_KEY", &token);
        let output = redact_text(&input, &[]);
        assert!(!output.contains("sk-ant-api03-"));
        assert_eq!(output, "OPENAI_API_KEY=[REDACTED]");
    }

    #[test]
    fn redacts_json_string_values_and_sensitive_keys() {
        let message_token = provider_token("sk-proj-");
        let output = redact_json_value(
            serde_json::json!({
                "message": format!("OPENAI_API_KEY={message_token}"),
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
        let token = provider_token("sk-proj-");

        let first = buffer
            .push_chunk(&format!("prefix {}", &token[..5]), &[])
            .expect("safe prefix should flush");
        assert_eq!(first, "prefix ");
        let second = buffer
            .push_chunk(&format!("{} suffix", &token[5..]), &[])
            .expect("provider token should flush once complete");
        assert_eq!(second, "[REDACTED] suffix");
    }

    #[test]
    fn stream_buffer_redacts_env_assignment_split_across_chunks() {
        let mut buffer = StreamRedactionBuffer::new();
        let token = provider_token("sk-ant-api03-");

        assert!(buffer
            .push_chunk(&format!(r#"OPENAI_API_KEY="{}"#, &token[..4]), &[])
            .is_none());
        let second = buffer
            .push_chunk(&format!(r#"{}" done"#, &token[4..]), &[])
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

    #[test]
    fn redacts_full_pem_private_key() {
        let input = format!(
            "before\n{}\nafter",
            pem_block(
                "PRIVATE KEY",
                "MIIEvQIBADANBgkqhkiG9w0BAQEFAASCBKcwggSjAgEAAoIBAQC7\nfake+base64+key+data+here=="
            )
        );
        let output = redact_text(&input, &[]);
        assert!(!output.contains("MIIEvQIBADANBg"));
        assert!(!output.contains("fake+base64"));
        assert!(output.contains(REDACTED));
        assert!(output.contains("before"));
        assert!(output.contains("after"));
    }

    #[test]
    fn redacts_rsa_private_key() {
        let input = pem_block(
            "RSA PRIVATE KEY",
            "MIIBogIBAAJBALRiMLAHudeSA/x3hB2f+2NRkJLA\nfake+rsa+key+data==",
        );
        let output = redact_text(&input, &[]);
        assert!(!output.contains("MIIBogIBAAJBALR"));
        assert_eq!(output, REDACTED);
    }

    #[test]
    fn redacts_ec_private_key() {
        let input = pem_block(
            "EC PRIVATE KEY",
            "MHQCAQEEIBkg2yBFhx8bioZERSOldqSeGXnMC8RD\nfake+ec+key==",
        );
        let output = redact_text(&input, &[]);
        assert!(!output.contains("MHQCAQEEIBkg"));
        assert_eq!(output, REDACTED);
    }

    #[test]
    fn redacts_openssh_private_key() {
        let input = pem_block(
            "OPENSSH PRIVATE KEY",
            "b3BlbnNzaC1rZXktdjEAAAAABG5vbmUAAAAEbm9uZQAAAAAAAAAB\nfake+openssh+key==",
        );
        let output = redact_text(&input, &[]);
        assert!(!output.contains("b3BlbnNzaC1rZXk"));
        assert_eq!(output, REDACTED);
    }

    #[test]
    fn redacts_encrypted_private_key() {
        let input = pem_block(
            "ENCRYPTED PRIVATE KEY",
            "MIIFHDBOBgkqhkiG9w0BBQ0wQTApBgkqhkiG9w0BBQwwHAQI\nfake+encrypted+key==",
        );
        let output = redact_text(&input, &[]);
        assert!(!output.contains("MIIFHDBOBgkqhk"));
        assert_eq!(output, REDACTED);
    }

    #[test]
    fn stream_buffer_redacts_pem_key_split_across_chunks() {
        let mut buffer = StreamRedactionBuffer::new();
        let begin_marker = pem_marker("RSA PRIVATE KEY", true);
        let end_marker = pem_marker("RSA PRIVATE KEY", false);
        let pem_start = format!("some output\n{begin_marker}\nMIIBogIBAAJ");
        let pem_end = format!("BALRiMLAHudeSAfake+rsa+data==\n{end_marker}\ndone");

        // First chunk contains the BEGIN marker; the buffer may flush the safe
        // prefix before it or hold the whole chunk — either way the key body
        // must not appear unredacted in the combined output.
        let first = buffer.push_chunk(&pem_start, &[]);

        // Second chunk completes the PEM block
        let second = buffer.push_chunk(&pem_end, &[]);
        let remainder = buffer.finish(&[]);

        // Combine all output
        let mut full_output = String::new();
        if let Some(f) = first {
            full_output.push_str(&f);
        }
        if let Some(s) = second {
            full_output.push_str(&s);
        }
        if let Some(r) = remainder {
            full_output.push_str(&r);
        }

        assert!(
            !full_output.contains("MIIBogIBAAJ"),
            "PEM key body should be redacted"
        );
        assert!(
            !full_output.contains("fake+rsa+data"),
            "PEM key body should be redacted"
        );
        assert!(full_output.contains(REDACTED));
    }

    #[test]
    fn does_not_redact_public_key() {
        let input = "-----BEGIN PUBLIC KEY-----\nMIIBIjANBgkqhkiG9w0BAQEFAAOCAQ8AMIIBCgKCAQEA\nfake+public+key==\n-----END PUBLIC KEY-----";
        let output = redact_text(input, &[]);
        assert_eq!(output, input);
    }

    #[test]
    fn redacts_aws_access_key() {
        let input = "found key AKIAIOSFODNN7EXAMPLE in config";
        let output = redact_text(input, &[]);
        assert!(!output.contains("AKIAIOSFODNN7EXAMPLE"));
        assert!(output.contains(REDACTED));
    }

    #[test]
    fn redacts_aws_secret_key_assignment() {
        let input = "AWS_SECRET_ACCESS_KEY=wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY";
        let output = redact_text(input, &[]);
        assert!(!output.contains("wJalrXUtnFEMI"));
        assert!(output.contains(REDACTED));
    }

    #[test]
    fn redacts_github_token() {
        for prefix in &["ghp_", "gho_", "ghs_", "ghr_"] {
            let token = format!("{prefix}ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghij0123456789");
            let input = format!("token: {token}");
            let output = redact_text(&input, &[]);
            assert!(
                !output.contains(prefix),
                "GitHub token with prefix {prefix} should be redacted"
            );
            assert!(output.contains(REDACTED));
        }
    }

    #[test]
    fn redacts_slack_token() {
        for prefix in &["xoxb-", "xoxp-", "xoxs-"] {
            let token = format!("{prefix}1234567890-abcdefgh");
            let input = format!("slack: {token}");
            let output = redact_text(&input, &[]);
            assert!(
                !output.contains(&token),
                "Slack token with prefix {prefix} should be redacted"
            );
            assert!(output.contains(REDACTED));
        }
    }

    #[test]
    fn redacts_connection_string() {
        let input = "db=postgresql://user:s3cretP4ss@host.example.com:5432/mydb";
        let output = redact_text(input, &[]);
        assert!(!output.contains("s3cretP4ss"));
        assert!(output.contains(REDACTED));
    }

    #[test]
    fn redacts_authorization_header_value() {
        let input = "Authorization: Bearer eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.test.signature";
        let output = redact_text(input, &[]);
        assert!(!output.contains("eyJhbGciOiJIUzI1NiI"));
        assert!(output.contains(REDACTED));
    }

    #[test]
    fn redacts_generic_key_value_pairs() {
        let inputs = [
            r#"api_key = "integration-demo-value-abcdef0123456789""#,
            r#"secret = "my-super-secret-value""#,
            "password=hunter2",
        ];
        for input in &inputs {
            let output = redact_text(input, &[]);
            assert!(
                output.contains(REDACTED),
                "Key-value pair should be redacted: {input}"
            );
        }
    }

    #[test]
    fn does_not_redact_safe_text() {
        let input =
            "Hello world! This is a normal log message with no secrets. Build #1234 complete.";
        let output = redact_text(input, &[]);
        assert_eq!(output, input);
    }

    #[test]
    fn stream_boundary_does_not_corrupt_safe_output() {
        let mut buffer = StreamRedactionBuffer::new();
        let chunk1 = "Hello, this is a perfectly safe message ";
        let chunk2 = "that continues across a chunk boundary. All good!";

        let mut full_output = String::new();
        if let Some(out) = buffer.push_chunk(chunk1, &[]) {
            full_output.push_str(&out);
        }
        if let Some(out) = buffer.push_chunk(chunk2, &[]) {
            full_output.push_str(&out);
        }
        if let Some(out) = buffer.finish(&[]) {
            full_output.push_str(&out);
        }
        assert_eq!(full_output, format!("{chunk1}{chunk2}"));
    }

    #[test]
    fn rejects_oversized_custom_regex() {
        // A pattern that compiles to a very large NFA should be rejected
        // by the size_limit guard on RegexBuilder.
        let huge_pattern = format!("({})", "a|".repeat(100_000));
        let result = compile_extra_patterns(&[huge_pattern]);
        assert!(result.is_err(), "oversized regex should be rejected");
    }

    #[test]
    fn secret_at_high_byte_offset_is_redacted() {
        // Verify the increased tail buffer (8192) catches secrets at high offsets
        let padding = "x".repeat(5000);
        let secret = "my-deep-secret-value";
        let input = format!("{padding}{secret} trailing");
        let output = redact_text(&input, &[secret.to_string()]);
        assert!(
            !output.contains(secret),
            "secret at byte offset 5000 should be redacted"
        );
        assert!(output.contains(REDACTED));
    }

    #[test]
    fn stream_buffer_catches_secret_at_high_offset() {
        let mut buffer = StreamRedactionBuffer::new();
        let padding = "x".repeat(5000);
        let secret = "high-offset-secret-val";
        let secrets = vec![secret.to_string()];

        // Push a large chunk with the secret near the end
        let chunk = format!("{padding}{secret} end");
        let mut full_output = String::new();
        if let Some(out) = buffer.push_chunk(&chunk, &secrets) {
            full_output.push_str(&out);
        }
        if let Some(out) = buffer.finish(&secrets) {
            full_output.push_str(&out);
        }
        assert!(
            !full_output.contains(secret),
            "secret at high byte offset should be caught by stream buffer"
        );
    }

    #[test]
    fn patterns_last_reviewed_is_valid_date() {
        // Ensure the constant parses as a valid date
        let parsed = chrono::NaiveDate::parse_from_str(PATTERNS_LAST_REVIEWED, "%Y-%m-%d");
        assert!(
            parsed.is_ok(),
            "PATTERNS_LAST_REVIEWED must be a valid YYYY-MM-DD date"
        );
    }

    // --- G.9: Redaction streaming edge cases ---

    #[test]
    fn stream_buffer_empty_input_returns_none() {
        let mut buffer = StreamRedactionBuffer::new();
        assert!(
            buffer.push_chunk("", &[]).is_none(),
            "empty chunk should produce no output"
        );
        assert!(
            buffer.finish(&[]).is_none(),
            "finish on empty buffer should produce no output"
        );
    }

    #[test]
    fn stream_buffer_secret_at_very_start_of_input() {
        let secret = "start-secret-value";
        let secrets = vec![secret.to_string()];
        let mut buffer = StreamRedactionBuffer::new();
        let chunk = format!("{secret} and then safe text");
        let mut full_output = String::new();
        if let Some(out) = buffer.push_chunk(&chunk, &secrets) {
            full_output.push_str(&out);
        }
        if let Some(out) = buffer.finish(&secrets) {
            full_output.push_str(&out);
        }
        assert!(
            !full_output.contains(secret),
            "secret at start of input should be redacted, got: {full_output}"
        );
        assert!(full_output.contains(REDACTED));
        assert!(full_output.contains("and then safe text"));
    }

    #[test]
    fn stream_buffer_secret_at_very_end_of_input() {
        let secret = "end-secret-value";
        let secrets = vec![secret.to_string()];
        let mut buffer = StreamRedactionBuffer::new();
        let chunk = format!("safe text before {secret}");
        let mut full_output = String::new();
        if let Some(out) = buffer.push_chunk(&chunk, &secrets) {
            full_output.push_str(&out);
        }
        if let Some(out) = buffer.finish(&secrets) {
            full_output.push_str(&out);
        }
        assert!(
            !full_output.contains(secret),
            "secret at end of input should be redacted, got: {full_output}"
        );
        assert!(full_output.contains(REDACTED));
    }

    #[test]
    fn stream_buffer_secret_split_across_two_chunks() {
        let secret = "split-across-chunks-secret";
        let secrets = vec![secret.to_string()];
        let mut buffer = StreamRedactionBuffer::new();
        // Split the secret in the middle
        let mid = secret.len() / 2;
        let part1 = &secret[..mid];
        let part2 = &secret[mid..];
        let mut full_output = String::new();
        if let Some(out) = buffer.push_chunk(&format!("before {part1}"), &secrets) {
            full_output.push_str(&out);
        }
        if let Some(out) = buffer.push_chunk(&format!("{part2} after"), &secrets) {
            full_output.push_str(&out);
        }
        if let Some(out) = buffer.finish(&secrets) {
            full_output.push_str(&out);
        }
        assert!(
            !full_output.contains(secret),
            "secret split across chunks should be redacted, got: {full_output}"
        );
        assert!(full_output.contains(REDACTED));
    }

    #[test]
    fn stream_buffer_overlapping_secrets() {
        // Two secrets that share a substring: "secret-overlap-ab" and "overlap-ab-end"
        let secret1 = "secret-overlap-ab";
        let secret2 = "overlap-ab-end";
        let secrets = vec![secret1.to_string(), secret2.to_string()];
        let mut buffer = StreamRedactionBuffer::new();
        // Input contains both secrets separately
        let input = format!("x {secret1} y {secret2} z");
        let mut full_output = String::new();
        if let Some(out) = buffer.push_chunk(&input, &secrets) {
            full_output.push_str(&out);
        }
        if let Some(out) = buffer.finish(&secrets) {
            full_output.push_str(&out);
        }
        assert!(
            !full_output.contains(secret1),
            "first overlapping secret should be redacted, got: {full_output}"
        );
        assert!(
            !full_output.contains(secret2),
            "second overlapping secret should be redacted, got: {full_output}"
        );
    }

    #[test]
    fn stream_buffer_long_input_no_secrets_passthrough() {
        let mut buffer = StreamRedactionBuffer::new();
        // 50KB of safe content with no secret patterns
        let line = "This is a safe log line with build ID 12345 and nothing sensitive.\n";
        let input: String = line.repeat(800); // ~52KB
        let mut full_output = String::new();
        if let Some(out) = buffer.push_chunk(&input, &[]) {
            full_output.push_str(&out);
        }
        if let Some(out) = buffer.finish(&[]) {
            full_output.push_str(&out);
        }
        // The complete input should pass through unmodified
        assert_eq!(
            full_output, input,
            "long safe input should pass through unchanged"
        );
    }

    #[test]
    fn stream_buffer_unicode_content_with_secrets() {
        let secret = "unicode-secret-val";
        let secrets = vec![secret.to_string()];
        let mut buffer = StreamRedactionBuffer::new();
        // Mix of unicode characters around the secret
        let input = format!(
            "Greetings, {}. Status: {secret}. Done.",
            "\u{1F600}\u{2603}\u{00E9}\u{4E16}\u{754C}"
        );
        let mut full_output = String::new();
        if let Some(out) = buffer.push_chunk(&input, &secrets) {
            full_output.push_str(&out);
        }
        if let Some(out) = buffer.finish(&secrets) {
            full_output.push_str(&out);
        }
        assert!(
            !full_output.contains(secret),
            "secret within unicode content should be redacted, got: {full_output}"
        );
        assert!(full_output.contains(REDACTED));
        // Verify unicode characters survived
        assert!(
            full_output.contains("\u{1F600}"),
            "unicode emoji should survive redaction"
        );
        assert!(
            full_output.contains("\u{4E16}\u{754C}"),
            "CJK characters should survive redaction"
        );
    }

    #[test]
    fn stream_buffer_unicode_split_at_boundary_does_not_corrupt() {
        // Ensure the buffer handles multi-byte characters that could be split
        // at a chunk boundary without corrupting the output.
        let mut buffer = StreamRedactionBuffer::new();
        // 4-byte emoji repeated to fill enough content that a split happens
        let emoji_text = "\u{1F680}".repeat(100); // 400 bytes of rockets
        let safe_suffix = " safe ending";
        let mut full_output = String::new();
        if let Some(out) = buffer.push_chunk(&emoji_text, &[]) {
            full_output.push_str(&out);
        }
        if let Some(out) = buffer.push_chunk(safe_suffix, &[]) {
            full_output.push_str(&out);
        }
        if let Some(out) = buffer.finish(&[]) {
            full_output.push_str(&out);
        }
        assert_eq!(
            full_output,
            format!("{emoji_text}{safe_suffix}"),
            "unicode content should not be corrupted across chunk boundaries"
        );
    }

    #[test]
    fn redact_text_empty_input_returns_empty() {
        let output = redact_text("", &[]);
        assert_eq!(output, "", "empty input should produce empty output");
    }

    #[test]
    fn redact_text_empty_input_with_secrets_returns_empty() {
        let output = redact_text("", &["some-secret".to_string()]);
        assert_eq!(
            output, "",
            "empty input with secrets should produce empty output"
        );
    }

    #[test]
    fn stream_buffer_multiple_secrets_in_single_chunk() {
        let secret_a = "first-secret-aaa";
        let secret_b = "second-secret-bbb";
        let secrets = vec![secret_a.to_string(), secret_b.to_string()];
        let mut buffer = StreamRedactionBuffer::new();
        let input = format!("start {secret_a} middle {secret_b} end");
        let mut full_output = String::new();
        if let Some(out) = buffer.push_chunk(&input, &secrets) {
            full_output.push_str(&out);
        }
        if let Some(out) = buffer.finish(&secrets) {
            full_output.push_str(&out);
        }
        assert!(
            !full_output.contains(secret_a),
            "first secret should be redacted"
        );
        assert!(
            !full_output.contains(secret_b),
            "second secret should be redacted"
        );
        assert!(full_output.contains("start"));
        assert!(full_output.contains("end"));
    }

    #[test]
    fn stream_buffer_finish_flushes_held_back_content() {
        let secret = "held-back-secret-value";
        let secrets = vec![secret.to_string()];
        let mut buffer = StreamRedactionBuffer::new();
        // Push partial prefix of the secret -- the buffer may hold it back
        let partial = &secret[..5];
        let _ = buffer.push_chunk(partial, &secrets);
        // finish() must flush everything
        let remainder = buffer.finish(&secrets);
        // Even if it was held, finish should produce the partial (not a secret match)
        let mut full_output = String::new();
        if let Some(out) = remainder {
            full_output.push_str(&out);
        }
        // The partial prefix by itself is not the secret, so it should appear unredacted
        assert!(
            !full_output.contains(secret),
            "full secret should not appear in output"
        );
    }

    #[test]
    fn redacts_stripe_live_key() {
        let input = "key sk_live_abcdefghijklmnopqrstuvwxyz";
        let output = redact_text(input, &[]);
        assert!(
            !output.contains("sk_live_"),
            "Stripe live key should be redacted: {output}"
        );
        assert!(output.contains(REDACTED));
    }

    #[test]
    fn redacts_stripe_test_key() {
        let input = "key sk_test_abcdefghijklmnopqrstuvwxyz";
        let output = redact_text(input, &[]);
        assert!(
            !output.contains("sk_test_"),
            "Stripe test key should be redacted: {output}"
        );
        assert!(output.contains(REDACTED));
    }

    #[test]
    fn redacts_stripe_restricted_key() {
        let input = "key rk_live_abcdefghijklmnopqrstuvwxyz1234";
        let output = redact_text(input, &[]);
        assert!(
            !output.contains("rk_live_"),
            "Stripe restricted key should be redacted: {output}"
        );
        assert!(output.contains(REDACTED));
    }

    #[test]
    fn redacts_twilio_key() {
        let input = "key SKabcdef0123456789abcdef0123456789";
        let output = redact_text(input, &[]);
        assert!(
            !output.contains("SKabcdef"),
            "Twilio key should be redacted: {output}"
        );
        assert!(output.contains(REDACTED));
    }

    #[test]
    fn redacts_redis_empty_user_connection_string() {
        let input = "redis://:s3cretP4ss@host:6379/0";
        let output = redact_text(input, &[]);
        assert!(
            !output.contains("s3cretP4ss"),
            "Redis password should be redacted: {output}"
        );
        assert!(output.contains(REDACTED));
    }

    #[test]
    fn redacts_query_param_password() {
        let input = "jdbc:postgresql://host/db?user=admin&password=s3cret&sslmode=require";
        let output = redact_text(input, &[]);
        assert!(
            !output.contains("s3cret"),
            "Query param password should be redacted: {output}"
        );
    }

    #[test]
    fn redacts_query_param_token() {
        let input = "https://api.example.com/v1?token=abc123def456ghi789";
        let output = redact_text(input, &[]);
        assert!(
            !output.contains("abc123def456"),
            "Query param token should be redacted: {output}"
        );
    }
}
