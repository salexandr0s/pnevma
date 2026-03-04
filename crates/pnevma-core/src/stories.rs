use regex::Regex;
use serde::{Deserialize, Serialize};
use std::sync::OnceLock;

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum StoryStatus {
    Pending,
    InProgress,
    Completed,
    Failed,
    Skipped,
}

impl StoryStatus {
    pub fn as_str(&self) -> &'static str {
        match self {
            StoryStatus::Pending => "pending",
            StoryStatus::InProgress => "in_progress",
            StoryStatus::Completed => "completed",
            StoryStatus::Failed => "failed",
            StoryStatus::Skipped => "skipped",
        }
    }
}

#[derive(Debug, Clone)]
pub struct DetectedStory {
    pub current: usize,
    pub total: usize,
    pub title: String,
}

/// Detect progress-indicating patterns in agent output lines.
pub struct StoryDetector;

impl StoryDetector {
    pub fn new() -> Self { Self }

    /// Scan a line for progress patterns. Returns the detected story info if found.
    pub fn detect(&self, line: &str) -> Option<DetectedStory> {
        // Pattern: "Processing file 3 of 8: user-profile.tsx"
        if let Some(caps) = processing_file_re().captures(line) {
            let current: usize = caps.get(1)?.as_str().parse().ok()?;
            let total: usize = caps.get(2)?.as_str().parse().ok()?;
            let title = caps.get(3).map(|m| m.as_str().trim().to_string())
                .unwrap_or_else(|| format!("Step {current}"));
            return Some(DetectedStory { current, total, title });
        }

        // Pattern: "[3/8] Linting..."
        if let Some(caps) = bracket_fraction_re().captures(line) {
            let current: usize = caps.get(1)?.as_str().parse().ok()?;
            let total: usize = caps.get(2)?.as_str().parse().ok()?;
            let title = caps.get(3).map(|m| m.as_str().trim().to_string())
                .unwrap_or_else(|| format!("Step {current}"));
            return Some(DetectedStory { current, total, title });
        }

        // Pattern: "Step 2/5: Running tests"
        if let Some(caps) = step_of_re().captures(line) {
            let current: usize = caps.get(1)?.as_str().parse().ok()?;
            let total: usize = caps.get(2)?.as_str().parse().ok()?;
            let title = caps.get(3).map(|m| m.as_str().trim().to_string())
                .unwrap_or_else(|| format!("Step {current}"));
            return Some(DetectedStory { current, total, title });
        }

        // Pattern: "3 of 8" or "3/8"
        if let Some(caps) = progress_fraction_re().captures(line) {
            let current: usize = caps.get(1)?.as_str().parse().ok()?;
            let total: usize = caps.get(2)?.as_str().parse().ok()?;
            if total >= 2 {
                return Some(DetectedStory { current, total, title: format!("Step {current}") });
            }
        }

        None
    }
}

impl Default for StoryDetector {
    fn default() -> Self { Self::new() }
}

fn progress_fraction_re() -> &'static Regex {
    static RE: OnceLock<Regex> = OnceLock::new();
    RE.get_or_init(|| Regex::new(r"(\d+)\s*(?:of|/)\s*(\d+)").unwrap())
}

fn bracket_fraction_re() -> &'static Regex {
    static RE: OnceLock<Regex> = OnceLock::new();
    RE.get_or_init(|| Regex::new(r"\[(\d+)/(\d+)\]\s*(.*)").unwrap())
}

fn step_of_re() -> &'static Regex {
    static RE: OnceLock<Regex> = OnceLock::new();
    RE.get_or_init(|| Regex::new(r"(?i)step\s+(\d+)\s*/\s*(\d+)\s*:?\s*(.*)").unwrap())
}

fn processing_file_re() -> &'static Regex {
    static RE: OnceLock<Regex> = OnceLock::new();
    RE.get_or_init(|| Regex::new(r"(?i)processing\s+(?:file\s+)?(\d+)\s+of\s+(\d+)\s*:?\s*(.*)").unwrap())
}
