use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use std::path::Path;

// --- Default value functions ---

fn default_enabled() -> bool {
    true
}

fn default_poll_interval() -> u64 {
    30
}

fn default_max_concurrent() -> usize {
    4
}

fn default_active_statuses() -> Vec<String> {
    vec!["Ready".to_string()]
}

fn default_max_retries() -> u32 {
    1
}

fn default_backoff_seconds() -> u64 {
    60
}

// --- Config structs ---

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct WorkflowMdConfig {
    #[serde(default = "default_enabled")]
    pub enabled: bool,
    #[serde(default = "default_poll_interval")]
    pub poll_interval_seconds: u64,
    #[serde(default = "default_max_concurrent")]
    pub max_concurrent: usize,
    #[serde(default = "default_active_statuses")]
    pub active_task_statuses: Vec<String>,
    #[serde(default)]
    pub hooks: WorkflowHooks,
    #[serde(default)]
    pub retry: RetryDefaults,
    #[serde(default)]
    pub agent: AgentDefaults,
    #[serde(default)]
    pub tracker: Option<TrackerSettings>,
    #[serde(default)]
    pub prompt_template: Option<String>,
}

impl Default for WorkflowMdConfig {
    fn default() -> Self {
        Self {
            enabled: default_enabled(),
            poll_interval_seconds: default_poll_interval(),
            max_concurrent: default_max_concurrent(),
            active_task_statuses: default_active_statuses(),
            hooks: WorkflowHooks::default(),
            retry: RetryDefaults::default(),
            agent: AgentDefaults::default(),
            tracker: None,
            prompt_template: None,
        }
    }
}

#[derive(Debug, Clone, Default, Serialize, Deserialize)]
pub struct WorkflowHooks {
    pub after_create: Option<Vec<String>>,
    pub before_run: Option<Vec<String>>,
    pub after_run: Option<Vec<String>>,
    pub before_remove: Option<Vec<String>>,
    pub verify: Option<Vec<VerificationHook>>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct VerificationHook {
    pub command: String,
    pub description: String,
    #[serde(default = "default_verify_timeout")]
    pub timeout_seconds: u64,
    #[serde(default = "default_verify_retries")]
    pub max_retries: u32,
}

fn default_verify_timeout() -> u64 {
    120
}

fn default_verify_retries() -> u32 {
    2
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct RetryDefaults {
    #[serde(default = "default_max_retries")]
    pub max_retries: u32,
    #[serde(default = "default_backoff_seconds")]
    pub backoff_seconds: u64,
}

impl Default for RetryDefaults {
    fn default() -> Self {
        Self {
            max_retries: default_max_retries(),
            backoff_seconds: default_backoff_seconds(),
        }
    }
}

#[derive(Debug, Clone, Default, Serialize, Deserialize)]
pub struct AgentDefaults {
    pub provider: Option<String>,
    pub model: Option<String>,
    pub timeout_minutes: Option<u64>,
    pub auto_approve: Option<bool>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct TrackerSettings {
    pub provider: String,
    pub project_key: Option<String>,
    #[serde(default)]
    pub sync_statuses: Vec<String>,
}

// --- Document ---

#[derive(Debug, Clone)]
pub struct WorkflowDocument {
    pub config: WorkflowMdConfig,
    pub body_markdown: String,
    pub source_hash: String,
}

// --- Errors ---

#[derive(Debug, thiserror::Error)]
pub enum WorkflowParseError {
    #[error("missing YAML front matter delimiters (---)")]
    MissingFrontMatter,
    #[error("invalid YAML: {0}")]
    InvalidYaml(String),
    #[error("validation error: {0}")]
    Validation(String),
    #[error("io error: {0}")]
    Io(#[from] std::io::Error),
}

// --- Implementation ---

impl WorkflowDocument {
    pub fn parse(content: &str) -> Result<Self, WorkflowParseError> {
        // Compute hash of the full content first
        let mut hasher = Sha256::new();
        hasher.update(content.as_bytes());
        let source_hash = format!("{:x}", hasher.finalize());

        // Trim leading whitespace/newlines before the first delimiter
        let trimmed = content.trim_start();
        if !trimmed.starts_with("---") {
            return Err(WorkflowParseError::MissingFrontMatter);
        }

        // Skip past the opening "---" line
        let after_open = &trimmed["---".len()..];
        // The opening delimiter must be followed by a newline (or end of string)
        let after_open = after_open
            .strip_prefix('\n')
            .or_else(|| after_open.strip_prefix("\r\n"))
            .unwrap_or(after_open);

        // Find closing "---"
        let close_marker = "\n---";
        let close_pos = after_open
            .find(close_marker)
            .ok_or(WorkflowParseError::MissingFrontMatter)?;

        let yaml_str = &after_open[..close_pos];
        let after_close = &after_open[close_pos + close_marker.len()..];

        // Body is everything after the closing delimiter line
        let body_markdown = after_close
            .strip_prefix('\n')
            .or_else(|| after_close.strip_prefix("\r\n"))
            .unwrap_or(after_close)
            .to_string();

        // Parse YAML
        let config: WorkflowMdConfig = serde_yaml::from_str(yaml_str)
            .map_err(|e| WorkflowParseError::InvalidYaml(e.to_string()))?;

        Ok(Self {
            config,
            body_markdown,
            source_hash,
        })
    }

    pub fn from_file(path: &Path) -> Result<Self, WorkflowParseError> {
        let content = std::fs::read_to_string(path)?;
        Self::parse(&content)
    }

    pub fn validate(&self) -> Result<(), WorkflowParseError> {
        if self.config.poll_interval_seconds == 0 {
            return Err(WorkflowParseError::Validation(
                "poll_interval_seconds must be > 0".into(),
            ));
        }
        if self.config.max_concurrent == 0 {
            return Err(WorkflowParseError::Validation(
                "max_concurrent must be > 0".into(),
            ));
        }
        Ok(())
    }
}

// --- Tests ---

#[cfg(test)]
mod tests {
    use super::*;

    const VALID_WORKFLOW: &str = r#"---
enabled: true
poll_interval_seconds: 15
max_concurrent: 2
active_task_statuses:
  - Ready
  - In Progress
hooks:
  after_create:
    - "echo created"
retry:
  max_retries: 3
  backoff_seconds: 30
agent:
  provider: "anthropic"
  model: "claude-opus-4-6"
  timeout_minutes: 60
  auto_approve: false
---
# My Workflow

This is the body of the workflow document.
"#;

    #[test]
    fn test_parse_valid_workflow_md() {
        let doc = WorkflowDocument::parse(VALID_WORKFLOW).expect("should parse");

        assert!(doc.config.enabled);
        assert_eq!(doc.config.poll_interval_seconds, 15);
        assert_eq!(doc.config.max_concurrent, 2);
        assert_eq!(
            doc.config.active_task_statuses,
            vec!["Ready".to_string(), "In Progress".to_string()]
        );
        assert_eq!(
            doc.config.hooks.after_create,
            Some(vec!["echo created".to_string()])
        );
        assert_eq!(doc.config.retry.max_retries, 3);
        assert_eq!(doc.config.retry.backoff_seconds, 30);
        assert_eq!(doc.config.agent.provider, Some("anthropic".to_string()));
        assert!(doc.body_markdown.contains("# My Workflow"));
        assert!(!doc.source_hash.is_empty());
    }

    #[test]
    fn test_parse_missing_front_matter() {
        let content = "# Just a markdown file\n\nNo front matter here.\n";
        let err = WorkflowDocument::parse(content).unwrap_err();
        assert!(
            matches!(err, WorkflowParseError::MissingFrontMatter),
            "expected MissingFrontMatter, got: {err}"
        );
    }

    #[test]
    fn test_parse_missing_closing_delimiter() {
        let content = "---\nenabled: true\n# No closing delimiter\n";
        let err = WorkflowDocument::parse(content).unwrap_err();
        assert!(
            matches!(err, WorkflowParseError::MissingFrontMatter),
            "expected MissingFrontMatter, got: {err}"
        );
    }

    #[test]
    fn test_parse_invalid_yaml() {
        let content = "---\nenabled: [unclosed bracket\n---\n# Body\n";
        let err = WorkflowDocument::parse(content).unwrap_err();
        assert!(
            matches!(err, WorkflowParseError::InvalidYaml(_)),
            "expected InvalidYaml, got: {err}"
        );
    }

    #[test]
    fn test_defaults_when_fields_omitted() {
        let content = "---\n{}\n---\n";
        let doc = WorkflowDocument::parse(content).expect("should parse empty front matter");

        assert!(doc.config.enabled);
        assert_eq!(doc.config.poll_interval_seconds, 30);
        assert_eq!(doc.config.max_concurrent, 4);
        assert_eq!(doc.config.active_task_statuses, vec!["Ready".to_string()]);
        assert_eq!(doc.config.retry.max_retries, 1);
        assert_eq!(doc.config.retry.backoff_seconds, 60);
        assert!(doc.config.agent.provider.is_none());
        assert!(doc.config.tracker.is_none());
        assert!(doc.config.prompt_template.is_none());
    }

    #[test]
    fn test_validate_rejects_zero_poll_interval() {
        let content = "---\npoll_interval_seconds: 0\n---\n";
        let doc = WorkflowDocument::parse(content).expect("should parse");
        let err = doc.validate().unwrap_err();
        assert!(
            matches!(err, WorkflowParseError::Validation(_)),
            "expected Validation error, got: {err}"
        );
    }

    #[test]
    fn test_validate_rejects_zero_max_concurrent() {
        let content = "---\nmax_concurrent: 0\n---\n";
        let doc = WorkflowDocument::parse(content).expect("should parse");
        let err = doc.validate().unwrap_err();
        assert!(
            matches!(err, WorkflowParseError::Validation(_)),
            "expected Validation error, got: {err}"
        );
    }

    #[test]
    fn test_source_hash_is_deterministic() {
        let content = "---\nenabled: true\n---\n# Body\n";
        let doc1 = WorkflowDocument::parse(content).unwrap();
        let doc2 = WorkflowDocument::parse(content).unwrap();
        assert_eq!(doc1.source_hash, doc2.source_hash);
    }

    #[test]
    fn test_source_hash_differs_for_different_content() {
        let content1 = "---\nenabled: true\n---\n# Body\n";
        let content2 = "---\nenabled: false\n---\n# Body\n";
        let doc1 = WorkflowDocument::parse(content1).unwrap();
        let doc2 = WorkflowDocument::parse(content2).unwrap();
        assert_ne!(doc1.source_hash, doc2.source_hash);
    }
}
