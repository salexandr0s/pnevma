use crate::state::AppState;
use chrono::{DateTime, Utc};
use serde::{de::Deserializer, Deserialize, Serialize};
use serde_json::json;
use std::collections::BTreeSet;
use std::collections::HashMap;
use std::path::PathBuf;
use std::process::Stdio;
use std::sync::atomic::{AtomicBool, Ordering};
use tokio::process::Command as TokioCommand;
use tokio::sync::{Mutex, RwLock};
use tokio::task::JoinHandle;
use tokio::time::{sleep, timeout, Duration};

const GITHUB_HOST: &str = "github.com";
const STATUS_STALE_AFTER: Duration = Duration::from_secs(5);
const BACKGROUND_REFRESH_INTERVAL: Duration = Duration::from_secs(15);
const BACKGROUND_FORCED_REFRESH_INTERVAL: chrono::Duration = chrono::Duration::seconds(60);
const LOGIN_TIMEOUT: Duration = Duration::from_secs(300);

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct GitHubAuthAccountView {
    pub login: String,
    pub active: bool,
    pub state: String,
    pub token_source: Option<String>,
    pub git_protocol: Option<String>,
    pub scopes: Vec<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct GitHubGitHelperStatusView {
    pub state: String,
    pub message: String,
    pub detail: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct GitHubAuthJobView {
    pub state: String,
    pub message: Option<String>,
    pub started_at: DateTime<Utc>,
    pub finished_at: Option<DateTime<Utc>>,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct GitHubAuthStatusView {
    pub host: String,
    pub cli_available: bool,
    pub active_login: Option<String>,
    pub accounts: Vec<GitHubAuthAccountView>,
    pub git_helper: GitHubGitHelperStatusView,
    pub auth_job: Option<GitHubAuthJobView>,
    pub error: Option<String>,
    pub last_refreshed_at: Option<DateTime<Utc>>,
}

impl Default for GitHubAuthStatusView {
    fn default() -> Self {
        Self {
            host: GITHUB_HOST.to_string(),
            cli_available: false,
            active_login: None,
            accounts: Vec::new(),
            git_helper: helper_unknown_status(),
            auth_job: None,
            error: None,
            last_refreshed_at: None,
        }
    }
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct GitHubAuthSwitchInput {
    pub login: String,
}

#[derive(Debug, Default)]
pub struct GitHubAuthRuntimeState {
    pub snapshot: RwLock<Option<GitHubAuthStatusView>>,
    pub refresh_lock: Mutex<()>,
    pub monitor_task: Mutex<Option<JoinHandle<()>>>,
    pub auth_job_running: AtomicBool,
    pub last_hosts_mtime: Mutex<Option<std::time::SystemTime>>,
}

#[derive(Debug, Deserialize)]
struct GhAuthStatusJson {
    hosts: HashMap<String, Vec<GhAuthStatusAccountJson>>,
}

#[derive(Debug, Clone, Deserialize)]
struct GhAuthStatusAccountJson {
    active: bool,
    login: String,
    state: String,
    #[serde(rename = "tokenSource")]
    token_source: Option<String>,
    #[serde(rename = "gitProtocol")]
    git_protocol: Option<String>,
    #[serde(default, deserialize_with = "deserialize_scopes")]
    scopes: Vec<String>,
}

fn deserialize_scopes<'de, D>(deserializer: D) -> Result<Vec<String>, D::Error>
where
    D: Deserializer<'de>,
{
    #[derive(Deserialize)]
    #[serde(untagged)]
    enum Scopes {
        List(Vec<String>),
        Csv(String),
    }

    Ok(match Option::<Scopes>::deserialize(deserializer)? {
        Some(Scopes::List(scopes)) => scopes,
        Some(Scopes::Csv(scopes)) => scopes
            .split(',')
            .map(str::trim)
            .filter(|scope| !scope.is_empty())
            .map(ToOwned::to_owned)
            .collect(),
        None => Vec::new(),
    })
}

fn helper_unknown_status() -> GitHubGitHelperStatusView {
    GitHubGitHelperStatusView {
        state: "unknown".to_string(),
        message: "Git helper status is unavailable.".to_string(),
        detail: None,
    }
}

fn helper_ready_status() -> GitHubGitHelperStatusView {
    GitHubGitHelperStatusView {
        state: "ready".to_string(),
        message: "GitHub CLI is configured as a Git credential helper for GitHub HTTPS remotes."
            .to_string(),
        detail: None,
    }
}

fn helper_warning_status(detail: Option<String>) -> GitHubGitHelperStatusView {
    GitHubGitHelperStatusView {
        state: "warning".to_string(),
        message: "Git HTTPS auth is not currently managed by GitHub CLI.".to_string(),
        detail,
    }
}

fn helper_error_status(detail: String) -> GitHubGitHelperStatusView {
    GitHubGitHelperStatusView {
        state: "error".to_string(),
        message: "Could not inspect Git credential helper status.".to_string(),
        detail: Some(detail),
    }
}

fn gh_command_with_common_env() -> TokioCommand {
    let mut command = crate::github_cli::command();
    command
        .env("GH_NO_UPDATE_NOTIFIER", "1")
        .env("GH_NO_EXTENSION_UPDATE_NOTIFIER", "1")
        .env("GH_BROWSER", "open");
    command
}

fn normalize_accounts(mut accounts: Vec<GitHubAuthAccountView>) -> Vec<GitHubAuthAccountView> {
    accounts.sort_by(|left, right| {
        right
            .active
            .cmp(&left.active)
            .then_with(|| left.login.to_lowercase().cmp(&right.login.to_lowercase()))
    });
    accounts
}

fn active_login(accounts: &[GitHubAuthAccountView]) -> Option<String> {
    accounts
        .iter()
        .find(|account| account.active)
        .map(|account| account.login.clone())
}

fn output_text(output: &std::process::Output) -> String {
    let stderr = String::from_utf8_lossy(&output.stderr).trim().to_string();
    if !stderr.is_empty() {
        return stderr;
    }
    String::from_utf8_lossy(&output.stdout).trim().to_string()
}

fn generic_login_failure_message() -> String {
    "GitHub login did not complete. Check the browser flow and GitHub CLI state, then try again."
        .to_string()
}

fn should_retry_with_script(output: &std::process::Output) -> bool {
    let text = output_text(output).to_lowercase();
    [
        "prompt",
        "tty",
        "interactive",
        "stdin",
        "terminal",
        "disabled",
    ]
    .iter()
    .any(|pattern| text.contains(pattern))
}

async fn gh_cli_available() -> bool {
    let mut command = gh_command_with_common_env();
    command.arg("--version");
    command
        .output()
        .await
        .map(|output| output.status.success())
        .unwrap_or(false)
}

fn script_binary_path() -> PathBuf {
    #[cfg(test)]
    if let Some(path) = std::env::var_os("PNEVMA_GITHUB_AUTH_SCRIPT_BIN") {
        return PathBuf::from(path);
    }

    pnevma_session::resolve_binary("script")
}

fn hosts_file_mtime() -> Option<std::time::SystemTime> {
    std::fs::metadata(crate::github_cli::hosts_file_path())
        .ok()
        .and_then(|metadata| metadata.modified().ok())
}

async fn detect_git_helper_status() -> GitHubGitHelperStatusView {
    let output = TokioCommand::new("git")
        .args([
            "config",
            "--global",
            "--get-regexp",
            r"^credential\..*\.helper$|^credential\.helper$",
        ])
        .output()
        .await;

    let Ok(output) = output else {
        return helper_error_status("failed to inspect git config".to_string());
    };

    if !output.status.success() {
        return helper_warning_status(Some(
            "Run `gh auth setup-git --hostname github.com` if you want Git HTTPS auth to follow the active GitHub CLI account."
                .to_string(),
        ));
    }

    let stdout = String::from_utf8_lossy(&output.stdout);
    if stdout
        .lines()
        .any(|line| line.contains("gh auth git-credential"))
    {
        helper_ready_status()
    } else {
        helper_warning_status(Some(
            "Run `gh auth setup-git --hostname github.com` if you want Git HTTPS auth to follow the active GitHub CLI account."
                .to_string(),
        ))
    }
}

pub async fn inspect_github_auth_status() -> GitHubAuthStatusView {
    let cli_available = gh_cli_available().await;
    if !cli_available {
        return GitHubAuthStatusView {
            cli_available: false,
            git_helper: helper_unknown_status(),
            last_refreshed_at: Some(Utc::now()),
            ..GitHubAuthStatusView::default()
        };
    }

    let mut command = gh_command_with_common_env();
    command.args([
        "auth",
        "status",
        "--hostname",
        GITHUB_HOST,
        "--json",
        "hosts",
    ]);
    let output = match command.output().await {
        Ok(output) => output,
        Err(error) => {
            return GitHubAuthStatusView {
                cli_available: true,
                git_helper: detect_git_helper_status().await,
                error: Some(format!("failed to run gh: {error}")),
                last_refreshed_at: Some(Utc::now()),
                ..GitHubAuthStatusView::default()
            };
        }
    };

    if !output.status.success() {
        return GitHubAuthStatusView {
            cli_available: true,
            git_helper: detect_git_helper_status().await,
            error: Some(output_text(&output)),
            last_refreshed_at: Some(Utc::now()),
            ..GitHubAuthStatusView::default()
        };
    }

    let parsed: GhAuthStatusJson = match serde_json::from_slice(&output.stdout) {
        Ok(parsed) => parsed,
        Err(error) => {
            return GitHubAuthStatusView {
                cli_available: true,
                git_helper: detect_git_helper_status().await,
                error: Some(format!("failed to parse gh auth status JSON: {error}")),
                last_refreshed_at: Some(Utc::now()),
                ..GitHubAuthStatusView::default()
            };
        }
    };

    let accounts = parsed
        .hosts
        .get(GITHUB_HOST)
        .cloned()
        .unwrap_or_default()
        .into_iter()
        .map(|account| GitHubAuthAccountView {
            login: account.login,
            active: account.active,
            state: account.state,
            token_source: account.token_source,
            git_protocol: account.git_protocol,
            scopes: account.scopes,
        })
        .collect::<Vec<_>>();
    let accounts = normalize_accounts(accounts);

    GitHubAuthStatusView {
        host: GITHUB_HOST.to_string(),
        cli_available: true,
        active_login: active_login(&accounts),
        accounts,
        git_helper: detect_git_helper_status().await,
        auth_job: None,
        error: None,
        last_refreshed_at: Some(Utc::now()),
    }
}

pub fn authenticated_account(snapshot: &GitHubAuthStatusView) -> Option<&GitHubAuthAccountView> {
    snapshot
        .accounts
        .iter()
        .find(|account| account.active && account.state == "success")
}

fn merge_with_cached_job(
    mut snapshot: GitHubAuthStatusView,
    cached: Option<&GitHubAuthStatusView>,
) -> GitHubAuthStatusView {
    if let Some(cached) = cached {
        snapshot.auth_job = cached.auth_job.clone();
    }
    snapshot
}

async fn store_snapshot(state: &AppState, snapshot: GitHubAuthStatusView) -> GitHubAuthStatusView {
    let mut guard = state.github_auth.snapshot.write().await;
    let changed = guard.as_ref() != Some(&snapshot);
    *guard = Some(snapshot.clone());
    drop(guard);

    if changed {
        state.emitter.emit(
            "github_auth_changed",
            json!({ "snapshot": snapshot.clone() }),
        );
    }

    snapshot
}

async fn refresh_github_auth_status_locked(state: &AppState) -> GitHubAuthStatusView {
    let cached = state.github_auth.snapshot.read().await.clone();
    let snapshot = merge_with_cached_job(inspect_github_auth_status().await, cached.as_ref());
    *state.github_auth.last_hosts_mtime.lock().await = hosts_file_mtime();
    store_snapshot(state, snapshot).await
}

async fn ensure_monitor_started(state: &AppState) {
    let Some(state_arc) = state.arc() else {
        return;
    };

    let mut guard = state.github_auth.monitor_task.lock().await;
    if guard.is_some() {
        return;
    }

    *guard = Some(tokio::spawn(async move {
        loop {
            sleep(BACKGROUND_REFRESH_INTERVAL).await;
            let current_mtime = hosts_file_mtime();
            let known_mtime = *state_arc.github_auth.last_hosts_mtime.lock().await;
            let cached = state_arc.github_auth.snapshot.read().await.clone();
            let force_refresh = cached
                .as_ref()
                .and_then(|snapshot| snapshot.last_refreshed_at)
                .map(|timestamp| Utc::now() - timestamp > BACKGROUND_FORCED_REFRESH_INTERVAL)
                .unwrap_or(true);

            if force_refresh || current_mtime != known_mtime {
                let _refresh_guard = state_arc.github_auth.refresh_lock.lock().await;
                let _ = refresh_github_auth_status_locked(state_arc.as_ref()).await;
            }
        }
    }));
}

pub async fn get_github_auth_status(state: &AppState) -> GitHubAuthStatusView {
    ensure_monitor_started(state).await;

    if let Some(snapshot) = state.github_auth.snapshot.read().await.clone() {
        let is_stale = snapshot
            .last_refreshed_at
            .map(|timestamp| {
                (Utc::now() - timestamp)
                    .to_std()
                    .map(|elapsed| elapsed > STATUS_STALE_AFTER)
                    .unwrap_or(true)
            })
            .unwrap_or(true);
        if !is_stale {
            return snapshot;
        }
    }

    refresh_github_auth_status(state).await
}

pub async fn refresh_github_auth_status(state: &AppState) -> GitHubAuthStatusView {
    ensure_monitor_started(state).await;
    let _guard = state.github_auth.refresh_lock.lock().await;
    refresh_github_auth_status_locked(state).await
}

async fn update_auth_job(
    state: &AppState,
    auth_job: Option<GitHubAuthJobView>,
) -> GitHubAuthStatusView {
    let mut snapshot = state
        .github_auth
        .snapshot
        .read()
        .await
        .clone()
        .unwrap_or_else(GitHubAuthStatusView::default);
    snapshot.auth_job = auth_job;
    store_snapshot(state, snapshot).await
}

fn account_logins(snapshot: &GitHubAuthStatusView) -> BTreeSet<String> {
    snapshot
        .accounts
        .iter()
        .map(|account| account.login.clone())
        .collect()
}

async fn run_direct_login() -> Result<(), String> {
    let mut command = gh_command_with_common_env();
    command
        .env("GH_PROMPT_DISABLED", "1")
        .args([
            "auth",
            "login",
            "--hostname",
            GITHUB_HOST,
            "--web",
            "--clipboard",
            "--git-protocol",
            "https",
            "--skip-ssh-key",
        ])
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped());

    let output = timeout(LOGIN_TIMEOUT, command.output())
        .await
        .map_err(|_| generic_login_failure_message())
        .and_then(|result| result.map_err(|_| generic_login_failure_message()))?;

    if output.status.success() {
        return Ok(());
    }

    if should_retry_with_script(&output) {
        return Err("__retry_with_script__".to_string());
    }

    Err(generic_login_failure_message())
}

async fn run_script_login() -> Result<(), String> {
    let script_bin = script_binary_path();
    let gh_bin = crate::github_cli::binary_path();
    let mut command = TokioCommand::new(script_bin);
    command
        .env("GH_NO_UPDATE_NOTIFIER", "1")
        .env("GH_NO_EXTENSION_UPDATE_NOTIFIER", "1")
        .args([
            "-q",
            "/dev/null",
            gh_bin.to_string_lossy().as_ref(),
            "auth",
            "login",
            "--hostname",
            GITHUB_HOST,
            "--web",
            "--clipboard",
            "--git-protocol",
            "https",
            "--skip-ssh-key",
        ])
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped());

    let output = timeout(LOGIN_TIMEOUT, command.output())
        .await
        .map_err(|_| generic_login_failure_message())
        .and_then(|result| result.map_err(|_| generic_login_failure_message()))?;

    if output.status.success() {
        Ok(())
    } else {
        Err(generic_login_failure_message())
    }
}

async fn perform_login() -> Result<(), String> {
    match run_direct_login().await {
        Ok(()) => Ok(()),
        Err(error) if error == "__retry_with_script__" => run_script_login().await,
        Err(error) => Err(error),
    }
}

pub async fn start_github_auth_login(state: &AppState) -> GitHubAuthStatusView {
    ensure_monitor_started(state).await;

    if state
        .github_auth
        .auth_job_running
        .swap(true, Ordering::SeqCst)
    {
        return state
            .github_auth
            .snapshot
            .read()
            .await
            .clone()
            .unwrap_or_else(GitHubAuthStatusView::default);
    }

    let previous_snapshot = if let Some(snapshot) = state.github_auth.snapshot.read().await.clone()
    {
        snapshot
    } else {
        let _guard = state.github_auth.refresh_lock.lock().await;
        refresh_github_auth_status_locked(state).await
    };
    let previous_account_logins = account_logins(&previous_snapshot);

    let started_at = Utc::now();
    let running_job = GitHubAuthJobView {
        state: "running".to_string(),
        message: Some("Opening GitHub sign-in in your default browser.".to_string()),
        started_at,
        finished_at: None,
    };
    let snapshot = update_auth_job(state, Some(running_job)).await;

    let Some(state_arc) = state.arc() else {
        state
            .github_auth
            .auth_job_running
            .store(false, Ordering::SeqCst);
        let failed_job = GitHubAuthJobView {
            state: "failed".to_string(),
            message: Some(
                "Background GitHub auth requires the shared app state to be initialized."
                    .to_string(),
            ),
            started_at,
            finished_at: Some(Utc::now()),
        };
        return update_auth_job(state, Some(failed_job)).await;
    };

    tokio::spawn(async move {
        let result = perform_login().await;
        state_arc
            .github_auth
            .auth_job_running
            .store(false, Ordering::SeqCst);

        match result {
            Ok(()) => {
                let _guard = state_arc.github_auth.refresh_lock.lock().await;
                let mut refreshed = inspect_github_auth_status().await;
                *state_arc.github_auth.last_hosts_mtime.lock().await = hosts_file_mtime();
                let refreshed_account_logins = account_logins(&refreshed);
                let added_accounts = refreshed_account_logins
                    .difference(&previous_account_logins)
                    .cloned()
                    .collect::<Vec<_>>();
                refreshed.auth_job = if !previous_account_logins.is_empty()
                    && added_accounts.is_empty()
                {
                    Some(GitHubAuthJobView {
                        state: "failed".to_string(),
                        message: Some(
                            "No new GitHub account was added. Your browser likely reused the current GitHub session. Switch accounts in the opened browser, then try Add Account again."
                                .to_string(),
                        ),
                        started_at,
                        finished_at: Some(Utc::now()),
                    })
                } else {
                    None
                };
                let _ = store_snapshot(state_arc.as_ref(), refreshed).await;
            }
            Err(message) => {
                let failed_job = GitHubAuthJobView {
                    state: "failed".to_string(),
                    message: Some(message),
                    started_at,
                    finished_at: Some(Utc::now()),
                };
                let _ = update_auth_job(state_arc.as_ref(), Some(failed_job)).await;
            }
        }
    });

    snapshot
}

pub async fn switch_github_auth_account(
    input: GitHubAuthSwitchInput,
    state: &AppState,
) -> Result<GitHubAuthStatusView, String> {
    let login = input.login.trim();
    if login.is_empty() {
        return Err("login must not be empty".to_string());
    }
    if login.len() > 256 || login.chars().any(|c| c.is_control() || c == '\0') {
        return Err("login contains invalid characters".to_string());
    }

    let mut command = gh_command_with_common_env();
    command.args(["auth", "switch", "--hostname", GITHUB_HOST, "--user", login]);
    let output = command
        .output()
        .await
        .map_err(|e| format!("failed to run gh: {e}"))?;

    if !output.status.success() {
        let detail = output_text(&output);
        return Err(if detail.is_empty() {
            "GitHub account switch failed.".to_string()
        } else {
            detail
        });
    }

    Ok(refresh_github_auth_status(state).await)
}

pub async fn fix_github_git_helper(state: &AppState) -> Result<GitHubAuthStatusView, String> {
    let mut command = gh_command_with_common_env();
    command.args(["auth", "setup-git", "--hostname", GITHUB_HOST]);
    let output = command
        .output()
        .await
        .map_err(|e| format!("failed to run gh: {e}"))?;

    if !output.status.success() {
        let detail = output_text(&output);
        return Err(if detail.is_empty() {
            "Could not configure GitHub CLI as the Git credential helper.".to_string()
        } else {
            detail
        });
    }

    Ok(refresh_github_auth_status(state).await)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::github_cli::TestGithubCliBinaryOverride;
    use std::ffi::OsString;
    use std::fs;
    use std::os::unix::fs::PermissionsExt;
    use tempfile::tempdir;
    use tokio::sync::{Mutex, MutexGuard};

    fn env_lock() -> &'static Mutex<()> {
        static LOCK: std::sync::OnceLock<Mutex<()>> = std::sync::OnceLock::new();
        LOCK.get_or_init(|| Mutex::new(()))
    }

    struct EnvGuard {
        previous_home: Option<OsString>,
        previous_script: Option<OsString>,
        _guard: MutexGuard<'static, ()>,
    }

    impl EnvGuard {
        async fn new(home: &std::path::Path, script_bin: Option<&std::path::Path>) -> Self {
            let guard = env_lock().lock().await;
            let previous_home = std::env::var_os("HOME");
            std::env::set_var("HOME", home);
            let previous_script = std::env::var_os("PNEVMA_GITHUB_AUTH_SCRIPT_BIN");
            if let Some(script_bin) = script_bin {
                std::env::set_var("PNEVMA_GITHUB_AUTH_SCRIPT_BIN", script_bin);
            } else {
                std::env::remove_var("PNEVMA_GITHUB_AUTH_SCRIPT_BIN");
            }
            Self {
                previous_home,
                previous_script,
                _guard: guard,
            }
        }
    }

    impl Drop for EnvGuard {
        fn drop(&mut self) {
            if let Some(home) = self.previous_home.as_ref() {
                std::env::set_var("HOME", home);
            } else {
                std::env::remove_var("HOME");
            }
            if let Some(script) = self.previous_script.as_ref() {
                std::env::set_var("PNEVMA_GITHUB_AUTH_SCRIPT_BIN", script);
            } else {
                std::env::remove_var("PNEVMA_GITHUB_AUTH_SCRIPT_BIN");
            }
        }
    }

    fn write_fake_executable(path: &std::path::Path, body: &str) {
        fs::write(path, body).expect("write fake executable");
        let mut permissions = fs::metadata(path).expect("metadata").permissions();
        permissions.set_mode(0o755);
        fs::set_permissions(path, permissions).expect("set permissions");
    }

    #[tokio::test]
    async fn inspect_github_auth_status_reads_multiple_accounts() {
        let home = tempdir().expect("temp home");
        let _env = EnvGuard::new(home.path(), None).await;
        fs::create_dir_all(home.path().join(".config/gh")).expect("create gh config dir");
        fs::write(home.path().join(".gitconfig"), b"").expect("write gitconfig");

        let gh_path = home.path().join("gh");
        write_fake_executable(
            &gh_path,
            r#"#!/bin/sh
if [ "$1" = "--version" ]; then
  echo "gh version 2.99.0"
  exit 0
fi
if [ "$1" = "auth" ] && [ "$2" = "status" ]; then
  cat <<'JSON'
{"hosts":{"github.com":[{"active":false,"login":"beta","state":"success","tokenSource":"/tmp/hosts.yml","gitProtocol":"https","scopes":["repo"]},{"active":true,"login":"alpha","state":"success","tokenSource":"/tmp/hosts.yml","gitProtocol":"https","scopes":["repo","read:org"]}]}}
JSON
  exit 0
fi
if [ "$1" = "auth" ] && [ "$2" = "setup-git" ]; then
  exit 0
fi
echo "unexpected gh args: $*" >&2
exit 1
"#,
        );
        let _gh = TestGithubCliBinaryOverride::new(gh_path);

        let snapshot = inspect_github_auth_status().await;
        assert!(snapshot.cli_available);
        assert_eq!(snapshot.active_login.as_deref(), Some("alpha"));
        assert_eq!(snapshot.accounts.len(), 2);
        assert_eq!(snapshot.accounts[0].login, "alpha");
        assert!(snapshot.accounts[0].active);
        assert_eq!(snapshot.accounts[1].login, "beta");
    }

    #[tokio::test]
    async fn inspect_github_auth_status_accepts_comma_delimited_scopes() {
        let home = tempdir().expect("temp home");
        let _env = EnvGuard::new(home.path(), None).await;
        fs::create_dir_all(home.path().join(".config/gh")).expect("create gh config dir");
        fs::write(home.path().join(".gitconfig"), b"").expect("write gitconfig");

        let gh_path = home.path().join("gh");
        write_fake_executable(
            &gh_path,
            r#"#!/bin/sh
if [ "$1" = "--version" ]; then
  echo "gh version 2.99.0"
  exit 0
fi
if [ "$1" = "auth" ] && [ "$2" = "status" ]; then
  cat <<'JSON'
{"hosts":{"github.com":[{"active":true,"login":"alpha","state":"success","tokenSource":"/tmp/hosts.yml","gitProtocol":"https","scopes":"gist, read:org, repo, workflow"}]}}
JSON
  exit 0
fi
echo "unexpected gh args: $*" >&2
exit 1
"#,
        );
        let _gh = TestGithubCliBinaryOverride::new(gh_path);

        let snapshot = inspect_github_auth_status().await;
        assert!(snapshot.cli_available);
        assert_eq!(snapshot.active_login.as_deref(), Some("alpha"));
        assert_eq!(
            snapshot.accounts[0].scopes,
            vec![
                "gist".to_string(),
                "read:org".to_string(),
                "repo".to_string(),
                "workflow".to_string(),
            ]
        );
    }

    #[tokio::test]
    async fn inspect_github_auth_status_reports_missing_helper() {
        let home = tempdir().expect("temp home");
        let _env = EnvGuard::new(home.path(), None).await;
        fs::create_dir_all(home.path().join(".config/gh")).expect("create gh config dir");
        fs::write(home.path().join(".gitconfig"), b"[user]\n\tname = Test\n")
            .expect("write gitconfig");

        let gh_path = home.path().join("gh");
        write_fake_executable(
            &gh_path,
            r#"#!/bin/sh
if [ "$1" = "--version" ]; then
  echo "gh version 2.99.0"
  exit 0
fi
if [ "$1" = "auth" ] && [ "$2" = "status" ]; then
  echo '{"hosts":{}}'
  exit 0
fi
echo "unexpected gh args: $*" >&2
exit 1
"#,
        );
        let _gh = TestGithubCliBinaryOverride::new(gh_path);

        let snapshot = inspect_github_auth_status().await;
        assert_eq!(snapshot.git_helper.state, "warning");
    }

    #[tokio::test]
    async fn switch_github_auth_account_runs_expected_command() {
        let home = tempdir().expect("temp home");
        let _env = EnvGuard::new(home.path(), None).await;
        fs::create_dir_all(home.path().join(".config/gh")).expect("create gh config dir");
        fs::write(home.path().join(".gitconfig"), b"").expect("write gitconfig");
        let log_path = home.path().join("gh.log");
        let gh_path = home.path().join("gh");
        write_fake_executable(
            &gh_path,
            &format!(
                r#"#!/bin/sh
echo "$@" >> "{}"
if [ "$1" = "--version" ]; then
  echo "gh version 2.99.0"
  exit 0
fi
if [ "$1" = "auth" ] && [ "$2" = "switch" ]; then
  exit 0
fi
if [ "$1" = "auth" ] && [ "$2" = "status" ]; then
  echo '{{"hosts":{{"github.com":[{{"active":true,"login":"switched","state":"success","tokenSource":"/tmp/hosts.yml","gitProtocol":"https","scopes":["repo"]}}]}}}}'
  exit 0
fi
echo "unexpected gh args: $*" >&2
exit 1
"#,
                log_path.display()
            ),
        );
        let _gh = TestGithubCliBinaryOverride::new(gh_path);

        let state = std::sync::Arc::new(AppState::new(std::sync::Arc::new(crate::NullEmitter)));
        let _ = state.self_arc.set(std::sync::Arc::clone(&state));

        let snapshot = switch_github_auth_account(
            GitHubAuthSwitchInput {
                login: "switched".to_string(),
            },
            state.as_ref(),
        )
        .await
        .expect("switch account");

        assert_eq!(snapshot.active_login.as_deref(), Some("switched"));
        let log = fs::read_to_string(log_path).expect("read log");
        assert!(log.contains("auth switch --hostname github.com --user switched"));
    }

    #[tokio::test]
    async fn perform_login_uses_open_for_browser_launch() {
        let home = tempdir().expect("temp home");
        let _env = EnvGuard::new(home.path(), None).await;
        let log_path = home.path().join("gh.log");
        let gh_path = home.path().join("gh");
        write_fake_executable(
            &gh_path,
            &format!(
                r#"#!/bin/sh
echo "GH_BROWSER=$GH_BROWSER" >> "{}"
if [ "$1" = "--version" ]; then
  echo "gh version 2.99.0"
  exit 0
fi
if [ "$1" = "auth" ] && [ "$2" = "login" ]; then
  exit 0
fi
echo "unexpected gh args: $*" >&2
exit 1
"#,
                log_path.display()
            ),
        );
        let _gh = TestGithubCliBinaryOverride::new(gh_path);

        perform_login().await.expect("login succeeds");

        let log = fs::read_to_string(log_path).expect("read log");
        assert!(log.contains("GH_BROWSER=open"));
    }

    #[tokio::test]
    async fn start_login_reports_when_no_new_account_was_added() {
        let home = tempdir().expect("temp home");
        let _env = EnvGuard::new(home.path(), None).await;
        fs::create_dir_all(home.path().join(".config/gh")).expect("create gh config dir");
        fs::write(home.path().join(".gitconfig"), b"").expect("write gitconfig");

        let gh_path = home.path().join("gh");
        write_fake_executable(
            &gh_path,
            r#"#!/bin/sh
if [ "$1" = "--version" ]; then
  echo "gh version 2.99.0"
  exit 0
fi
if [ "$1" = "auth" ] && [ "$2" = "status" ]; then
  cat <<'JSON'
{"hosts":{"github.com":[{"active":true,"login":"alpha","state":"success","tokenSource":"/tmp/hosts.yml","gitProtocol":"https","scopes":"repo, read:org"}]}}
JSON
  exit 0
fi
if [ "$1" = "auth" ] && [ "$2" = "login" ]; then
  exit 0
fi
echo "unexpected gh args: $*" >&2
exit 1
"#,
        );
        let _gh = TestGithubCliBinaryOverride::new(gh_path);

        let state = std::sync::Arc::new(AppState::new(std::sync::Arc::new(crate::NullEmitter)));
        let _ = state.self_arc.set(std::sync::Arc::clone(&state));

        let initial = refresh_github_auth_status(state.as_ref()).await;
        assert_eq!(initial.active_login.as_deref(), Some("alpha"));

        let _running = start_github_auth_login(state.as_ref()).await;

        let mut final_snapshot = None;
        for _ in 0..50 {
            let snapshot = get_github_auth_status(state.as_ref()).await;
            if snapshot
                .auth_job
                .as_ref()
                .and_then(|job| job.finished_at)
                .is_some()
            {
                final_snapshot = Some(snapshot);
                break;
            }
            sleep(Duration::from_millis(20)).await;
        }

        let snapshot = final_snapshot.expect("completed snapshot");
        assert_eq!(snapshot.active_login.as_deref(), Some("alpha"));
        assert_eq!(
            snapshot.auth_job.as_ref().map(|job| job.state.as_str()),
            Some("failed")
        );
        assert!(snapshot
            .auth_job
            .as_ref()
            .and_then(|job| job.message.as_deref())
            .unwrap_or_default()
            .contains("No new GitHub account was added"));
    }
}
