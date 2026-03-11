// =============================================================================
// Dead code extracted from the Pnevma Rust codebase.
// Moved here on 2026-03-11 as part of a dead code audit.
// Each section notes the original file and why it was dead.
// =============================================================================

// ---------------------------------------------------------------------------
// From pnevma-core/src/stories.rs
// StoryDetector and DetectedStory were exported but never used outside the file.
// StoryStatus::as_str() was never called anywhere.
// ---------------------------------------------------------------------------

/*
use regex::Regex;
use std::sync::OnceLock;

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

pub struct StoryDetector;

impl StoryDetector {
    pub fn new() -> Self { Self }

    pub fn detect(&self, line: &str) -> Option<DetectedStory> {
        if let Some(caps) = processing_file_re().captures(line) {
            let current: usize = caps.get(1)?.as_str().parse().ok()?;
            let total: usize = caps.get(2)?.as_str().parse().ok()?;
            let title = caps.get(3).map(|m| m.as_str().trim().to_string())
                .unwrap_or_else(|| format!("Step {current}"));
            return Some(DetectedStory { current, total, title });
        }
        if let Some(caps) = bracket_fraction_re().captures(line) {
            let current: usize = caps.get(1)?.as_str().parse().ok()?;
            let total: usize = caps.get(2)?.as_str().parse().ok()?;
            let title = caps.get(3).map(|m| m.as_str().trim().to_string())
                .unwrap_or_else(|| format!("Step {current}"));
            return Some(DetectedStory { current, total, title });
        }
        if let Some(caps) = step_of_re().captures(line) {
            let current: usize = caps.get(1)?.as_str().parse().ok()?;
            let total: usize = caps.get(2)?.as_str().parse().ok()?;
            let title = caps.get(3).map(|m| m.as_str().trim().to_string())
                .unwrap_or_else(|| format!("Step {current}"));
            return Some(DetectedStory { current, total, title });
        }
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
*/

// ---------------------------------------------------------------------------
// From pnevma-context/src/compiler.rs
// ContextCompileMode::V1 was never constructed — all code uses V2.
// compile_v1() was therefore unreachable.
// ---------------------------------------------------------------------------

/*
// Enum variant:
//   V1,

fn compile_v1(
    &self,
    input: ContextCompileInput,
) -> Result<ContextCompilerResult, ContextError> {
    let task = self.redact_task(input.task);
    if task.goal.trim().is_empty() {
        return Err(ContextError::Compile(
            "task goal cannot be empty for context compilation".to_string(),
        ));
    }
    let project_brief = self.redact_string(&input.project_brief);
    let architecture_notes = self.redact_string(&input.architecture_notes);
    let conventions = self.redact_strings(&input.conventions);
    let rules = self.redact_strings(&input.rules);
    let relevant_file_contents = self.redact_file_contents(&input.relevant_file_contents);
    let prior_task_summaries = self.redact_strings(&input.prior_task_summaries);
    let markdown = format!(
        "# Task Context\n\n## Goal\n{}\n\n## Acceptance Criteria\n{}\n\n## Constraints\n{}\n\n## Scope\n{}\n\n## Rules\n{}\n",
        task.goal,
        task.acceptance_criteria.iter().map(|c| format!("- {}", c.description)).collect::<Vec<_>>().join("\n"),
        task.constraints.iter().map(|c| format!("- {}", c)).collect::<Vec<_>>().join("\n"),
        task.scope.iter().map(|s| format!("- {}", s)).collect::<Vec<_>>().join("\n"),
        rules.iter().map(|r| format!("- {}", r)).collect::<Vec<_>>().join("\n")
    );

    let pack = ContextPack {
        task_contract: Box::new(task),
        project_brief,
        architecture_notes,
        conventions,
        rules,
        relevant_file_contents,
        prior_task_summaries,
        token_budget: self.config.token_budget,
        actual_tokens: markdown.len() / 4,
        manifest: vec![ContextManifestItem {
            kind: "v1_simplified".to_string(),
            included: true,
            reason: None,
        }],
    };

    Ok(ContextCompilerResult { pack, markdown })
}
*/

// ---------------------------------------------------------------------------
// From pnevma-remote/src/lib.rs
// RemoteServerHandle::wait() — zero callers anywhere.
// ---------------------------------------------------------------------------

/*
pub async fn wait(self) {
    let _ = self.join.await;
}
*/

// ---------------------------------------------------------------------------
// From pnevma-git/src/lib.rs
// Re-exports never imported outside the crate.
// ---------------------------------------------------------------------------

/*
// Removed from pub use:
//   HookSeverity  (hooks::HookSeverity — used internally but never imported externally)
//   MergeQueue    (service::MergeQueue — used only in pnevma-git tests)
*/
