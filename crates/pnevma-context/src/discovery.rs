use crate::error::ContextError;
use pnevma_core::TaskContract;
use regex::Regex;
use serde::{Deserialize, Serialize};
use std::path::{Path, PathBuf};
use std::sync::OnceLock;
use tokio::process::Command;
use tracing::{debug, warn};

const CHARS_PER_TOKEN_ESTIMATE: usize = 4;

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct DiscoveryConfig {
    #[serde(default = "default_strategies")]
    pub strategies: Vec<String>,
    #[serde(default = "default_max_file_size_kb")]
    pub max_file_size_kb: usize,
    #[serde(default)]
    pub exclude_patterns: Vec<String>,
}

impl Default for DiscoveryConfig {
    fn default() -> Self {
        Self {
            strategies: default_strategies(),
            max_file_size_kb: 100,
            exclude_patterns: vec![
                "*.lock".to_string(),
                "node_modules/**".to_string(),
                "target/**".to_string(),
                ".git/**".to_string(),
                "dist/**".to_string(),
                "build/**".to_string(),
                ".env".to_string(),
                ".env.*".to_string(),
                "*.pem".to_string(),
                "*.key".to_string(),
                "*.p12".to_string(),
                "*.pfx".to_string(),
                "id_rsa*".to_string(),
                "*.secret".to_string(),
                "credentials*".to_string(),
                "*.keystore".to_string(),
                "*.jks".to_string(),
                ".npmrc".to_string(),
                ".pypirc".to_string(),
            ],
        }
    }
}

fn default_strategies() -> Vec<String> {
    vec![
        "scope".to_string(),
        "claude_md".to_string(),
        "git_diff".to_string(),
    ]
}

fn default_max_file_size_kb() -> usize {
    100
}

fn secret_patterns() -> &'static [Regex] {
    static PATTERNS: OnceLock<Vec<Regex>> = OnceLock::new();
    PATTERNS.get_or_init(|| {
        [
            r"AKIA[0-9A-Z]{16}",
            r"gh[pousr]_[A-Za-z0-9_]{36,255}",
            r"sk-[A-Za-z0-9]{20,}",
            r"sk-ant-[A-Za-z0-9\-]{20,}",
            "(?m)^[A-Z][A-Z0-9_]{2,}=[\"']?[A-Za-z0-9/+=]{40,}[\"']?",
            r"-----BEGIN (?:RSA |EC |DSA |OPENSSH )?PRIVATE KEY-----",
        ]
        .iter()
        .map(|p| Regex::new(p).expect("secret pattern must compile"))
        .collect()
    })
}

fn redact_secrets(content: &str) -> String {
    let mut result = content.to_string();
    for pattern in secret_patterns() {
        result = pattern.replace_all(&result, "[REDACTED]").to_string();
    }
    result
}

pub struct FileDiscovery {
    config: DiscoveryConfig,
}

impl FileDiscovery {
    pub fn new(config: DiscoveryConfig) -> Self {
        Self { config }
    }

    /// Discover relevant file contents for a task, respecting the token budget.
    pub async fn discover(
        &self,
        task: &TaskContract,
        project_root: &Path,
        token_budget: usize,
    ) -> Result<Vec<(String, String)>, ContextError> {
        let max_file_bytes = self.config.max_file_size_kb * 1024;
        let mut results: Vec<(String, String)> = Vec::new();
        let mut used_tokens = 0usize;
        let mut seen_paths = std::collections::HashSet::new();
        let canonical_root = match project_root.canonicalize() {
            Ok(p) => p,
            Err(e) => {
                warn!(error = %e, "failed to canonicalize project root");
                return Ok(results);
            }
        };

        // Reserve ~50% of budget for file contents (rest for task contract, rules, etc.)
        let file_budget = token_budget / 2;

        for strategy in &self.config.strategies {
            if used_tokens >= file_budget {
                debug!(
                    strategy = %strategy,
                    "skipping strategy — file token budget exhausted"
                );
                break;
            }

            let paths = match strategy.as_str() {
                "scope" => self.discover_scope(task, project_root).await,
                "claude_md" => self.discover_config_files(project_root).await,
                "git_diff" => self.discover_git_diff(project_root).await,
                "grep" => self.discover_grep(task, project_root).await,
                other => {
                    warn!(strategy = %other, "unknown discovery strategy, skipping");
                    Ok(vec![])
                }
            };

            let paths = match paths {
                Ok(p) => p,
                Err(e) => {
                    warn!(strategy = %strategy, error = %e, "discovery strategy failed, continuing");
                    continue;
                }
            };

            for path in paths {
                if used_tokens >= file_budget {
                    break;
                }

                let joined = if path.is_absolute() {
                    path.clone()
                } else {
                    project_root.join(&path)
                };
                let canonical = match joined.canonicalize() {
                    Ok(p) => p,
                    Err(_) => continue,
                };
                if !canonical.starts_with(&canonical_root) {
                    warn!(path = %path.display(), "path escapes project root, skipping");
                    continue;
                }

                if !canonical.is_file() {
                    continue;
                }

                let rel = canonical
                    .strip_prefix(&canonical_root)
                    .unwrap_or(&canonical)
                    .to_string_lossy()
                    .to_string();

                if seen_paths.contains(&rel) {
                    continue;
                }

                if self.is_excluded(&rel) {
                    continue;
                }

                let meta = match tokio::fs::metadata(&canonical).await {
                    Ok(m) => m,
                    Err(_) => continue,
                };

                if meta.len() as usize > max_file_bytes {
                    debug!(path = %rel, size = meta.len(), "file too large, skipping");
                    continue;
                }

                let content = match tokio::fs::read_to_string(&canonical).await {
                    Ok(c) => c,
                    Err(_) => continue, // binary file or read error
                };

                let token_cost = content.len() / CHARS_PER_TOKEN_ESTIMATE;
                if used_tokens + token_cost > file_budget {
                    // Try truncating to fit
                    let remaining_chars = (file_budget - used_tokens) * CHARS_PER_TOKEN_ESTIMATE;
                    if remaining_chars > 200 {
                        let truncated = truncate_content(&content, remaining_chars);
                        let trunc_tokens = truncated.len() / CHARS_PER_TOKEN_ESTIMATE;
                        used_tokens += trunc_tokens;
                        seen_paths.insert(rel.clone());
                        results.push((rel, redact_secrets(&truncated)));
                    }
                    break;
                }

                used_tokens += token_cost;
                seen_paths.insert(rel.clone());
                results.push((rel, redact_secrets(&content)));
            }
        }

        debug!(
            files_discovered = results.len(),
            tokens_used = used_tokens,
            file_budget = file_budget,
            "context file discovery complete"
        );

        Ok(results)
    }

    /// Strategy: read files listed in task.scope
    async fn discover_scope(
        &self,
        task: &TaskContract,
        project_root: &Path,
    ) -> Result<Vec<PathBuf>, ContextError> {
        let canonical_root = project_root.canonicalize().map_err(|e| {
            ContextError::Compile(format!("failed to canonicalize project root: {e}"))
        })?;
        let mut paths = Vec::new();
        for s in &task.scope {
            let joined = project_root.join(s);
            match joined.canonicalize() {
                Ok(p) if p.starts_with(&canonical_root) => paths.push(p),
                Ok(p) => {
                    warn!(path = %p.display(), "scope path escapes project root, skipping");
                }
                Err(_) => {
                    // File may not exist yet, include as-is for later filtering
                    paths.push(joined);
                }
            }
        }
        Ok(paths)
    }

    /// Strategy: read CLAUDE.md, AGENTS.md, README.md from project root
    async fn discover_config_files(
        &self,
        project_root: &Path,
    ) -> Result<Vec<PathBuf>, ContextError> {
        let candidates = ["CLAUDE.md", "AGENTS.md", ".claude/CLAUDE.md", "pnevma.toml"];
        Ok(candidates
            .iter()
            .map(|name| project_root.join(name))
            .filter(|p| p.is_file())
            .collect())
    }

    /// Strategy: git diff to find recently changed files
    async fn discover_git_diff(&self, project_root: &Path) -> Result<Vec<PathBuf>, ContextError> {
        // Get files changed relative to main/master
        let output = Command::new("git")
            .current_dir(project_root)
            .args(["diff", "--name-only", "HEAD~10"])
            .output()
            .await;

        let output = match output {
            Ok(o) if o.status.success() => o,
            _ => {
                // Fallback: try with just unstaged changes
                let fallback = Command::new("git")
                    .current_dir(project_root)
                    .args(["diff", "--name-only"])
                    .output()
                    .await
                    .map_err(|e| ContextError::Compile(format!("git diff failed: {e}")))?;
                fallback
            }
        };

        let stdout = String::from_utf8_lossy(&output.stdout);
        Ok(stdout
            .lines()
            .filter(|line| !line.trim().is_empty())
            .map(|line| project_root.join(line.trim()))
            .collect())
    }

    /// Strategy: grep project for keywords from task goal
    async fn discover_grep(
        &self,
        task: &TaskContract,
        project_root: &Path,
    ) -> Result<Vec<PathBuf>, ContextError> {
        // Extract meaningful keywords from task title and goal
        let text = format!("{} {}", task.title, task.goal);
        let keywords: Vec<&str> = text
            .split_whitespace()
            .filter(|w| w.len() > 3)
            .filter(|w| {
                !matches!(
                    w.to_lowercase().as_str(),
                    "the"
                        | "and"
                        | "for"
                        | "with"
                        | "from"
                        | "that"
                        | "this"
                        | "should"
                        | "implement"
                        | "create"
                        | "update"
                        | "make"
                        | "add"
                )
            })
            .take(5)
            .collect();

        if keywords.is_empty() {
            return Ok(vec![]);
        }

        let pattern = keywords
            .iter()
            .map(|kw| regex::escape(kw))
            .collect::<Vec<_>>()
            .join("|");
        let output = Command::new("grep")
            .current_dir(project_root)
            .args([
                "-r",
                "-l",
                "--include=*.rs",
                "--include=*.ts",
                "--include=*.tsx",
                "--include=*.js",
                "--include=*.py",
                "--include=*.toml",
                "--include=*.yaml",
                "--include=*.yml",
                "--include=*.md",
                "-E",
                &pattern,
                ".",
            ])
            .output()
            .await
            .map_err(|e| ContextError::Compile(format!("grep failed: {e}")))?;

        let stdout = String::from_utf8_lossy(&output.stdout);
        Ok(stdout
            .lines()
            .filter(|line| !line.trim().is_empty())
            .take(20) // limit grep results
            .map(|line| project_root.join(line.trim().trim_start_matches("./")))
            .collect())
    }

    fn is_excluded(&self, rel_path: &str) -> bool {
        self.config
            .exclude_patterns
            .iter()
            .any(|p| matches_glob_simple(p, rel_path))
    }
}

/// Simple glob matching (supports * and ** patterns).
fn matches_glob_simple(pattern: &str, path: &str) -> bool {
    if pattern.starts_with("*.") {
        // Extension match: "*.lock" matches "Cargo.lock"
        let ext = &pattern[1..];
        return path.ends_with(ext);
    }
    if let Some(prefix) = pattern.strip_suffix("/**") {
        // Directory prefix: "node_modules/**" matches "node_modules/foo/bar.js"
        return path.starts_with(prefix) || path.contains(&format!("/{prefix}/"));
    }
    if pattern.contains("**") {
        // General double-star: split and check contains
        let parts: Vec<&str> = pattern.split("**").collect();
        if parts.len() == 2 {
            return path.starts_with(parts[0]) && path.ends_with(parts[1]);
        }
    }
    // Prefix-star match: "id_rsa*" matches "id_rsa", "id_rsa.pub"
    if let Some(prefix) = pattern.strip_suffix('*') {
        if !prefix.contains('*') {
            let file_name = path.rsplit('/').next().unwrap_or(path);
            return file_name.starts_with(prefix);
        }
    }
    // Prefix-dot-star match: ".env.*" matches ".env.local", ".env.production"
    if pattern.contains(".*") && !pattern.contains("**") {
        let (before, after) = pattern.split_once(".*").unwrap_or((pattern, ""));
        let file_name = path.rsplit('/').next().unwrap_or(path);
        return file_name.starts_with(before)
            && file_name.len() > before.len()
            && (after.is_empty() || file_name.ends_with(after));
    }
    // Exact filename match: ".env" matches "path/to/.env", ".npmrc" matches "some/.npmrc"
    let file_name = path.rsplit('/').next().unwrap_or(path);
    if file_name == pattern {
        return true;
    }
    path == pattern
}

/// Truncate content at a reasonable boundary (end of line), adding a note.
fn truncate_content(content: &str, max_chars: usize) -> String {
    if content.len() <= max_chars {
        return content.to_string();
    }
    // Find the last valid char boundary at or before max_chars
    let safe_end = content
        .char_indices()
        .map(|(i, _)| i)
        .take_while(|&i| i <= max_chars)
        .last()
        .unwrap_or(0);
    // Find last newline before safe_end for a clean cut
    let cut = content[..safe_end].rfind('\n').unwrap_or(safe_end);
    let mut truncated = content[..cut].to_string();
    truncated.push_str("\n\n... [truncated — file continues] ...\n");
    truncated
}

#[cfg(test)]
mod tests {
    use super::*;
    use chrono::Utc;
    use pnevma_core::{Priority, TaskStatus};
    use uuid::Uuid;

    fn make_task(scope: Vec<String>) -> TaskContract {
        TaskContract {
            id: Uuid::new_v4(),
            title: "test task".to_string(),
            goal: "test goal".to_string(),
            scope,
            out_of_scope: vec![],
            dependencies: vec![],
            acceptance_criteria: vec![],
            constraints: vec![],
            priority: Priority::P2,
            status: TaskStatus::Ready,
            assigned_session: None,
            branch: None,
            worktree: None,
            prompt_pack: None,
            handoff_summary: None,
            auto_dispatch: false,
            agent_profile_override: None,
            execution_mode: None,
            timeout_minutes: None,
            max_retries: None,
            created_at: Utc::now(),
            updated_at: Utc::now(),
        }
    }

    #[test]
    fn glob_extension_match() {
        assert!(matches_glob_simple("*.lock", "Cargo.lock"));
        assert!(!matches_glob_simple("*.lock", "package-lock.json"));
        assert!(matches_glob_simple("*.lock", "some/path/yarn.lock"));
    }

    #[test]
    fn glob_directory_match() {
        assert!(matches_glob_simple(
            "node_modules/**",
            "node_modules/foo/bar.js"
        ));
        assert!(matches_glob_simple("target/**", "target/debug/build"));
        assert!(!matches_glob_simple("target/**", "src/target.rs"));
    }

    #[test]
    fn glob_exact_match() {
        assert!(matches_glob_simple("CLAUDE.md", "CLAUDE.md"));
        assert!(!matches_glob_simple("CLAUDE.md", "other.md"));
    }

    #[test]
    fn truncate_at_line_boundary() {
        let content = "line1\nline2\nline3\nline4\nline5";
        let truncated = truncate_content(content, 15);
        assert!(truncated.starts_with("line1\nline2"));
        assert!(truncated.contains("[truncated"));
    }

    #[test]
    fn truncate_noop_for_short_content() {
        let content = "short";
        assert_eq!(truncate_content(content, 100), "short");
    }

    #[test]
    fn truncate_preserves_truncation_note() {
        let content = "a".repeat(1000);
        let truncated = truncate_content(&content, 100);
        assert!(truncated.contains("[truncated"));
        assert!(truncated.len() < content.len());
    }

    #[test]
    fn truncate_content_handles_multibyte_utf8() {
        let content = "Hello 世界! 🌍 This is a test with multibyte characters.";
        let truncated = truncate_content(content, 10);
        // Should not panic and should produce valid UTF-8
        assert!(truncated.len() < content.len());
        // Verify it's valid UTF-8 by trying to access it
        assert!(truncated.contains("[truncated"));
    }

    #[test]
    fn truncate_content_handles_cjk_characters() {
        let content = "日本語のテスト文字列です。これは長いテキストです。";
        let truncated = truncate_content(content, 15);
        assert!(truncated.contains("[truncated"));
        // Ensure no panic from splitting multibyte chars
    }

    // ── Token budget enforcement ─────────────────────────────────────────────

    #[tokio::test]
    async fn token_budget_stops_adding_files() {
        let tmp = tempfile::tempdir().expect("tempdir");
        let root = tmp.path();

        // Create several files each ~100 bytes
        let content = "x".repeat(100);
        for i in 0..10 {
            tokio::fs::write(root.join(format!("file{i}.txt")), &content)
                .await
                .unwrap();
        }

        let task = make_task((0..10).map(|i| format!("file{i}.txt")).collect());

        // Budget of 1 token — file_budget = 0 (1/2), so no files should be included
        let fd = FileDiscovery::new(DiscoveryConfig {
            strategies: vec!["scope".to_string()],
            max_file_size_kb: 1,
            exclude_patterns: vec![],
        });
        let results = fd.discover(&task, root, 1).await.expect("discover");
        // Budget is 1/2 = 0, so no files fit
        assert!(results.is_empty());
    }

    #[tokio::test]
    async fn token_budget_admits_small_files() {
        let tmp = tempfile::tempdir().expect("tempdir");
        let root = tmp.path();

        // 4 chars = 1 token estimate
        tokio::fs::write(root.join("small.txt"), "abcd")
            .await
            .unwrap();

        let task = make_task(vec!["small.txt".to_string()]);

        let fd = FileDiscovery::new(DiscoveryConfig {
            strategies: vec!["scope".to_string()],
            max_file_size_kb: 1,
            exclude_patterns: vec![],
        });
        // Budget of 1000 tokens => file_budget = 500 >> 1 token needed
        let results = fd.discover(&task, root, 1000).await.expect("discover");
        assert_eq!(results.len(), 1);
        assert_eq!(results[0].0, "small.txt");
        assert_eq!(results[0].1, "abcd");
    }

    // ── Exclusion filter ─────────────────────────────────────────────────────

    #[tokio::test]
    async fn excluded_files_are_skipped() {
        let tmp = tempfile::tempdir().expect("tempdir");
        let root = tmp.path();

        tokio::fs::write(root.join("Cargo.lock"), "lock content")
            .await
            .unwrap();
        tokio::fs::write(root.join("main.rs"), "fn main() {}")
            .await
            .unwrap();

        let task = make_task(vec!["Cargo.lock".to_string(), "main.rs".to_string()]);

        let fd = FileDiscovery::new(DiscoveryConfig {
            strategies: vec!["scope".to_string()],
            max_file_size_kb: 10,
            exclude_patterns: vec!["*.lock".to_string()],
        });
        let results = fd.discover(&task, root, 10000).await.expect("discover");
        // Cargo.lock is excluded; only main.rs should be included
        assert_eq!(results.len(), 1);
        assert_eq!(results[0].0, "main.rs");
    }

    // ── Deduplication ────────────────────────────────────────────────────────

    #[tokio::test]
    async fn duplicate_scope_entries_deduplicated() {
        let tmp = tempfile::tempdir().expect("tempdir");
        let root = tmp.path();

        tokio::fs::write(root.join("readme.md"), "# Hello")
            .await
            .unwrap();

        // Scope lists the same file twice
        let task = make_task(vec!["readme.md".to_string(), "readme.md".to_string()]);

        let fd = FileDiscovery::new(DiscoveryConfig {
            strategies: vec!["scope".to_string()],
            max_file_size_kb: 10,
            exclude_patterns: vec![],
        });
        let results = fd.discover(&task, root, 10000).await.expect("discover");
        assert_eq!(results.len(), 1);
    }

    // ── Unknown strategy ─────────────────────────────────────────────────────

    #[tokio::test]
    async fn unknown_strategy_is_skipped_gracefully() {
        let tmp = tempfile::tempdir().expect("tempdir");
        let root = tmp.path();

        let task = make_task(vec![]);
        let fd = FileDiscovery::new(DiscoveryConfig {
            strategies: vec!["nonexistent_strategy".to_string()],
            max_file_size_kb: 10,
            exclude_patterns: vec![],
        });
        // Should not panic or error — just returns empty
        let results = fd.discover(&task, root, 10000).await.expect("discover");
        assert!(results.is_empty());
    }

    // ── Config defaults ──────────────────────────────────────────────────────

    #[test]
    fn discovery_config_default_strategies() {
        let cfg = DiscoveryConfig::default();
        assert!(cfg.strategies.contains(&"scope".to_string()));
        assert!(cfg.strategies.contains(&"claude_md".to_string()));
        assert!(cfg.strategies.contains(&"git_diff".to_string()));
    }

    #[test]
    fn discovery_config_default_excludes_common_patterns() {
        let cfg = DiscoveryConfig::default();
        assert!(cfg
            .exclude_patterns
            .iter()
            .any(|p| p.contains("node_modules")));
        assert!(cfg.exclude_patterns.iter().any(|p| p.contains("target")));
        assert!(cfg.exclude_patterns.iter().any(|p| p.contains(".git")));
    }

    #[test]
    fn default_excludes_secret_file_patterns() {
        let cfg = DiscoveryConfig::default();
        let fd = FileDiscovery::new(cfg.clone());
        assert!(fd.is_excluded(".env"));
        assert!(fd.is_excluded(".env.local"));
        assert!(fd.is_excluded("some/path/id_rsa"));
        assert!(fd.is_excluded("some/path/id_rsa.pub"));
        assert!(fd.is_excluded("creds.pem"));
        assert!(fd.is_excluded("path/.npmrc"));
        assert!(fd.is_excluded("path/.pypirc"));
    }

    #[test]
    fn redact_aws_key() {
        let input = "key = AKIAIOSFODNN7EXAMPLE";
        let output = redact_secrets(input);
        assert!(!output.contains("AKIAIOSFODNN7EXAMPLE"));
        assert!(output.contains("[REDACTED]"));
    }

    #[test]
    fn redact_github_token() {
        let input = "token = ghp_ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghij0123";
        let output = redact_secrets(input);
        assert!(!output.contains("ghp_"));
        assert!(output.contains("[REDACTED]"));
    }

    #[test]
    fn redact_openai_key() {
        let input = "OPENAI_API_KEY=sk-abcdefghijklmnopqrstuvwxyz";
        let output = redact_secrets(input);
        assert!(!output.contains("sk-abcdefghijklmnopqrstuvwxyz"));
    }

    #[test]
    fn redact_private_key_header() {
        let input = "-----BEGIN RSA PRIVATE KEY-----\nMIIEpAIBAAKCAQ...";
        let output = redact_secrets(input);
        assert!(!output.contains("BEGIN RSA PRIVATE KEY"));
    }

    #[test]
    fn redact_preserves_non_secret_content() {
        let input = "This is normal code with no secrets\nfn main() {}";
        let output = redact_secrets(input);
        assert_eq!(output, input);
    }

    #[test]
    fn grep_pattern_escapes_regex_metacharacters() {
        let keywords = ["foo.bar", "baz()", "qux+"];
        let pattern = keywords
            .iter()
            .map(|kw| regex::escape(kw))
            .collect::<Vec<_>>()
            .join("|");
        assert!(pattern.contains(r"foo\.bar"));
        assert!(pattern.contains(r"baz\(\)"));
        assert!(pattern.contains(r"qux\+"));
    }
}
