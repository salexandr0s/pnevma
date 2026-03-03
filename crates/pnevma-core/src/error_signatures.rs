use regex::Regex;
use sha2::{Digest, Sha256};
use std::sync::OnceLock;

/// Normalize an error message by replacing variable parts with placeholders.
pub fn normalize_error(raw: &str) -> String {
    let mut s = raw.to_string();
    s = timestamp_re().replace_all(&s, "<TIMESTAMP>").to_string();
    s = uuid_re().replace_all(&s, "<UUID>").to_string();
    s = filepath_re().replace_all(&s, "<PATH>").to_string();
    s = hex_addr_re().replace_all(&s, "<ADDR>").to_string();
    s = pid_re().replace_all(&s, "<NUM>").to_string();
    s = whitespace_re().replace_all(&s, " ").to_string();
    s.trim().to_string()
}

/// Compute a 16-char hex hash of the normalized message.
pub fn signature_hash(normalized: &str) -> String {
    let mut hasher = Sha256::new();
    hasher.update(normalized.as_bytes());
    let result = hasher.finalize();
    result[..8].iter().map(|b| format!("{b:02x}")).collect()
}

/// Categorize an error message based on keywords.
pub fn categorize_error(normalized: &str) -> &'static str {
    let lower = normalized.to_ascii_lowercase();
    if lower.contains("timeout") || lower.contains("timed out") {
        return "timeout";
    }
    if lower.contains("429") || lower.contains("rate limit") {
        return "rate_limit";
    }
    if lower.contains("eacces") || lower.contains("permission denied") {
        return "permission";
    }
    if lower.contains("conflict") || lower.contains("merge conflict") {
        return "conflict";
    }
    if lower.contains("not found") || lower.contains("404") {
        return "not_found";
    }
    if lower.contains("connection") || lower.contains("econnrefused") {
        return "connection";
    }
    if lower.contains("oom") || lower.contains("out of memory") {
        return "memory";
    }
    "unknown"
}

/// Get a remediation hint for an error category.
pub fn remediation_hint(category: &str) -> Option<&'static str> {
    match category {
        "timeout" => Some("Consider increasing timeout or breaking the task into smaller chunks"),
        "rate_limit" => {
            Some("Wait before retrying. Consider using a different model or reducing concurrency")
        }
        "permission" => Some(
            "Check file permissions and ensure the agent has access to the required paths",
        ),
        "conflict" => {
            Some("Resolve merge conflicts manually or re-dispatch with conflict context")
        }
        "not_found" => Some("Verify file paths and resource URLs are correct"),
        "connection" => Some("Check network connectivity and service availability"),
        "memory" => Some("Reduce task scope or increase available memory"),
        _ => None,
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
        Regex::new(
            r"[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}",
        )
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
