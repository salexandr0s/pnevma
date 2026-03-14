use regex::Regex;
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use std::borrow::Cow;
use std::fmt;
use std::sync::OnceLock;

/// Typed error category returned by [`categorize_error`].
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum ErrorCategory {
    Timeout,
    RateLimit,
    Permission,
    Conflict,
    NotFound,
    Connection,
    Memory,
    Unknown,
}

impl fmt::Display for ErrorCategory {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        let s = match self {
            Self::Timeout => "timeout",
            Self::RateLimit => "rate_limit",
            Self::Permission => "permission",
            Self::Conflict => "conflict",
            Self::NotFound => "not_found",
            Self::Connection => "connection",
            Self::Memory => "memory",
            Self::Unknown => "unknown",
        };
        f.write_str(s)
    }
}

impl ErrorCategory {
    /// Convert from a legacy string representation.
    pub fn from_str_legacy(s: &str) -> Self {
        match s {
            "timeout" => Self::Timeout,
            "rate_limit" => Self::RateLimit,
            "permission" => Self::Permission,
            "conflict" => Self::Conflict,
            "not_found" => Self::NotFound,
            "connection" => Self::Connection,
            "memory" => Self::Memory,
            _ => Self::Unknown,
        }
    }
}

/// Apply a single regex replacement, only allocating when the pattern matches.
fn cow_replace_all<'a>(input: Cow<'a, str>, re: &Regex, rep: &str) -> Cow<'a, str> {
    if !re.is_match(&input) {
        return input;
    }
    Cow::Owned(re.replace_all(&input, rep).into_owned())
}

/// Normalize an error message by replacing variable parts with placeholders.
///
/// Returns `Cow::Borrowed` when no regex matches (i.e. the input is already
/// normalized), avoiding heap allocation entirely in that case.
pub fn normalize_error(raw: &str) -> Cow<'_, str> {
    let s: Cow<'_, str> = Cow::Borrowed(raw);
    let s = cow_replace_all(s, timestamp_re(), "<TIMESTAMP>");
    let s = cow_replace_all(s, uuid_re(), "<UUID>");
    let s = cow_replace_all(s, filepath_re(), "<PATH>");
    let s = cow_replace_all(s, hex_addr_re(), "<ADDR>");
    let s = cow_replace_all(s, pid_re(), "<NUM>");
    let s = cow_replace_all(s, whitespace_re(), " ");
    let trimmed = s.trim();
    if trimmed.len() == s.len() {
        s
    } else {
        Cow::Owned(trimmed.to_string())
    }
}

/// Compute a 16-char hex hash of the normalized message.
pub fn signature_hash(normalized: &str) -> String {
    let mut hasher = Sha256::new();
    hasher.update(normalized.as_bytes());
    let result = hasher.finalize();
    result[..8].iter().map(|b| format!("{b:02x}")).collect()
}

/// Categorize an error message based on keywords.
pub fn categorize_error(normalized: &str) -> ErrorCategory {
    let lower = normalized.to_ascii_lowercase();
    if lower.contains("timeout") || lower.contains("timed out") {
        return ErrorCategory::Timeout;
    }
    if lower.contains("429") || lower.contains("rate limit") {
        return ErrorCategory::RateLimit;
    }
    if lower.contains("eacces") || lower.contains("permission denied") {
        return ErrorCategory::Permission;
    }
    if lower.contains("conflict") || lower.contains("merge conflict") {
        return ErrorCategory::Conflict;
    }
    if lower.contains("not found") || lower.contains("404") {
        return ErrorCategory::NotFound;
    }
    if lower.contains("connection") || lower.contains("econnrefused") {
        return ErrorCategory::Connection;
    }
    if lower.contains("oom") || lower.contains("out of memory") {
        return ErrorCategory::Memory;
    }
    ErrorCategory::Unknown
}

/// Get a remediation hint for an error category.
pub fn remediation_hint(category: ErrorCategory) -> Option<&'static str> {
    match category {
        ErrorCategory::Timeout => {
            Some("Consider increasing timeout or breaking the task into smaller chunks")
        }
        ErrorCategory::RateLimit => {
            Some("Wait before retrying. Consider using a different model or reducing concurrency")
        }
        ErrorCategory::Permission => {
            Some("Check file permissions and ensure the agent has access to the required paths")
        }
        ErrorCategory::Conflict => {
            Some("Resolve merge conflicts manually or re-dispatch with conflict context")
        }
        ErrorCategory::NotFound => Some("Verify file paths and resource URLs are correct"),
        ErrorCategory::Connection => Some("Check network connectivity and service availability"),
        ErrorCategory::Memory => Some("Reduce task scope or increase available memory"),
        ErrorCategory::Unknown => None,
    }
}

fn timestamp_re() -> &'static Regex {
    static RE: OnceLock<Regex> = OnceLock::new();
    RE.get_or_init(|| {
        Regex::new(r"\d{4}-\d{2}-\d{2}[T ]\d{2}:\d{2}:\d{2}[.\d]*[Z+\-\d:]*").unwrap()
    })
}

fn uuid_re() -> &'static Regex {
    static RE: OnceLock<Regex> = OnceLock::new();
    RE.get_or_init(|| {
        Regex::new(r"[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}")
            .unwrap()
    })
}

fn filepath_re() -> &'static Regex {
    static RE: OnceLock<Regex> = OnceLock::new();
    RE.get_or_init(|| Regex::new(r"(?:/[\w.\-]+)+(?::\d+(?::\d+)?)?").unwrap())
}

fn hex_addr_re() -> &'static Regex {
    static RE: OnceLock<Regex> = OnceLock::new();
    RE.get_or_init(|| Regex::new(r"0x[0-9a-fA-F]{4,16}").unwrap())
}

fn pid_re() -> &'static Regex {
    static RE: OnceLock<Regex> = OnceLock::new();
    RE.get_or_init(|| Regex::new(r"\bpid[=: ]\d+\b").unwrap())
}

fn whitespace_re() -> &'static Regex {
    static RE: OnceLock<Regex> = OnceLock::new();
    RE.get_or_init(|| Regex::new(r"\s+").unwrap())
}

#[cfg(test)]
mod tests {
    use super::*;

    // --- normalize_error tests ---

    #[test]
    fn normalize_replaces_timestamp() {
        let raw = "error at 2024-03-14T10:30:00Z: something failed";
        let n = normalize_error(raw);
        assert!(n.contains("<TIMESTAMP>"), "got: {n}");
        assert!(!n.contains("2024"));
    }

    #[test]
    fn normalize_replaces_uuid() {
        let raw = "task 550e8400-e29b-41d4-a716-446655440000 failed";
        let n = normalize_error(raw);
        assert!(n.contains("<UUID>"), "got: {n}");
        assert!(!n.contains("550e8400"));
    }

    #[test]
    fn normalize_replaces_filepath() {
        let raw = "error in /Users/dev/project/src/main.rs:42:10";
        let n = normalize_error(raw);
        assert!(n.contains("<PATH>"), "got: {n}");
    }

    #[test]
    fn normalize_replaces_hex_address() {
        let raw = "segfault at 0x7fff5fbff8e0";
        let n = normalize_error(raw);
        assert!(n.contains("<ADDR>"), "got: {n}");
    }

    #[test]
    fn normalize_replaces_pid() {
        let raw = "process pid=12345 crashed";
        let n = normalize_error(raw);
        assert!(n.contains("<NUM>"), "got: {n}");
    }

    #[test]
    fn normalize_collapses_whitespace() {
        let raw = "error   with   extra   spaces";
        let n = normalize_error(raw);
        assert_eq!(n.as_ref(), "error with extra spaces");
    }

    #[test]
    fn normalize_returns_borrowed_when_no_changes() {
        let raw = "simple-error";
        let n = normalize_error(raw);
        assert!(matches!(n, Cow::Borrowed(_)), "should avoid allocation");
    }

    #[test]
    fn normalize_combined_replacements() {
        let raw =
            "2024-01-01T00:00:00Z task 550e8400-e29b-41d4-a716-446655440000 in /tmp/foo.rs pid=99";
        let n = normalize_error(raw);
        assert!(n.contains("<TIMESTAMP>"));
        assert!(n.contains("<UUID>"));
        assert!(n.contains("<PATH>"));
        assert!(n.contains("<NUM>"));
    }

    // --- signature_hash tests ---

    #[test]
    fn signature_hash_is_16_hex_chars() {
        let h = signature_hash("some normalized message");
        assert_eq!(h.len(), 16);
        assert!(h.chars().all(|c| c.is_ascii_hexdigit()));
    }

    #[test]
    fn signature_hash_is_deterministic() {
        let h1 = signature_hash("same input");
        let h2 = signature_hash("same input");
        assert_eq!(h1, h2);
    }

    #[test]
    fn signature_hash_differs_for_different_inputs() {
        let h1 = signature_hash("error A");
        let h2 = signature_hash("error B");
        assert_ne!(h1, h2);
    }

    // --- categorize_error tests ---

    #[test]
    fn categorize_timeout() {
        assert_eq!(
            categorize_error("operation timed out"),
            ErrorCategory::Timeout
        );
        assert_eq!(
            categorize_error("request timeout after 30s"),
            ErrorCategory::Timeout
        );
    }

    #[test]
    fn categorize_rate_limit() {
        assert_eq!(
            categorize_error("received 429 status"),
            ErrorCategory::RateLimit
        );
        assert_eq!(
            categorize_error("rate limit exceeded"),
            ErrorCategory::RateLimit
        );
    }

    #[test]
    fn categorize_permission() {
        assert_eq!(
            categorize_error("EACCES: permission denied"),
            ErrorCategory::Permission
        );
    }

    #[test]
    fn categorize_conflict() {
        assert_eq!(
            categorize_error("merge conflict in file"),
            ErrorCategory::Conflict
        );
    }

    #[test]
    fn categorize_not_found() {
        assert_eq!(
            categorize_error("resource not found"),
            ErrorCategory::NotFound
        );
        assert_eq!(
            categorize_error("404 page missing"),
            ErrorCategory::NotFound
        );
    }

    #[test]
    fn categorize_connection() {
        assert_eq!(categorize_error("ECONNREFUSED"), ErrorCategory::Connection);
        assert_eq!(
            categorize_error("connection reset"),
            ErrorCategory::Connection
        );
    }

    #[test]
    fn categorize_memory() {
        assert_eq!(categorize_error("out of memory"), ErrorCategory::Memory);
        assert_eq!(categorize_error("OOM killed"), ErrorCategory::Memory);
    }

    #[test]
    fn categorize_unknown() {
        assert_eq!(
            categorize_error("something weird happened"),
            ErrorCategory::Unknown
        );
    }

    // --- ErrorCategory Display and roundtrip ---

    #[test]
    fn error_category_display_roundtrip() {
        for cat in [
            ErrorCategory::Timeout,
            ErrorCategory::RateLimit,
            ErrorCategory::Permission,
            ErrorCategory::Conflict,
            ErrorCategory::NotFound,
            ErrorCategory::Connection,
            ErrorCategory::Memory,
            ErrorCategory::Unknown,
        ] {
            let s = cat.to_string();
            assert_eq!(ErrorCategory::from_str_legacy(&s), cat);
        }
    }

    // --- remediation_hint tests ---

    #[test]
    fn remediation_hint_returns_some_for_known_categories() {
        assert!(remediation_hint(ErrorCategory::Timeout).is_some());
        assert!(remediation_hint(ErrorCategory::RateLimit).is_some());
        assert!(remediation_hint(ErrorCategory::Permission).is_some());
        assert!(remediation_hint(ErrorCategory::Conflict).is_some());
        assert!(remediation_hint(ErrorCategory::NotFound).is_some());
        assert!(remediation_hint(ErrorCategory::Connection).is_some());
        assert!(remediation_hint(ErrorCategory::Memory).is_some());
    }

    #[test]
    fn remediation_hint_returns_none_for_unknown() {
        assert!(remediation_hint(ErrorCategory::Unknown).is_none());
    }

    // --- cow_replace_all tests ---

    #[test]
    fn cow_replace_no_match_returns_borrowed() {
        let input = Cow::Borrowed("no numbers here");
        let result = cow_replace_all(input, uuid_re(), "<UUID>");
        assert!(matches!(result, Cow::Borrowed(_)));
    }

    #[test]
    fn cow_replace_with_match_returns_owned() {
        let input = Cow::Borrowed("id 550e8400-e29b-41d4-a716-446655440000 here");
        let result = cow_replace_all(input, uuid_re(), "<UUID>");
        assert!(matches!(result, Cow::Owned(_)));
        assert!(result.contains("<UUID>"));
    }
}
