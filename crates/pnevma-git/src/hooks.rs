use serde::{Deserialize, Serialize};
use std::collections::HashMap;
use std::path::{Path, PathBuf};
use std::time::Duration;
use tokio::process::Command;
use tracing::{debug, info, warn};

/// A hook definition from WORKFLOW.md config.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct HookDef {
    /// Display name for logging.
    pub name: String,
    /// Command + arguments to execute.
    pub argv: Vec<String>,
    /// Per-hook timeout in seconds. Default: 30.
    #[serde(default = "default_hook_timeout")]
    pub timeout_seconds: u64,
    /// Additional environment variables.
    #[serde(default)]
    pub env: HashMap<String, String>,
}

fn default_hook_timeout() -> u64 {
    30
}

/// The phase at which a hook runs.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub enum HookPhase {
    AfterCreate,
    BeforeRun,
    AfterRun,
    BeforeRemove,
}

impl HookPhase {
    /// Whether this phase is fatal (failure aborts the operation) or best-effort.
    pub fn severity(&self) -> HookSeverity {
        match self {
            HookPhase::AfterCreate | HookPhase::BeforeRun => HookSeverity::Fatal,
            HookPhase::AfterRun | HookPhase::BeforeRemove => HookSeverity::BestEffort,
        }
    }

    pub fn as_str(&self) -> &'static str {
        match self {
            HookPhase::AfterCreate => "after_create",
            HookPhase::BeforeRun => "before_run",
            HookPhase::AfterRun => "after_run",
            HookPhase::BeforeRemove => "before_remove",
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum HookSeverity {
    Fatal,
    BestEffort,
}

/// Result of running a single hook.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct HookResult {
    pub hook_name: String,
    pub phase: HookPhase,
    pub exit_code: Option<i32>,
    pub stdout: String,
    pub stderr: String,
    pub duration_ms: u64,
    pub success: bool,
}

/// Errors from hook execution.
#[derive(Debug, thiserror::Error)]
pub enum HookError {
    #[error("hook '{0}' failed with exit code {1:?}")]
    Failed(String, Option<i32>),
    #[error("hook '{0}' timed out after {1}s")]
    Timeout(String, u64),
    #[error("hook config error: {0}")]
    Config(String),
}

/// Parse hook definitions from WORKFLOW.md config strings.
/// Each string is split by whitespace into argv.
pub fn parse_hook_defs(phase: HookPhase, commands: &[String]) -> Vec<HookDef> {
    commands
        .iter()
        .enumerate()
        .filter_map(|(i, cmd)| {
            let argv: Vec<String> = cmd.split_whitespace().map(String::from).collect();
            if argv.is_empty() {
                return None;
            }
            Some(HookDef {
                name: format!("{}-{}", phase.as_str(), i),
                argv,
                timeout_seconds: default_hook_timeout(),
                env: HashMap::new(),
            })
        })
        .collect()
}

/// Validate that the hook binary is safe to execute.
/// Rejects symlinks that point outside the repo root.
pub fn validate_hook_binary(argv0: &str, repo_root: &Path) -> Result<PathBuf, HookError> {
    let binary_path = if Path::new(argv0).is_absolute() {
        PathBuf::from(argv0)
    } else {
        repo_root.join(argv0)
    };

    let metadata = std::fs::symlink_metadata(&binary_path)
        .map_err(|e| HookError::Config(format!("cannot stat hook binary '{}': {}", argv0, e)))?;

    if metadata.file_type().is_symlink() {
        let target = std::fs::read_link(&binary_path)
            .map_err(|e| HookError::Config(format!("cannot read symlink '{}': {}", argv0, e)))?;
        let resolved = if target.is_absolute() {
            target
        } else {
            binary_path.parent().unwrap_or(Path::new("/")).join(&target)
        };
        let canonical = resolved
            .canonicalize()
            .map_err(|e| HookError::Config(format!("cannot resolve symlink target: {}", e)))?;
        let canonical_repo = repo_root
            .canonicalize()
            .map_err(|e| HookError::Config(format!("cannot resolve repo root: {}", e)))?;
        if !canonical.starts_with(&canonical_repo) {
            return Err(HookError::Config(format!(
                "hook binary '{}' is a symlink pointing outside the repo ({})",
                argv0,
                canonical.display()
            )));
        }
    }

    Ok(binary_path)
}

/// Run a single hook command.
pub async fn run_single_hook(
    hook: &HookDef,
    phase: HookPhase,
    worktree_path: &Path,
    task_id: &str,
    branch: &str,
    redaction_secrets: &[String],
) -> HookResult {
    let start = std::time::Instant::now();

    let mut cmd = Command::new(&hook.argv[0]);
    if hook.argv.len() > 1 {
        cmd.args(&hook.argv[1..]);
    }
    cmd.current_dir(worktree_path)
        .env(
            "PNEVMA_WORKTREE_PATH",
            worktree_path.to_string_lossy().as_ref(),
        )
        .env("PNEVMA_TASK_ID", task_id)
        .env("PNEVMA_BRANCH", branch)
        .env("PNEVMA_HOOK_PHASE", phase.as_str());

    for (k, v) in &hook.env {
        cmd.env(k, v);
    }

    let timeout_dur = Duration::from_secs(hook.timeout_seconds);

    let output = match tokio::time::timeout(timeout_dur, cmd.output()).await {
        Ok(Ok(output)) => output,
        Ok(Err(e)) => {
            return HookResult {
                hook_name: hook.name.clone(),
                phase,
                exit_code: None,
                stdout: String::new(),
                stderr: format!("spawn error: {}", e),
                duration_ms: start.elapsed().as_millis() as u64,
                success: false,
            };
        }
        Err(_) => {
            return HookResult {
                hook_name: hook.name.clone(),
                phase,
                exit_code: None,
                stdout: String::new(),
                stderr: format!("hook timed out after {}s", hook.timeout_seconds),
                duration_ms: start.elapsed().as_millis() as u64,
                success: false,
            };
        }
    };

    let mut stdout = String::from_utf8_lossy(&output.stdout).to_string();
    let mut stderr = String::from_utf8_lossy(&output.stderr).to_string();

    // Redact secrets from output
    for secret in redaction_secrets {
        if !secret.is_empty() {
            stdout = stdout.replace(secret, "***");
            stderr = stderr.replace(secret, "***");
        }
    }

    // Truncate long output
    const MAX_OUTPUT: usize = 4096;
    if stdout.len() > MAX_OUTPUT {
        stdout.truncate(MAX_OUTPUT);
        stdout.push_str("...(truncated)");
    }
    if stderr.len() > MAX_OUTPUT {
        stderr.truncate(MAX_OUTPUT);
        stderr.push_str("...(truncated)");
    }

    HookResult {
        hook_name: hook.name.clone(),
        phase,
        exit_code: output.status.code(),
        stdout,
        stderr,
        duration_ms: start.elapsed().as_millis() as u64,
        success: output.status.success(),
    }
}

/// Run all hooks for a given phase.
///
/// For Fatal phases (AfterCreate, BeforeRun): returns error on first failure.
/// For BestEffort phases (AfterRun, BeforeRemove): logs warnings, always returns Ok.
pub async fn run_hooks(
    hooks: &[HookDef],
    phase: HookPhase,
    worktree_path: &Path,
    task_id: &str,
    branch: &str,
    redaction_secrets: &[String],
) -> Result<Vec<HookResult>, HookError> {
    if hooks.is_empty() {
        return Ok(Vec::new());
    }

    let severity = phase.severity();
    let mut results = Vec::with_capacity(hooks.len());

    for hook in hooks {
        debug!(hook = %hook.name, phase = %phase.as_str(), "running hook");
        let result = run_single_hook(
            hook,
            phase,
            worktree_path,
            task_id,
            branch,
            redaction_secrets,
        )
        .await;

        info!(
            hook = %result.hook_name,
            phase = %phase.as_str(),
            success = result.success,
            duration_ms = result.duration_ms,
            exit_code = ?result.exit_code,
            "hook completed"
        );

        if !result.success {
            match severity {
                HookSeverity::Fatal => {
                    let err = if result.exit_code.is_none() && result.stderr.contains("timed out") {
                        HookError::Timeout(hook.name.clone(), hook.timeout_seconds)
                    } else {
                        HookError::Failed(hook.name.clone(), result.exit_code)
                    };
                    results.push(result);
                    return Err(err);
                }
                HookSeverity::BestEffort => {
                    warn!(
                        hook = %result.hook_name,
                        stderr = %result.stderr,
                        "best-effort hook failed, continuing"
                    );
                }
            }
        }

        results.push(result);
    }

    Ok(results)
}

#[cfg(test)]
mod tests {
    use super::*;
    use tempfile::TempDir;

    #[test]
    fn test_parse_hook_defs_from_strings() {
        let commands = vec!["echo hello".to_string(), "make lint".to_string()];
        let hooks = parse_hook_defs(HookPhase::AfterCreate, &commands);
        assert_eq!(hooks.len(), 2);
        assert_eq!(hooks[0].argv, vec!["echo", "hello"]);
        assert_eq!(hooks[1].argv, vec!["make", "lint"]);
    }

    #[test]
    fn test_parse_hook_defs_skips_empty() {
        let commands = vec!["".to_string(), "echo ok".to_string()];
        let hooks = parse_hook_defs(HookPhase::BeforeRun, &commands);
        assert_eq!(hooks.len(), 1);
    }

    #[test]
    fn test_hook_phase_severity() {
        assert_eq!(HookPhase::AfterCreate.severity(), HookSeverity::Fatal);
        assert_eq!(HookPhase::BeforeRun.severity(), HookSeverity::Fatal);
        assert_eq!(HookPhase::AfterRun.severity(), HookSeverity::BestEffort);
        assert_eq!(HookPhase::BeforeRemove.severity(), HookSeverity::BestEffort);
    }

    #[test]
    fn test_validate_hook_binary_rejects_external_symlink() {
        let dir = TempDir::new().unwrap();
        let repo_root = dir.path();
        let hook_path = repo_root.join("hook.sh");
        std::os::unix::fs::symlink("/usr/bin/env", &hook_path).unwrap();
        let result = validate_hook_binary("hook.sh", repo_root);
        assert!(result.is_err());
        assert!(result.unwrap_err().to_string().contains("outside the repo"));
    }

    #[test]
    fn test_validate_hook_binary_accepts_internal_symlink() {
        let dir = TempDir::new().unwrap();
        let repo_root = dir.path();
        let real_script = repo_root.join("scripts/real.sh");
        std::fs::create_dir_all(repo_root.join("scripts")).unwrap();
        std::fs::write(&real_script, "#!/bin/sh\necho ok").unwrap();
        let hook_path = repo_root.join("hook.sh");
        std::os::unix::fs::symlink("scripts/real.sh", &hook_path).unwrap();
        let result = validate_hook_binary("hook.sh", repo_root);
        assert!(result.is_ok());
    }

    #[tokio::test]
    async fn test_run_single_hook_success() {
        let dir = TempDir::new().unwrap();
        let hook = HookDef {
            name: "test-echo".to_string(),
            argv: vec!["echo".to_string(), "hello".to_string()],
            timeout_seconds: 5,
            env: HashMap::new(),
        };
        let result = run_single_hook(
            &hook,
            HookPhase::AfterCreate,
            dir.path(),
            "task-123",
            "feat/test",
            &[],
        )
        .await;
        assert!(result.success);
        assert!(result.stdout.contains("hello"));
    }

    #[tokio::test]
    async fn test_run_single_hook_timeout() {
        let dir = TempDir::new().unwrap();
        let hook = HookDef {
            name: "test-sleep".to_string(),
            argv: vec!["sleep".to_string(), "60".to_string()],
            timeout_seconds: 1,
            env: HashMap::new(),
        };
        let result = run_single_hook(
            &hook,
            HookPhase::BeforeRun,
            dir.path(),
            "task-123",
            "feat/test",
            &[],
        )
        .await;
        assert!(!result.success);
        assert!(result.stderr.contains("timed out"));
    }

    #[tokio::test]
    async fn test_fatal_hook_failure_returns_error() {
        let dir = TempDir::new().unwrap();
        let hooks = vec![HookDef {
            name: "test-fail".to_string(),
            argv: vec!["false".to_string()],
            timeout_seconds: 5,
            env: HashMap::new(),
        }];
        let result = run_hooks(
            &hooks,
            HookPhase::AfterCreate,
            dir.path(),
            "task-123",
            "feat/test",
            &[],
        )
        .await;
        assert!(result.is_err());
    }

    #[tokio::test]
    async fn test_best_effort_hook_failure_continues() {
        let dir = TempDir::new().unwrap();
        let hooks = vec![
            HookDef {
                name: "test-fail".to_string(),
                argv: vec!["false".to_string()],
                timeout_seconds: 5,
                env: HashMap::new(),
            },
            HookDef {
                name: "test-ok".to_string(),
                argv: vec!["true".to_string()],
                timeout_seconds: 5,
                env: HashMap::new(),
            },
        ];
        let result = run_hooks(
            &hooks,
            HookPhase::AfterRun,
            dir.path(),
            "task-123",
            "feat/test",
            &[],
        )
        .await;
        assert!(result.is_ok());
        let results = result.unwrap();
        assert_eq!(results.len(), 2);
        assert!(!results[0].success);
        assert!(results[1].success);
    }

    #[tokio::test]
    async fn test_redaction_in_hook_output() {
        let dir = TempDir::new().unwrap();
        let hook = HookDef {
            name: "test-secret".to_string(),
            argv: vec!["echo".to_string(), "my-secret-token".to_string()],
            timeout_seconds: 5,
            env: HashMap::new(),
        };
        let result = run_single_hook(
            &hook,
            HookPhase::AfterCreate,
            dir.path(),
            "task-123",
            "feat/test",
            &["my-secret-token".to_string()],
        )
        .await;
        assert!(result.success);
        assert!(!result.stdout.contains("my-secret-token"));
        assert!(result.stdout.contains("***"));
    }
}
