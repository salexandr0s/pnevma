use super::*;
use std::collections::HashMap;
use std::path::{Path, PathBuf};
use std::process::Output;

fn parse_shortstat(stat: &str) -> (Option<i64>, Option<i64>) {
    let mut insertions: Option<i64> = None;
    let mut deletions: Option<i64> = None;
    for part in stat.split(',') {
        let part = part.trim();
        if part.contains("insertion") {
            insertions = part.split_whitespace().next().and_then(|n| n.parse().ok());
        } else if part.contains("deletion") {
            deletions = part.split_whitespace().next().and_then(|n| n.parse().ok());
        }
    }
    (insertions, deletions)
}

const FLEET_MACHINE_ID_KEY: &str = "fleet.machine_id";

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct WorkspaceOpenerPathInput {
    pub path: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct GitHubRepoStatusView {
    pub state: String,
    pub message: String,
    pub detail: Option<String>,
    pub resolved_repo: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct GitHubPullRequestView {
    pub number: i64,
    pub title: String,
    pub source_branch: String,
    pub target_branch: String,
    pub status: String,
}

#[derive(Debug, Deserialize)]
struct GhRepoViewJson {
    #[serde(rename = "nameWithOwner")]
    name_with_owner: String,
    #[serde(rename = "defaultBranchRef")]
    default_branch_ref: Option<GhBranchRefJson>,
}

#[derive(Debug, Deserialize)]
struct GhPullRequestJson {
    number: i64,
    title: String,
    #[serde(rename = "headRefName")]
    head_ref_name: String,
    #[serde(rename = "baseRefName")]
    base_ref_name: String,
    state: String,
}

#[derive(Debug, Deserialize)]
struct GhBranchRefJson {
    name: String,
}

#[derive(Debug, Deserialize)]
struct GhIssueDetailJson {
    number: i64,
    title: String,
    state: String,
    url: String,
}

#[derive(Debug, Deserialize)]
struct GhRepositoryUrlJson {
    url: Option<String>,
}

#[derive(Debug, Deserialize)]
struct GhPullRequestDetailJson {
    number: i64,
    title: String,
    #[serde(rename = "headRefName")]
    head_ref_name: String,
    #[serde(rename = "baseRefName")]
    _base_ref_name: String,
    state: String,
    url: String,
    #[serde(rename = "headRepository")]
    head_repository: Option<GhRepositoryUrlJson>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct WorkspaceOpenerIssueLaunchInput {
    pub path: String,
    pub issue_number: i64,
    #[serde(default)]
    pub create_linked_task_worktree: bool,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct WorkspaceOpenerPullRequestLaunchInput {
    pub path: String,
    pub pr_number: i64,
    #[serde(default)]
    pub create_linked_task_worktree: bool,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct WorkspaceOpenerBranchLaunchInput {
    pub path: String,
    pub branch_name: String,
    #[serde(default)]
    pub create_new: bool,
}

struct WorkspaceOpenerRepoContext {
    repo_root: PathBuf,
    repo_spec: String,
}

struct WorkspaceOpenerManagedProject {
    repo_root: PathBuf,
    project_id: Uuid,
    db: Db,
    config: ProjectConfig,
    global_config: GlobalConfig,
    git: GitService,
}

fn project_path_from_input(input: &WorkspaceOpenerPathInput) -> Result<PathBuf, String> {
    ensure_safe_path_input(&input.path, "project path")?;
    Ok(PathBuf::from(&input.path))
}

async fn git_repo_root_for_path(path: &Path) -> Result<PathBuf, String> {
    let output = TokioCommand::new("git")
        .args(["rev-parse", "--show-toplevel"])
        .current_dir(path)
        .output()
        .await
        .map_err(|e| format!("failed to run git: {e}"))?;

    if !output.status.success() {
        return Err("Selected folder is not a git repository.".to_string());
    }

    let root = String::from_utf8_lossy(&output.stdout).trim().to_string();
    if root.is_empty() {
        return Err("Could not determine the repository root.".to_string());
    }

    Ok(PathBuf::from(root))
}

async fn workspace_opener_auxiliary_worktrees_by_branch(
    repo_root: &Path,
) -> Result<HashMap<String, String>, String> {
    let output = TokioCommand::new("git")
        .args(["worktree", "list", "--porcelain"])
        .current_dir(repo_root)
        .output()
        .await
        .map_err(|e| format!("failed to run git worktree list: {e}"))?;

    if !output.status.success() {
        let stderr = String::from_utf8_lossy(&output.stderr);
        return Err(format!("git worktree list failed: {}", stderr.trim()));
    }

    let canonical_repo_root = tokio::fs::canonicalize(repo_root)
        .await
        .unwrap_or_else(|_| repo_root.to_path_buf());
    let stdout = String::from_utf8_lossy(&output.stdout);
    let mut worktrees_by_branch = HashMap::new();
    let mut current_path: Option<String> = None;
    let mut current_branch: Option<String> = None;

    for line in stdout.lines().chain(std::iter::once("")) {
        if line.is_empty() {
            if let (Some(path), Some(branch)) = (current_path.take(), current_branch.take()) {
                let path_buf = PathBuf::from(&path);
                let canonical_path = tokio::fs::canonicalize(&path_buf).await.unwrap_or(path_buf);
                if canonical_path != canonical_repo_root {
                    worktrees_by_branch
                        .insert(branch, canonical_path.to_string_lossy().to_string());
                }
            }
            current_path = None;
            current_branch = None;
            continue;
        }

        if let Some(rest) = line.strip_prefix("worktree ") {
            current_path = Some(rest.to_string());
        } else if let Some(rest) = line.strip_prefix("branch refs/heads/") {
            current_branch = Some(rest.to_string());
        }
    }

    Ok(worktrees_by_branch)
}

async fn gh_cli_available() -> bool {
    let mut command = crate::github_cli::command();
    command.arg("--version");
    command
        .output()
        .await
        .map(|output| output.status.success())
        .unwrap_or(false)
}

async fn gh_auth_ready() -> Result<(), String> {
    let mut command = crate::github_cli::command();
    command.args(["auth", "status", "--hostname", "github.com"]);
    let output = command
        .output()
        .await
        .map_err(|e| format!("failed to run gh: {e}"))?;

    if output.status.success() {
        return Ok(());
    }

    let stderr = String::from_utf8_lossy(&output.stderr).trim().to_string();
    if stderr.is_empty() {
        Err("GitHub CLI is not authenticated.".to_string())
    } else {
        Err(stderr)
    }
}

fn parse_github_remote_spec(remote_url: &str) -> Option<String> {
    let trimmed = remote_url.trim().trim_end_matches('/');
    let suffix = [
        "git@github.com:",
        "ssh://git@github.com/",
        "https://github.com/",
        "http://github.com/",
        "git://github.com/",
    ]
    .iter()
    .find_map(|prefix| trimmed.strip_prefix(prefix))?;

    let normalized = suffix.trim_end_matches(".git").trim_matches('/');
    let mut parts = normalized.split('/');
    let owner = parts.next()?.trim();
    let repo = parts.next()?.trim();

    if owner.is_empty() || repo.is_empty() || parts.next().is_some() {
        return None;
    }

    Some(format!("{owner}/{repo}"))
}

async fn github_remote_spec_for_path(project_path: &Path) -> Result<Option<String>, String> {
    let output = TokioCommand::new("git")
        .args(["remote", "-v"])
        .current_dir(project_path)
        .output()
        .await
        .map_err(|e| format!("failed to inspect git remotes: {e}"))?;

    if !output.status.success() {
        return Ok(None);
    }

    let stdout = String::from_utf8_lossy(&output.stdout);
    let mut fallback: Option<String> = None;

    for line in stdout.lines() {
        let mut fields = line.split_whitespace();
        let remote_name = fields.next().unwrap_or_default();
        let remote_url = fields.next().unwrap_or_default();
        let spec = parse_github_remote_spec(remote_url);

        if remote_name == "origin" && spec.is_some() {
            return Ok(spec);
        }
        if fallback.is_none() {
            fallback = spec;
        }
    }

    Ok(fallback)
}

async fn gh_repo_view(project_path: &Path, repo_spec: &str) -> Result<GhRepoViewJson, String> {
    let mut command = crate::github_cli::command();
    command
        .args([
            "repo",
            "view",
            repo_spec,
            "--json",
            "nameWithOwner,defaultBranchRef",
        ])
        .current_dir(project_path);
    let output = command
        .output()
        .await
        .map_err(|e| format!("failed to run gh: {e}"))?;

    if !output.status.success() {
        let stderr = String::from_utf8_lossy(&output.stderr).trim().to_string();
        return Err(if stderr.is_empty() {
            "Could not resolve the GitHub repository for this folder.".to_string()
        } else {
            stderr
        });
    }

    serde_json::from_slice(&output.stdout).map_err(|e| format!("parse error: {e}"))
}

async fn workspace_opener_repo_context_for_input(
    input: &WorkspaceOpenerPathInput,
) -> Result<WorkspaceOpenerRepoContext, GitHubRepoStatusView> {
    let requested_path = match project_path_from_input(input) {
        Ok(path) => path,
        Err(message) => {
            return Err(github_status_view(
                "error",
                "Invalid project path.",
                Some(message),
                None,
            ));
        }
    };

    let repo_root = match git_repo_root_for_path(&requested_path).await {
        Ok(root) => root,
        Err(message) => {
            return Err(github_status_view(
                "not_git_repo",
                "This folder is not a git repository.",
                Some(message),
                None,
            ));
        }
    };

    if !gh_cli_available().await {
        return Err(github_status_view(
            "missing_gh_cli",
            "GitHub CLI (`gh`) is not installed.",
            Some("Install GitHub CLI to browse issues and pull requests.".to_string()),
            None,
        ));
    }

    let Some(repo_spec) = github_remote_spec_for_path(&repo_root)
        .await
        .map_err(|detail| {
            github_status_view("error", "GitHub is unavailable.", Some(detail), None)
        })?
    else {
        return Err(github_status_view(
            "no_github_remote",
            "This repository has no GitHub remote.",
            Some("Add a GitHub remote before browsing issues or pull requests.".to_string()),
            None,
        ));
    };

    if let Err(detail) = gh_auth_ready().await {
        return Err(github_status_view(
            "not_authenticated",
            "GitHub CLI is not authenticated.",
            Some(detail),
            Some(repo_spec),
        ));
    }

    Ok(WorkspaceOpenerRepoContext {
        repo_root,
        repo_spec,
    })
}

async fn workspace_opener_repo_context_from_path(
    path: &str,
) -> Result<WorkspaceOpenerRepoContext, String> {
    workspace_opener_repo_context_for_input(&WorkspaceOpenerPathInput {
        path: path.to_string(),
    })
    .await
    .map_err(|status| status.detail.unwrap_or(status.message))
}

fn ensure_positive_external_number(value: i64, label: &str) -> Result<(), String> {
    if value <= 0 {
        return Err(format!("{label} must be greater than zero"));
    }
    Ok(())
}

async fn workspace_opener_managed_project(
    repo_root: &Path,
    state: &AppState,
) -> Result<WorkspaceOpenerManagedProject, String> {
    let canonical_root = std::fs::canonicalize(repo_root)
        .map_err(|e| format!("failed to canonicalize project path: {e}"))?;
    if !project_is_initialized(&canonical_root) {
        return Err("workspace_not_initialized".to_string());
    }

    let config_path = canonical_root.join("pnevma.toml");
    let config_content = std::fs::read_to_string(&config_path).map_err(|e| e.to_string())?;
    let current_fingerprint = sha256_hex(config_content.as_bytes());
    let path_str = canonical_root.to_string_lossy().to_string();
    let global_db = state.global_db()?;
    let trust = global_db
        .is_path_trusted(&path_str)
        .await
        .map_err(|e| e.to_string())?;
    match trust {
        Some(record) if record.fingerprint == current_fingerprint => {}
        Some(_) => return Err("workspace_config_changed".to_string()),
        None => return Err("workspace_not_trusted".to_string()),
    }

    let config = load_project_config(&config_path).map_err(|e| e.to_string())?;
    let global_config = load_global_config().map_err(|e| e.to_string())?;
    let db = Db::open(&canonical_root).await.map_err(|e| e.to_string())?;
    let existing = db
        .find_project_by_path(&path_str)
        .await
        .map_err(|e| e.to_string())?;
    let project_id = existing
        .as_ref()
        .and_then(|project| Uuid::parse_str(&project.id).ok())
        .unwrap_or_else(Uuid::new_v4);

    db.upsert_project(
        &project_id.to_string(),
        &config.project.name,
        &path_str,
        Some(&config.project.brief),
        Some(config_path.to_string_lossy().as_ref()),
    )
    .await
    .map_err(|e| e.to_string())?;

    Ok(WorkspaceOpenerManagedProject {
        repo_root: canonical_root.clone(),
        project_id,
        db,
        config,
        global_config,
        git: GitService::new(canonical_root),
    })
}

fn workspace_launch_source(
    kind: &str,
    number: i64,
    title: &str,
    url: &str,
) -> WorkspaceLaunchSourceView {
    WorkspaceLaunchSourceView {
        kind: kind.to_string(),
        number,
        title: title.to_string(),
        url: url.to_string(),
    }
}

fn workspace_opener_workspace_name(prefix: &str, number: i64, title: &str) -> String {
    format!("{prefix} #{number} — {title}")
}

fn workspace_opener_task_title(prefix: &str, number: i64, title: &str) -> String {
    format!("{prefix} #{number}: {title}")
}

fn workspace_opener_task_goal(prefix: &str, number: i64, title: &str) -> String {
    format!("Track {prefix} #{number}: {title}")
}

fn workspace_opener_branch_launch_source(branch_name: &str) -> WorkspaceLaunchSourceView {
    workspace_launch_source("branch", 0, branch_name, "")
}

async fn workspace_opener_validated_branch_name(
    repo_root: &Path,
    raw_branch_name: &str,
) -> Result<String, String> {
    ensure_bounded_text_field(raw_branch_name, "branch name", 255)?;
    let branch_name = raw_branch_name.trim().to_string();
    let output = TokioCommand::new("git")
        .args(["check-ref-format", "--branch", &branch_name])
        .current_dir(repo_root)
        .output()
        .await
        .map_err(|e| format!("failed to validate branch name: {e}"))?;

    if output.status.success() {
        Ok(branch_name)
    } else {
        let stderr = String::from_utf8_lossy(&output.stderr).trim().to_string();
        if stderr.is_empty() {
            Err("Branch name is invalid.".to_string())
        } else {
            Err(format!("Branch name is invalid: {stderr}"))
        }
    }
}

async fn workspace_opener_existing_launch_result(
    project: &WorkspaceOpenerManagedProject,
    external_kind: &str,
    external_id: &str,
    workspace_name: &str,
    launch_source: &WorkspaceLaunchSourceView,
) -> Result<Option<WorkspaceOpenerLaunchResult>, String> {
    let Some(source_row) = project
        .db
        .get_task_external_source(&project.project_id.to_string(), external_kind, external_id)
        .await
        .map_err(|e| e.to_string())?
    else {
        return Ok(None);
    };

    let Some(task_row) = project
        .db
        .get_task(&source_row.task_id)
        .await
        .map_err(|e| e.to_string())?
    else {
        return Ok(None);
    };

    let Some(worktree_id) = task_row.worktree_id.as_ref() else {
        return Ok(None);
    };

    let worktree_row = project
        .db
        .list_worktrees(&project.project_id.to_string())
        .await
        .map_err(|e| e.to_string())?
        .into_iter()
        .find(|row| row.id == *worktree_id);

    let Some(worktree_row) = worktree_row else {
        return Ok(None);
    };

    if !Path::new(&worktree_row.path).exists() {
        return Ok(None);
    }

    Ok(Some(WorkspaceOpenerLaunchResult {
        project_path: project.repo_root.to_string_lossy().to_string(),
        workspace_name: workspace_name.to_string(),
        launch_source: launch_source.clone(),
        working_directory: Some(worktree_row.path),
        task_id: Some(task_row.id),
        branch: Some(worktree_row.branch),
    }))
}

struct WorkspaceOpenerExternalSourceSpec {
    task_title: String,
    task_goal: String,
    external_kind: &'static str,
    external_id: String,
    identifier: String,
    url: String,
    state: String,
}

async fn workspace_opener_create_task_with_external_source(
    project: &WorkspaceOpenerManagedProject,
    spec: WorkspaceOpenerExternalSourceSpec,
    app_state: &AppState,
) -> Result<pnevma_db::TaskExternalSourceRow, String> {
    let task_id = Uuid::new_v4();
    let now = Utc::now();
    let task_title_for_source = spec.task_title.clone();
    let external_id_for_event = spec.external_id.clone();
    let task = TaskContract {
        id: task_id,
        title: spec.task_title.clone(),
        goal: spec.task_goal,
        scope: Vec::new(),
        out_of_scope: Vec::new(),
        dependencies: Vec::new(),
        acceptance_criteria: Vec::new(),
        constraints: Vec::new(),
        priority: Priority::P2,
        status: TaskStatus::Planned,
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
        loop_iteration: 0,
        loop_context_json: None,
        external_source: None,
        created_at: now,
        updated_at: now,
    };
    task.validate_new().map_err(|e| e.to_string())?;

    let row = task_contract_to_row(&task, &project.project_id.to_string())?;
    project
        .db
        .create_task(&row)
        .await
        .map_err(|e| e.to_string())?;

    append_event(
        &project.db,
        project.project_id,
        Some(task_id),
        None,
        "workspace_opener",
        "TaskCreated",
        json!({"title": row.title, "source": spec.external_kind, "external_id": external_id_for_event}),
    )
    .await;
    append_telemetry_event(
        &project.db,
        project.project_id,
        &project.global_config,
        "workspace_opener.task_create",
        json!({"task_id": row.id, "source": spec.external_kind, "external_id": external_id_for_event}),
    )
    .await;
    emit_enriched_task_event(&app_state.emitter, &project.db, &row.id).await;

    let external_source = pnevma_db::TaskExternalSourceRow {
        id: Uuid::new_v4().to_string(),
        project_id: project.project_id.to_string(),
        task_id: row.id.clone(),
        kind: spec.external_kind.to_string(),
        external_id: spec.external_id,
        identifier: spec.identifier,
        url: spec.url,
        state: spec.state,
        synced_at: now,
        title: Some(task_title_for_source),
        description: None,
        labels_json: Some("[]".to_string()),
    };
    project
        .db
        .upsert_task_external_source(&external_source)
        .await
        .map_err(|e| e.to_string())?;

    append_event(
        &project.db,
        project.project_id,
        Some(task_id),
        None,
        "workspace_opener",
        "TaskExternalSourceLinked",
        json!({"kind": external_source.kind, "external_id": external_source.external_id}),
    )
    .await;

    Ok(external_source)
}

async fn workspace_opener_attach_worktree_to_task(
    project: &WorkspaceOpenerManagedProject,
    task_id: Uuid,
    start_point: &str,
    slug_source: &str,
    state: &AppState,
) -> Result<(String, String), String> {
    let slug = slugify_with_fallback(slug_source, "task");
    let lease = project
        .git
        .create_worktree_from_start_point(task_id, start_point, &slug)
        .await
        .map_err(|e| e.to_string())?;
    let canonical_worktree = tokio::fs::canonicalize(&lease.path)
        .await
        .map_err(|e| format!("worktree path unavailable: {e}"))?;
    let canonical_worktree_str = canonical_worktree.to_string_lossy().to_string();
    let worktree_row = pnevma_db::WorktreeRow {
        id: lease.id.to_string(),
        project_id: project.project_id.to_string(),
        task_id: task_id.to_string(),
        path: canonical_worktree_str.clone(),
        branch: lease.branch.clone(),
        lease_status: "Active".to_string(),
        lease_started: lease.started_at,
        last_active: lease.last_active,
    };
    project
        .db
        .upsert_worktree(&worktree_row)
        .await
        .map_err(|e| e.to_string())?;

    let mut task_row = project
        .db
        .get_task(&task_id.to_string())
        .await
        .map_err(|e| e.to_string())?
        .ok_or_else(|| format!("task not found: {task_id}"))?;
    task_row.branch = Some(lease.branch.clone());
    task_row.worktree_id = Some(worktree_row.id.clone());
    task_row.updated_at = Utc::now();
    project
        .db
        .update_task(&task_row)
        .await
        .map_err(|e| e.to_string())?;

    append_event(
        &project.db,
        project.project_id,
        Some(task_id),
        None,
        "workspace_opener",
        "WorktreeCreated",
        json!({"branch": lease.branch, "path": canonical_worktree_str}),
    )
    .await;
    append_telemetry_event(
        &project.db,
        project.project_id,
        &project.global_config,
        "workspace_opener.worktree_create",
        json!({"task_id": task_id.to_string(), "branch": task_row.branch}),
    )
    .await;
    emit_enriched_task_event(&state.emitter, &project.db, &task_row.id).await;

    Ok((canonical_worktree_str, task_row.branch.unwrap_or_default()))
}

fn github_status_view(
    state: &str,
    message: impl Into<String>,
    detail: Option<String>,
    resolved_repo: Option<String>,
) -> GitHubRepoStatusView {
    GitHubRepoStatusView {
        state: state.to_string(),
        message: message.into(),
        detail,
        resolved_repo,
    }
}

pub async fn github_status_for_path(
    input: WorkspaceOpenerPathInput,
) -> Result<GitHubRepoStatusView, String> {
    let context = match workspace_opener_repo_context_for_input(&input).await {
        Ok(context) => context,
        Err(status) => return Ok(status),
    };

    match gh_repo_view(&context.repo_root, &context.repo_spec).await {
        Ok(repo) => Ok(github_status_view(
            "ready",
            "GitHub is connected for this repository.",
            None,
            Some(repo.name_with_owner),
        )),
        Err(detail) => Ok(github_status_view(
            "error",
            "Could not access the GitHub repository for this folder.",
            Some(detail),
            Some(context.repo_spec),
        )),
    }
}

pub async fn github_connect_for_path(
    input: WorkspaceOpenerPathInput,
) -> Result<GitHubRepoStatusView, String> {
    github_status_for_path(input).await
}

pub async fn list_branches_for_path(
    input: WorkspaceOpenerPathInput,
) -> Result<Vec<WorkspaceOpenerBranchView>, String> {
    let requested_path = project_path_from_input(&input)?;
    let project_path = git_repo_root_for_path(&requested_path).await?;
    let worktrees_by_branch = workspace_opener_auxiliary_worktrees_by_branch(&project_path).await?;
    let output = TokioCommand::new("git")
        .args([
            "branch",
            "--sort=-committerdate",
            "--format=%(refname:short)",
        ])
        .current_dir(&project_path)
        .output()
        .await
        .map_err(|e| e.to_string())?;

    if !output.status.success() {
        return Err("git branch failed".to_string());
    }

    Ok(String::from_utf8_lossy(&output.stdout)
        .lines()
        .map(str::trim)
        .filter(|branch| !branch.is_empty())
        .map(|branch| WorkspaceOpenerBranchView {
            name: branch.to_string(),
            has_worktree: worktrees_by_branch.contains_key(branch),
            worktree_path: worktrees_by_branch.get(branch).cloned(),
        })
        .collect())
}

pub async fn create_workspace_from_branch(
    input: WorkspaceOpenerBranchLaunchInput,
) -> Result<WorkspaceOpenerLaunchResult, String> {
    ensure_safe_path_input(&input.path, "project path")?;

    let requested_path = PathBuf::from(&input.path);
    let repo_root = git_repo_root_for_path(&requested_path).await?;
    let branch_name =
        workspace_opener_validated_branch_name(&repo_root, &input.branch_name).await?;
    let launch_source = workspace_opener_branch_launch_source(&branch_name);
    let worktrees_by_branch = workspace_opener_auxiliary_worktrees_by_branch(&repo_root).await?;

    if let Some(worktree_path) = worktrees_by_branch.get(&branch_name) {
        return Ok(WorkspaceOpenerLaunchResult {
            project_path: repo_root.to_string_lossy().to_string(),
            workspace_name: branch_name.clone(),
            launch_source,
            working_directory: Some(worktree_path.clone()),
            task_id: None,
            branch: Some(branch_name),
        });
    }

    let git_args = if input.create_new {
        vec!["checkout", "-b", branch_name.as_str()]
    } else {
        vec!["checkout", branch_name.as_str()]
    };
    let output = TokioCommand::new("git")
        .args(&git_args)
        .current_dir(&repo_root)
        .output()
        .await
        .map_err(|e| format!("failed to run git checkout: {e}"))?;

    if !output.status.success() {
        let stderr = String::from_utf8_lossy(&output.stderr).trim().to_string();
        let action = if input.create_new {
            "create branch"
        } else {
            "checkout branch"
        };
        let message = if stderr.is_empty() {
            format!("Could not {action}.")
        } else {
            format!("Could not {action}: {stderr}")
        };
        return Err(message);
    }

    Ok(WorkspaceOpenerLaunchResult {
        project_path: repo_root.to_string_lossy().to_string(),
        workspace_name: branch_name.clone(),
        launch_source,
        working_directory: None,
        task_id: None,
        branch: Some(branch_name),
    })
}

pub async fn list_github_issues_for_path(
    input: WorkspaceOpenerPathInput,
) -> Result<Vec<GitHubIssueView>, String> {
    let context = workspace_opener_repo_context_from_path(&input.path).await?;
    let mut command = crate::github_cli::command();
    command
        .args([
            "issue",
            "list",
            "-R",
            &context.repo_spec,
            "--json",
            "number,title,state,labels,author",
            "--limit",
            "50",
        ])
        .current_dir(&context.repo_root);
    let output = command
        .output()
        .await
        .map_err(|e| format!("failed to run gh: {e}"))?;

    if !output.status.success() {
        let stderr = String::from_utf8_lossy(&output.stderr);
        return Err(format!("gh issue list failed: {stderr}"));
    }

    let items: Vec<GhIssueJson> =
        serde_json::from_slice(&output.stdout).map_err(|e| format!("parse error: {e}"))?;

    Ok(items
        .into_iter()
        .map(|item| GitHubIssueView {
            number: item.number,
            title: item.title,
            state: item.state,
            labels: item.labels.into_iter().map(|label| label.name).collect(),
            author: item.author.login,
        })
        .collect())
}

pub async fn list_github_pull_requests_for_path(
    input: WorkspaceOpenerPathInput,
) -> Result<Vec<GitHubPullRequestView>, String> {
    let context = workspace_opener_repo_context_from_path(&input.path).await?;
    let mut command = crate::github_cli::command();
    command
        .args([
            "pr",
            "list",
            "-R",
            &context.repo_spec,
            "--json",
            "number,title,headRefName,baseRefName,state",
            "--limit",
            "50",
        ])
        .current_dir(&context.repo_root);
    let output = command
        .output()
        .await
        .map_err(|e| format!("failed to run gh: {e}"))?;

    if !output.status.success() {
        let stderr = String::from_utf8_lossy(&output.stderr);
        return Err(format!("gh pr list failed: {stderr}"));
    }

    let items: Vec<GhPullRequestJson> =
        serde_json::from_slice(&output.stdout).map_err(|e| format!("parse error: {e}"))?;

    Ok(items
        .into_iter()
        .map(|item| GitHubPullRequestView {
            number: item.number,
            title: item.title,
            source_branch: item.head_ref_name,
            target_branch: item.base_ref_name,
            status: item.state,
        })
        .collect())
}

pub async fn create_workspace_from_issue(
    input: WorkspaceOpenerIssueLaunchInput,
    state: &AppState,
) -> Result<WorkspaceOpenerLaunchResult, String> {
    ensure_safe_path_input(&input.path, "project path")?;
    ensure_positive_external_number(input.issue_number, "issue number")?;

    let repo_context = workspace_opener_repo_context_from_path(&input.path).await?;
    let issue_number = input.issue_number.to_string();
    let mut issue_command = crate::github_cli::command();
    issue_command
        .args([
            "issue",
            "view",
            &issue_number,
            "-R",
            &repo_context.repo_spec,
            "--json",
            "number,title,state,url",
        ])
        .current_dir(&repo_context.repo_root);
    let issue_output = issue_command
        .output()
        .await
        .map_err(|e| format!("failed to run gh: {e}"))?;
    if !issue_output.status.success() {
        let stderr = String::from_utf8_lossy(&issue_output.stderr);
        return Err(format!("gh issue view failed: {stderr}"));
    }
    let issue: GhIssueDetailJson =
        serde_json::from_slice(&issue_output.stdout).map_err(|e| format!("parse error: {e}"))?;

    let workspace_name = workspace_opener_workspace_name("Issue", issue.number, &issue.title);
    let launch_source = workspace_launch_source("issue", issue.number, &issue.title, &issue.url);
    if !input.create_linked_task_worktree {
        return Ok(WorkspaceOpenerLaunchResult {
            project_path: repo_context.repo_root.to_string_lossy().to_string(),
            workspace_name,
            launch_source,
            working_directory: None,
            task_id: None,
            branch: None,
        });
    }

    let project = workspace_opener_managed_project(&repo_context.repo_root, state).await?;
    if let Some(existing) = workspace_opener_existing_launch_result(
        &project,
        "github_issue",
        &issue.number.to_string(),
        &workspace_name,
        &launch_source,
    )
    .await?
    {
        return Ok(existing);
    }

    let repo = gh_repo_view(&repo_context.repo_root, &repo_context.repo_spec).await?;
    let start_point = project.config.branches.target.trim().to_string();
    let start_point = if start_point.is_empty() {
        repo.default_branch_ref
            .as_ref()
            .map(|branch| branch.name.clone())
            .unwrap_or_else(|| "main".to_string())
    } else {
        start_point
    };

    let external_source = workspace_opener_create_task_with_external_source(
        &project,
        WorkspaceOpenerExternalSourceSpec {
            task_title: workspace_opener_task_title("Issue", issue.number, &issue.title),
            task_goal: workspace_opener_task_goal("issue", issue.number, &issue.title),
            external_kind: "github_issue",
            external_id: issue.number.to_string(),
            identifier: format!("#{}", issue.number),
            url: issue.url.clone(),
            state: issue.state,
        },
        state,
    )
    .await?;
    let task_id =
        Uuid::parse_str(&external_source.task_id).map_err(|e| format!("invalid task id: {e}"))?;
    let (working_directory, branch) = workspace_opener_attach_worktree_to_task(
        &project,
        task_id,
        &start_point,
        &issue.title,
        state,
    )
    .await?;

    Ok(WorkspaceOpenerLaunchResult {
        project_path: project.repo_root.to_string_lossy().to_string(),
        workspace_name,
        launch_source,
        working_directory: Some(working_directory),
        task_id: Some(task_id.to_string()),
        branch: Some(branch),
    })
}

pub async fn create_workspace_from_pull_request(
    input: WorkspaceOpenerPullRequestLaunchInput,
    state: &AppState,
) -> Result<WorkspaceOpenerLaunchResult, String> {
    ensure_safe_path_input(&input.path, "project path")?;
    ensure_positive_external_number(input.pr_number, "pull request number")?;

    let repo_context = workspace_opener_repo_context_from_path(&input.path).await?;
    let pr_number = input.pr_number.to_string();
    let mut pr_command = crate::github_cli::command();
    pr_command
        .args([
            "pr",
            "view",
            &pr_number,
            "-R",
            &repo_context.repo_spec,
            "--json",
            "number,title,headRefName,baseRefName,state,url,headRepository",
        ])
        .current_dir(&repo_context.repo_root);
    let pr_output = pr_command
        .output()
        .await
        .map_err(|e| format!("failed to run gh: {e}"))?;
    if !pr_output.status.success() {
        let stderr = String::from_utf8_lossy(&pr_output.stderr);
        return Err(format!("gh pr view failed: {stderr}"));
    }
    let pr: GhPullRequestDetailJson =
        serde_json::from_slice(&pr_output.stdout).map_err(|e| format!("parse error: {e}"))?;

    let workspace_name = workspace_opener_workspace_name("PR", pr.number, &pr.title);
    let launch_source = workspace_launch_source("pull_request", pr.number, &pr.title, &pr.url);
    if !input.create_linked_task_worktree {
        return Ok(WorkspaceOpenerLaunchResult {
            project_path: repo_context.repo_root.to_string_lossy().to_string(),
            workspace_name,
            launch_source,
            working_directory: None,
            task_id: None,
            branch: None,
        });
    }

    let project = workspace_opener_managed_project(&repo_context.repo_root, state).await?;
    if let Some(existing) = workspace_opener_existing_launch_result(
        &project,
        "github_pull_request",
        &pr.number.to_string(),
        &workspace_name,
        &launch_source,
    )
    .await?
    {
        return Ok(existing);
    }

    let external_source = workspace_opener_create_task_with_external_source(
        &project,
        WorkspaceOpenerExternalSourceSpec {
            task_title: workspace_opener_task_title("PR", pr.number, &pr.title),
            task_goal: workspace_opener_task_goal("pull request", pr.number, &pr.title),
            external_kind: "github_pull_request",
            external_id: pr.number.to_string(),
            identifier: format!("#{}", pr.number),
            url: pr.url.clone(),
            state: pr.state.clone(),
        },
        state,
    )
    .await?;
    let task_id =
        Uuid::parse_str(&external_source.task_id).map_err(|e| format!("invalid task id: {e}"))?;

    let head_repository = pr
        .head_repository
        .and_then(|repo| repo.url)
        .filter(|url| !url.trim().is_empty())
        .ok_or_else(|| "Pull request head repository is unavailable.".to_string())?;

    let fetch_output = TokioCommand::new("git")
        .args([
            "fetch",
            "--no-tags",
            "--depth=1",
            &head_repository,
            &pr.head_ref_name,
        ])
        .current_dir(&repo_context.repo_root)
        .output()
        .await
        .map_err(|e| format!("failed to run git fetch: {e}"))?;
    if !fetch_output.status.success() {
        let stderr = String::from_utf8_lossy(&fetch_output.stderr);
        return Err(format!("git fetch failed: {stderr}"));
    }

    let (working_directory, branch) =
        workspace_opener_attach_worktree_to_task(&project, task_id, "FETCH_HEAD", &pr.title, state)
            .await?;

    Ok(WorkspaceOpenerLaunchResult {
        project_path: project.repo_root.to_string_lossy().to_string(),
        workspace_name,
        launch_source,
        working_directory: Some(working_directory),
        task_id: Some(task_id.to_string()),
        branch: Some(branch),
    })
}

async fn fleet_machine_id() -> Result<String, String> {
    let global_db = pnevma_db::GlobalDb::open()
        .await
        .map_err(|e| format!("failed to open global db: {e}"))?;
    if let Some(existing) = global_db
        .get_metadata(FLEET_MACHINE_ID_KEY)
        .await
        .map_err(|e| e.to_string())?
    {
        return Ok(existing);
    }

    let generated = Uuid::new_v4().to_string();
    global_db
        .set_metadata(FLEET_MACHINE_ID_KEY, &generated)
        .await
        .map_err(|e| e.to_string())?;
    Ok(generated)
}

fn fleet_machine_name() -> String {
    std::env::var("HOSTNAME")
        .ok()
        .map(|value| value.trim().to_string())
        .filter(|value| !value.is_empty())
        .unwrap_or_else(|| "local-machine".to_string())
}

pub async fn project_status(state: &AppState) -> Result<ProjectStatusView, String> {
    // Extract everything we need from the lock scope first, then release
    // the lock before calling coord.snapshot() — snapshot() also acquires
    // state.current, and Tokio mutexes are not reentrant.
    let (db, project_id, project_name, project_path, coordinator) = state
        .with_project("project_status", |ctx| {
            (
                ctx.db.clone(),
                ctx.project_id,
                ctx.config.project.name.clone(),
                ctx.project_path.to_string_lossy().to_string(),
                ctx.coordinator.clone(),
            )
        })
        .await?;

    let sessions = db
        .list_sessions(&project_id.to_string())
        .await
        .map_err(|e| e.to_string())?;
    let tasks = db
        .list_tasks(&project_id.to_string())
        .await
        .map_err(|e| e.to_string())?;
    let worktrees = db
        .list_worktrees(&project_id.to_string())
        .await
        .map_err(|e| e.to_string())?;
    let automation = if let Some(ref coord) = coordinator {
        Some(super::automation_status_from_snapshot(coord.snapshot().await, &db, &project_id).await)
    } else {
        None
    };
    Ok(ProjectStatusView {
        project_id: project_id.to_string(),
        project_name,
        project_path,
        sessions: sessions.len(),
        tasks: tasks.len(),
        worktrees: worktrees.len(),
        automation,
    })
}

pub async fn project_summary(state: &AppState) -> Result<ProjectSummaryView, String> {
    let (db, project_id, project_path) = state
        .with_project("project_summary", |ctx| {
            (ctx.db.clone(), ctx.project_id, ctx.project_path.clone())
        })
        .await?;

    let sessions = db
        .list_sessions(&project_id.to_string())
        .await
        .map_err(|e| e.to_string())?;
    let tasks = db
        .list_tasks(&project_id.to_string())
        .await
        .map_err(|e| e.to_string())?;
    let unread_notifications = db
        .list_notifications(&project_id.to_string(), true)
        .await
        .map_err(|e| e.to_string())?
        .len();

    db.aggregate_costs_daily(&project_id.to_string())
        .await
        .map_err(|e| e.to_string())?;
    let today = Utc::now().format("%Y-%m-%d").to_string();
    let cost_today = db
        .get_usage_daily_trend(&project_id.to_string(), 1)
        .await
        .map_err(|e| e.to_string())?
        .into_iter()
        .find(|row| row.period_date == today)
        .map(|row| row.estimated_usd)
        .unwrap_or(0.0);

    let git_branch = TokioCommand::new("git")
        .arg("rev-parse")
        .arg("--abbrev-ref")
        .arg("HEAD")
        .current_dir(&project_path)
        .output()
        .await
        .ok()
        .filter(|out| out.status.success())
        .and_then(|out| String::from_utf8(out.stdout).ok())
        .map(|branch| branch.trim().to_string())
        .filter(|branch| !branch.is_empty());

    let git_dirty = TokioCommand::new("git")
        .args(["status", "--porcelain"])
        .current_dir(&project_path)
        .output()
        .await
        .ok()
        .filter(|out| out.status.success())
        .map(|out| !out.stdout.is_empty());

    let (diff_insertions, diff_deletions) = TokioCommand::new("git")
        .args(["diff", "--shortstat"])
        .current_dir(&project_path)
        .output()
        .await
        .ok()
        .filter(|out| out.status.success())
        .and_then(|out| String::from_utf8(out.stdout).ok())
        .map(|stat| parse_shortstat(&stat))
        .unwrap_or((None, None));

    let (linked_pr_number, linked_pr_url, ci_status) = if let Some(ref branch) = git_branch {
        let pr_result = tokio::time::timeout(std::time::Duration::from_millis(3000), {
            let mut command = crate::github_cli::command();
            command
                .args([
                    "pr",
                    "list",
                    "--head",
                    branch,
                    "--json",
                    "number,url,statusCheckRollup",
                    "--limit",
                    "1",
                ])
                .current_dir(&project_path);
            command.output()
        })
        .await
        .ok()
        .and_then(|r| r.ok())
        .filter(|out| out.status.success())
        .and_then(|out| String::from_utf8(out.stdout).ok())
        .and_then(|json_str| serde_json::from_str::<Vec<serde_json::Value>>(&json_str).ok())
        .and_then(|arr| arr.into_iter().next());

        match pr_result {
            Some(pr) => {
                let number = pr.get("number").and_then(|v| v.as_u64());
                let url = pr.get("url").and_then(|v| v.as_str()).map(String::from);
                let ci = pr
                    .get("statusCheckRollup")
                    .and_then(|v| v.as_array())
                    .map(|checks| {
                        if checks.iter().any(|c| {
                            c.get("conclusion").and_then(|v| v.as_str()) == Some("FAILURE")
                        }) {
                            "failed".to_string()
                        } else if checks.iter().any(|c| {
                            c.get("status").and_then(|v| v.as_str()) == Some("IN_PROGRESS")
                        }) {
                            "running".to_string()
                        } else if checks.iter().all(|c| {
                            c.get("conclusion").and_then(|v| v.as_str()) == Some("SUCCESS")
                        }) {
                            "pass".to_string()
                        } else {
                            "none".to_string()
                        }
                    });
                (number, url, ci)
            }
            None => (None, None, None),
        }
    } else {
        (None, None, None)
    };

    Ok(ProjectSummaryView {
        project_id: project_id.to_string(),
        git_branch,
        active_tasks: tasks
            .iter()
            .filter(|task| !matches!(task.status.as_str(), "Done" | "Failed"))
            .count(),
        active_agents: sessions
            .iter()
            .filter(|session| {
                session.r#type.as_deref() == Some("agent") && session.status == "running"
            })
            .count(),
        cost_today,
        unread_notifications,
        diff_insertions,
        diff_deletions,
        linked_pr_number,
        linked_pr_url,
        ci_status,
        attention_reason: None,
        git_dirty,
    })
}

#[derive(Debug, Clone)]
struct CommandCenterSessionCandidate {
    id: String,
    name: String,
    status: String,
    health: String,
    branch: Option<String>,
    worktree_id: Option<String>,
    started_at: DateTime<Utc>,
    last_activity_at: DateTime<Utc>,
}

fn command_center_session_status(status: SessionStatus) -> &'static str {
    match status {
        SessionStatus::Running => "running",
        SessionStatus::Waiting => "waiting",
        SessionStatus::Error => "error",
        SessionStatus::Complete => "complete",
    }
}

fn command_center_session_health(health: SessionHealth) -> &'static str {
    match health {
        SessionHealth::Active => "active",
        SessionHealth::Idle => "idle",
        SessionHealth::Stuck => "stuck",
        SessionHealth::Waiting => "waiting",
        SessionHealth::Error => "error",
        SessionHealth::Complete => "complete",
    }
}

fn command_center_actions(
    task_id: Option<&str>,
    task_status: Option<&str>,
    session_id: Option<&str>,
    session_status: Option<&str>,
) -> Vec<String> {
    let mut actions = Vec::new();
    if session_id.is_some() {
        actions.push("open_terminal".to_string());
        actions.push("open_replay".to_string());
        actions.push("restart_session".to_string());
        if matches!(session_status, Some("running" | "waiting" | "error")) {
            actions.push("kill_session".to_string());
        }
        if matches!(session_status, Some("waiting")) {
            actions.push("reattach_session".to_string());
        }
    }
    if task_id.is_some() {
        actions.push("open_diff".to_string());
        actions.push("open_files".to_string());
        if matches!(task_status, Some("Review")) {
            actions.push("open_review".to_string());
        }
    }
    actions
}

fn command_center_file_targets(
    project_path: &str,
    task_scope_json: &str,
    worktree: Option<&WorktreeRow>,
) -> (Option<String>, Vec<String>, Option<String>) {
    let scope: Vec<String> = serde_json::from_str(task_scope_json).unwrap_or_default();
    let project_root = std::path::Path::new(project_path);
    let worktree_root = worktree.map(|row| std::path::Path::new(&row.path));

    let mut scope_paths = Vec::new();
    for raw_scope in scope {
        let trimmed = raw_scope.trim().trim_start_matches('/');
        if trimmed.is_empty() {
            continue;
        }

        let scope_path = std::path::Path::new(trimmed);
        let candidate = if let Some(worktree_root) = worktree_root {
            worktree_root.join(scope_path)
        } else {
            project_root.join(scope_path)
        };

        if let Ok(relative) = candidate.strip_prefix(project_root) {
            let rel = relative.to_string_lossy().replace('\\', "/");
            if !rel.is_empty() && !scope_paths.contains(&rel) {
                scope_paths.push(rel);
            }
        }
    }

    let worktree_path = worktree.and_then(|row| {
        std::path::Path::new(&row.path)
            .strip_prefix(project_root)
            .ok()
            .map(|path| path.to_string_lossy().replace('\\', "/"))
            .filter(|path| !path.is_empty())
    });
    let primary_file_path = scope_paths.first().cloned();

    (primary_file_path, scope_paths, worktree_path)
}

pub async fn command_center_snapshot(
    state: &AppState,
) -> Result<CommandCenterSnapshotView, String> {
    let (db, project_id, project_name, project_path, max_concurrent, sessions, coordinator) = state
        .with_project("command_center_snapshot", |ctx| {
            (
                ctx.db.clone(),
                ctx.project_id,
                ctx.config.project.name.clone(),
                ctx.project_path.to_string_lossy().to_string(),
                ctx.config.agents.max_concurrent,
                ctx.sessions.clone(),
                ctx.coordinator.clone(),
            )
        })
        .await?;

    let tasks = db
        .list_tasks(&project_id.to_string())
        .await
        .map_err(|e| e.to_string())?;
    let worktrees = db
        .list_worktrees(&project_id.to_string())
        .await
        .map_err(|e| e.to_string())?;
    let recent_runs = db
        .list_automation_runs(&project_id.to_string(), 100)
        .await
        .map_err(|e| e.to_string())?;
    let pending_retries = db
        .list_pending_retries(&project_id.to_string())
        .await
        .map_err(|e| e.to_string())?;

    db.aggregate_costs_daily(&project_id.to_string())
        .await
        .map_err(|e| e.to_string())?;
    let today = Utc::now().format("%Y-%m-%d").to_string();
    let cost_today = db
        .get_usage_daily_trend(&project_id.to_string(), 1)
        .await
        .map_err(|e| e.to_string())?
        .into_iter()
        .find(|row| row.period_date == today)
        .map(|row| row.estimated_usd)
        .unwrap_or(0.0);

    let automation_snapshot = if let Some(coord) = coordinator {
        coord.snapshot().await
    } else {
        default_automation_snapshot(max_concurrent)
    };

    let worktrees_by_id: HashMap<String, WorktreeRow> = worktrees
        .into_iter()
        .map(|row| (row.id.clone(), row))
        .collect();
    let runs_by_task: HashMap<String, AutomationRunRow> = recent_runs.into_iter().fold(
        HashMap::<String, AutomationRunRow>::new(),
        |mut acc, row| {
            acc.entry(row.task_id.clone()).or_insert(row);
            acc
        },
    );
    let retries_by_task: HashMap<String, pnevma_db::AutomationRetryRow> = pending_retries
        .into_iter()
        .fold(HashMap::new(), |mut acc, row| {
            acc.entry(row.task_id.clone()).or_insert(row);
            acc
        });

    let live_sessions: Vec<CommandCenterSessionCandidate> = sessions
        .list()
        .await
        .into_iter()
        .map(|meta| CommandCenterSessionCandidate {
            id: meta.id.to_string(),
            name: meta.name,
            status: command_center_session_status(meta.status).to_string(),
            health: command_center_session_health(meta.health).to_string(),
            branch: meta.branch,
            worktree_id: meta.worktree_id.map(|id| id.to_string()),
            started_at: meta.started_at,
            last_activity_at: meta.last_heartbeat,
        })
        .collect();

    let claims: HashSet<&str> = automation_snapshot
        .claimed_task_ids
        .iter()
        .map(String::as_str)
        .collect();
    let running_task_ids: HashSet<&str> = automation_snapshot
        .running_task_ids
        .iter()
        .map(String::as_str)
        .collect();

    let mut runs: Vec<CommandCenterRunView> = Vec::new();
    let mut matched_session_ids: HashSet<String> = HashSet::new();

    for task in tasks {
        let branch = task.branch.clone();
        let worktree_id = task.worktree_id.clone();
        let live_session = live_sessions.iter().find(|session| {
            worktree_id
                .as_ref()
                .is_some_and(|id| session.worktree_id.as_ref() == Some(id))
                || branch
                    .as_ref()
                    .is_some_and(|task_branch| session.branch.as_ref() == Some(task_branch))
        });
        if let Some(session) = live_session {
            matched_session_ids.insert(session.id.clone());
        }
        let latest_run = runs_by_task.get(&task.id);
        let pending_retry = retries_by_task.get(&task.id);
        let is_running = running_task_ids.contains(task.id.as_str());
        let is_claimed = claims.contains(task.id.as_str());

        let (state, attention_reason) = if let Some(retry) = pending_retry {
            let _ = retry;
            ("retrying".to_string(), Some("retrying".to_string()))
        } else if task.status == "Review" {
            (
                "review_needed".to_string(),
                Some("review_needed".to_string()),
            )
        } else if let Some(session) = live_session {
            match session.health.as_str() {
                "stuck" => ("stuck".to_string(), Some("stuck".to_string())),
                "idle" => ("idle".to_string(), Some("idle".to_string())),
                _ if matches!(session.status.as_str(), "running" | "waiting") => {
                    ("running".to_string(), None)
                }
                _ => ("failed".to_string(), Some("failed".to_string())),
            }
        } else if is_claimed && !is_running {
            ("queued".to_string(), Some("queued".to_string()))
        } else if task.status == "Failed"
            || latest_run
                .map(|run| run.status == "failed")
                .unwrap_or(false)
        {
            ("failed".to_string(), Some("failed".to_string()))
        } else if latest_run
            .map(|run| run.status == "completed")
            .unwrap_or(false)
        {
            ("completed".to_string(), None)
        } else {
            continue;
        };

        let started_at = live_session
            .map(|session| session.started_at)
            .or_else(|| latest_run.map(|run| run.started_at))
            .unwrap_or(task.updated_at);
        let last_activity_at = live_session
            .map(|session| session.last_activity_at)
            .or_else(|| pending_retry.map(|retry| retry.retry_after))
            .or_else(|| latest_run.and_then(|run| run.finished_at))
            .unwrap_or(task.updated_at);
        let cost_usd = latest_run.map(|run| run.cost_usd).unwrap_or(0.0);
        let tokens_in = latest_run.map(|run| run.tokens_in).unwrap_or(0);
        let tokens_out = latest_run.map(|run| run.tokens_out).unwrap_or(0);
        let derived_branch = branch.clone().or_else(|| {
            worktree_id
                .as_ref()
                .and_then(|id| worktrees_by_id.get(id).map(|wt| wt.branch.clone()))
        });
        let worktree = worktree_id.as_ref().and_then(|id| worktrees_by_id.get(id));
        let (primary_file_path, scope_paths, worktree_path) =
            command_center_file_targets(&project_path, &task.scope_json, worktree);

        runs.push(CommandCenterRunView {
            id: latest_run
                .map(|run| run.run_id.clone())
                .or_else(|| live_session.map(|session| session.id.clone()))
                .unwrap_or_else(|| task.id.clone()),
            task_id: Some(task.id.clone()),
            task_title: Some(task.title.clone()),
            task_status: Some(task.status.clone()),
            session_id: live_session.map(|session| session.id.clone()),
            session_name: live_session.map(|session| session.name.clone()),
            session_status: live_session.map(|session| session.status.clone()),
            session_health: live_session.map(|session| session.health.clone()),
            provider: latest_run.map(|run| run.provider.clone()),
            model: latest_run.and_then(|run| run.model.clone()),
            agent_profile: task.agent_profile_override.clone(),
            branch: derived_branch,
            worktree_id: worktree_id.clone(),
            primary_file_path,
            scope_paths,
            worktree_path,
            state: state.clone(),
            attention_reason,
            started_at,
            last_activity_at,
            retry_count: pending_retry
                .map(|retry| retry.attempt)
                .unwrap_or_else(|| latest_run.map(|run| run.attempt).unwrap_or(0)),
            retry_after: pending_retry.map(|retry| retry.retry_after),
            cost_usd,
            tokens_in,
            tokens_out,
            available_actions: command_center_actions(
                Some(task.id.as_str()),
                Some(task.status.as_str()),
                live_session.map(|session| session.id.as_str()),
                live_session.map(|session| session.status.as_str()),
            ),
        });
    }

    for session in live_sessions {
        if matched_session_ids.contains(&session.id) {
            continue;
        }
        runs.push(CommandCenterRunView {
            id: session.id.clone(),
            task_id: None,
            task_title: None,
            task_status: None,
            session_id: Some(session.id.clone()),
            session_name: Some(session.name.clone()),
            session_status: Some(session.status.clone()),
            session_health: Some(session.health.clone()),
            provider: None,
            model: None,
            agent_profile: None,
            branch: session.branch.clone(),
            worktree_id: session.worktree_id.clone(),
            primary_file_path: None,
            scope_paths: Vec::new(),
            worktree_path: session
                .worktree_id
                .as_ref()
                .and_then(|id| worktrees_by_id.get(id))
                .and_then(|wt| {
                    std::path::Path::new(&wt.path)
                        .strip_prefix(std::path::Path::new(&project_path))
                        .ok()
                        .map(|path| path.to_string_lossy().replace('\\', "/"))
                        .filter(|path| !path.is_empty())
                }),
            state: match session.health.as_str() {
                "stuck" => "stuck",
                "idle" => "idle",
                _ => "running",
            }
            .to_string(),
            attention_reason: match session.health.as_str() {
                "stuck" => Some("stuck".to_string()),
                "idle" => Some("idle".to_string()),
                _ => None,
            },
            started_at: session.started_at,
            last_activity_at: session.last_activity_at,
            retry_count: 0,
            retry_after: None,
            cost_usd: 0.0,
            tokens_in: 0,
            tokens_out: 0,
            available_actions: command_center_actions(
                None,
                None,
                Some(session.id.as_str()),
                Some(session.status.as_str()),
            ),
        });
    }

    runs.sort_by(|lhs, rhs| {
        let lhs_attention = lhs.attention_reason.is_some();
        let rhs_attention = rhs.attention_reason.is_some();
        rhs_attention
            .cmp(&lhs_attention)
            .then_with(|| rhs.last_activity_at.cmp(&lhs.last_activity_at))
    });

    let summary = CommandCenterSummaryView {
        active_count: runs.iter().filter(|run| run.state == "running").count(),
        queued_count: runs.iter().filter(|run| run.state == "queued").count(),
        idle_count: runs.iter().filter(|run| run.state == "idle").count(),
        stuck_count: runs.iter().filter(|run| run.state == "stuck").count(),
        review_needed_count: runs
            .iter()
            .filter(|run| run.state == "review_needed")
            .count(),
        failed_count: runs.iter().filter(|run| run.state == "failed").count(),
        retrying_count: runs.iter().filter(|run| run.state == "retrying").count(),
        slot_limit: automation_snapshot.max_concurrent,
        slot_in_use: automation_snapshot.active_runs.max(
            runs.iter()
                .filter(|run| matches!(run.state.as_str(), "running" | "idle" | "stuck"))
                .count(),
        ),
        cost_today_usd: cost_today,
    };

    Ok(CommandCenterSnapshotView {
        project_id: project_id.to_string(),
        project_name,
        project_path,
        generated_at: Utc::now(),
        summary,
        runs,
    })
}

pub async fn fleet_snapshot(state: &AppState) -> Result<FleetMachineSnapshotView, String> {
    let machine_id = fleet_machine_id().await?;
    let machine_name = fleet_machine_name();
    let generated_at = Utc::now();
    let open_snapshot = command_center_snapshot(state).await.ok();
    let open_project_path = open_snapshot
        .as_ref()
        .map(|snapshot| snapshot.project_path.clone());

    let mut projects = Vec::new();
    if let Some(snapshot) = open_snapshot.clone() {
        projects.push(FleetProjectEntryView {
            machine_id: machine_id.clone(),
            project_id: snapshot.project_id.clone(),
            project_name: snapshot.project_name.clone(),
            project_path: snapshot.project_path.clone(),
            state: "open".to_string(),
            last_opened_at: Some(generated_at),
            snapshot: Some(snapshot),
        });
    }

    if let Ok(global_db) = pnevma_db::GlobalDb::open().await {
        let recents = global_db
            .list_recent_projects(50)
            .await
            .map_err(|e| e.to_string())?;
        for recent in recents {
            if open_project_path.as_deref() == Some(recent.path.as_str()) {
                continue;
            }
            projects.push(FleetProjectEntryView {
                machine_id: machine_id.clone(),
                project_id: recent.project_id,
                project_name: recent.name,
                project_path: recent.path,
                state: "cataloged".to_string(),
                last_opened_at: Some(recent.opened_at),
                snapshot: None,
            });
        }
    }

    projects.sort_by(|left, right| {
        right
            .last_opened_at
            .cmp(&left.last_opened_at)
            .then_with(|| left.project_name.cmp(&right.project_name))
    });

    let summary = projects.iter().fold(
        FleetMachineSummaryView {
            project_count: projects.len(),
            open_project_count: 0,
            active_count: 0,
            queued_count: 0,
            idle_count: 0,
            stuck_count: 0,
            review_needed_count: 0,
            failed_count: 0,
            retrying_count: 0,
            slot_limit: 0,
            slot_in_use: 0,
            cost_today_usd: 0.0,
        },
        |mut acc, project| {
            if project.state == "open" {
                acc.open_project_count += 1;
            }
            if let Some(snapshot) = &project.snapshot {
                acc.active_count += snapshot.summary.active_count;
                acc.queued_count += snapshot.summary.queued_count;
                acc.idle_count += snapshot.summary.idle_count;
                acc.stuck_count += snapshot.summary.stuck_count;
                acc.review_needed_count += snapshot.summary.review_needed_count;
                acc.failed_count += snapshot.summary.failed_count;
                acc.retrying_count += snapshot.summary.retrying_count;
                acc.slot_limit += snapshot.summary.slot_limit;
                acc.slot_in_use += snapshot.summary.slot_in_use;
                acc.cost_today_usd += snapshot.summary.cost_today_usd;
            }
            acc
        },
    );

    Ok(FleetMachineSnapshotView {
        machine_id,
        machine_name,
        generated_at,
        summary,
        projects,
    })
}

pub async fn get_daily_brief(state: &AppState) -> Result<DailyBriefView, String> {
    let (db, project_id) = state
        .with_project("get_daily_brief", |ctx| (ctx.db.clone(), ctx.project_id))
        .await?;
    let tasks = db
        .list_tasks(&project_id.to_string())
        .await
        .map_err(|e| e.to_string())?;
    let recent = db
        .list_recent_events(&project_id.to_string(), 20)
        .await
        .map_err(|e| e.to_string())?;
    let ready_tasks = tasks.iter().filter(|task| task.status == "Ready").count();
    let review_tasks = tasks.iter().filter(|task| task.status == "Review").count();
    let blocked_tasks = tasks.iter().filter(|task| task.status == "Blocked").count();
    let failed_tasks = tasks.iter().filter(|task| task.status == "Failed").count();
    let mut actions = Vec::new();
    if review_tasks > 0 {
        actions.push(format!(
            "{review_tasks} task(s) waiting for review decisions"
        ));
    }
    if ready_tasks > 0 {
        actions.push(format!("{ready_tasks} task(s) ready for dispatch"));
    }
    if blocked_tasks > 0 {
        actions.push(format!("{blocked_tasks} task(s) blocked by dependencies"));
    }
    if failed_tasks > 0 {
        actions.push(format!(
            "{failed_tasks} task(s) failed and need handoff/recovery"
        ));
    }
    if actions.is_empty() {
        actions.push("No urgent actions. Continue highest-priority in-progress work.".to_string());
    }

    let recent_events = recent
        .into_iter()
        .map(timeline_view_from_event)
        .collect::<Vec<_>>();

    // Extended intelligence: active sessions
    let sessions = db
        .list_sessions(&project_id.to_string())
        .await
        .map_err(|e| e.to_string())?;
    let active_sessions = sessions.iter().filter(|s| s.status == "running").count();

    // Cost in last 24h
    let cost_last_24h_usd: f64 = sqlx::query_scalar(
        "SELECT COALESCE(SUM(c.estimated_usd), 0.0) FROM costs c JOIN tasks t ON c.task_id = t.id WHERE t.project_id = ?1 AND c.timestamp > datetime('now', '-24 hours')",
    )
    .bind(project_id.to_string())
    .fetch_one(db.pool())
    .await
    .unwrap_or(0.0);

    // Tasks completed/failed in last 24h (from events)
    let tasks_completed_last_24h: i64 = sqlx::query_scalar(
        "SELECT COUNT(*) FROM events WHERE project_id = ?1 AND event_type = 'TaskStatusChanged' AND json_extract(payload_json, '$.to') = 'Done' AND timestamp > datetime('now', '-24 hours')",
    )
    .bind(project_id.to_string())
    .fetch_one(db.pool())
    .await
    .unwrap_or(0);

    let tasks_failed_last_24h: i64 = sqlx::query_scalar(
        "SELECT COUNT(*) FROM events WHERE project_id = ?1 AND event_type = 'TaskStatusChanged' AND json_extract(payload_json, '$.to') = 'Failed' AND timestamp > datetime('now', '-24 hours')",
    )
    .bind(project_id.to_string())
    .fetch_one(db.pool())
    .await
    .unwrap_or(0);

    // Stale ready: Ready for >24h without dispatch
    let twenty_four_hours_ago = Utc::now() - chrono::Duration::hours(24);
    let stale_ready_count = tasks
        .iter()
        .filter(|t| t.status == "Ready" && t.updated_at < twenty_four_hours_ago)
        .count();

    // Longest running task (InProgress, oldest created_at)
    let longest_running_task = tasks
        .iter()
        .filter(|t| t.status == "InProgress")
        .min_by_key(|t| t.created_at)
        .map(|t| t.title.clone());

    // Top 3 tasks by cost
    #[derive(sqlx::FromRow)]
    struct TaskCostRow {
        task_id: String,
        total_cost: f64,
    }
    let top_cost_rows: Vec<TaskCostRow> = sqlx::query_as(
        "SELECT c.task_id, SUM(c.estimated_usd) as total_cost FROM costs c JOIN tasks t ON c.task_id = t.id WHERE t.project_id = ?1 AND c.task_id != '' GROUP BY c.task_id ORDER BY total_cost DESC LIMIT 3",
    )
    .bind(project_id.to_string())
    .fetch_all(db.pool())
    .await
    .unwrap_or_default();

    let mut top_cost_tasks = Vec::new();
    for cr in top_cost_rows {
        let title = tasks
            .iter()
            .find(|t| t.id == cr.task_id)
            .map(|t| t.title.clone())
            .unwrap_or_else(|| cr.task_id.clone());
        top_cost_tasks.push(TaskCostEntry {
            task_id: cr.task_id,
            title,
            cost_usd: cr.total_cost,
        });
    }

    if stale_ready_count > 0 {
        actions.push(format!(
            "{stale_ready_count} task(s) have been Ready for >24h — consider dispatching"
        ));
    }
    if let Some(ref lt) = longest_running_task {
        actions.push(format!("Longest running task: \"{lt}\" — check for stalls"));
    }

    let brief = DailyBriefView {
        generated_at: Utc::now(),
        total_tasks: tasks.len(),
        ready_tasks,
        review_tasks,
        blocked_tasks,
        failed_tasks,
        total_cost_usd: db
            .project_cost_total(&project_id.to_string())
            .await
            .unwrap_or(0.0),
        recent_events,
        recommended_actions: actions,
        active_sessions,
        cost_last_24h_usd,
        tasks_completed_last_24h: tasks_completed_last_24h as usize,
        tasks_failed_last_24h: tasks_failed_last_24h as usize,
        stale_ready_count,
        longest_running_task,
        top_cost_tasks,
    };
    append_event(
        &db,
        project_id,
        None,
        None,
        "system",
        "DailyBriefGenerated",
        json!({
            "total_tasks": brief.total_tasks,
            "ready_tasks": brief.ready_tasks,
            "review_tasks": brief.review_tasks,
            "blocked_tasks": brief.blocked_tasks,
            "failed_tasks": brief.failed_tasks
        }),
    )
    .await;
    Ok(brief)
}

fn infer_scope_paths(input: &str) -> Vec<String> {
    let mut paths = Vec::new();
    for token in input.split_whitespace() {
        let trimmed = token.trim_matches(|c: char| {
            matches!(
                c,
                ',' | '.' | ':' | ';' | '"' | '\'' | '(' | ')' | '[' | ']' | '{' | '}'
            )
        });
        let looks_like_path = trimmed.contains('/')
            || trimmed.ends_with(".rs")
            || trimmed.ends_with(".ts")
            || trimmed.ends_with(".tsx")
            || trimmed.ends_with(".js")
            || trimmed.ends_with(".json")
            || trimmed.ends_with(".toml")
            || trimmed.ends_with(".md");
        if looks_like_path && !trimmed.is_empty() && !paths.iter().any(|p| p == trimmed) {
            paths.push(trimmed.to_string());
        }
    }
    paths
}

fn normalize_priority(input: Option<&str>) -> String {
    match input.unwrap_or("P1").trim().to_ascii_uppercase().as_str() {
        "P0" => "P0".to_string(),
        "P1" => "P1".to_string(),
        "P2" => "P2".to_string(),
        _ => "P3".to_string(),
    }
}

pub(crate) fn fallback_draft(text: &str, warning: Option<String>) -> DraftTaskView {
    let title = text
        .split(['.', '\n'])
        .next()
        .map(str::trim)
        .filter(|line| !line.is_empty())
        .map(|line| {
            if line.chars().count() > 72 {
                line.chars().take(72).collect::<String>()
            } else {
                line.to_string()
            }
        })
        .unwrap_or_else(|| "Draft Task".to_string());
    let mut warnings = Vec::new();
    if let Some(message) = warning {
        warnings.push(message);
    }
    DraftTaskView {
        title,
        goal: text.to_string(),
        scope: infer_scope_paths(text),
        acceptance_criteria: vec![
            "Relevant tests pass".to_string(),
            "Manual review confirms expected behavior".to_string(),
        ],
        constraints: vec!["Keep changes scoped to requested behavior".to_string()],
        dependencies: Vec::new(),
        priority: "P1".to_string(),
        source: "fallback".to_string(),
        warnings,
    }
}

fn extract_first_json_object(raw: &str) -> Option<serde_json::Value> {
    let starts = raw
        .match_indices('{')
        .map(|(idx, _)| idx)
        .collect::<Vec<_>>();
    for start in starts {
        let mut ends = raw[start..]
            .match_indices('}')
            .map(|(idx, _)| start + idx + 1)
            .collect::<Vec<_>>();
        ends.reverse();
        for end in ends {
            if let Ok(parsed) = serde_json::from_str::<serde_json::Value>(&raw[start..end]) {
                if parsed.is_object() {
                    return Some(parsed);
                }
            }
        }
    }
    None
}

fn strings_from_array(value: Option<&serde_json::Value>) -> Vec<String> {
    value
        .and_then(|item| item.as_array())
        .map(|items| {
            items
                .iter()
                .filter_map(|item| item.as_str())
                .map(ToString::to_string)
                .filter(|item| !item.trim().is_empty())
                .collect::<Vec<_>>()
        })
        .unwrap_or_default()
}

fn parse_provider_draft(
    value: serde_json::Value,
    user_text: &str,
) -> Result<DraftTaskView, String> {
    let obj = value
        .as_object()
        .ok_or_else(|| "provider draft response must be a JSON object".to_string())?;
    let title = obj
        .get("title")
        .and_then(|v| v.as_str())
        .map(str::trim)
        .filter(|v| !v.is_empty())
        .ok_or_else(|| "provider draft missing title".to_string())?
        .to_string();
    let goal = obj
        .get("goal")
        .and_then(|v| v.as_str())
        .map(str::trim)
        .filter(|v| !v.is_empty())
        .map(ToString::to_string)
        .unwrap_or_else(|| user_text.to_string());
    let mut acceptance = strings_from_array(obj.get("acceptance_criteria"));
    if acceptance.is_empty() {
        acceptance.push("Relevant tests pass".to_string());
    }

    Ok(DraftTaskView {
        title,
        goal,
        scope: strings_from_array(obj.get("scope")),
        acceptance_criteria: acceptance,
        constraints: strings_from_array(obj.get("constraints")),
        dependencies: strings_from_array(obj.get("dependencies")),
        priority: normalize_priority(obj.get("priority").and_then(|v| v.as_str())),
        source: "provider".to_string(),
        warnings: Vec::new(),
    })
}

#[allow(clippy::too_many_arguments)]
pub(crate) async fn try_provider_task_draft(
    adapter: Arc<dyn pnevma_agents::AgentAdapter>,
    provider: &str,
    model: Option<String>,
    timeout_minutes: u64,
    env: Vec<(String, String)>,
    project_path: &Path,
    text: &str,
) -> Result<DraftTaskView, String> {
    let handle = adapter
        .spawn(AgentConfig {
            provider: provider.to_string(),
            model,
            env,
            working_dir: project_path.to_string_lossy().to_string(),
            timeout_minutes,
            auto_approve: false,
            allow_npx: false,
            npx_allowed_packages: vec![],
            allow_full_sandbox_access: false,
            output_format: "stream-json".to_string(),
            context_file: None,
            thread_id: None,
            dynamic_tools: vec![],
        })
        .await
        .map_err(|e| e.to_string())?;
    let mut rx = adapter.events(&handle);
    let objective = format!(
        "Draft a software task contract from this request.\n\
Return JSON only (no markdown, no prose) with keys:\n\
title, goal, scope[], acceptance_criteria[], constraints[], dependencies[], priority.\n\
Priority must be one of P0/P1/P2/P3.\n\
User request:\n{}",
        text
    );
    adapter
        .send(
            &handle,
            TaskPayload {
                task_id: Uuid::new_v4(),
                objective,
                constraints: vec!["Return strict JSON object only".to_string()],
                project_rules: Vec::new(),
                worktree_path: project_path.to_string_lossy().to_string(),
                branch_name: "draft-only".to_string(),
                acceptance_checks: Vec::new(),
                relevant_file_paths: Vec::new(),
                prior_context_summary: None,
            },
        )
        .await
        .map_err(|e| e.to_string())?;

    let mut combined_output = String::new();
    let timeout_window = Duration::from_secs((timeout_minutes.max(1) * 60).min(45));
    loop {
        let event = timeout(timeout_window, rx.recv())
            .await
            .map_err(|_| "provider draft timed out".to_string())?
            .map_err(|e| e.to_string())?;
        match event {
            AgentEvent::OutputChunk(chunk) => {
                combined_output.push_str(&chunk);
                if combined_output.len() > 128_000 {
                    let keep_from = combined_output.len().saturating_sub(96_000);
                    combined_output = combined_output[keep_from..].to_string();
                }
            }
            AgentEvent::Complete { summary } => {
                combined_output.push('\n');
                combined_output.push_str(&summary);
                break;
            }
            AgentEvent::Error(err) => {
                return Err(format!("provider draft failed: {err}"));
            }
            AgentEvent::ToolUse { .. }
            | AgentEvent::StatusChange(_)
            | AgentEvent::UsageUpdate { .. } => {}
            _ => {}
        }
    }

    let parsed = extract_first_json_object(&combined_output)
        .ok_or_else(|| "provider output did not contain parseable JSON object".to_string())?;
    parse_provider_draft(parsed, text)
}

pub async fn create_notification(
    input: NotificationInput,
    emitter: &Arc<dyn EventEmitter>,
    state: &AppState,
) -> Result<NotificationView, String> {
    let (db, project_id) = state
        .with_project("create_notification", |ctx| {
            (ctx.db.clone(), ctx.project_id)
        })
        .await?;
    let secret_values = load_redaction_secrets(&db, project_id).await;
    create_notification_row(
        &db,
        emitter,
        project_id,
        input
            .task_id
            .as_deref()
            .and_then(|v| Uuid::parse_str(v).ok()),
        input
            .session_id
            .as_deref()
            .and_then(|v| Uuid::parse_str(v).ok()),
        &input.title,
        &input.body,
        input.level.as_deref(),
        "manual",
        &secret_values,
    )
    .await
}

pub async fn list_notifications(
    input: Option<NotificationListInput>,
    state: &AppState,
) -> Result<Vec<NotificationView>, String> {
    let (db, project_id) = state
        .with_project("list_notifications", |ctx| (ctx.db.clone(), ctx.project_id))
        .await?;
    let unread_only = input.map(|v| v.unread_only).unwrap_or(false);
    let rows = db
        .list_notifications(&project_id.to_string(), unread_only)
        .await
        .map_err(|e| e.to_string())?;
    Ok(rows
        .into_iter()
        .map(|row| NotificationView {
            id: row.id,
            task_id: row.task_id,
            session_id: row.session_id,
            title: row.title,
            body: row.body,
            level: row.level,
            unread: row.unread,
            created_at: row.created_at,
        })
        .collect())
}

pub async fn mark_notification_read(
    notification_id: String,
    emitter: &Arc<dyn EventEmitter>,
    state: &AppState,
) -> Result<(), String> {
    let (db, project_id) = state
        .with_project("mark_notification_read", |ctx| {
            (ctx.db.clone(), ctx.project_id)
        })
        .await?;
    db.mark_notification_read(&notification_id)
        .await
        .map_err(|e| e.to_string())?;
    append_event(
        &db,
        project_id,
        None,
        None,
        "system",
        "NotificationMarkedRead",
        json!({"notification_id": notification_id}),
    )
    .await;
    emitter.emit(
        "notification_updated",
        json!({"id": notification_id, "unread": false}),
    );
    Ok(())
}

pub async fn clear_notifications(
    emitter: &Arc<dyn EventEmitter>,
    state: &AppState,
) -> Result<(), String> {
    let (db, project_id) = state
        .with_project("clear_notifications", |ctx| {
            (ctx.db.clone(), ctx.project_id)
        })
        .await?;
    db.clear_notifications(&project_id.to_string())
        .await
        .map_err(|e| e.to_string())?;
    append_event(
        &db,
        project_id,
        None,
        None,
        "system",
        "NotificationsCleared",
        json!({}),
    )
    .await;
    emitter.emit(
        "notification_cleared",
        json!({"project_id": project_id.to_string()}),
    );
    Ok(())
}

pub async fn list_registered_commands() -> Result<Vec<RegisteredCommand>, String> {
    Ok(default_registry().list())
}

pub async fn execute_registered_command(
    input: ExecuteRegisteredCommandInput,
    _emitter: &Arc<dyn EventEmitter>,
    state: &AppState,
) -> Result<serde_json::Value, String> {
    if !default_registry().contains(&input.id) {
        return Err(format!("unknown command id: {}", input.id));
    }

    let command_id = input.id.clone();
    let mut params = serde_json::Map::new();
    for (key, value) in &input.args {
        params.insert(key.clone(), json_value_from_arg(value));
    }

    if input.id == "task.new" {
        params
            .entry("scope".to_string())
            .or_insert_with(|| json!([]));
        params
            .entry("acceptance_criteria".to_string())
            .or_insert_with(|| json!(["manual review"]));
        params
            .entry("constraints".to_string())
            .or_insert_with(|| json!([]));
        params
            .entry("dependencies".to_string())
            .or_insert_with(|| json!([]));
    }

    let result = match input.id.as_str() {
        "session.reattach_active" => {
            let session_id = required_arg(&input.args, "active_session_id")?;
            reattach_session(session_id.clone(), state).await?;
            Ok(json!({ "session_id": session_id }))
        }
        "session.restart_active" => {
            let session_id = required_arg(&input.args, "active_session_id")?;
            let active_pane_id = required_arg(&input.args, "active_pane_id")?;
            let new_session_id = restart_session(session_id.clone(), state).await?;
            if let Some(active) = list_panes(state)
                .await?
                .into_iter()
                .find(|pane| pane.id == active_pane_id)
            {
                let _ = upsert_pane(
                    PaneInput {
                        id: Some(active.id.clone()),
                        session_id: Some(new_session_id.clone()),
                        r#type: active.r#type,
                        position: active.position,
                        label: active.label,
                        metadata_json: active.metadata_json,
                    },
                    state,
                )
                .await?;
            }
            Ok(json!({
                "old_session_id": session_id,
                "new_session_id": new_session_id
            }))
        }
        "pane.split_horizontal" | "pane.split_vertical" => {
            let suffix = if input.id.ends_with("horizontal") {
                ":h"
            } else {
                ":v"
            };
            let active_pane_id = optional_arg(&input.args, "active_pane_id");
            let panes = list_panes(state).await?;
            let active = active_pane_id
                .as_ref()
                .and_then(|id| panes.iter().find(|pane| &pane.id == id))
                .cloned()
                .or_else(|| panes.first().cloned())
                .ok_or_else(|| "no panes found".to_string())?;
            let new_pane = upsert_pane(
                PaneInput {
                    id: None,
                    session_id: active.session_id,
                    r#type: active.r#type,
                    position: format!("{}{}", active.id, suffix),
                    label: format!("{} Copy", active.label),
                    metadata_json: active.metadata_json,
                },
                state,
            )
            .await?;
            Ok(json!({ "pane_id": new_pane.id }))
        }
        "pane.close" => {
            let active_pane_id = required_arg(&input.args, "active_pane_id")?;
            let panes = list_panes(state).await?;
            let active = panes
                .into_iter()
                .find(|pane| pane.id == active_pane_id)
                .ok_or_else(|| format!("pane not found: {active_pane_id}"))?;
            remove_pane(active.id.clone(), state).await?;
            Ok(json!({ "closed": true, "pane_id": active.id }))
        }
        "pane.open_review"
        | "pane.open_notifications"
        | "pane.open_merge_queue"
        | "pane.open_replay"
        | "pane.open_daily_brief"
        | "pane.open_search"
        | "pane.open_diff"
        | "pane.open_file_browser"
        | "pane.open_rules_manager"
        | "pane.open_settings" => {
            let active_pane_id = optional_arg(&input.args, "active_pane_id");
            let position = active_pane_id
                .map(|id| format!("after:{id}"))
                .unwrap_or_else(|| "after:root".to_string());
            let (pane_type, label) = match input.id.as_str() {
                "pane.open_review" => ("review", "Review"),
                "pane.open_notifications" => ("notifications", "Notifications"),
                "pane.open_merge_queue" => ("merge_queue", "Merge Queue"),
                "pane.open_replay" => ("replay", "Replay"),
                "pane.open_daily_brief" => ("daily_brief", "Daily Brief"),
                "pane.open_search" => ("search", "Search"),
                "pane.open_diff" => ("diff", "Diff"),
                "pane.open_file_browser" => ("file_browser", "Files"),
                "pane.open_rules_manager" => ("rules", "Rules"),
                "pane.open_settings" => ("settings", "Settings"),
                _ => return Err(format!("unhandled pane method: {}", input.id)),
            };
            let pane = upsert_pane(
                PaneInput {
                    id: None,
                    session_id: None,
                    r#type: pane_type.to_string(),
                    position,
                    label: label.to_string(),
                    metadata_json: None,
                },
                state,
            )
            .await?;
            Ok(json!({ "pane_id": pane.id }))
        }
        "task.delete_ready" => {
            let ready = list_tasks(state)
                .await?
                .into_iter()
                .find(|task| task.status == "Ready");
            let Some(ready) = ready else {
                return Ok(json!({ "deleted": false }));
            };
            delete_task(ready.id.clone(), &state.emitter, state).await?;
            Ok(json!({ "deleted": true, "task_id": ready.id }))
        }
        "review.approve_task" => crate::control::route_method(
            state,
            "review.approve",
            &serde_json::Value::Object(params),
        )
        .await
        .map_err(|(_code, msg)| msg),
        "review.reject_task" => {
            crate::control::route_method(state, "review.reject", &serde_json::Value::Object(params))
                .await
                .map_err(|(_code, msg)| msg)
        }
        "merge.execute_task" => crate::control::route_method(
            state,
            "merge.queue.execute",
            &serde_json::Value::Object(params),
        )
        .await
        .map_err(|(_code, msg)| msg),
        _ => crate::control::route_method(state, &input.id, &serde_json::Value::Object(params))
            .await
            .map_err(|(_code, msg)| msg),
    };

    if result.is_ok() {
        if let Ok((db, project_id, global_config)) = state
            .with_project("execute_registered_command.telemetry", |ctx| {
                (ctx.db.clone(), ctx.project_id, ctx.global_config.clone())
            })
            .await
        {
            append_telemetry_event(
                &db,
                project_id,
                &global_config,
                "command.execute",
                json!({"id": command_id}),
            )
            .await;
        }
    }
    result
}

pub async fn pool_state(state: &AppState) -> Result<(usize, usize, usize, usize), String> {
    let pool = state
        .with_project("pool_state", |ctx| Arc::clone(&ctx.pool))
        .await?;
    Ok(pool.state().await)
}

pub async fn check_action_risk(
    action_kind: pnevma_core::ActionKind,
) -> Result<pnevma_core::ActionRiskInfo, String> {
    Ok(action_kind.risk_info())
}

pub(crate) async fn automation_status_from_snapshot(
    snapshot: crate::automation::coordinator::AutomationSnapshot,
    db: &pnevma_db::Db,
    project_id: &uuid::Uuid,
) -> AutomationStatusView {
    let recent_runs = db
        .list_automation_runs(&project_id.to_string(), 20)
        .await
        .unwrap_or_default()
        .into_iter()
        .map(|r| AutomationRunView {
            id: r.id,
            task_id: r.task_id,
            run_id: r.run_id,
            origin: r.origin,
            provider: r.provider,
            model: r.model,
            status: r.status,
            attempt: r.attempt,
            started_at: r.started_at,
            finished_at: r.finished_at,
            duration_seconds: r.duration_seconds,
            tokens_in: r.tokens_in,
            tokens_out: r.tokens_out,
            cost_usd: r.cost_usd,
            summary: r.summary,
        })
        .collect();

    AutomationStatusView {
        enabled: snapshot.enabled,
        config_source: snapshot.config_source,
        poll_interval_seconds: snapshot.poll_interval_seconds,
        max_concurrent: snapshot.max_concurrent,
        active_runs: snapshot.active_runs,
        queued_tasks: snapshot.queued_tasks,
        retry_queue_size: snapshot.retry_queue_size,
        last_tick_at: snapshot.last_tick_at,
        total_dispatched: snapshot.total_dispatched,
        total_completed: snapshot.total_completed,
        total_failed: snapshot.total_failed,
        total_retried: snapshot.total_retried,
        recent_runs,
    }
}

fn default_automation_snapshot(
    max_concurrent: usize,
) -> crate::automation::coordinator::AutomationSnapshot {
    crate::automation::coordinator::AutomationSnapshot {
        enabled: false,
        config_source: "none".to_string(),
        poll_interval_seconds: 0,
        max_concurrent,
        active_runs: 0,
        queued_tasks: 0,
        claimed_task_ids: Vec::new(),
        running_task_ids: Vec::new(),
        retry_queue_size: 0,
        last_tick_at: None,
        total_dispatched: 0,
        total_completed: 0,
        total_failed: 0,
        total_retried: 0,
    }
}

pub async fn automation_status(state: &AppState) -> Result<AutomationStatusView, String> {
    let (db, project_id, coordinator) = state
        .with_project("automation_status", |ctx| {
            (ctx.db.clone(), ctx.project_id, ctx.coordinator.clone())
        })
        .await
        .map_err(|_| "no project open".to_string())?;

    let snapshot = if let Some(ref coord) = coordinator {
        coord.snapshot().await
    } else {
        default_automation_snapshot(0)
    };

    Ok(automation_status_from_snapshot(snapshot, &db, &project_id).await)
}
pub async fn resolve_pr_url(url: &str, state: &AppState) -> Result<PRResolveView, String> {
    let project_path = state
        .with_project("resolve_pr_url", |ctx| ctx.project_path.clone())
        .await
        .map_err(|_| "no open project".to_string())?;
    let mut command = crate::github_cli::command();
    command
        .args([
            "pr",
            "view",
            url,
            "--json",
            "number,title,headRefName,baseRefName,url",
        ])
        .current_dir(&project_path);
    let output = command.output().await.map_err(|e| e.to_string())?;
    if !output.status.success() {
        return Err(String::from_utf8_lossy(&output.stderr).to_string());
    }
    let val: serde_json::Value =
        serde_json::from_slice(&output.stdout).map_err(|e| e.to_string())?;
    Ok(PRResolveView {
        number: val.get("number").and_then(|v| v.as_u64()).unwrap_or(0),
        title: val
            .get("title")
            .and_then(|v| v.as_str())
            .unwrap_or("")
            .to_string(),
        head_ref: val
            .get("headRefName")
            .and_then(|v| v.as_str())
            .unwrap_or("")
            .to_string(),
        base_ref: val
            .get("baseRefName")
            .and_then(|v| v.as_str())
            .unwrap_or("")
            .to_string(),
        url: val
            .get("url")
            .and_then(|v| v.as_str())
            .unwrap_or("")
            .to_string(),
    })
}

pub async fn resolve_issue_url(url: &str, state: &AppState) -> Result<IssueResolveView, String> {
    let project_path = state
        .with_project("resolve_issue_url", |ctx| ctx.project_path.clone())
        .await
        .map_err(|_| "no open project".to_string())?;
    let mut command = crate::github_cli::command();
    command
        .args(["issue", "view", url, "--json", "number,title,url"])
        .current_dir(&project_path);
    let output = command.output().await.map_err(|e| e.to_string())?;
    if !output.status.success() {
        return Err(String::from_utf8_lossy(&output.stderr).to_string());
    }
    let val: serde_json::Value =
        serde_json::from_slice(&output.stdout).map_err(|e| e.to_string())?;
    Ok(IssueResolveView {
        number: val.get("number").and_then(|v| v.as_u64()).unwrap_or(0),
        title: val
            .get("title")
            .and_then(|v| v.as_str())
            .unwrap_or("")
            .to_string(),
        url: val
            .get("url")
            .and_then(|v| v.as_str())
            .unwrap_or("")
            .to_string(),
    })
}

pub async fn list_project_files_flat(state: &AppState) -> Result<Vec<String>, String> {
    let project_path = state
        .with_project("list_project_files_flat", |ctx| ctx.project_path.clone())
        .await
        .map_err(|_| "no open project".to_string())?;
    let output = TokioCommand::new("git")
        .args(["ls-files"])
        .current_dir(&project_path)
        .output()
        .await
        .map_err(|e| e.to_string())?;
    if !output.status.success() {
        return Err("git ls-files failed".to_string());
    }
    let files: Vec<String> = String::from_utf8_lossy(&output.stdout)
        .lines()
        .take(5000)
        .map(String::from)
        .collect();
    Ok(files)
}

pub async fn list_branches(state: &AppState) -> Result<Vec<String>, String> {
    let project_path = state
        .with_project("list_branches", |ctx| ctx.project_path.clone())
        .await
        .map_err(|_| "no open project".to_string())?;
    let output = TokioCommand::new("git")
        .args([
            "branch",
            "--sort=-committerdate",
            "--format=%(refname:short)",
        ])
        .current_dir(&project_path)
        .output()
        .await
        .map_err(|e| e.to_string())?;
    if !output.status.success() {
        return Err("git branch failed".to_string());
    }
    let branches: Vec<String> = String::from_utf8_lossy(&output.stdout)
        .lines()
        .map(|line| line.trim().to_string())
        .filter(|b| !b.is_empty())
        .collect();
    Ok(branches)
}

pub async fn changes_summary(state: &AppState) -> Result<Vec<FileChangeView>, String> {
    let project_path = state
        .with_project("changes_summary", |ctx| ctx.project_path.clone())
        .await
        .map_err(|_| "no open project".to_string())?;
    let output = TokioCommand::new("git")
        .args(["diff", "--numstat"])
        .current_dir(&project_path)
        .output()
        .await
        .map_err(|e| e.to_string())?;
    if !output.status.success() {
        return Err("git diff --numstat failed".to_string());
    }
    let changes: Vec<FileChangeView> = String::from_utf8_lossy(&output.stdout)
        .lines()
        .filter_map(|line| {
            let parts: Vec<&str> = line.split('\t').collect();
            if parts.len() >= 3 {
                Some(FileChangeView {
                    additions: parts[0].parse().unwrap_or(0),
                    deletions: parts[1].parse().unwrap_or(0),
                    path: parts[2].to_string(),
                })
            } else {
                None
            }
        })
        .collect();
    Ok(changes)
}

pub async fn check_summary(state: &AppState) -> Result<CheckSummaryView, String> {
    let project_path = state
        .with_project("check_summary", |ctx| ctx.project_path.clone())
        .await
        .map_err(|_| "no open project".to_string())?;
    let output = tokio::time::timeout(std::time::Duration::from_millis(5000), {
        let mut command = crate::github_cli::command();
        command
            .args(["pr", "checks", "--json", "name,state,conclusion"])
            .current_dir(&project_path);
        command.output()
    })
    .await
    .map_err(|_| "timeout".to_string())?
    .map_err(|e| e.to_string())?;
    if !output.status.success() {
        return Ok(CheckSummaryView {
            total: 0,
            passed: 0,
            failed: 0,
            running: 0,
        });
    }
    let checks: Vec<serde_json::Value> = serde_json::from_slice(&output.stdout).unwrap_or_default();
    let total = checks.len();
    let passed = checks
        .iter()
        .filter(|c| c.get("conclusion").and_then(|v| v.as_str()) == Some("SUCCESS"))
        .count();
    let failed = checks
        .iter()
        .filter(|c| c.get("conclusion").and_then(|v| v.as_str()) == Some("FAILURE"))
        .count();
    let running = checks
        .iter()
        .filter(|c| c.get("state").and_then(|v| v.as_str()) == Some("IN_PROGRESS"))
        .count();
    Ok(CheckSummaryView {
        total,
        passed,
        failed,
        running,
    })
}

pub async fn merge_queue_readiness(state: &AppState) -> Result<MergeReadinessView, String> {
    let project_path = state
        .with_project("merge_queue_readiness", |ctx| ctx.project_path.clone())
        .await
        .map_err(|_| "no open project".to_string())?;
    let output = tokio::time::timeout(std::time::Duration::from_millis(5000), {
        let mut command = crate::github_cli::command();
        command
            .args([
                "pr",
                "view",
                "--json",
                "mergeStateStatus,statusCheckRollup,reviewDecision",
            ])
            .current_dir(&project_path);
        command.output()
    })
    .await
    .map_err(|_| "timeout".to_string())?
    .map_err(|e| e.to_string())?;
    if !output.status.success() {
        return Ok(MergeReadinessView {
            is_ready: false,
            blockers: vec!["No PR found".to_string()],
            required_checks: vec![],
        });
    }
    let val: serde_json::Value =
        serde_json::from_slice(&output.stdout).map_err(|e| e.to_string())?;
    let mut blockers = Vec::new();
    let merge_state = val
        .get("mergeStateStatus")
        .and_then(|v| v.as_str())
        .unwrap_or("UNKNOWN");
    if merge_state != "CLEAN" {
        blockers.push(format!("Merge state: {}", merge_state));
    }
    let review = val
        .get("reviewDecision")
        .and_then(|v| v.as_str())
        .unwrap_or("NONE");
    if review != "APPROVED" {
        blockers.push(format!("Review: {}", review));
    }
    let required_checks: Vec<String> = val
        .get("statusCheckRollup")
        .and_then(|v| v.as_array())
        .map(|arr| {
            arr.iter()
                .filter_map(|c| c.get("name").and_then(|n| n.as_str()).map(String::from))
                .collect()
        })
        .unwrap_or_default();
    Ok(MergeReadinessView {
        is_ready: blockers.is_empty(),
        blockers,
        required_checks,
    })
}

fn git_failure_message(output: &Output, fallback: &str) -> String {
    let stderr = String::from_utf8_lossy(&output.stderr).trim().to_string();
    if !stderr.is_empty() {
        return stderr;
    }

    let stdout = String::from_utf8_lossy(&output.stdout).trim().to_string();
    if !stdout.is_empty() {
        return stdout;
    }

    fallback.to_string()
}

async fn active_project_path(state: &AppState, operation: &'static str) -> Result<PathBuf, String> {
    state
        .with_project(operation, |ctx| ctx.project_path.clone())
        .await
        .map_err(|_| "no open project".to_string())
}

async fn stage_all_changes(project_path: &Path) -> Result<(), String> {
    let add_out = TokioCommand::new("git")
        .args(["add", "-A"])
        .current_dir(project_path)
        .output()
        .await
        .map_err(|e| e.to_string())?;
    if add_out.status.success() {
        Ok(())
    } else {
        Err(git_failure_message(&add_out, "git add failed"))
    }
}

async fn read_head_sha(project_path: &Path) -> Option<String> {
    TokioCommand::new("git")
        .args(["rev-parse", "HEAD"])
        .current_dir(project_path)
        .output()
        .await
        .ok()
        .filter(|out| out.status.success())
        .and_then(|out| String::from_utf8(out.stdout).ok())
        .map(|sha| sha.trim().to_string())
}

pub async fn commit(message: &str, state: &AppState) -> Result<GitCommitView, String> {
    let project_path = active_project_path(state, "commit").await?;
    stage_all_changes(&project_path).await?;

    let commit_out = TokioCommand::new("git")
        .args(["commit", "-m", message])
        .current_dir(&project_path)
        .output()
        .await
        .map_err(|e| e.to_string())?;
    if !commit_out.status.success() {
        return Ok(GitCommitView {
            success: false,
            commit_sha: None,
            error_message: Some(git_failure_message(&commit_out, "git commit failed")),
        });
    }

    Ok(GitCommitView {
        success: true,
        commit_sha: read_head_sha(&project_path).await,
        error_message: None,
    })
}

pub async fn push(state: &AppState) -> Result<GitPushView, String> {
    let project_path = active_project_path(state, "push").await?;
    let push_out = TokioCommand::new("git")
        .args(["push"])
        .current_dir(&project_path)
        .output()
        .await
        .map_err(|e| e.to_string())?;

    Ok(GitPushView {
        success: push_out.status.success(),
        error_message: (!push_out.status.success())
            .then(|| git_failure_message(&push_out, "git push failed")),
    })
}

pub async fn commit_and_push(message: &str, state: &AppState) -> Result<CommitAndPushView, String> {
    let commit_result = commit(message, state).await?;
    if !commit_result.success {
        return Ok(CommitAndPushView {
            success: false,
            commit_sha: None,
            push_error: commit_result.error_message,
        });
    }

    let push_result = push(state).await?;
    Ok(CommitAndPushView {
        success: push_result.success,
        commit_sha: commit_result.commit_sha,
        push_error: push_result.error_message,
    })
}

pub async fn list_ports(_state: &AppState) -> Result<Vec<PortEntryView>, String> {
    let output = TokioCommand::new("lsof")
        .args(["-i", "-P", "-n", "-sTCP:LISTEN"])
        .output()
        .await
        .map_err(|e| e.to_string())?;
    if !output.status.success() {
        return Ok(vec![]);
    }
    let now = Utc::now().to_rfc3339();
    let ports: Vec<PortEntryView> = String::from_utf8_lossy(&output.stdout)
        .lines()
        .skip(1) // skip header
        .filter_map(|line| {
            let parts: Vec<&str> = line.split_whitespace().collect();
            if parts.len() < 9 {
                return None;
            }
            let process_name = parts[0].to_string();
            let pid: u32 = parts[1].parse().ok()?;
            let addr = parts[8];
            let port: u16 = addr.rsplit(':').next()?.parse().ok()?;
            let label = match port {
                3000 => Some("React".to_string()),
                5173 => Some("Vite".to_string()),
                8080 => Some("HTTP".to_string()),
                4200 => Some("Angular".to_string()),
                8000 => Some("Python".to_string()),
                4000 => Some("Phoenix".to_string()),
                _ => None,
            };
            Some(PortEntryView {
                port,
                pid,
                process_name,
                workspace_name: None,
                session_id: None,
                label,
                protocol: "TCP".to_string(),
                detected_at: now.clone(),
            })
        })
        .collect();
    Ok(ports)
}

// ── GitHub issues via `gh` CLI ─────────────────────────────────────────────

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct GitHubIssueView {
    pub number: i64,
    pub title: String,
    pub state: String,
    pub labels: Vec<String>,
    pub author: String,
}

#[derive(Debug, Deserialize)]
struct GhIssueJson {
    number: i64,
    title: String,
    state: String,
    labels: Vec<GhLabelJson>,
    author: GhAuthorJson,
}

#[derive(Debug, Deserialize)]
struct GhLabelJson {
    name: String,
}

#[derive(Debug, Deserialize)]
struct GhAuthorJson {
    login: String,
}

pub async fn list_github_issues(state: &AppState) -> Result<Vec<GitHubIssueView>, String> {
    let project_path = state
        .with_project("list_github_issues", |ctx| ctx.project_path.clone())
        .await
        .map_err(|_| "no open project".to_string())?;
    let mut command = crate::github_cli::command();
    command
        .args([
            "issue",
            "list",
            "--json",
            "number,title,state,labels,author",
            "--limit",
            "50",
        ])
        .current_dir(&project_path);
    let output = command
        .output()
        .await
        .map_err(|e| format!("failed to run gh: {e}"))?;
    if !output.status.success() {
        let stderr = String::from_utf8_lossy(&output.stderr);
        return Err(format!("gh issue list failed: {stderr}"));
    }
    let items: Vec<GhIssueJson> =
        serde_json::from_slice(&output.stdout).map_err(|e| format!("parse error: {e}"))?;
    Ok(items
        .into_iter()
        .map(|i| GitHubIssueView {
            number: i.number,
            title: i.title,
            state: i.state,
            labels: i.labels.into_iter().map(|l| l.name).collect(),
            author: i.author.login,
        })
        .collect())
}
