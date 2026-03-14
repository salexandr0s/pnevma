use serde::{Deserialize, Serialize};
use std::time::{Duration, Instant};

/// Check if `needle` appears as a whole word in `haystack`.
fn word_boundary_match(haystack: &str, needle: &str) -> bool {
    for (start, _) in haystack.match_indices(needle) {
        let before_ok = start == 0 || !haystack.as_bytes()[start - 1].is_ascii_alphanumeric();
        let end = start + needle.len();
        let after_ok = end >= haystack.len() || !haystack.as_bytes()[end].is_ascii_alphanumeric();
        if before_ok && after_ok {
            return true;
        }
    }
    false
}

/// Policy controlling retry behavior.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct RetryPolicy {
    /// Maximum number of retry attempts (not counting the initial attempt).
    #[serde(default = "default_max_attempts")]
    pub max_attempts: u32,
    /// Base delay between retries.
    #[serde(default = "default_base_delay_secs")]
    pub base_delay_secs: u64,
    /// Maximum delay cap.
    #[serde(default = "default_max_delay_secs")]
    pub max_delay_secs: u64,
    /// Whether to add random jitter.
    #[serde(default = "default_jitter")]
    pub jitter: bool,
}

fn default_max_attempts() -> u32 {
    3
}
fn default_base_delay_secs() -> u64 {
    5
}
fn default_max_delay_secs() -> u64 {
    120
}
fn default_jitter() -> bool {
    true
}

impl Default for RetryPolicy {
    fn default() -> Self {
        Self {
            max_attempts: default_max_attempts(),
            base_delay_secs: default_base_delay_secs(),
            max_delay_secs: default_max_delay_secs(),
            jitter: default_jitter(),
        }
    }
}

/// Classification of a failure for retry decisions.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum FailureClass {
    /// Transient failure — safe to retry (rate limit, timeout, network).
    Transient,
    /// Permanent failure — do not retry (auth error, bad config, code error).
    Permanent,
    /// Stall — agent stopped producing output.
    Stall,
}

/// Classify a failure based on error message content.
pub fn classify_failure(error_msg: &str) -> FailureClass {
    let lower = error_msg.to_lowercase();

    // Stall indicators — check before generic timeout to avoid misclassification
    if lower.contains("stall")
        || lower.contains("heartbeat timeout")
        || lower.contains("no activity")
    {
        return FailureClass::Stall;
    }

    // Rate limit indicators
    if lower.contains("rate limit") || lower.contains("429") || lower.contains("too many requests")
    {
        return FailureClass::Transient;
    }

    // Network/timeout indicators
    if lower.contains("timeout")
        || lower.contains("timed out")
        || lower.contains("connection reset")
        || lower.contains("connection refused")
        || lower.contains("network")
        || lower.contains("dns")
        || word_boundary_match(&lower, "eof")
        || lower.contains("broken pipe")
    {
        return FailureClass::Transient;
    }

    // Server errors — use word boundaries to avoid matching "500" in "processed 500 items"
    if word_boundary_match(&lower, "500")
        || word_boundary_match(&lower, "502")
        || word_boundary_match(&lower, "503")
        || word_boundary_match(&lower, "504")
        || lower.contains("internal server error")
        || lower.contains("service unavailable")
    {
        return FailureClass::Transient;
    }

    // Auth errors — permanent
    if lower.contains("401")
        || lower.contains("403")
        || lower.contains("unauthorized")
        || lower.contains("forbidden")
        || lower.contains("invalid api key")
        || lower.contains("authentication")
    {
        return FailureClass::Permanent;
    }

    // Default to permanent (don't retry unknown errors)
    FailureClass::Permanent
}

/// Compute exponential backoff duration for a given attempt.
pub fn compute_backoff(attempt: u32, policy: &RetryPolicy) -> Duration {
    let base = policy.base_delay_secs as f64;
    let exp = base * 2.0_f64.powi(attempt.saturating_sub(1) as i32);
    let capped = exp.min(policy.max_delay_secs as f64);

    let delay = if policy.jitter {
        // Add jitter: random value between 50% and 100% of computed delay
        let jitter_factor = 0.5 + (rand::random::<f64>() * 0.5);
        capped * jitter_factor
    } else {
        capped
    };

    Duration::from_secs_f64(delay.max(1.0))
}

/// Tracks continuation state across turns within a single thread.
#[derive(Debug, Clone)]
pub struct ContinuationState {
    pub thread_id: Option<String>,
    pub turn_count: u32,
    pub max_turns: u32,
    pub accumulated_tokens_in: u64,
    pub accumulated_tokens_out: u64,
    pub accumulated_cost_usd: f64,
    pub last_finish_reason: Option<String>,
}

impl ContinuationState {
    pub fn new(thread_id: Option<String>, max_turns: u32) -> Self {
        Self {
            thread_id,
            turn_count: 0,
            max_turns,
            accumulated_tokens_in: 0,
            accumulated_tokens_out: 0,
            accumulated_cost_usd: 0.0,
            last_finish_reason: None,
        }
    }

    /// Record a completed turn.
    pub fn record_turn(&mut self, finish_reason: &str) {
        self.turn_count += 1;
        self.last_finish_reason = Some(finish_reason.to_string());
    }

    /// Record usage from a turn.
    pub fn record_usage(&mut self, tokens_in: u64, tokens_out: u64, cost_usd: f64) {
        self.accumulated_tokens_in += tokens_in;
        self.accumulated_tokens_out += tokens_out;
        self.accumulated_cost_usd += cost_usd;
    }

    /// Whether the agent should continue with another turn.
    pub fn should_continue(&self) -> bool {
        if self.turn_count >= self.max_turns {
            return false;
        }

        match self.last_finish_reason.as_deref() {
            // Agent explicitly completed
            Some("stop") | Some("end_turn") | Some("complete") => false,
            // Agent hit max tokens — might need continuation
            Some("max_tokens") | Some("length") => true,
            // Tool use requires continuation
            Some("tool_use") => true,
            // Unknown or no finish reason — don't continue
            None => false,
            Some(_) => false,
        }
    }
}

/// Configuration for stall detection.
#[derive(Debug, Clone)]
pub struct StallDetectorConfig {
    /// How long to wait without activity before declaring a stall.
    pub heartbeat_timeout: Duration,
    /// Maximum number of stall recoveries before giving up.
    pub max_stall_retries: u32,
}

impl Default for StallDetectorConfig {
    fn default() -> Self {
        Self {
            heartbeat_timeout: Duration::from_secs(120),
            max_stall_retries: 2,
        }
    }
}

/// Detects stalls (periods of inactivity) in agent execution.
#[derive(Debug)]
pub struct StallDetector {
    config: StallDetectorConfig,
    last_activity: Instant,
    stall_count: u32,
}

impl StallDetector {
    pub fn new(config: StallDetectorConfig) -> Self {
        Self {
            config,
            last_activity: Instant::now(),
            stall_count: 0,
        }
    }

    /// Record that activity was observed (heartbeat, output, tool use, etc.).
    pub fn record_activity(&mut self) {
        self.last_activity = Instant::now();
    }

    /// Check if the agent appears to be stalled.
    pub fn is_stalled(&self) -> bool {
        self.last_activity.elapsed() > self.config.heartbeat_timeout
    }

    /// Increment the stall count and return the new count.
    pub fn increment_stall_count(&mut self) -> u32 {
        self.stall_count += 1;
        self.stall_count
    }

    /// Whether we've exceeded the maximum stall recovery attempts.
    pub fn max_stalls_exceeded(&self) -> bool {
        self.stall_count >= self.config.max_stall_retries
    }

    /// Get current stall count.
    pub fn stall_count(&self) -> u32 {
        self.stall_count
    }

    /// Reset activity timer (e.g., after recovering from a stall).
    pub fn reset(&mut self) {
        self.last_activity = Instant::now();
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    // ── classify_failure tests ──────────────────────────────

    #[test]
    fn classify_rate_limit_as_transient() {
        assert_eq!(
            classify_failure("rate limit exceeded"),
            FailureClass::Transient
        );
        assert_eq!(
            classify_failure("HTTP 429 Too Many Requests"),
            FailureClass::Transient
        );
    }

    #[test]
    fn classify_timeout_as_transient() {
        assert_eq!(
            classify_failure("connection timed out"),
            FailureClass::Transient
        );
        assert_eq!(classify_failure("request timeout"), FailureClass::Transient);
    }

    #[test]
    fn classify_server_error_as_transient() {
        assert_eq!(
            classify_failure("500 Internal Server Error"),
            FailureClass::Transient
        );
        assert_eq!(classify_failure("502 Bad Gateway"), FailureClass::Transient);
        assert_eq!(
            classify_failure("503 Service Unavailable"),
            FailureClass::Transient
        );
    }

    #[test]
    fn classify_network_as_transient() {
        assert_eq!(
            classify_failure("connection refused"),
            FailureClass::Transient
        );
        assert_eq!(
            classify_failure("DNS resolution failed"),
            FailureClass::Transient
        );
    }

    #[test]
    fn classify_stall_indicators() {
        assert_eq!(classify_failure("heartbeat timeout"), FailureClass::Stall);
        assert_eq!(
            classify_failure("no activity detected - stall"),
            FailureClass::Stall
        );
    }

    #[test]
    fn classify_auth_as_permanent() {
        assert_eq!(
            classify_failure("401 Unauthorized"),
            FailureClass::Permanent
        );
        assert_eq!(classify_failure("403 Forbidden"), FailureClass::Permanent);
        assert_eq!(classify_failure("invalid api key"), FailureClass::Permanent);
    }

    #[test]
    fn classify_unknown_as_permanent() {
        assert_eq!(
            classify_failure("some random error"),
            FailureClass::Permanent
        );
        assert_eq!(
            classify_failure("codex exited with status 1"),
            FailureClass::Permanent
        );
    }

    // ── compute_backoff tests ───────────────────────────────

    #[test]
    fn backoff_grows_exponentially() {
        let policy = RetryPolicy {
            jitter: false,
            ..Default::default()
        };
        let d1 = compute_backoff(1, &policy);
        let d2 = compute_backoff(2, &policy);
        let d3 = compute_backoff(3, &policy);
        assert_eq!(d1, Duration::from_secs(5));
        assert_eq!(d2, Duration::from_secs(10));
        assert_eq!(d3, Duration::from_secs(20));
    }

    #[test]
    fn backoff_respects_max_delay() {
        let policy = RetryPolicy {
            base_delay_secs: 30,
            max_delay_secs: 60,
            jitter: false,
            ..Default::default()
        };
        let d = compute_backoff(5, &policy);
        assert_eq!(d, Duration::from_secs(60));
    }

    #[test]
    fn backoff_with_jitter_is_bounded() {
        let policy = RetryPolicy::default(); // jitter: true
        for attempt in 1..=5 {
            let d = compute_backoff(attempt, &policy);
            assert!(
                d.as_secs() <= policy.max_delay_secs,
                "attempt {attempt}: {:?}",
                d
            );
            assert!(
                d.as_millis() >= 1000,
                "attempt {attempt}: too small {:?}",
                d
            );
        }
    }

    // ── ContinuationState tests ─────────────────────────────

    #[test]
    fn continuation_should_not_continue_when_no_turns() {
        let state = ContinuationState::new(Some("t1".into()), 5);
        assert!(!state.should_continue());
    }

    #[test]
    fn continuation_stops_on_explicit_stop() {
        let mut state = ContinuationState::new(Some("t1".into()), 5);
        state.record_turn("stop");
        assert!(!state.should_continue());
    }

    #[test]
    fn continuation_continues_on_max_tokens() {
        let mut state = ContinuationState::new(Some("t1".into()), 5);
        state.record_turn("max_tokens");
        assert!(state.should_continue());
    }

    #[test]
    fn continuation_continues_on_tool_use() {
        let mut state = ContinuationState::new(Some("t1".into()), 5);
        state.record_turn("tool_use");
        assert!(state.should_continue());
    }

    #[test]
    fn continuation_stops_at_max_turns() {
        let mut state = ContinuationState::new(Some("t1".into()), 2);
        state.record_turn("max_tokens");
        assert!(state.should_continue()); // turn 1/2
        state.record_turn("max_tokens");
        assert!(!state.should_continue()); // turn 2/2, at limit
    }

    #[test]
    fn continuation_accumulates_usage() {
        let mut state = ContinuationState::new(None, 10);
        state.record_usage(100, 50, 0.01);
        state.record_usage(200, 100, 0.02);
        assert_eq!(state.accumulated_tokens_in, 300);
        assert_eq!(state.accumulated_tokens_out, 150);
        assert!((state.accumulated_cost_usd - 0.03).abs() < f64::EPSILON);
    }

    // ── StallDetector tests ─────────────────────────────────

    #[test]
    fn stall_detector_not_stalled_initially() {
        let detector = StallDetector::new(StallDetectorConfig::default());
        assert!(!detector.is_stalled());
    }

    #[test]
    fn stall_detector_detects_timeout() {
        let config = StallDetectorConfig {
            heartbeat_timeout: Duration::from_millis(1),
            max_stall_retries: 2,
        };
        let detector = StallDetector::new(config);
        std::thread::sleep(Duration::from_millis(5));
        assert!(detector.is_stalled());
    }

    #[test]
    fn stall_detector_resets_on_activity() {
        let config = StallDetectorConfig {
            heartbeat_timeout: Duration::from_millis(50),
            max_stall_retries: 2,
        };
        let mut detector = StallDetector::new(config);
        std::thread::sleep(Duration::from_millis(60));
        assert!(detector.is_stalled());
        detector.record_activity();
        assert!(!detector.is_stalled());
    }

    #[test]
    fn stall_detector_tracks_count() {
        let mut detector = StallDetector::new(StallDetectorConfig {
            heartbeat_timeout: Duration::from_secs(120),
            max_stall_retries: 2,
        });
        assert!(!detector.max_stalls_exceeded());
        detector.increment_stall_count();
        assert!(!detector.max_stalls_exceeded());
        detector.increment_stall_count();
        assert!(detector.max_stalls_exceeded());
    }
}
