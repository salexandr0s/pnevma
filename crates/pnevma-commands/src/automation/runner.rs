use crate::automation::DispatchOrigin;
use crate::control::resolve_control_plane_settings;
// Helpers defined in commands/mod.rs (pub(crate) — accessible via full path within the crate)
use crate::commands::{
    append_event, append_telemetry_event, build_secrets_list, check_loop_trigger,
    check_workflow_completion, cleanup_task_worktree, create_notification_row,
    current_redaction_secrets, emit_enriched_task_event, emit_task_updated, generate_review_pack,
    is_terminal_task_status, load_active_scope_texts, load_recent_knowledge_summaries, load_texts,
    load_workflow_hooks, normalize_redaction_secrets, notify_task_status_transition, osc_level,
    osc_title, parse_osc_attention, parse_status, prepare_task_branch_for_review,
    redact_json_value, redact_text, refresh_dependency_states_after_completion_without_dispatch,
    resolve_secret_env, run_acceptance_checks_for_task, session_row_to_event_payload,
    slugify_with_fallback, status_to_str, task_contract_to_row, task_row_to_contract,
    StreamRedactor,
};
use pnevma_git::{parse_hook_defs, run_hooks, GitService, HookPhase};
// Helpers in commands/tasks.rs (pub(crate))
use crate::commands::tasks::ensure_scope_rows_from_config;
use crate::event_emitter::EventEmitter;
use crate::state::AppState;
use chrono::Utc;
use pnevma_agents::{
    classify_failure, compute_backoff, prepare_claude_team_environment, AgentAdapter, AgentConfig,
    AgentEvent, AgentHandle, AgentTeamConfig, ContinuationState, DispatchPermit, FailureClass,
    QueuedDispatch, RetryContext, RetryPolicy, StallDetector, StallDetectorConfig, TaskPayload,
};
use pnevma_context::{
    ContextCompileInput, ContextCompileMode, ContextCompiler, ContextCompilerConfig,
    DiscoveryConfig, FileDiscovery,
};
use pnevma_core::{ProjectConfig, TaskContract, TaskStatus};
use pnevma_db::{
    AutomationRunRow, ContextRuleUsageRow, CostRow, Db, PaneRow, SessionRow, TaskRow, WorktreeRow,
};
use pnevma_session::SessionSupervisor;
use serde_json::json;
use std::path::{Path, PathBuf};
use std::sync::Arc;
use thiserror::Error;
use tokio::sync::RwLock;
use tokio::task::JoinHandle;
use uuid::Uuid;

#[derive(Debug, Error)]
pub enum RunnerError {
    #[error("no open project")]
    NoProject,
    #[error("task not found: {0}")]
    TaskNotFound(String),
    #[error("task must be Ready before dispatch (current: {0})")]
    InvalidStatus(String),
    #[error("agent profile override '{0}' not found")]
    ProfileNotFound(String),
    #[error("no available agent adapters found")]
    NoAdapter,
    #[error("queued:{0}")]
    Queued(usize),
    #[error("dispatch failed: {0}")]
    DispatchFailed(String),
    #[error("{0}")]
    Internal(String),
}

impl From<RunnerError> for String {
    fn from(e: RunnerError) -> String {
        e.to_string()
    }
}

/// All resolved state needed to launch an agent run.
pub struct PreparedRun {
    pub project_id: Uuid,
    pub db: Db,
    pub sessions: SessionSupervisor,
    pub config: ProjectConfig,
    pub global_config: pnevma_core::GlobalConfig,
    pub provider: String,
    pub adapter: Arc<dyn pnevma_agents::AgentAdapter>,
    /// Shared permit holder — the event loop takes the permit from here when it completes.
    pub permit_holder: Arc<std::sync::Mutex<Option<DispatchPermit>>>,
    pub working_dir: String,
    /// Root of the project repository (where WORKFLOW.md lives).
    pub project_path: PathBuf,
    pub secret_env: Vec<(String, String)>,
    pub secret_values: Vec<String>,
    pub rules: Vec<String>,
    pub context_path: PathBuf,
    pub timeout_minutes: u64,
    pub model: Option<String>,
    pub auto_approve: bool,
    pub allow_npx: bool,
    pub npx_allowed_packages: Vec<String>,
    pub allow_full_sandbox_access: bool,
    pub task: TaskContract,
    pub task_row: TaskRow,
    pub origin: DispatchOrigin,
    pub emitter: Arc<dyn EventEmitter>,
    pub git: Arc<GitService>,
    pub redaction_secrets: Arc<RwLock<Vec<String>>>,
    pub pool: Arc<pnevma_agents::DispatchPool>,
    pub target_branch: String,
    pub global_db: Option<pnevma_db::GlobalDb>,
    /// Tracker adapter for dynamic tool calls, present when the task has an external source
    /// and the project has a tracker configured.
    pub tracker: Option<Arc<dyn pnevma_tracker::TrackerAdapter>>,
    /// Holder for the DB automation_run ID, written by coordinator after create_automation_run.
    pub db_run_id_holder: Arc<std::sync::Mutex<Option<String>>>,
    /// Cached WORKFLOW.md hooks (avoids redundant disk reads).
    pub hooks: pnevma_core::WorkflowHooks,
    /// Shared pending browser tool calls (passed from AppState).
    pub browser_tool_pending: crate::commands::browser_tools::BrowserToolPending,
    /// Shared Pnevma-native agent team store.
    pub agent_teams: Arc<RwLock<crate::agent_teams::AgentTeamStore>>,
}

/// A running agent handle plus its background event-loop task.
pub struct RunningAgent {
    pub task_id: Uuid,
    pub session_id: Uuid,
    pub handle: AgentHandle,
    pub event_task: JoinHandle<()>,
    pub origin: DispatchOrigin,
    pub permit_holder: Arc<std::sync::Mutex<Option<DispatchPermit>>>,
    pub db_run_id_holder: Arc<std::sync::Mutex<Option<String>>>,
}

pub struct AgentRunOutcome {
    pub task_id: Uuid,
    pub failed: bool,
    pub last_summary: Option<String>,
    pub final_status: TaskStatus,
}

fn dispatch_origin_str(origin: DispatchOrigin) -> &'static str {
    match origin {
        DispatchOrigin::Manual => "manual",
        DispatchOrigin::AutoDispatch => "auto_dispatch",
        DispatchOrigin::Workflow => "workflow",
    }
}

pub async fn create_automation_run_record(
    prepared: &PreparedRun,
    run_id: Uuid,
    attempt: u32,
) -> Result<String, RunnerError> {
    let now = Utc::now();
    let db_row_id = Uuid::new_v4().to_string();
    let run_row = AutomationRunRow {
        id: db_row_id.clone(),
        project_id: prepared.project_id.to_string(),
        task_id: prepared.task.id.to_string(),
        run_id: run_id.to_string(),
        origin: dispatch_origin_str(prepared.origin).to_string(),
        provider: prepared.provider.clone(),
        model: prepared.model.clone(),
        status: "running".to_string(),
        attempt: attempt as i64,
        started_at: now,
        finished_at: None,
        duration_seconds: None,
        tokens_in: 0,
        tokens_out: 0,
        cost_usd: 0.0,
        summary: None,
        error_message: None,
        created_at: now,
    };
    prepared
        .db
        .create_automation_run(&run_row)
        .await
        .map_err(|e| RunnerError::Internal(e.to_string()))?;
    if let Ok(mut guard) = prepared.db_run_id_holder.lock() {
        guard.replace(db_row_id.clone());
    }
    Ok(db_row_id)
}

async fn finalize_automation_run_record(
    db: &Db,
    db_run_id_holder: &Arc<std::sync::Mutex<Option<String>>>,
    update: AutomationRunFinalization<'_>,
) {
    let Some(db_run_id) = db_run_id_holder.lock().ok().and_then(|guard| guard.clone()) else {
        return;
    };

    let finished_at = Utc::now();
    let duration_seconds = db
        .get_automation_run(&db_run_id)
        .await
        .ok()
        .flatten()
        .map(|row| {
            finished_at
                .signed_duration_since(row.started_at)
                .num_milliseconds() as f64
                / 1000.0
        });

    let _ = db
        .update_automation_run_usage(
            &db_run_id,
            update.tokens_in,
            update.tokens_out,
            update.cost_usd,
            update.summary,
        )
        .await;
    let _ = db
        .update_automation_run_status(
            &db_run_id,
            update.status,
            Some(finished_at),
            duration_seconds,
            update.error_message,
        )
        .await;
}

struct AutomationRunFinalization<'a> {
    status: &'a str,
    tokens_in: i64,
    tokens_out: i64,
    cost_usd: f64,
    summary: Option<&'a str>,
    error_message: Option<&'a str>,
}

async fn git_stdout(dir: &Path, args: &[&str]) -> Result<String, String> {
    let out = tokio::process::Command::new("git")
        .args(args)
        .current_dir(dir)
        .output()
        .await
        .map_err(|e| e.to_string())?;
    if !out.status.success() {
        return Err(String::from_utf8_lossy(&out.stderr).trim().to_string());
    }
    Ok(String::from_utf8_lossy(&out.stdout).to_string())
}

async fn branch_ahead_count(worktree_path: &Path, target_branch: &str) -> Result<u64, String> {
    git_stdout(
        worktree_path,
        &["rev-list", "--count", &format!("{target_branch}..HEAD")],
    )
    .await?
    .trim()
    .parse::<u64>()
    .map_err(|e| format!("parse ahead count: {e}"))
}

async fn prepare_merge_ready_worktree(
    worktree_path: &Path,
    target_branch: &str,
    task: &TaskContract,
) -> Result<Option<crate::commands::TaskCommitResult>, String> {
    let commit_result = if task.branch.is_some() {
        Some(
            prepare_task_branch_for_review(worktree_path, task.id, &task.title, target_branch)
                .await?,
        )
    } else {
        None
    };

    let has_uncommitted = !git_stdout(worktree_path, &["status", "--porcelain"])
        .await?
        .trim()
        .is_empty();
    if has_uncommitted {
        return Err("agent left uncommitted changes after sanitize/commit".to_string());
    }

    let ahead_count = branch_ahead_count(worktree_path, target_branch).await?;
    if ahead_count == 0 {
        return Err("agent produced no mergeable repository changes".to_string());
    }
    Ok(commit_result)
}

async fn upsert_agent_session_status(
    db: &Db,
    project_id: Uuid,
    session_id: Uuid,
    status: &str,
) -> Result<(), String> {
    let existing = db
        .list_sessions(&project_id.to_string())
        .await
        .map_err(|e| e.to_string())?
        .into_iter()
        .find(|session| session.id == session_id.to_string());

    let Some(mut row) = existing else {
        return Ok(());
    };

    row.status = status.to_string();
    row.last_heartbeat = Utc::now();
    db.upsert_session(&row).await.map_err(|e| e.to_string())
}

/// Phase 1 – resolve all context, acquire permit, create worktree, transition to InProgress.
pub async fn prepare(
    task_id: String,
    emitter: &Arc<dyn EventEmitter>,
    state: &AppState,
    origin: DispatchOrigin,
) -> Result<PreparedRun, RunnerError> {
    let (
        project_id,
        db,
        sessions,
        project_path,
        config,
        global_config,
        pool,
        adapters,
        git,
        redaction_secrets,
        tracker_coordinator,
    ) = {
        let current = state.current.lock().await;
        let ctx = current.as_ref().ok_or(RunnerError::NoProject)?;
        (
            ctx.project_id,
            ctx.db.clone(),
            ctx.sessions.clone(),
            ctx.project_path.clone(),
            ctx.config.clone(),
            ctx.global_config.clone(),
            ctx.pool.clone(),
            ctx.adapters.clone(),
            ctx.git.clone(),
            Arc::clone(&ctx.redaction_secrets),
            ctx.tracker.clone(),
        )
    };

    let global_db = state.global_db.clone();

    let task_id_uuid =
        Uuid::parse_str(&task_id).map_err(|e| RunnerError::Internal(e.to_string()))?;
    let row = db
        .get_task(&task_id)
        .await
        .map_err(|e| RunnerError::Internal(e.to_string()))?
        .ok_or_else(|| RunnerError::TaskNotFound(task_id.clone()))?;
    let mut task = task_row_to_contract(&row).map_err(|e| RunnerError::Internal(e.to_string()))?;

    if task.status != TaskStatus::Ready {
        return Err(RunnerError::InvalidStatus(
            status_to_str(&task.status).to_string(),
        ));
    }

    let queued = QueuedDispatch {
        task_id: task_id_uuid,
        priority: task.priority,
    };

    let permit = match pool.try_acquire(queued).await {
        pnevma_agents::TryAcquireResult::Acquired(permit) => permit,
        pnevma_agents::TryAcquireResult::Queued(position) => {
            emitter.emit(
                "task_queue_updated",
                json!({"task_id": task_id, "queued_position": position}),
            );
            return Err(RunnerError::Queued(position));
        }
        pnevma_agents::TryAcquireResult::QueueFull(position) => {
            return Err(RunnerError::DispatchFailed(format!(
                "dispatch queue full (capacity {position}), try again later"
            )));
        }
    };

    // Check for task-level agent profile override first, then fall back to defaults.
    let profile_override = if let Some(ref override_name) = row.agent_profile_override {
        let profile = db
            .get_agent_profile_by_name(&project_id.to_string(), override_name)
            .await
            .ok()
            .flatten();
        if profile.is_none() {
            return Err(RunnerError::ProfileNotFound(override_name.clone()));
        }
        profile
    } else {
        None
    };

    let preferred_provider = if let Some(ref profile) = profile_override {
        profile.provider.clone()
    } else {
        global_config
            .default_provider
            .clone()
            .unwrap_or_else(|| config.agents.default_provider.clone())
    };
    let provider = if adapters.get(&preferred_provider).is_some() {
        preferred_provider
    } else if adapters.get("claude-code").is_some() {
        "claude-code".to_string()
    } else {
        "codex".to_string()
    };

    let adapter = adapters.get(&provider).ok_or(RunnerError::NoAdapter)?;

    let execution_mode = row.execution_mode.as_deref().unwrap_or("worktree");
    let use_worktree = execution_mode != "main";

    // Load hooks once — used in after_create, before_run, and after_run phases.
    let cached_hooks = load_workflow_hooks(&project_path);

    let working_dir: String;
    if use_worktree {
        let slug = slugify_with_fallback(&task.title, "task");
        let lease = git
            .create_worktree(task_id_uuid, &config.branches.target, &slug)
            .await
            .map_err(|e| RunnerError::Internal(e.to_string()))?;
        let canonical_worktree = tokio::fs::canonicalize(&lease.path)
            .await
            .map_err(|e| RunnerError::Internal(format!("worktree path unavailable: {e}")))?;
        let canonical_worktree_str = canonical_worktree.to_string_lossy().to_string();
        let worktree_row = WorktreeRow {
            id: lease.id.to_string(),
            project_id: project_id.to_string(),
            task_id: task_id.clone(),
            path: canonical_worktree_str.clone(),
            branch: lease.branch.clone(),
            lease_status: "Active".to_string(),
            lease_started: lease.started_at,
            last_active: lease.last_active,
        };
        db.upsert_worktree(&worktree_row)
            .await
            .map_err(|e| RunnerError::Internal(e.to_string()))?;
        working_dir = canonical_worktree_str;
        task.branch = Some(lease.branch.clone());
        task.worktree = Some(worktree_row.id.clone());

        // AfterCreate hooks — fatal: abort dispatch on failure, clean up worktree
        if let Some(cmds) = &cached_hooks.after_create {
            let hook_defs = parse_hook_defs(HookPhase::AfterCreate, cmds);
            if !hook_defs.is_empty() {
                let secrets = current_redaction_secrets(&redaction_secrets).await;
                let wt_path = PathBuf::from(&working_dir);
                let branch = task.branch.clone().unwrap_or_default();
                if let Err(e) = run_hooks(
                    &hook_defs,
                    HookPhase::AfterCreate,
                    &wt_path,
                    &task_id,
                    &branch,
                    &secrets,
                )
                .await
                {
                    let _ = cleanup_task_worktree(
                        &db,
                        &git,
                        project_id,
                        task_id_uuid,
                        None,
                        Some(&project_path),
                    )
                    .await;
                    return Err(RunnerError::Internal(format!(
                        "after_create hook failed: {e}"
                    )));
                }
            }
        }
    } else {
        working_dir = project_path.to_string_lossy().to_string();
    }

    task.transition(TaskStatus::InProgress)
        .map_err(|e| RunnerError::Internal(e.to_string()))?;
    let task_row = task_contract_to_row(&task, &project_id.to_string())
        .map_err(|e| RunnerError::Internal(e.to_string()))?;
    db.update_task(&task_row)
        .await
        .map_err(|e| RunnerError::Internal(e.to_string()))?;
    emit_task_updated(&db, project_id, task.id).await;
    emit_enriched_task_event(emitter, &db, &task.id.to_string()).await;
    append_telemetry_event(
        &db,
        project_id,
        &global_config,
        "task.dispatch",
        json!({"task_id": task.id.to_string(), "provider": provider}),
    )
    .await;

    ensure_scope_rows_from_config(&db, project_id, &project_path, &config, "rule")
        .await
        .map_err(|e| RunnerError::Internal(e.to_string()))?;
    ensure_scope_rows_from_config(&db, project_id, &project_path, &config, "convention")
        .await
        .map_err(|e| RunnerError::Internal(e.to_string()))?;
    let mut rules = load_active_scope_texts(&db, project_id, &project_path, "rule")
        .await
        .map_err(|e| RunnerError::Internal(e.to_string()))?;
    if rules.is_empty() {
        rules = load_texts(&config.rules.paths, &project_path).await;
    }
    let mut conventions = load_active_scope_texts(&db, project_id, &project_path, "convention")
        .await
        .map_err(|e| RunnerError::Internal(e.to_string()))?;
    if conventions.is_empty() {
        conventions = load_texts(&config.conventions.paths, &project_path).await;
    }
    let token_budget = match provider.as_str() {
        "codex" => config
            .agents
            .codex
            .as_ref()
            .map(|c| c.token_budget)
            .unwrap_or(60_000),
        _ => config
            .agents
            .claude_code
            .as_ref()
            .map(|c| c.token_budget)
            .unwrap_or(80_000),
    };
    let (secret_env, keychain_secret_values) = resolve_secret_env(&db, project_id)
        .await
        .unwrap_or_else(|_| (Vec::new(), Vec::new()));
    let mut secret_values = build_secrets_list();
    secret_values.extend(keychain_secret_values);
    let secret_values = normalize_redaction_secrets(&secret_values);
    let compiler = ContextCompiler::new(
        ContextCompilerConfig {
            mode: ContextCompileMode::V2,
            token_budget,
        },
        secret_values.clone(),
    );
    let discovery = FileDiscovery::new(DiscoveryConfig::default(), secret_values.clone());
    let relevant_file_contents = discovery
        .discover(&task, &project_path, token_budget)
        .await
        .unwrap_or_default();
    let prior_task_summaries =
        load_recent_knowledge_summaries(&db, project_id, &project_path, 8).await;
    let ctx_result = compiler
        .compile(ContextCompileInput {
            task: task.clone(),
            project_brief: config.project.brief.clone(),
            architecture_notes: String::new(),
            conventions,
            rules: rules.clone(),
            relevant_file_contents,
            prior_task_summaries,
        })
        .map_err(|e| RunnerError::Internal(e.to_string()))?;
    let context_path = PathBuf::from(&working_dir)
        .join(".pnevma")
        .join("task-context.md");
    let available_secret_names = crate::commands::secrets::available_secret_names(&db, project_id)
        .await
        .unwrap_or_default();
    let secret_names_section = if available_secret_names.is_empty() {
        String::new()
    } else {
        format!(
            "\n\n## Available secret environment variables\n{}\n",
            available_secret_names
                .iter()
                .map(|name| format!("- {name}"))
                .collect::<Vec<_>>()
                .join("\n")
        )
    };
    let redacted_context_markdown = redact_text(
        &format!("{}{}", ctx_result.markdown, secret_names_section),
        &secret_values,
    );
    compiler
        .write_markdown(&redacted_context_markdown, &context_path)
        .map_err(|e| RunnerError::Internal(e.to_string()))?;
    let manifest_path = PathBuf::from(&working_dir)
        .join(".pnevma")
        .join("task-context.manifest.json");
    let redacted_manifest = redact_json_value(
        serde_json::to_value(&ctx_result.pack.manifest)
            .map_err(|e| RunnerError::Internal(e.to_string()))?,
        &secret_values,
    );
    tokio::fs::write(
        &manifest_path,
        serde_json::to_string_pretty(&redacted_manifest)
            .map_err(|e| RunnerError::Internal(e.to_string()))?,
    )
    .await
    .map_err(|e| RunnerError::Internal(e.to_string()))?;

    let context_run_id = format!("{}:{}", task.id, Utc::now().timestamp_millis());
    let scoped_rows = db
        .list_rules(&project_id.to_string(), None)
        .await
        .map_err(|e| RunnerError::Internal(e.to_string()))?;
    for rule_row in scoped_rows {
        let included = rule_row.active;
        let reason = if included { "active" } else { "disabled" };
        let _ = db
            .create_context_rule_usage(&ContextRuleUsageRow {
                id: Uuid::new_v4().to_string(),
                project_id: project_id.to_string(),
                run_id: context_run_id.clone(),
                rule_id: rule_row.id,
                included,
                reason: reason.to_string(),
                created_at: Utc::now(),
            })
            .await;
    }

    let timeout_minutes = if let Some(ref profile) = profile_override {
        profile.timeout_minutes as u64
    } else if let Some(task_timeout) = row.timeout_minutes.filter(|&t| t > 0) {
        task_timeout as u64
    } else {
        match provider.as_str() {
            "codex" => config
                .agents
                .codex
                .as_ref()
                .map(|c| c.timeout_minutes)
                .unwrap_or(20),
            _ => config
                .agents
                .claude_code
                .as_ref()
                .map(|c| c.timeout_minutes)
                .unwrap_or(30),
        }
    };
    let model = if let Some(ref profile) = profile_override {
        Some(profile.model.clone())
    } else {
        match provider.as_str() {
            "codex" => config.agents.codex.as_ref().and_then(|c| c.model.clone()),
            _ => config
                .agents
                .claude_code
                .as_ref()
                .and_then(|c| c.model.clone()),
        }
    };
    let auto_approve = match provider.as_str() {
        "codex" => config
            .agents
            .codex
            .as_ref()
            .map(|c| c.auto_approve)
            .unwrap_or(false),
        _ => config
            .agents
            .claude_code
            .as_ref()
            .map(|c| c.auto_approve)
            .unwrap_or(false),
    };
    let allow_npx = match provider.as_str() {
        "codex" => config
            .agents
            .codex
            .as_ref()
            .map(|c| c.allow_npx)
            .unwrap_or(false),
        _ => config
            .agents
            .claude_code
            .as_ref()
            .map(|c| c.allow_npx)
            .unwrap_or(false),
    };
    let npx_allowed_packages = match provider.as_str() {
        "codex" => config
            .agents
            .codex
            .as_ref()
            .map(|c| c.npx_allowed_packages.clone())
            .unwrap_or_default(),
        _ => config
            .agents
            .claude_code
            .as_ref()
            .map(|c| c.npx_allowed_packages.clone())
            .unwrap_or_default(),
    };

    let target_branch = config.branches.target.clone();
    let permit_holder = Arc::new(std::sync::Mutex::new(Some(permit)));

    // Resolve tracker adapter: present only when both the project has a tracker configured
    // and this task has a linked external source row.
    let tracker = if let Some(coordinator) = tracker_coordinator {
        let has_external_source = db
            .get_external_source_by_task(&task_id)
            .await
            .unwrap_or(None)
            .is_some();
        if has_external_source {
            Some(Arc::clone(coordinator.adapter()))
        } else {
            None
        }
    } else {
        None
    };

    Ok(PreparedRun {
        project_id,
        db,
        sessions,
        config,
        global_config,
        provider,
        adapter,
        permit_holder,
        working_dir,
        project_path,
        secret_env,
        secret_values,
        rules,
        context_path,
        timeout_minutes,
        model,
        auto_approve,
        allow_npx,
        npx_allowed_packages,
        allow_full_sandbox_access: false,
        task,
        task_row,
        origin,
        emitter: Arc::clone(emitter),
        git,
        redaction_secrets,
        pool,
        target_branch,
        global_db,
        tracker,
        db_run_id_holder: Arc::new(std::sync::Mutex::new(None)),
        hooks: cached_hooks,
        browser_tool_pending: state.browser_tool_pending.clone(),
        agent_teams: Arc::clone(&state.agent_teams),
    })
}

/// Phase 2 – spawn the agent process, create session/pane rows, start the event loop.
pub async fn start(prepared: &PreparedRun) -> Result<RunningAgent, RunnerError> {
    // BeforeRun hooks — fatal: abort if they fail
    {
        if let Some(cmds) = &prepared.hooks.before_run {
            let hook_defs = parse_hook_defs(HookPhase::BeforeRun, cmds);
            if !hook_defs.is_empty() {
                let secrets = current_redaction_secrets(&prepared.redaction_secrets).await;
                let wt_path = PathBuf::from(&prepared.working_dir);
                let branch = prepared.task.branch.clone().unwrap_or_default();
                if let Err(e) = run_hooks(
                    &hook_defs,
                    HookPhase::BeforeRun,
                    &wt_path,
                    &prepared.task.id.to_string(),
                    &branch,
                    &secrets,
                )
                .await
                {
                    let _ = cleanup_task_worktree(
                        &prepared.db,
                        &prepared.git,
                        prepared.project_id,
                        prepared.task.id,
                        None,
                        Some(&prepared.project_path),
                    )
                    .await;
                    return Err(RunnerError::Internal(format!(
                        "before_run hook failed: {e}"
                    )));
                }
            }
        }
    }

    let control_socket_path = resolve_control_plane_settings(
        &prepared.project_path,
        &prepared.config,
        &prepared.global_config,
    )
    .map(|settings| settings.socket_path.to_string_lossy().to_string())
    .unwrap_or_else(|_| {
        prepared
            .project_path
            .join(&prepared.config.automation.socket_path)
            .to_string_lossy()
            .to_string()
    });
    let team_id = Uuid::new_v4().to_string();
    let leader_pane_id = Uuid::new_v4().to_string();
    let team_seed = AgentTeamConfig {
        team_id: team_id.clone(),
        provider: prepared.provider.clone(),
        leader_session_id: Uuid::nil().to_string(),
        leader_pane_id: leader_pane_id.clone(),
        control_socket_path: control_socket_path.clone(),
        working_dir: prepared.working_dir.clone(),
        base_env: Vec::new(),
    };
    let team_base_env = if prepared.provider == "claude-code" {
        prepare_claude_team_environment(&team_seed, "%0").map_err(RunnerError::Internal)?
    } else {
        Vec::new()
    };
    let team_config = AgentTeamConfig {
        base_env: team_base_env,
        ..team_seed
    };
    let handle = prepared
        .adapter
        .spawn(AgentConfig {
            provider: prepared.provider.clone(),
            model: prepared.model.clone(),
            env: prepared.secret_env.clone(),
            working_dir: prepared.working_dir.clone(),
            timeout_minutes: prepared.timeout_minutes,
            auto_approve: prepared.auto_approve,
            allow_npx: prepared.allow_npx,
            npx_allowed_packages: prepared.npx_allowed_packages.clone(),
            allow_full_sandbox_access: prepared.allow_full_sandbox_access,
            output_format: "stream-json".to_string(),
            context_file: Some(prepared.context_path.to_string_lossy().to_string()),
            thread_id: None,
            dynamic_tools: {
                let mut tools = vec![];
                if prepared.tracker.is_some() {
                    tools.extend(crate::commands::tracker_tools::tracker_tool_defs());
                }
                tools.extend(crate::commands::browser_tools::browser_tool_defs());
                tools.extend(crate::commands::plan_tools::plan_tool_defs());
                if prepared.provider.starts_with("codex") {
                    tools.extend(crate::commands::team_tools::team_tool_defs());
                }
                tools
            },
            team: Some(team_config.clone()),
        })
        .await
        .map_err(|e| RunnerError::Internal(e.to_string()))?;

    let leader_session_id = handle.id.to_string();
    let agent_session_row = SessionRow {
        id: handle.id.to_string(),
        project_id: prepared.project_id.to_string(),
        name: format!("agent-{}", prepared.task.title),
        r#type: Some("agent".to_string()),
        backend: "tmux_compat".to_string(),
        durability: "durable".to_string(),
        lifecycle_state: "attached".to_string(),
        status: "running".to_string(),
        pid: None,
        cwd: prepared.working_dir.clone(),
        command: prepared.provider.clone(),
        branch: prepared.task.branch.clone(),
        worktree_id: prepared.task.worktree.clone(),
        connection_id: None,
        remote_session_id: None,
        controller_id: Some(team_id.clone()),
        started_at: Utc::now(),
        last_heartbeat: Utc::now(),
        last_output_at: None,
        detached_at: None,
        last_error: None,
        restore_status: None,
        exit_code: None,
        ended_at: None,
    };
    prepared
        .db
        .upsert_session(&agent_session_row)
        .await
        .map_err(|e| RunnerError::Internal(e.to_string()))?;
    let pane = PaneRow {
        id: leader_pane_id.clone(),
        project_id: prepared.project_id.to_string(),
        session_id: Some(handle.id.to_string()),
        r#type: "terminal".to_string(),
        position: "after:pane-board".to_string(),
        label: format!("Agent {}", prepared.task.title),
        metadata_json: Some(
            serde_json::to_string(&json!({
                "read_only": true,
                "agent_team": {
                    "team_id": team_id.clone(),
                    "leader_session_id": leader_session_id.clone(),
                    "provider": prepared.provider.clone(),
                    "role": "leader",
                    "member_index": 0,
                }
            }))
            .map_err(|e| RunnerError::Internal(e.to_string()))?,
        ),
    };
    prepared
        .db
        .upsert_pane(&pane)
        .await
        .map_err(|e| RunnerError::Internal(e.to_string()))?;
    let team_snapshot = {
        let mut guard = prepared.agent_teams.write().await;
        guard.start(crate::agent_teams::AgentTeamConfigInput {
            team_id: team_id.clone(),
            provider: prepared.provider.clone(),
            leader_session_id,
            leader_pane_id: leader_pane_id.clone(),
            working_dir: prepared.working_dir.clone(),
            control_socket_path: control_socket_path.clone(),
            base_env: team_config.base_env.clone(),
        })
    };
    prepared.emitter.emit(
        "agent_team_started",
        json!({
            "project_id": prepared.project_id,
            "team": team_snapshot,
        }),
    );
    prepared.emitter.emit(
        "session_spawned",
        json!({
            "project_id": prepared.project_id,
            "session_id": handle.id.to_string(),
            "name": agent_session_row.name,
            "session": session_row_to_event_payload(&agent_session_row)
        }),
    );

    let rx = prepared.adapter.events(&handle);

    let db_for_task = prepared.db.clone();
    let app_for_task = Arc::clone(&prepared.emitter);
    let git_for_task = prepared.git.clone();
    let provider_for_task = prepared.provider.clone();
    let project_id = prepared.project_id;
    let task_id = prepared.task.id;
    let session_id = handle.id;
    // project_path is the repo root (for loading WORKFLOW.md hooks)
    let project_path_for_task = prepared.project_path.clone();
    // worktree_path is where the agent ran (for executing hooks)
    let worktree_path_for_task = PathBuf::from(&prepared.working_dir);
    let branch_for_task = prepared.task.branch.clone().unwrap_or_default();
    let redaction_secrets_for_task = Arc::clone(&prepared.redaction_secrets);
    let permit_holder_for_task = Arc::clone(&prepared.permit_holder);
    let target_branch_for_task = prepared.target_branch.clone();
    let global_db_for_task = prepared.global_db.clone();
    let adapter_for_task = Arc::clone(&prepared.adapter);
    let handle_for_task = handle.clone();

    let tracker_for_task = prepared.tracker.clone();
    let db_run_id_holder_for_task = Arc::clone(&prepared.db_run_id_holder);
    let hooks_for_task = prepared.hooks.clone();

    let event_task = tokio::spawn(run_event_loop(RunEventLoopContext {
        rx,
        db: db_for_task,
        project_id,
        task_id,
        session_id,
        team_id: team_id.clone(),
        emitter: app_for_task,
        provider: provider_for_task,
        git: git_for_task,
        project_path: project_path_for_task,
        worktree_path: worktree_path_for_task,
        branch: branch_for_task,
        global_db: global_db_for_task,
        target_branch: target_branch_for_task,
        redaction_secrets: redaction_secrets_for_task,
        permit_holder: permit_holder_for_task,
        sessions: prepared.sessions.clone(),
        agent_teams: Arc::clone(&prepared.agent_teams),
        adapter: adapter_for_task,
        handle: handle_for_task,
        tracker: tracker_for_task,
        db_run_id_holder: db_run_id_holder_for_task,
        hooks: hooks_for_task,
        browser_tool_pending: prepared.browser_tool_pending.clone(),
    }));

    Ok(RunningAgent {
        task_id,
        session_id,
        handle,
        event_task,
        origin: prepared.origin,
        permit_holder: Arc::clone(&prepared.permit_holder),
        db_run_id_holder: Arc::clone(&prepared.db_run_id_holder),
    })
}

/// Phase 3 – build the payload and send to the agent. On error, abort event loop and clean up.
pub async fn send_payload(prepared: &PreparedRun, running: &RunningAgent) -> Result<(), String> {
    let task = &prepared.task;
    let row = &prepared.task_row;

    let payload = TaskPayload {
        task_id: running.task_id,
        objective: task.goal.clone(),
        constraints: task.constraints.clone(),
        project_rules: prepared.rules.clone(),
        worktree_path: prepared.working_dir.clone(),
        branch_name: task.branch.clone().unwrap_or_default(),
        acceptance_checks: task
            .acceptance_criteria
            .iter()
            .map(|check| check.description.clone())
            .collect(),
        relevant_file_paths: task.scope.clone(),
        prior_context_summary: row.loop_context_json.as_ref().and_then(|json_str| {
            let ctx: serde_json::Value = serde_json::from_str(json_str).ok()?;
            let mut parts = Vec::new();

            if let Some(iter) = ctx.get("iteration").and_then(|v| v.as_i64()) {
                parts.push(format!("This is loop iteration {}.", iter));
            }

            if let Some(summaries) = ctx.get("accumulated_summaries").and_then(|v| v.as_array()) {
                if !summaries.is_empty() {
                    parts.push("## Previous Iteration Results\n".to_string());
                    for s in summaries {
                        let iter_n = s.get("iteration").and_then(|v| v.as_i64()).unwrap_or(0);
                        let status = s.get("status").and_then(|v| v.as_str()).unwrap_or("?");
                        let text = s.get("summary").and_then(|v| v.as_str()).unwrap_or("");
                        parts.push(format!("**Iteration {} ({}):** {}", iter_n, status, text));
                    }
                }
            }

            if let Some(fb) = ctx.get("feedback").and_then(|v| v.as_str()) {
                if !fb.is_empty() {
                    parts.push(format!("\n## Feedback from Previous Attempt\n\n{}", fb));
                }
            }

            if parts.is_empty() {
                None
            } else {
                Some(parts.join("\n\n"))
            }
        }),
    };

    if let Err(err) = prepared.adapter.send(&running.handle, payload).await {
        return Err(handle_send_failure(prepared, running, err).await);
    }

    Ok(())
}

async fn handle_send_failure(
    prepared: &PreparedRun,
    running: &RunningAgent,
    err: pnevma_agents::AgentError,
) -> String {
    running.event_task.abort();
    drop(
        running
            .permit_holder
            .lock()
            .expect("permit lock poisoned")
            .take(),
    );

    let error = err.to_string();
    let failed_summary = redact_text(&error, &prepared.secret_values);

    if let Ok(Some(mut row)) = prepared.db.get_task(&running.task_id.to_string()).await {
        let prev_status = parse_status(&row.status);
        row.status = status_to_str(&TaskStatus::Failed).to_string();
        row.handoff_summary = Some(failed_summary.clone());
        row.updated_at = Utc::now();
        let _ = prepared.db.update_task(&row).await;
        notify_task_status_transition(
            &prepared.db,
            &prepared.emitter,
            prepared.project_id,
            running.task_id,
            &row.title,
            &prev_status,
            &TaskStatus::Failed,
            Some(&failed_summary),
        )
        .await;
        emit_enriched_task_event(&prepared.emitter, &prepared.db, &row.id).await;
    }

    let _ = upsert_agent_session_status(
        &prepared.db,
        prepared.project_id,
        running.handle.id,
        "failed",
    )
    .await;
    finalize_automation_run_record(
        &prepared.db,
        &prepared.db_run_id_holder,
        AutomationRunFinalization {
            status: "failed",
            tokens_in: 0,
            tokens_out: 0,
            cost_usd: 0.0,
            summary: Some(&failed_summary),
            error_message: Some(&failed_summary),
        },
    )
    .await;

    let _ = cleanup_task_worktree(
        &prepared.db,
        &prepared.git,
        prepared.project_id,
        running.task_id,
        Some(&prepared.emitter),
        None,
    )
    .await;

    append_event(
        &prepared.db,
        prepared.project_id,
        Some(running.task_id),
        Some(running.handle.id),
        "agent",
        "AgentLaunchFailed",
        json!({"error": failed_summary}),
    )
    .await;

    error
}

pub async fn handle_start_failure(prepared: &PreparedRun, error: &str) {
    drop(
        prepared
            .permit_holder
            .lock()
            .expect("permit lock poisoned")
            .take(),
    );

    let failed_summary = redact_text(error, &prepared.secret_values);

    if let Ok(Some(mut row)) = prepared.db.get_task(&prepared.task.id.to_string()).await {
        let prev_status = parse_status(&row.status);
        row.status = status_to_str(&TaskStatus::Failed).to_string();
        row.handoff_summary = Some(failed_summary.clone());
        row.updated_at = Utc::now();
        let _ = prepared.db.update_task(&row).await;
        notify_task_status_transition(
            &prepared.db,
            &prepared.emitter,
            prepared.project_id,
            prepared.task.id,
            &row.title,
            &prev_status,
            &TaskStatus::Failed,
            Some(&failed_summary),
        )
        .await;
        emit_enriched_task_event(&prepared.emitter, &prepared.db, &row.id).await;
    }

    finalize_automation_run_record(
        &prepared.db,
        &prepared.db_run_id_holder,
        AutomationRunFinalization {
            status: "failed",
            tokens_in: 0,
            tokens_out: 0,
            cost_usd: 0.0,
            summary: Some(&failed_summary),
            error_message: Some(&failed_summary),
        },
    )
    .await;

    let _ = cleanup_task_worktree(
        &prepared.db,
        &prepared.git,
        prepared.project_id,
        prepared.task.id,
        Some(&prepared.emitter),
        Some(&prepared.project_path),
    )
    .await;

    append_event(
        &prepared.db,
        prepared.project_id,
        Some(prepared.task.id),
        None,
        "agent",
        "AgentLaunchFailed",
        json!({"error": failed_summary}),
    )
    .await;
}

struct RunEventLoopContext {
    rx: tokio::sync::broadcast::Receiver<AgentEvent>,
    db: Db,
    project_id: Uuid,
    task_id: Uuid,
    session_id: Uuid,
    team_id: String,
    emitter: Arc<dyn EventEmitter>,
    provider: String,
    git: Arc<GitService>,
    project_path: PathBuf,
    worktree_path: PathBuf,
    branch: String,
    global_db: Option<pnevma_db::GlobalDb>,
    target_branch: String,
    redaction_secrets: Arc<RwLock<Vec<String>>>,
    permit_holder: Arc<std::sync::Mutex<Option<DispatchPermit>>>,
    sessions: SessionSupervisor,
    agent_teams: Arc<RwLock<crate::agent_teams::AgentTeamStore>>,
    adapter: Arc<dyn AgentAdapter>,
    handle: AgentHandle,
    tracker: Option<Arc<dyn pnevma_tracker::TrackerAdapter>>,
    db_run_id_holder: Arc<std::sync::Mutex<Option<String>>>,
    hooks: pnevma_core::WorkflowHooks,
    browser_tool_pending: crate::commands::browser_tools::BrowserToolPending,
}

async fn run_event_loop(ctx: RunEventLoopContext) {
    let RunEventLoopContext {
        mut rx,
        db,
        project_id,
        task_id,
        session_id,
        team_id,
        emitter,
        provider,
        git,
        project_path,
        worktree_path,
        branch,
        global_db,
        target_branch,
        redaction_secrets,
        permit_holder,
        sessions,
        agent_teams,
        adapter,
        handle,
        tracker,
        db_run_id_holder,
        hooks,
        browser_tool_pending,
    } = ctx;
    let session_id_str = session_id.to_string();
    let mut last_summary: Option<String> = None;
    let mut failed = false;
    let mut output_redactor = StreamRedactor::new(Arc::clone(&redaction_secrets));

    // Resilience state
    let retry_policy = RetryPolicy::default();
    let mut retry_ctx = RetryContext::new(task_id, provider.clone(), retry_policy.max_attempts);
    let mut continuation = ContinuationState::new(handle.thread_id.clone(), 10);
    let mut stall_detector = StallDetector::new(StallDetectorConfig::default());
    let mut stall_check_interval = tokio::time::interval(std::time::Duration::from_secs(30));
    // Consume the first tick which fires immediately.
    stall_check_interval.tick().await;

    'event_loop: loop {
        tokio::select! {
            biased;

            recv_result = rx.recv() => {
                let event = match recv_result {
                    Ok(e) => e,
                    Err(_) => break 'event_loop,
                };

                // Any received event counts as activity.
                stall_detector.record_activity();
                let _ = upsert_agent_session_status(&db, project_id, session_id, "running").await;

                match event {
                    AgentEvent::OutputChunk(chunk) => {
                        if let Some(safe_chunk) = output_redactor.push_chunk(&chunk).await {
                            emitter.emit(
                                "session_output",
                                json!({"session_id": session_id_str, "chunk": safe_chunk.clone()}),
                            );
                            append_event(
                                &db,
                                project_id,
                                Some(task_id),
                                None,
                                "agent",
                                "AgentOutputChunk",
                                json!({"chunk": safe_chunk.clone()}),
                            )
                            .await;
                            for attention in parse_osc_attention(&safe_chunk) {
                                let body = if attention.body.trim().is_empty() {
                                    format!("OSC {} attention sequence received", attention.code)
                                } else {
                                    attention.body
                                };
                                let current_secrets =
                                    current_redaction_secrets(&redaction_secrets).await;
                                let _ = create_notification_row(
                                    &db,
                                    &emitter,
                                    project_id,
                                    Some(task_id),
                                    Some(session_id),
                                    osc_title(&attention.code),
                                    &body,
                                    Some(osc_level(&attention.code)),
                                    "osc",
                                    &current_secrets,
                                )
                                .await;
                            }
                        }
                    }
                    AgentEvent::ToolUse { name, input, output } => {
                        let current_secrets = current_redaction_secrets(&redaction_secrets).await;
                        append_event(
                            &db,
                            project_id,
                            Some(task_id),
                            None,
                            "agent",
                            "AgentToolUse",
                            json!({
                                "name": name,
                                "input": redact_text(&input, &current_secrets),
                                "output": redact_text(&output, &current_secrets)
                            }),
                        )
                        .await;
                    }
                    AgentEvent::UsageUpdate { tokens_in, tokens_out, cost_usd } => {
                        continuation.record_usage(tokens_in, tokens_out, cost_usd);
                        let agent_run_id = db_run_id_holder
                            .lock()
                            .ok()
                            .and_then(|guard| guard.clone());
                        let _ = db
                            .append_cost(&CostRow {
                                id: Uuid::new_v4().to_string(),
                                agent_run_id,
                                task_id: task_id.to_string(),
                                session_id: session_id_str.clone(),
                                provider: provider.clone(),
                                model: None,
                                tokens_in: tokens_in as i64,
                                tokens_out: tokens_out as i64,
                                estimated_usd: cost_usd,
                                tracked: true,
                                timestamp: Utc::now(),
                            })
                            .await;
                        emitter.emit(
                            "cost_updated",
                            json!({"task_id": task_id.to_string(), "cost_usd": cost_usd}),
                        );
                    }
                    AgentEvent::SemanticHeartbeat { .. } => {
                        // Activity already recorded above; nothing else to do.
                    }
                    AgentEvent::TurnCompleted { ref finish_reason, .. } => {
                        continuation.record_turn(finish_reason);
                        // When max turns are reached and the agent still wants to continue,
                        // cap execution and treat as completion.
                        if continuation.turn_count >= continuation.max_turns
                            && continuation.should_continue()
                        {
                            last_summary = Some(format!(
                                "agent reached max turns limit ({})",
                                continuation.max_turns
                            ));
                            break 'event_loop;
                        }
                    }
                    AgentEvent::Error(message) => {
                        let class = classify_failure(&message);
                        let backoff = compute_backoff(retry_ctx.attempt + 1, &retry_policy);
                        retry_ctx.record_failure(class, &message, backoff.as_secs());
                        match class {
                            FailureClass::Transient if retry_ctx.should_retry() => {
                                append_event(
                                    &db,
                                    project_id,
                                    Some(task_id),
                                    None,
                                    "agent",
                                    "AgentRetry",
                                    json!({
                                        "attempt": retry_ctx.attempt,
                                        "backoff_secs": backoff.as_secs(),
                                        "cumulative_backoff_secs": retry_ctx.cumulative_backoff_secs,
                                        "reason": message
                                    }),
                                )
                                .await;
                                tokio::time::sleep(backoff).await;
                                stall_detector.reset();
                                // Continue the loop — the adapter may resume or error again.
                            }
                            _ => {
                                failed = true;
                                let current_secrets =
                                    current_redaction_secrets(&redaction_secrets).await;
                                last_summary = Some(redact_text(&message, &current_secrets));
                                break 'event_loop;
                            }
                        }
                    }
                    AgentEvent::Complete { summary } => {
                        let current_secrets = current_redaction_secrets(&redaction_secrets).await;
                        last_summary = Some(redact_text(&summary, &current_secrets));
                        break 'event_loop;
                    }
                    AgentEvent::DynamicToolCall { call_id, tool_name, params } => {
                        let result = if tool_name.starts_with("browser.") {
                            crate::commands::browser_tools::handle_browser_tool_call(
                                &call_id,
                                &tool_name,
                                &params,
                                &*emitter,
                                &browser_tool_pending,
                            )
                            .await
                        } else if tool_name.starts_with("plan.") {
                            crate::commands::plan_tools::handle_plan_tool_call(
                                &call_id,
                                &tool_name,
                                &params,
                                &project_path,
                            )
                            .await
                        } else if tool_name.starts_with("team.") {
                            crate::commands::team_tools::handle_team_tool_call(
                                &call_id,
                                &tool_name,
                                &params,
                                &team_id,
                                &provider,
                                project_id,
                                &project_path,
                                &db,
                                &sessions,
                                &redaction_secrets,
                                &agent_teams,
                                &emitter,
                            )
                            .await
                        } else if let Some(ref tracker_adapter) = tracker {
                            let secrets = current_redaction_secrets(&redaction_secrets).await;
                            crate::commands::tracker_tools::handle_dynamic_tool_call(
                                &call_id,
                                &tool_name,
                                &params,
                                tracker_adapter,
                                &task_id.to_string(),
                                &project_id.to_string(),
                                &secrets,
                            )
                            .await
                        } else {
                            tracing::debug!(call_id = %call_id, tool_name = %tool_name, "DynamicToolCall received but no handler matched");
                            serde_json::json!({"error": format!("unknown tool: {}", tool_name), "success": false})
                        };
                        if let Err(e) = adapter.send_tool_result(&handle, &call_id, result).await {
                            tracing::warn!(call_id = %call_id, error = %e, "failed to send tool result back to agent");
                        }
                    }
                    AgentEvent::StatusChange(_)
                    | AgentEvent::ThreadStarted { .. }
                    | AgentEvent::TurnStarted { .. }
                    | AgentEvent::RateLimitUpdated { .. } => {}
                }
            }

            _ = stall_check_interval.tick() => {
                if stall_detector.is_stalled() {
                    let stall_count = stall_detector.increment_stall_count();
                    if stall_detector.max_stalls_exceeded() {
                        failed = true;
                        last_summary = Some(format!(
                            "agent stalled after {} heartbeat timeout(s) with no activity",
                            stall_count
                        ));
                        append_event(
                            &db,
                            project_id,
                            Some(task_id),
                            None,
                            "agent",
                            "AgentStalled",
                            json!({"stall_count": stall_count, "terminal": true}),
                        )
                        .await;
                        break 'event_loop;
                    } else {
                        // Attempt recovery via interrupt.
                        append_event(
                            &db,
                            project_id,
                            Some(task_id),
                            None,
                            "agent",
                            "AgentStalled",
                            json!({
                                "stall_count": stall_count,
                                "terminal": false,
                                "action": "interrupt"
                            }),
                        )
                        .await;
                        let _ = adapter.interrupt(&handle).await;
                        stall_detector.reset();
                    }
                }
            }
        }
    }

    if let Some(safe_chunk) = output_redactor.finish().await {
        emitter.emit(
            "session_output",
            json!({"session_id": session_id_str, "chunk": safe_chunk.clone()}),
        );
        append_event(
            &db,
            project_id,
            Some(task_id),
            None,
            "agent",
            "AgentOutputChunk",
            json!({"chunk": safe_chunk.clone()}),
        )
        .await;
        for attention in parse_osc_attention(&safe_chunk) {
            let body = if attention.body.trim().is_empty() {
                format!("OSC {} attention sequence received", attention.code)
            } else {
                attention.body
            };
            let current_secrets = current_redaction_secrets(&redaction_secrets).await;
            let _ = create_notification_row(
                &db,
                &emitter,
                project_id,
                Some(task_id),
                Some(session_id),
                osc_title(&attention.code),
                &body,
                Some(osc_level(&attention.code)),
                "osc",
                &current_secrets,
            )
            .await;
        }
    }

    drop(permit_holder.lock().expect("permit lock poisoned").take());

    if let Ok(Some(mut row)) = db.get_task(&task_id.to_string()).await {
        let prev_status = parse_status(&row.status);
        row.handoff_summary = last_summary.clone();
        let mut next_status = if failed {
            TaskStatus::Failed
        } else {
            TaskStatus::InProgress
        };

        if !failed {
            // Check if this is an until_complete loop task — skip acceptance checks, go straight to Done
            let is_until_complete = row
                .loop_context_json
                .as_ref()
                .and_then(|s| serde_json::from_str::<serde_json::Value>(s).ok())
                .and_then(|v| v.get("mode")?.as_str().map(|s| s == "until_complete"))
                .unwrap_or(false);

            if is_until_complete {
                next_status = TaskStatus::Done;
            } else if let Ok(task_contract) = task_row_to_contract(&row) {
                match prepare_merge_ready_worktree(&worktree_path, &target_branch, &task_contract)
                    .await
                {
                    Err(err) => {
                        let current_secrets = current_redaction_secrets(&redaction_secrets).await;
                        let safe_error = redact_text(&err, &current_secrets);
                        row.handoff_summary = Some(safe_error.clone());
                        last_summary = Some(safe_error.clone());
                        next_status = TaskStatus::Failed;
                        failed = true;
                        append_event(
                            &db,
                            project_id,
                            Some(task_id),
                            None,
                            "git",
                            "AgentOutputNotMergeReady",
                            json!({
                                "task_id": task_id,
                                "error": safe_error
                            }),
                        )
                        .await;
                    }
                    Ok(commit_result) => {
                        append_event(
                        &db,
                        project_id,
                        Some(task_id),
                        None,
                        "git",
                        "AgentChangesCommitted",
                        json!({
                            "task_id": task_id,
                            "branch": branch.clone(),
                            "commit_sha": commit_result.as_ref().map(|result| result.commit_sha.clone()),
                            "commit_message": commit_result.as_ref().map(|result| result.commit_message.clone()),
                        }),
                    )
                    .await;
                        match run_acceptance_checks_for_task(
                            &db,
                            project_id,
                            &project_path,
                            &task_contract,
                        )
                        .await
                        {
                            Ok((check_run, check_results, all_automated_passed)) => {
                                if all_automated_passed {
                                    let current_secrets =
                                        current_redaction_secrets(&redaction_secrets).await;
                                    let cost = db
                                        .task_cost_total(&task_id.to_string())
                                        .await
                                        .unwrap_or(0.0);
                                    next_status = TaskStatus::Review;
                                    if let Err(err) = generate_review_pack(
                                        &db,
                                        project_id,
                                        &project_path,
                                        &target_branch,
                                        &task_contract,
                                        &check_run,
                                        &check_results,
                                        cost,
                                        last_summary.as_deref(),
                                        &current_secrets,
                                    )
                                    .await
                                    {
                                        append_event(
                                            &db,
                                            project_id,
                                            Some(task_id),
                                            None,
                                            "review",
                                            "ReviewPackGenerationFailed",
                                            json!({
                                                "task_id": task_id,
                                                "error": redact_text(&err, &current_secrets)
                                            }),
                                        )
                                        .await;
                                    }
                                }
                            }
                            Err(err) => {
                                let current_secrets =
                                    current_redaction_secrets(&redaction_secrets).await;
                                append_event(
                                    &db,
                                    project_id,
                                    Some(task_id),
                                    None,
                                    "core",
                                    "AcceptanceCheckRunFailed",
                                    json!({
                                        "task_id": task_id,
                                        "error": redact_text(&err, &current_secrets)
                                    }),
                                )
                                .await;
                            }
                        }
                    }
                }
            }
        }

        // Run verification hooks after acceptance checks, before final status
        if !failed {
            if let Some(ref verify_hooks) = hooks.verify {
                let verify_results =
                    run_verification_hooks(verify_hooks, &worktree_path, &branch).await;
                if let Some(failure) = verify_results.first_failure() {
                    let verify_feedback = format!(
                        "Verification failed — {}:\n```\n{}\n```\nFix the issues and ensure verification passes.",
                        failure.description, failure.output
                    );
                    row.handoff_summary = Some(verify_feedback);
                    next_status = TaskStatus::Failed;
                    failed = true;

                    append_event(
                        &db,
                        project_id,
                        Some(task_id),
                        None,
                        "core",
                        "VerificationFailed",
                        json!({
                            "task_id": task_id,
                            "hook_description": failure.description,
                            "exit_code": failure.exit_code,
                        }),
                    )
                    .await;
                }
            }
        }

        row.status = status_to_str(&next_status).to_string();
        row.updated_at = Utc::now();
        if let Err(e) = db.update_task(&row).await {
            tracing::error!(
                task_id = %row.id,
                status = %row.status,
                error = %e,
                "failed to persist task status transition — dependents may not unblock"
            );
        }
        notify_task_status_transition(
            &db,
            &emitter,
            project_id,
            task_id,
            &row.title,
            &prev_status,
            &next_status,
            row.handoff_summary.as_deref(),
        )
        .await;
        if is_terminal_task_status(&next_status) {
            let loop_triggered = check_loop_trigger(
                &db,
                &row.id,
                &next_status,
                &project_path,
                global_db.as_ref(),
            )
            .await
            .unwrap_or_else(|e| {
                tracing::warn!(task_id = %row.id, error = %e, "check_loop_trigger failed");
                false
            });
            if !loop_triggered && next_status == TaskStatus::Done {
                if let Err(e) = refresh_dependency_states_after_completion_without_dispatch(
                    &db,
                    project_id,
                    task_id,
                    Some(&emitter),
                )
                .await
                {
                    tracing::warn!(task_id = %row.id, error = %e, "failed to refresh dependency states after completion");
                }
            }
            if !loop_triggered {
                check_workflow_completion(&db, &row.id, Some(&emitter)).await;
            }
            // Note: Loop tasks are created as Ready when their pre-loop deps
            // are satisfied (see create_loop_iteration). The auto_dispatch
            // background loop picks them up for dispatch.

            // Outbound tracker sync: push terminal status to external tracker.
            if let Some(ref tracker_adapter) = tracker {
                if let Ok(Some(source_row)) =
                    db.get_external_source_by_task(&task_id.to_string()).await
                {
                    let to_state = if failed {
                        pnevma_tracker::ExternalState::Cancelled
                    } else {
                        pnevma_tracker::ExternalState::Done
                    };
                    let from_state = pnevma_tracker::ExternalState::from_display(&source_row.state);
                    let transition = pnevma_tracker::StateTransition {
                        external_id: source_row.external_id.clone(),
                        kind: source_row.kind.clone(),
                        team_id: None,
                        from_state,
                        to_state,
                        comment: last_summary.clone(),
                    };
                    match tokio::time::timeout(
                        std::time::Duration::from_secs(10),
                        tracker_adapter.transition_item(&transition),
                    )
                    .await
                    {
                        Ok(Ok(())) => {
                            tracing::info!(external_id = %source_row.external_id, "tracker outbound sync succeeded");
                        }
                        Ok(Err(e)) => {
                            tracing::warn!(external_id = %source_row.external_id, error = %e, "tracker outbound sync failed");
                        }
                        Err(_) => {
                            tracing::warn!(external_id = %source_row.external_id, "tracker outbound sync timed out");
                        }
                    }
                }
            }
        }
        if prev_status != next_status {
            append_event(
                &db,
                project_id,
                Some(task_id),
                None,
                "core",
                "TaskStatusChanged",
                json!({
                    "task_id": task_id,
                    "from": status_to_str(&prev_status),
                    "to": status_to_str(&next_status),
                    "reason": "agent_completion"
                }),
            )
            .await;
        }
        emit_enriched_task_event(&emitter, &db, &row.id).await;
    }

    let session_status = if failed { "failed" } else { "completed" };
    let _ = upsert_agent_session_status(&db, project_id, session_id, session_status).await;

    // Run after_run hooks when not failed. Non-fatal — log errors only.
    if !failed {
        if let Some(cmds) = &hooks.after_run {
            let hook_defs = parse_hook_defs(HookPhase::AfterRun, cmds);
            if !hook_defs.is_empty() {
                let secrets = current_redaction_secrets(&redaction_secrets).await;
                if let Err(e) = run_hooks(
                    &hook_defs,
                    HookPhase::AfterRun,
                    &worktree_path,
                    &task_id.to_string(),
                    &branch,
                    &secrets,
                )
                .await
                {
                    tracing::warn!(task_id = %task_id, error = %e, "after_run hook failed");
                }
            }
        }
    }

    if failed {
        let _ = cleanup_task_worktree(&db, &git, project_id, task_id, Some(&emitter), None).await;

        // Ingest error signature from failure summary
        if let Some(ref summary) = last_summary {
            let normalized = pnevma_core::error_signatures::normalize_error(summary);
            let sig_hash = pnevma_core::error_signatures::signature_hash(&normalized);
            let category = pnevma_core::error_signatures::categorize_error(&normalized);
            let hint = pnevma_core::error_signatures::remediation_hint(category);
            let now = Utc::now();
            let sig_row = pnevma_db::ErrorSignatureRow {
                id: Uuid::new_v4().to_string(),
                project_id: project_id.to_string(),
                signature_hash: sig_hash,
                canonical_message: normalized.into_owned(),
                category: category.to_string(),
                first_seen: now,
                last_seen: now,
                total_count: 1,
                sample_output: Some(summary.clone()),
                remediation_hint: hint.map(|s| s.to_string()),
            };
            let _ = db.upsert_error_signature(&sig_row).await;
            let date_str = now.format("%Y-%m-%d").to_string();
            let _ = db
                .increment_error_signature_daily(&sig_row.id, &date_str)
                .await;
        }
    }

    finalize_automation_run_record(
        &db,
        &db_run_id_holder,
        AutomationRunFinalization {
            status: if failed { "failed" } else { "completed" },
            tokens_in: continuation.accumulated_tokens_in as i64,
            tokens_out: continuation.accumulated_tokens_out as i64,
            cost_usd: continuation.accumulated_cost_usd,
            summary: last_summary.as_deref(),
            error_message: if failed {
                last_summary.as_deref()
            } else {
                None
            },
        },
    )
    .await;

    emitter.emit(
        "pool_updated",
        json!({"state": db.path().to_string_lossy()}),
    );
    append_event(
        &db,
        project_id,
        Some(task_id),
        None,
        "agent",
        "AgentComplete",
        json!({
            "task_id": task_id,
            "failed": failed,
            "handoff_summary": last_summary
        }),
    )
    .await;
}

// ── Verification Hooks ──────────────────────────────────────────────────────

struct VerifyResult {
    description: String,
    output: String,
    exit_code: i32,
}

struct VerifyResults(Vec<VerifyResult>);

impl VerifyResults {
    fn first_failure(&self) -> Option<&VerifyResult> {
        self.0.iter().find(|r| r.exit_code != 0)
    }
}

async fn run_verification_hooks(
    hooks: &[pnevma_core::VerificationHook],
    working_dir: &Path,
    branch: &str,
) -> VerifyResults {
    let mut results = Vec::new();
    for hook in hooks {
        let timeout = std::time::Duration::from_secs(hook.timeout_seconds);
        let output = tokio::time::timeout(
            timeout,
            tokio::process::Command::new("sh")
                .arg("-c")
                .arg(&hook.command)
                .current_dir(working_dir)
                .env("PNEVMA_BRANCH", branch)
                .output(),
        )
        .await;

        match output {
            Ok(Ok(out)) => {
                let stdout = String::from_utf8_lossy(&out.stdout);
                let stderr = String::from_utf8_lossy(&out.stderr);
                let combined = format!("{stdout}{stderr}");
                // Truncate output to avoid blowing up context
                let truncated = if combined.len() > 4000 {
                    // Find a valid UTF-8 char boundary at or before 4000
                    let end = combined
                        .char_indices()
                        .map(|(i, _)| i)
                        .take_while(|&i| i <= 4000)
                        .last()
                        .unwrap_or(0);
                    format!("{}...[truncated]", &combined[..end])
                } else {
                    combined
                };
                let exit_code = out.status.code().unwrap_or(-1);
                if exit_code != 0 {
                    tracing::warn!(
                        hook = %hook.description,
                        exit_code = exit_code,
                        "verification hook failed"
                    );
                }
                results.push(VerifyResult {
                    description: hook.description.clone(),
                    output: truncated,
                    exit_code,
                });
            }
            Ok(Err(e)) => {
                tracing::warn!(hook = %hook.description, error = %e, "verification hook execution error");
                results.push(VerifyResult {
                    description: hook.description.clone(),
                    output: format!("execution error: {e}"),
                    exit_code: -1,
                });
            }
            Err(_) => {
                tracing::warn!(hook = %hook.description, "verification hook timed out");
                results.push(VerifyResult {
                    description: hook.description.clone(),
                    output: format!("timed out after {}s", hook.timeout_seconds),
                    exit_code: -1,
                });
            }
        }

        // Stop on first failure — no need to run remaining hooks
        if results.last().is_some_and(|r| r.exit_code != 0) {
            break;
        }
    }
    VerifyResults(results)
}
