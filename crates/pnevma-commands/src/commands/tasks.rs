use super::project::{fallback_draft, try_provider_task_draft};
use super::*;

pub async fn get_task_diff(
    input: TaskDiffInput,
    state: &AppState,
) -> Result<Option<TaskDiffView>, String> {
    let db = {
        let current = state.current.lock().await;
        let ctx = current
            .as_ref()
            .ok_or_else(|| "no open project".to_string())?;
        ctx.db.clone()
    };
    let Some(review) = db
        .get_review_by_task(&input.task_id)
        .await
        .map_err(|e| e.to_string())?
    else {
        return Ok(None);
    };
    let review_text = tokio::fs::read_to_string(&review.review_pack_path)
        .await
        .map_err(|e| e.to_string())?;
    let pack =
        serde_json::from_str::<serde_json::Value>(&review_text).map_err(|e| e.to_string())?;
    let diff_path = pack
        .get("diff_path")
        .and_then(|v| v.as_str())
        .map(ToString::to_string)
        .unwrap_or_else(|| {
            PathBuf::from(&review.review_pack_path)
                .with_file_name("diff.patch")
                .to_string_lossy()
                .to_string()
        });
    let diff_text = tokio::fs::read_to_string(&diff_path)
        .await
        .map_err(|e| e.to_string())?;
    Ok(Some(TaskDiffView {
        task_id: input.task_id,
        diff_path,
        files: parse_diff_patch(&diff_text),
    }))
}

pub(crate) async fn rule_row_to_view(row: RuleRow, project_path: &Path) -> RuleView {
    let content = tokio::fs::read_to_string(project_path.join(&row.path))
        .await
        .unwrap_or_default();
    RuleView {
        id: row.id,
        name: row.name,
        path: row.path,
        scope: row.scope.unwrap_or_else(|| "rule".to_string()),
        active: row.active,
        content,
    }
}

pub(crate) async fn ensure_scope_rows_from_config(
    db: &Db,
    project_id: Uuid,
    project_path: &Path,
    config: &ProjectConfig,
    scope: &str,
) -> Result<(), String> {
    let patterns = if normalize_rule_scope(scope) == "convention" {
        &config.conventions.paths
    } else {
        &config.rules.paths
    };
    ensure_rule_rows(db, project_id, project_path, scope, patterns).await
}

pub async fn draft_task_contract(
    input: DraftTaskInput,
    state: &AppState,
) -> Result<DraftTaskView, String> {
    let (db, project_id, adapters, config, global_config, project_path) = {
        let current = state.current.lock().await;
        let ctx = current
            .as_ref()
            .ok_or_else(|| "no open project".to_string())?;
        (
            ctx.db.clone(),
            ctx.project_id,
            ctx.adapters.clone(),
            ctx.config.clone(),
            ctx.global_config.clone(),
            ctx.project_path.clone(),
        )
    };
    let text = input.text.trim();
    if text.is_empty() {
        return Err("draft input text is required".to_string());
    }
    let preferred_provider = global_config
        .default_provider
        .clone()
        .unwrap_or_else(|| config.agents.default_provider.clone());
    let provider = if adapters.get(&preferred_provider).is_some() {
        preferred_provider
    } else if adapters.get("claude-code").is_some() {
        "claude-code".to_string()
    } else {
        "codex".to_string()
    };
    let model = match provider.as_str() {
        "codex" => config
            .agents
            .codex
            .as_ref()
            .and_then(|cfg| cfg.model.clone()),
        _ => config
            .agents
            .claude_code
            .as_ref()
            .and_then(|cfg| cfg.model.clone()),
    };
    let timeout_minutes = match provider.as_str() {
        "codex" => config
            .agents
            .codex
            .as_ref()
            .map(|cfg| cfg.timeout_minutes)
            .unwrap_or(20),
        _ => config
            .agents
            .claude_code
            .as_ref()
            .map(|cfg| cfg.timeout_minutes)
            .unwrap_or(30),
    };
    let (secret_env, _) = resolve_secret_env(&db, project_id)
        .await
        .unwrap_or_else(|_| (Vec::new(), Vec::new()));

    let draft = if let Some(adapter) = adapters.get(&provider) {
        match try_provider_task_draft(
            adapter,
            &provider,
            model,
            timeout_minutes,
            secret_env,
            project_path.as_path(),
            text,
        )
        .await
        {
            Ok(provider_draft) => provider_draft,
            Err(err) => fallback_draft(text, Some(err)),
        }
    } else {
        fallback_draft(
            text,
            Some(format!(
                "provider '{}' unavailable; used deterministic fallback",
                provider
            )),
        )
    };
    append_event(
        &db,
        project_id,
        None,
        None,
        "core",
        "TaskDraftGenerated",
        json!({
            "title": draft.title,
            "scope_items": draft.scope.len(),
            "source": draft.source,
            "warnings": draft.warnings
        }),
    )
    .await;
    Ok(draft)
}

pub async fn run_task_checks(
    task_id: String,
    state: &AppState,
) -> Result<TaskCheckRunView, String> {
    let (db, project_id, project_path) = {
        let current = state.current.lock().await;
        let ctx = current
            .as_ref()
            .ok_or_else(|| "no open project".to_string())?;
        (ctx.db.clone(), ctx.project_id, ctx.project_path.clone())
    };
    let row = db
        .get_task(&task_id)
        .await
        .map_err(|e| e.to_string())?
        .ok_or_else(|| format!("task not found: {task_id}"))?;
    let task = task_row_to_contract(&row)?;
    let (run, results, _) =
        run_acceptance_checks_for_task(&db, project_id, &project_path, &task).await?;
    Ok(TaskCheckRunView {
        id: run.id,
        task_id: run.task_id,
        status: run.status,
        summary: run.summary,
        created_at: run.created_at,
        results: results
            .into_iter()
            .map(|row| TaskCheckResultView {
                id: row.id,
                description: row.description,
                check_type: row.check_type,
                command: row.command,
                passed: row.passed,
                output: row.output,
                created_at: row.created_at,
            })
            .collect(),
    })
}

pub async fn get_task_check_results(
    task_id: String,
    state: &AppState,
) -> Result<Option<TaskCheckRunView>, String> {
    let db = {
        let current = state.current.lock().await;
        let ctx = current
            .as_ref()
            .ok_or_else(|| "no open project".to_string())?;
        ctx.db.clone()
    };
    let Some(run) = db
        .latest_check_run_for_task(&task_id)
        .await
        .map_err(|e| e.to_string())?
    else {
        return Ok(None);
    };
    let results = db
        .list_check_results_for_run(&run.id)
        .await
        .map_err(|e| e.to_string())?;
    Ok(Some(TaskCheckRunView {
        id: run.id,
        task_id: run.task_id,
        status: run.status,
        summary: run.summary,
        created_at: run.created_at,
        results: results
            .into_iter()
            .map(|row| TaskCheckResultView {
                id: row.id,
                description: row.description,
                check_type: row.check_type,
                command: row.command,
                passed: row.passed,
                output: row.output,
                created_at: row.created_at,
            })
            .collect(),
    }))
}

pub async fn get_review_pack(
    task_id: String,
    state: &AppState,
) -> Result<Option<ReviewPackView>, String> {
    let db = {
        let current = state.current.lock().await;
        let ctx = current
            .as_ref()
            .ok_or_else(|| "no open project".to_string())?;
        ctx.db.clone()
    };
    let Some(review) = db
        .get_review_by_task(&task_id)
        .await
        .map_err(|e| e.to_string())?
    else {
        return Ok(None);
    };
    let pack_text = tokio::fs::read_to_string(&review.review_pack_path)
        .await
        .map_err(|e| e.to_string())?;
    let pack = serde_json::from_str::<serde_json::Value>(&pack_text).map_err(|e| e.to_string())?;
    Ok(Some(ReviewPackView {
        task_id: review.task_id,
        status: review.status,
        review_pack_path: review.review_pack_path,
        reviewer_notes: review.reviewer_notes,
        approved_at: review.approved_at,
        pack,
    }))
}

pub async fn approve_review(
    input: ReviewDecisionInput,
    emitter: &Arc<dyn EventEmitter>,
    state: &AppState,
) -> Result<(), String> {
    let (db, project_id) = {
        let current = state.current.lock().await;
        let ctx = current
            .as_ref()
            .ok_or_else(|| "no open project".to_string())?;
        (ctx.db.clone(), ctx.project_id)
    };
    let task_id = Uuid::parse_str(&input.task_id).map_err(|e| e.to_string())?;
    let Some(mut review) = db
        .get_review_by_task(&input.task_id)
        .await
        .map_err(|e| e.to_string())?
    else {
        return Err(format!("review pack not found for task {}", input.task_id));
    };
    review.status = "Approved".to_string();
    review.reviewer_notes = input.note.clone();
    review.approved_at = Some(Utc::now());
    db.upsert_review(&review).await.map_err(|e| e.to_string())?;

    db.upsert_merge_queue_item(&MergeQueueRow {
        id: Uuid::new_v4().to_string(),
        project_id: project_id.to_string(),
        task_id: input.task_id.clone(),
        status: "Queued".to_string(),
        blocked_reason: None,
        approved_at: review.approved_at.unwrap_or_else(Utc::now),
        started_at: None,
        completed_at: None,
    })
    .await
    .map_err(|e| e.to_string())?;

    append_event(
        &db,
        project_id,
        Some(task_id),
        None,
        "review",
        "ReviewApproved",
        json!({"task_id": input.task_id, "note": input.note}),
    )
    .await;
    emit_enriched_task_event(emitter, &db, &input.task_id).await;
    emitter.emit("merge_queue_updated", json!({"task_id": input.task_id}));
    Ok(())
}

pub async fn reject_review(
    input: ReviewDecisionInput,
    emitter: &Arc<dyn EventEmitter>,
    state: &AppState,
) -> Result<(), String> {
    let (db, project_id) = {
        let current = state.current.lock().await;
        let ctx = current
            .as_ref()
            .ok_or_else(|| "no open project".to_string())?;
        (ctx.db.clone(), ctx.project_id)
    };
    let task_id = Uuid::parse_str(&input.task_id).map_err(|e| e.to_string())?;
    if let Some(mut review) = db
        .get_review_by_task(&input.task_id)
        .await
        .map_err(|e| e.to_string())?
    {
        review.status = "Rejected".to_string();
        review.reviewer_notes = input.note.clone();
        db.upsert_review(&review).await.map_err(|e| e.to_string())?;
    }
    if let Some(mut task_row) = db
        .get_task(&input.task_id)
        .await
        .map_err(|e| e.to_string())?
    {
        task_row.status = "InProgress".to_string();
        task_row.updated_at = Utc::now();
        db.update_task(&task_row).await.map_err(|e| e.to_string())?;
    }
    append_event(
        &db,
        project_id,
        Some(task_id),
        None,
        "review",
        "ReviewRejected",
        json!({"task_id": input.task_id, "note": input.note}),
    )
    .await;
    emit_enriched_task_event(emitter, &db, &input.task_id).await;
    Ok(())
}

pub async fn list_merge_queue(state: &AppState) -> Result<Vec<MergeQueueItemView>, String> {
    let (db, project_id) = {
        let current = state.current.lock().await;
        let ctx = current
            .as_ref()
            .ok_or_else(|| "no open project".to_string())?;
        (ctx.db.clone(), ctx.project_id)
    };
    merge_queue_views(&db, project_id).await
}

async fn merge_queue_views(db: &Db, project_id: Uuid) -> Result<Vec<MergeQueueItemView>, String> {
    let rows = db
        .list_merge_queue(&project_id.to_string())
        .await
        .map_err(|e| e.to_string())?;
    let mut views = Vec::with_capacity(rows.len());
    for row in rows {
        let task_title = db
            .get_task(&row.task_id)
            .await
            .ok()
            .flatten()
            .map(|task| task.title)
            .unwrap_or_else(|| row.task_id.clone());
        views.push(MergeQueueItemView {
            id: row.id,
            task_id: row.task_id,
            task_title,
            status: row.status,
            blocked_reason: row.blocked_reason,
            approved_at: row.approved_at,
            started_at: row.started_at,
            completed_at: row.completed_at,
        });
    }
    Ok(views)
}

pub async fn move_merge_queue_item(
    input: MoveMergeQueueInput,
    emitter: &Arc<dyn EventEmitter>,
    state: &AppState,
) -> Result<Vec<MergeQueueItemView>, String> {
    let (db, project_id) = {
        let current = state.current.lock().await;
        let ctx = current
            .as_ref()
            .ok_or_else(|| "no open project".to_string())?;
        (ctx.db.clone(), ctx.project_id)
    };
    let mut rows = db
        .list_merge_queue(&project_id.to_string())
        .await
        .map_err(|e| e.to_string())?;
    let Some(index) = rows.iter().position(|row| row.task_id == input.task_id) else {
        return Err(format!("task not in merge queue: {}", input.task_id));
    };
    let target = input.direction.trim().to_ascii_lowercase();
    let swap_with = match target.as_str() {
        "up" if index > 0 => Some(index - 1),
        "down" if index + 1 < rows.len() => Some(index + 1),
        "up" | "down" => None,
        _ => return Err("direction must be 'up' or 'down'".to_string()),
    };
    if let Some(other_index) = swap_with {
        let first_time = rows[index].approved_at;
        let second_time = rows[other_index].approved_at;
        rows[index].approved_at = second_time;
        rows[other_index].approved_at = first_time;
        db.upsert_merge_queue_item(&rows[index])
            .await
            .map_err(|e| e.to_string())?;
        db.upsert_merge_queue_item(&rows[other_index])
            .await
            .map_err(|e| e.to_string())?;
        append_event(
            &db,
            project_id,
            Uuid::parse_str(&input.task_id).ok(),
            None,
            "review",
            "MergeQueueReordered",
            json!({"task_id": input.task_id, "direction": target}),
        )
        .await;
        emitter.emit("merge_queue_updated", json!({"ok": true}));
    }
    merge_queue_views(&db, project_id).await
}

pub async fn merge_queue_execute(
    task_id: String,
    emitter: &Arc<dyn EventEmitter>,
    state: &AppState,
) -> Result<(), String> {
    let (project_id, db, project_path, git, config, global_config) = {
        let current = state.current.lock().await;
        let ctx = current
            .as_ref()
            .ok_or_else(|| "no open project".to_string())?;
        (
            ctx.project_id,
            ctx.db.clone(),
            ctx.project_path.clone(),
            ctx.git.clone(),
            ctx.config.clone(),
            ctx.global_config.clone(),
        )
    };
    let target_branch = config.branches.target.clone();

    // CONCURRENCY: Two-level lock pattern — no deadlock risk because:
    // 1. The outer map lock (merge_branch_locks) is held only to clone the per-branch Arc,
    //    then immediately released before acquiring the inner per-branch Mutex.
    // 2. The inner per-branch Mutex guards only same-branch merge serialization.
    // Code paths never hold both locks simultaneously.
    let branch_lock = {
        let mut locks = state.merge_branch_locks.lock().await;
        locks
            .entry(target_branch.clone())
            .or_insert_with(|| std::sync::Arc::new(tokio::sync::Mutex::new(())))
            .clone()
    };
    let _branch_guard = branch_lock.lock().await;

    let Some(mut queue_item) = db
        .get_merge_queue_item_by_task(&task_id)
        .await
        .map_err(|e| e.to_string())?
    else {
        return Err(format!("task not in merge queue: {task_id}"));
    };
    queue_item.status = "Running".to_string();
    queue_item.started_at = Some(Utc::now());
    queue_item.blocked_reason = None;
    db.upsert_merge_queue_item(&queue_item)
        .await
        .map_err(|e| e.to_string())?;
    emitter.emit(
        "merge_queue_updated",
        json!({"task_id": task_id, "status": "Running"}),
    );

    let task_uuid = Uuid::parse_str(&task_id).map_err(|e| e.to_string())?;
    let mut task_row = db
        .get_task(&task_id)
        .await
        .map_err(|e| e.to_string())?
        .ok_or_else(|| format!("task not found: {task_id}"))?;
    let task = task_row_to_contract(&task_row)?;
    let worktree = db
        .find_worktree_by_task(&task_id)
        .await
        .map_err(|e| e.to_string())?
        .ok_or_else(|| "task worktree not found".to_string())?;
    let worktree_path = PathBuf::from(&worktree.path);

    let checkpoint_id = Uuid::new_v4().to_string();
    let checkpoint_ref = format!("pnevma/checkpoint/{checkpoint_id}");
    let _ = git_output(&project_path, &["tag", &checkpoint_ref]).await?;
    db.create_checkpoint(&CheckpointRow {
        id: checkpoint_id.clone(),
        project_id: project_id.to_string(),
        task_id: Some(task_id.clone()),
        git_ref: checkpoint_ref.clone(),
        session_metadata_json: "{}".to_string(),
        created_at: Utc::now(),
        description: Some("auto-checkpoint before merge queue execution".to_string()),
    })
    .await
    .map_err(|e| e.to_string())?;
    append_event(
        &db,
        project_id,
        Some(task_uuid),
        None,
        "core",
        "CheckpointCreated",
        json!({"checkpoint_id": checkpoint_id, "git_ref": checkpoint_ref}),
    )
    .await;

    let dirty = git_output(&worktree_path, &["status", "--porcelain"]).await?;
    if !dirty.trim().is_empty() {
        queue_item.status = "Blocked".to_string();
        queue_item.blocked_reason = Some("worktree has uncommitted changes".to_string());
        db.upsert_merge_queue_item(&queue_item)
            .await
            .map_err(|e| e.to_string())?;
        emitter.emit(
            "merge_queue_updated",
            json!({"task_id": task_id, "status": "Blocked"}),
        );
        return Err("merge blocked: worktree has uncommitted changes".to_string());
    }

    if let Err(err) = git_output(&worktree_path, &["rebase", &target_branch]).await {
        let conflicts = git_output(&worktree_path, &["diff", "--name-only", "--diff-filter=U"])
            .await
            .unwrap_or_default();
        queue_item.status = "Blocked".to_string();
        queue_item.blocked_reason = Some(format!(
            "rebase conflict: {}",
            conflicts.lines().collect::<Vec<_>>().join(", ")
        ));
        db.upsert_merge_queue_item(&queue_item)
            .await
            .map_err(|e| e.to_string())?;
        emitter.emit(
            "merge_queue_updated",
            json!({"task_id": task_id, "status": "Blocked"}),
        );
        append_event(
            &db,
            project_id,
            Some(task_uuid),
            None,
            "git",
            "ConflictDetected",
            json!({"task_id": task_id, "error": err, "conflicts": conflicts}),
        )
        .await;
        return Err("merge blocked by rebase conflicts".to_string());
    }

    let (_, _, checks_ok) =
        run_acceptance_checks_for_task(&db, project_id, &project_path, &task).await?;
    if !checks_ok {
        queue_item.status = "Blocked".to_string();
        queue_item.blocked_reason = Some("automated checks failed after rebase".to_string());
        db.upsert_merge_queue_item(&queue_item)
            .await
            .map_err(|e| e.to_string())?;
        emitter.emit(
            "merge_queue_updated",
            json!({"task_id": task_id, "status": "Blocked"}),
        );
        return Err("merge blocked: checks failed".to_string());
    }

    let _ = git_output(&project_path, &["checkout", &target_branch]).await?;
    if let Err(ff_err) = git_output(&project_path, &["merge", "--ff-only", &worktree.branch]).await
    {
        let _ = git_output(
            &project_path,
            &[
                "merge",
                "--no-ff",
                "-m",
                &format!("Merge task {}", task_id),
                &worktree.branch,
            ],
        )
        .await
        .map_err(|merge_err| {
            format!("ff merge failed: {ff_err}; merge commit failed: {merge_err}")
        })?;
    }

    task_row.status = "Done".to_string();
    task_row.updated_at = Utc::now();
    db.update_task(&task_row).await.map_err(|e| e.to_string())?;
    cleanup_task_worktree(&db, &git, project_id, task_uuid, Some(emitter)).await?;

    queue_item.status = "Merged".to_string();
    queue_item.completed_at = Some(Utc::now());
    queue_item.blocked_reason = None;
    db.upsert_merge_queue_item(&queue_item)
        .await
        .map_err(|e| e.to_string())?;
    emitter.emit(
        "merge_queue_updated",
        json!({"task_id": task_id, "status": "Completed"}),
    );
    append_event(
        &db,
        project_id,
        Some(task_uuid),
        None,
        "git",
        "MergeCompleted",
        json!({"task_id": task_id, "target_branch": target_branch}),
    )
    .await;
    append_telemetry_event(
        &db,
        project_id,
        &global_config,
        "merge.completed",
        json!({"task_id": task_id, "target_branch": target_branch}),
    )
    .await;
    emit_enriched_task_event(emitter, &db, &task_id).await;
    emitter.emit(
        "knowledge_capture_requested",
        json!({"task_id": task_id, "kinds": ["adr", "changelog", "convention-update"]}),
    );
    Ok(())
}

pub async fn list_conflicts(task_id: String, state: &AppState) -> Result<Vec<String>, String> {
    let db = {
        let current = state.current.lock().await;
        let ctx = current
            .as_ref()
            .ok_or_else(|| "no open project".to_string())?;
        ctx.db.clone()
    };
    let Some(worktree) = db
        .find_worktree_by_task(&task_id)
        .await
        .map_err(|e| e.to_string())?
    else {
        return Ok(Vec::new());
    };
    let out = git_output(
        Path::new(&worktree.path),
        &["diff", "--name-only", "--diff-filter=U"],
    )
    .await?;
    Ok(out
        .lines()
        .map(str::trim)
        .filter(|line| !line.is_empty())
        .map(ToString::to_string)
        .collect())
}

pub async fn resolve_conflicts_manual(task_id: String, state: &AppState) -> Result<String, String> {
    let db = {
        let current = state.current.lock().await;
        let ctx = current
            .as_ref()
            .ok_or_else(|| "no open project".to_string())?;
        ctx.db.clone()
    };
    let worktree = db
        .find_worktree_by_task(&task_id)
        .await
        .map_err(|e| e.to_string())?
        .ok_or_else(|| format!("worktree not found for task {task_id}"))?;
    Ok(worktree.path)
}

pub async fn redispatch_with_conflict_context(
    task_id: String,
    emitter: &Arc<dyn EventEmitter>,
    state: &AppState,
) -> Result<String, String> {
    let (db, project_id) = {
        let current = state.current.lock().await;
        let ctx = current
            .as_ref()
            .ok_or_else(|| "no open project".to_string())?;
        (ctx.db.clone(), ctx.project_id)
    };
    let conflicts = list_conflicts(task_id.clone(), state)
        .await
        .unwrap_or_default();
    if let Some(mut row) = db.get_task(&task_id).await.map_err(|e| e.to_string())? {
        let prior = row.handoff_summary.unwrap_or_default();
        row.handoff_summary = Some(format!(
            "{prior}\nConflict files:\n{}",
            conflicts
                .iter()
                .map(|v| format!("- {v}"))
                .collect::<Vec<_>>()
                .join("\n")
        ));
        row.status = "Ready".to_string();
        row.updated_at = Utc::now();
        db.update_task(&row).await.map_err(|e| e.to_string())?;
    }
    append_event(
        &db,
        project_id,
        Uuid::parse_str(&task_id).ok(),
        None,
        "git",
        "ConflictRedispatchRequested",
        json!({"task_id": task_id, "conflicts": conflicts}),
    )
    .await;
    dispatch_task(task_id, emitter, state).await
}

pub async fn secrets_set_ref(
    input: SecretRefInput,
    state: &AppState,
) -> Result<SecretRefView, String> {
    pnevma_agents::validate_agent_env_entry(&input.name, &input.value)?;

    let (db, project_id, sessions, redaction_secrets) = {
        let current = state.current.lock().await;
        let ctx = current
            .as_ref()
            .ok_or_else(|| "no open project".to_string())?;
        (
            ctx.db.clone(),
            ctx.project_id,
            ctx.sessions.clone(),
            Arc::clone(&ctx.redaction_secrets),
        )
    };
    let scope = if input.scope.eq_ignore_ascii_case("global") {
        "global".to_string()
    } else {
        "project".to_string()
    };
    let project_scope_id = if scope == "project" {
        Some(project_id.to_string())
    } else {
        None
    };
    let service = if let Some(project_scope_id) = &project_scope_id {
        format!("pnevma.{scope}.{project_scope_id}")
    } else {
        format!("pnevma.{scope}")
    };
    let account = input.name.clone();
    store_keychain_secret(&service, &account, &input.value).await?;

    let now = Utc::now();
    let row = SecretRefRow {
        id: Uuid::new_v4().to_string(),
        project_id: project_scope_id.clone(),
        scope: scope.clone(),
        name: input.name.clone(),
        keychain_service: service.clone(),
        keychain_account: account.clone(),
        created_at: now,
        updated_at: now,
    };
    db.upsert_secret_ref(&row)
        .await
        .map_err(|e| e.to_string())?;
    let updated_redaction_secrets = load_redaction_secrets(&db, project_id).await;
    register_project_redaction_secrets(project_id, &updated_redaction_secrets);
    sessions
        .set_redaction_secrets(updated_redaction_secrets.clone())
        .await;
    *redaction_secrets.write().await = updated_redaction_secrets;
    Ok(SecretRefView {
        id: row.id,
        project_id: row.project_id,
        scope: row.scope,
        name: row.name,
        keychain_service: row.keychain_service,
        keychain_account: row.keychain_account,
        created_at: row.created_at,
        updated_at: row.updated_at,
    })
}

pub async fn secrets_list(
    scope: Option<String>,
    state: &AppState,
) -> Result<Vec<SecretRefView>, String> {
    let (db, project_id) = {
        let current = state.current.lock().await;
        let ctx = current
            .as_ref()
            .ok_or_else(|| "no open project".to_string())?;
        (ctx.db.clone(), ctx.project_id)
    };
    let rows = db
        .list_secret_refs(&project_id.to_string(), scope.as_deref())
        .await
        .map_err(|e| e.to_string())?;
    Ok(rows
        .into_iter()
        .map(|row| SecretRefView {
            id: row.id,
            project_id: row.project_id,
            scope: row.scope,
            name: row.name,
            keychain_service: row.keychain_service,
            keychain_account: row.keychain_account,
            created_at: row.created_at,
            updated_at: row.updated_at,
        })
        .collect())
}

pub async fn checkpoint_create(
    input: CheckpointInput,
    state: &AppState,
) -> Result<CheckpointView, String> {
    let (db, project_id, project_path) = {
        let current = state.current.lock().await;
        let ctx = current
            .as_ref()
            .ok_or_else(|| "no open project".to_string())?;
        (ctx.db.clone(), ctx.project_id, ctx.project_path.clone())
    };
    let checkpoint_id = Uuid::new_v4().to_string();
    let git_ref = format!("pnevma/checkpoint/{checkpoint_id}");
    let _ = git_output(&project_path, &["tag", &git_ref]).await?;
    let sessions = db
        .list_sessions(&project_id.to_string())
        .await
        .map_err(|e| e.to_string())?;
    let session_json = serde_json::to_string(&sessions).map_err(|e| e.to_string())?;
    let row = CheckpointRow {
        id: checkpoint_id.clone(),
        project_id: project_id.to_string(),
        task_id: input.task_id.clone(),
        git_ref: git_ref.clone(),
        session_metadata_json: session_json,
        created_at: Utc::now(),
        description: input.description.clone(),
    };
    db.create_checkpoint(&row)
        .await
        .map_err(|e| e.to_string())?;
    Ok(CheckpointView {
        id: row.id,
        task_id: row.task_id,
        git_ref: row.git_ref,
        created_at: row.created_at,
        description: row.description,
    })
}

pub async fn checkpoint_list(state: &AppState) -> Result<Vec<CheckpointView>, String> {
    let (db, project_id) = {
        let current = state.current.lock().await;
        let ctx = current
            .as_ref()
            .ok_or_else(|| "no open project".to_string())?;
        (ctx.db.clone(), ctx.project_id)
    };
    let rows = db
        .list_checkpoints(&project_id.to_string())
        .await
        .map_err(|e| e.to_string())?;
    Ok(rows
        .into_iter()
        .map(|row| CheckpointView {
            id: row.id,
            task_id: row.task_id,
            git_ref: row.git_ref,
            created_at: row.created_at,
            description: row.description,
        })
        .collect())
}

pub async fn checkpoint_restore(
    checkpoint_id: String,
    emitter: &Arc<dyn EventEmitter>,
    state: &AppState,
) -> Result<(), String> {
    let (db, project_id, project_path) = {
        let current = state.current.lock().await;
        let ctx = current
            .as_ref()
            .ok_or_else(|| "no open project".to_string())?;
        (ctx.db.clone(), ctx.project_id, ctx.project_path.clone())
    };

    // Guard: reject restore if any sessions are running
    let sessions = db
        .list_sessions(&project_id.to_string())
        .await
        .map_err(|e| e.to_string())?;
    if sessions.iter().any(|s| s.status == "running") {
        return Err(
            "cannot restore checkpoint while sessions are running — stop all sessions first"
                .to_string(),
        );
    }

    let row = db
        .get_checkpoint(&checkpoint_id)
        .await
        .map_err(|e| e.to_string())?
        .ok_or_else(|| format!("checkpoint not found: {checkpoint_id}"))?;
    let _ = git_output(&project_path, &["reset", "--hard", &row.git_ref]).await?;
    append_event(
        &db,
        project_id,
        row.task_id.as_deref().and_then(|v| Uuid::parse_str(v).ok()),
        None,
        "core",
        "CheckpointRestored",
        json!({"checkpoint_id": checkpoint_id, "git_ref": row.git_ref}),
    )
    .await;
    emitter.emit("project_refreshed", json!({"checkpoint_id": checkpoint_id}));
    Ok(())
}

pub async fn create_task(
    input: CreateTaskInput,
    emitter: &Arc<dyn EventEmitter>,
    state: &AppState,
) -> Result<String, String> {
    let (project_id, db, project_path, global_config) = {
        let current = state.current.lock().await;
        let ctx = current
            .as_ref()
            .ok_or_else(|| "no open project".to_string())?;
        (
            ctx.project_id,
            ctx.db.clone(),
            ctx.project_path.clone(),
            ctx.global_config.clone(),
        )
    };

    let id = Uuid::new_v4();
    let now = Utc::now();
    let deps = parse_dependency_ids(&input.dependencies)?;
    validate_task_dependencies(&db, project_id, id, &deps).await?;

    let mut task = TaskContract {
        id,
        title: input.title.clone(),
        goal: input.goal.clone(),
        scope: input.scope.clone(),
        out_of_scope: Vec::new(),
        dependencies: deps,
        acceptance_criteria: input
            .acceptance_criteria
            .iter()
            .map(|description| Check {
                description: description.clone(),
                check_type: CheckType::ManualApproval,
                command: None,
            })
            .collect(),
        constraints: input.constraints.clone(),
        priority: map_priority(&input.priority),
        status: TaskStatus::Planned,
        assigned_session: None,
        branch: None,
        worktree: None,
        prompt_pack: None,
        handoff_summary: None,
        auto_dispatch: input.auto_dispatch.unwrap_or(false),
        agent_profile_override: input.agent_profile_override.clone(),
        execution_mode: input.execution_mode.clone(),
        timeout_minutes: input.timeout_minutes,
        max_retries: input.max_retries,
        loop_iteration: 0,
        loop_context_json: None,
        created_at: now,
        updated_at: now,
    };

    task.validate_new().map_err(|e| e.to_string())?;
    let existing = db
        .list_tasks(&project_id.to_string())
        .await
        .map_err(|e| e.to_string())?;
    let completed = existing
        .iter()
        .filter(|row| row.status == "Done")
        .filter_map(|row| Uuid::parse_str(&row.id).ok())
        .collect::<HashSet<_>>();
    task.refresh_blocked_status(&completed);

    if task.status == TaskStatus::Ready {
        if task.acceptance_criteria.is_empty() {
            return Err("task must include at least one acceptance criterion".to_string());
        }
        for rel in &task.scope {
            if !project_path.join(rel).exists() {
                return Err(format!("scope file does not exist: {rel}"));
            }
        }
    }

    let row = task_contract_to_row(&task, &project_id.to_string())?;
    db.create_task(&row).await.map_err(|e| e.to_string())?;
    db.replace_task_dependencies(
        &row.id,
        &task
            .dependencies
            .iter()
            .map(ToString::to_string)
            .collect::<Vec<_>>(),
    )
    .await
    .map_err(|e| e.to_string())?;
    append_event(
        &db,
        project_id,
        Some(id),
        None,
        "core",
        "TaskCreated",
        json!({"title": row.title}),
    )
    .await;
    append_telemetry_event(
        &db,
        project_id,
        &global_config,
        "task.create",
        json!({"task_id": id.to_string(), "priority": row.priority}),
    )
    .await;
    refresh_dependency_states(&db, project_id, Some(emitter), state).await?;
    emit_enriched_task_event(emitter, &db, &id.to_string()).await;

    Ok(id.to_string())
}

pub async fn list_tasks(state: &AppState) -> Result<Vec<TaskView>, String> {
    let (project_id, db) = {
        let current = state.current.lock().await;
        let ctx = current
            .as_ref()
            .ok_or_else(|| "no open project".to_string())?;
        (ctx.project_id, ctx.db.clone())
    };

    let rows = db
        .list_tasks(&project_id.to_string())
        .await
        .map_err(|e| e.to_string())?;
    let mut out = Vec::with_capacity(rows.len());
    for row in rows {
        let cost = db.task_cost_total(&row.id).await.ok();
        out.push(task_row_to_view(row, cost)?);
    }
    Ok(out)
}

pub async fn get_task(task_id: String, state: &AppState) -> Result<TaskView, String> {
    let db = {
        let current = state.current.lock().await;
        let ctx = current
            .as_ref()
            .ok_or_else(|| "no open project".to_string())?;
        ctx.db.clone()
    };
    let row = db
        .get_task(&task_id)
        .await
        .map_err(|e| e.to_string())?
        .ok_or_else(|| format!("task not found: {task_id}"))?;
    let cost = db.task_cost_total(&task_id).await.ok();
    task_row_to_view(row, cost)
}

pub async fn update_task(
    input: UpdateTaskInput,
    emitter: &Arc<dyn EventEmitter>,
    state: &AppState,
) -> Result<TaskView, String> {
    let (project_id, db, project_path, git) = {
        let current = state.current.lock().await;
        let ctx = current
            .as_ref()
            .ok_or_else(|| "no open project".to_string())?;
        (
            ctx.project_id,
            ctx.db.clone(),
            ctx.project_path.clone(),
            ctx.git.clone(),
        )
    };

    let existing = db
        .get_task(&input.id)
        .await
        .map_err(|e| e.to_string())?
        .ok_or_else(|| format!("task not found: {}", input.id))?;
    let mut task = task_row_to_contract(&existing)?;
    let previous_status = task.status.clone();

    if let Some(title) = input.title {
        task.title = title;
    }
    if let Some(goal) = input.goal {
        task.goal = goal;
    }
    if let Some(scope) = input.scope {
        task.scope = scope;
    }
    if let Some(criteria) = input.acceptance_criteria {
        task.acceptance_criteria = criteria
            .into_iter()
            .map(|description| Check {
                description,
                check_type: CheckType::ManualApproval,
                command: None,
            })
            .collect();
    }
    if let Some(constraints) = input.constraints {
        task.constraints = constraints;
    }
    if let Some(priority) = input.priority {
        task.priority = map_priority(&priority);
    }
    if let Some(handoff) = input.handoff_summary {
        task.handoff_summary = Some(handoff);
    }
    if let Some(dependencies) = input.dependencies {
        task.dependencies = parse_dependency_ids(&dependencies)?;
        validate_task_dependencies(&db, project_id, task.id, &task.dependencies).await?;
    }
    if let Some(status) = input.status {
        let target = parse_status(&status);
        if target != task.status {
            task.transition(target).map_err(|e| e.to_string())?;
        }
    }

    if task.status == TaskStatus::Ready {
        if task.acceptance_criteria.is_empty() {
            return Err("acceptance_criteria is required before Ready".to_string());
        }
        for rel in &task.scope {
            if !project_path.join(rel).exists() {
                return Err(format!("scope file does not exist: {rel}"));
            }
        }
    }

    let all = db
        .list_tasks(&project_id.to_string())
        .await
        .map_err(|e| e.to_string())?;
    let completed = all
        .iter()
        .filter(|row| row.status == "Done")
        .filter_map(|row| Uuid::parse_str(&row.id).ok())
        .collect::<HashSet<_>>();
    task.refresh_blocked_status(&completed);
    validate_task_dependencies(&db, project_id, task.id, &task.dependencies).await?;
    task.validate_new().map_err(|e| e.to_string())?;
    task.updated_at = Utc::now();

    let row = task_contract_to_row(&task, &project_id.to_string())?;
    db.update_task(&row).await.map_err(|e| e.to_string())?;
    db.replace_task_dependencies(
        &row.id,
        &task
            .dependencies
            .iter()
            .map(ToString::to_string)
            .collect::<Vec<_>>(),
    )
    .await
    .map_err(|e| e.to_string())?;
    refresh_dependency_states(&db, project_id, Some(emitter), state).await?;
    emit_task_updated(&db, project_id, task.id).await;
    emit_enriched_task_event(emitter, &db, &row.id).await;
    if previous_status != task.status && is_terminal_task_status(&task.status) {
        cleanup_task_worktree(&db, &git, project_id, task.id, Some(emitter)).await?;
        let loop_triggered = check_loop_trigger(
            &db,
            &row.id,
            &task.status,
            &project_path,
            state.global_db.as_ref(),
        )
        .await
        .unwrap_or_else(|e| {
            tracing::warn!(task_id = %row.id, error = %e, "check_loop_trigger failed");
            false
        });
        if loop_triggered {
            // Refresh deps to unblock/auto-dispatch newly created loop tasks
            refresh_dependency_states(&db, project_id, Some(emitter), state).await?;
        } else {
            check_workflow_completion(&db, &row.id).await;
        }
    }
    task_row_to_view(row.clone(), db.task_cost_total(&row.id).await.ok())
}

pub async fn delete_task(
    task_id: String,
    emitter: &Arc<dyn EventEmitter>,
    state: &AppState,
) -> Result<(), String> {
    let (project_id, db, git) = {
        let current = state.current.lock().await;
        let ctx = current
            .as_ref()
            .ok_or_else(|| "no open project".to_string())?;
        (ctx.project_id, ctx.db.clone(), ctx.git.clone())
    };

    if let Ok(task_uuid) = Uuid::parse_str(&task_id) {
        let _ = cleanup_task_worktree(&db, &git, project_id, task_uuid, Some(emitter)).await;
    }
    db.delete_task(&task_id).await.map_err(|e| e.to_string())?;
    append_event(
        &db,
        project_id,
        Uuid::parse_str(&task_id).ok(),
        None,
        "core",
        "TaskDeleted",
        json!({"task_id": task_id}),
    )
    .await;
    refresh_dependency_states(&db, project_id, Some(emitter), state).await?;
    emitter.emit("task_updated", json!({"task_id": task_id, "deleted": true}));
    Ok(())
}

pub async fn dispatch_task(
    task_id: String,
    emitter: &Arc<dyn EventEmitter>,
    state: &AppState,
) -> Result<String, String> {
    let (
        project_id,
        db,
        project_path,
        config,
        global_config,
        pool,
        adapters,
        git,
        redaction_secrets,
    ) = {
        let current = state.current.lock().await;
        let ctx = current
            .as_ref()
            .ok_or_else(|| "no open project".to_string())?;
        (
            ctx.project_id,
            ctx.db.clone(),
            ctx.project_path.clone(),
            ctx.config.clone(),
            ctx.global_config.clone(),
            ctx.pool.clone(),
            ctx.adapters.clone(),
            ctx.git.clone(),
            Arc::clone(&ctx.redaction_secrets),
        )
    };

    let task_id_uuid = Uuid::parse_str(&task_id).map_err(|e| e.to_string())?;
    let row = db
        .get_task(&task_id)
        .await
        .map_err(|e| e.to_string())?
        .ok_or_else(|| format!("task not found: {task_id}"))?;
    let mut task = task_row_to_contract(&row)?;
    if task.status != TaskStatus::Ready {
        return Err(format!(
            "task must be Ready before dispatch (current: {})",
            status_to_str(&task.status)
        ));
    }

    let queued = QueuedDispatch {
        task_id: task_id_uuid,
        priority: task.priority.clone(),
    };

    let permit = match pool.try_acquire(queued).await {
        Ok(permit) => permit,
        Err(position) => {
            emitter.emit(
                "task_queue_updated",
                json!({"task_id": task_id, "queued_position": position}),
            );
            return Ok(format!("queued:{position}"));
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
            return Err(format!(
                "agent profile override '{}' not found",
                override_name
            ));
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

    let adapter = adapters
        .get(&provider)
        .ok_or_else(|| "no available agent adapters found".to_string())?;

    let execution_mode = row.execution_mode.as_deref().unwrap_or("worktree");
    let use_worktree = execution_mode != "main";

    let working_dir: String;
    if use_worktree {
        let slug = slugify_with_fallback(&task.title, "task");
        let lease = git
            .create_worktree(task_id_uuid, &config.branches.target, &slug)
            .await
            .map_err(|e| e.to_string())?;
        let worktree_row = WorktreeRow {
            id: lease.id.to_string(),
            project_id: project_id.to_string(),
            task_id: task_id.clone(),
            path: lease.path.clone(),
            branch: lease.branch.clone(),
            lease_status: "Active".to_string(),
            lease_started: lease.started_at,
            last_active: lease.last_active,
        };
        db.upsert_worktree(&worktree_row)
            .await
            .map_err(|e| e.to_string())?;
        working_dir = lease.path.clone();
        task.branch = Some(lease.branch.clone());
        task.worktree = Some(worktree_row.id.clone());
    } else {
        working_dir = project_path.to_string_lossy().to_string();
    }

    task.transition(TaskStatus::InProgress)
        .map_err(|e| e.to_string())?;
    let task_row = task_contract_to_row(&task, &project_id.to_string())?;
    db.update_task(&task_row).await.map_err(|e| e.to_string())?;
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

    ensure_scope_rows_from_config(&db, project_id, &project_path, &config, "rule").await?;
    ensure_scope_rows_from_config(&db, project_id, &project_path, &config, "convention").await?;
    let mut rules = load_active_scope_texts(&db, project_id, &project_path, "rule").await?;
    if rules.is_empty() {
        rules = load_texts(&config.rules.paths, &project_path).await;
    }
    let mut conventions =
        load_active_scope_texts(&db, project_id, &project_path, "convention").await?;
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
        .map_err(|e| e.to_string())?;
    let context_path = PathBuf::from(&working_dir)
        .join(".pnevma")
        .join("task-context.md");
    let redacted_context_markdown = redact_text(&ctx_result.markdown, &secret_values);
    compiler
        .write_markdown(&redacted_context_markdown, &context_path)
        .map_err(|e| e.to_string())?;
    let manifest_path = PathBuf::from(&working_dir)
        .join(".pnevma")
        .join("task-context.manifest.json");
    let redacted_manifest = redact_json_value(
        serde_json::to_value(&ctx_result.pack.manifest).map_err(|e| e.to_string())?,
        &secret_values,
    );
    tokio::fs::write(
        &manifest_path,
        serde_json::to_string_pretty(&redacted_manifest).map_err(|e| e.to_string())?,
    )
    .await
    .map_err(|e| e.to_string())?;
    let context_run_id = format!("{}:{}", task.id, Utc::now().timestamp_millis());
    let scoped_rows = db
        .list_rules(&project_id.to_string(), None)
        .await
        .map_err(|e| e.to_string())?;
    for row in scoped_rows {
        let included = row.active;
        let reason = if included { "active" } else { "disabled" };
        let _ = db
            .create_context_rule_usage(&ContextRuleUsageRow {
                id: Uuid::new_v4().to_string(),
                project_id: project_id.to_string(),
                run_id: context_run_id.clone(),
                rule_id: row.id,
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

    let handle = adapter
        .spawn(AgentConfig {
            provider: provider.clone(),
            model,
            env: secret_env,
            working_dir: working_dir.clone(),
            timeout_minutes,
            auto_approve,
            output_format: "stream-json".to_string(),
            context_file: Some(context_path.to_string_lossy().to_string()),
        })
        .await
        .map_err(|e| e.to_string())?;

    let agent_session_row = SessionRow {
        id: handle.id.to_string(),
        project_id: project_id.to_string(),
        name: format!("agent-{}", task.title),
        r#type: Some("agent".to_string()),
        status: "running".to_string(),
        pid: None,
        cwd: working_dir.clone(),
        command: provider.clone(),
        branch: task.branch.clone(),
        worktree_id: task.worktree.clone(),
        started_at: Utc::now(),
        last_heartbeat: Utc::now(),
    };
    db.upsert_session(&agent_session_row)
        .await
        .map_err(|e| e.to_string())?;
    let pane = PaneRow {
        id: Uuid::new_v4().to_string(),
        project_id: project_id.to_string(),
        session_id: Some(handle.id.to_string()),
        r#type: "terminal".to_string(),
        position: "after:pane-board".to_string(),
        label: format!("Agent {}", task.title),
        metadata_json: Some("{\"read_only\":true}".to_string()),
    };
    db.upsert_pane(&pane).await.map_err(|e| e.to_string())?;
    emitter.emit(
        "session_spawned",
        json!({
            "project_id": project_id,
            "session_id": handle.id.to_string(),
            "name": agent_session_row.name,
            "session": session_row_to_event_payload(&agent_session_row)
        }),
    );
    let mut rx = adapter.events(&handle);
    let payload = TaskPayload {
        task_id: task_id_uuid,
        objective: task.goal.clone(),
        constraints: task.constraints.clone(),
        project_rules: rules.clone(),
        worktree_path: working_dir.clone(),
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
    let permit_holder = Arc::new(std::sync::Mutex::new(Some(permit)));
    let db_for_task = db.clone();
    let app_for_task = Arc::clone(emitter);
    let git_for_task = git.clone();
    let lease_task_id = task_id_uuid;
    let provider_for_task = provider.clone();
    let session_id = handle.id.to_string();
    let session_uuid_for_task = handle.id;
    let project_path_for_task = project_path.clone();
    let global_db_for_task = state.global_db.clone();
    let target_branch_for_task = config.branches.target.clone();
    let redaction_secrets_for_task = Arc::clone(&redaction_secrets);
    let permit_holder_for_task = Arc::clone(&permit_holder);

    let event_task = tokio::spawn(async move {
        let mut last_summary: Option<String> = None;
        let mut failed = false;
        let mut output_redactor = StreamRedactor::new(Arc::clone(&redaction_secrets_for_task));

        while let Ok(event) = rx.recv().await {
            match event {
                AgentEvent::OutputChunk(chunk) => {
                    if let Some(safe_chunk) = output_redactor.push_chunk(&chunk).await {
                        app_for_task.emit(
                            "session_output",
                            json!({"session_id": session_id, "chunk": safe_chunk.clone()}),
                        );
                        append_event(
                            &db_for_task,
                            project_id,
                            Some(lease_task_id),
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
                                current_redaction_secrets(&redaction_secrets_for_task).await;
                            let _ = create_notification_row(
                                &db_for_task,
                                &app_for_task,
                                project_id,
                                Some(lease_task_id),
                                Some(session_uuid_for_task),
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
                AgentEvent::ToolUse {
                    name,
                    input,
                    output,
                } => {
                    let current_secrets =
                        current_redaction_secrets(&redaction_secrets_for_task).await;
                    append_event(
                        &db_for_task,
                        project_id,
                        Some(lease_task_id),
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
                AgentEvent::UsageUpdate {
                    tokens_in,
                    tokens_out,
                    cost_usd,
                } => {
                    let _ = db_for_task
                        .append_cost(&CostRow {
                            id: Uuid::new_v4().to_string(),
                            agent_run_id: None,
                            task_id: lease_task_id.to_string(),
                            session_id: session_id.clone(),
                            provider: provider_for_task.clone(),
                            model: None,
                            tokens_in: tokens_in as i64,
                            tokens_out: tokens_out as i64,
                            estimated_usd: cost_usd,
                            tracked: true,
                            timestamp: Utc::now(),
                        })
                        .await;
                    app_for_task.emit(
                        "cost_updated",
                        json!({"task_id": lease_task_id.to_string(), "cost_usd": cost_usd}),
                    );
                }
                AgentEvent::Error(message) => {
                    failed = true;
                    let current_secrets =
                        current_redaction_secrets(&redaction_secrets_for_task).await;
                    last_summary = Some(redact_text(&message, &current_secrets));
                    break;
                }
                AgentEvent::Complete { summary } => {
                    let current_secrets =
                        current_redaction_secrets(&redaction_secrets_for_task).await;
                    last_summary = Some(redact_text(&summary, &current_secrets));
                    break;
                }
                AgentEvent::StatusChange(_) => {}
            }
        }
        if let Some(safe_chunk) = output_redactor.finish().await {
            app_for_task.emit(
                "session_output",
                json!({"session_id": session_id, "chunk": safe_chunk.clone()}),
            );
            append_event(
                &db_for_task,
                project_id,
                Some(lease_task_id),
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
                let current_secrets = current_redaction_secrets(&redaction_secrets_for_task).await;
                let _ = create_notification_row(
                    &db_for_task,
                    &app_for_task,
                    project_id,
                    Some(lease_task_id),
                    Some(session_uuid_for_task),
                    osc_title(&attention.code),
                    &body,
                    Some(osc_level(&attention.code)),
                    "osc",
                    &current_secrets,
                )
                .await;
            }
        }
        drop(
            permit_holder_for_task
                .lock()
                .expect("permit lock poisoned")
                .take(),
        );
        if let Ok(Some(mut row)) = db_for_task.get_task(&lease_task_id.to_string()).await {
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
                    match run_acceptance_checks_for_task(
                        &db_for_task,
                        project_id,
                        &project_path_for_task,
                        &task_contract,
                    )
                    .await
                    {
                        Ok((check_run, check_results, all_automated_passed)) => {
                            if all_automated_passed {
                                let current_secrets =
                                    current_redaction_secrets(&redaction_secrets_for_task).await;
                                let cost = db_for_task
                                    .task_cost_total(&lease_task_id.to_string())
                                    .await
                                    .unwrap_or(0.0);
                                if generate_review_pack(
                                    &db_for_task,
                                    project_id,
                                    &project_path_for_task,
                                    &target_branch_for_task,
                                    &task_contract,
                                    &check_run,
                                    &check_results,
                                    cost,
                                    last_summary.as_deref(),
                                    &current_secrets,
                                )
                                .await
                                .is_ok()
                                {
                                    next_status = TaskStatus::Review;
                                }
                            }
                        }
                        Err(err) => {
                            let current_secrets =
                                current_redaction_secrets(&redaction_secrets_for_task).await;
                            append_event(
                                &db_for_task,
                                project_id,
                                Some(lease_task_id),
                                None,
                                "core",
                                "AcceptanceCheckRunFailed",
                                json!({
                                    "task_id": lease_task_id,
                                    "error": redact_text(&err, &current_secrets)
                                }),
                            )
                            .await;
                        }
                    }
                }
            }

            row.status = status_to_str(&next_status).to_string();
            row.updated_at = Utc::now();
            let _ = db_for_task.update_task(&row).await;
            if is_terminal_task_status(&next_status) {
                let loop_triggered = check_loop_trigger(
                    &db_for_task,
                    &row.id,
                    &next_status,
                    &project_path_for_task,
                    global_db_for_task.as_ref(),
                )
                .await
                .unwrap_or_else(|e| {
                    tracing::warn!(task_id = %row.id, error = %e, "check_loop_trigger failed");
                    false
                });
                if !loop_triggered {
                    check_workflow_completion(&db_for_task, &row.id).await;
                }
                // Note: Loop tasks are created as Ready when their pre-loop deps
                // are satisfied (see create_loop_iteration). The auto_dispatch
                // background loop picks them up for dispatch.
            }
            if prev_status != next_status {
                append_event(
                    &db_for_task,
                    project_id,
                    Some(lease_task_id),
                    None,
                    "core",
                    "TaskStatusChanged",
                    json!({
                        "task_id": lease_task_id,
                        "from": status_to_str(&prev_status),
                        "to": status_to_str(&next_status),
                        "reason": "agent_completion"
                    }),
                )
                .await;
            }
            emit_enriched_task_event(&app_for_task, &db_for_task, &row.id).await;
        }
        if failed {
            let _ = cleanup_task_worktree(
                &db_for_task,
                &git_for_task,
                project_id,
                lease_task_id,
                Some(&app_for_task),
            )
            .await;

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
                    canonical_message: normalized,
                    category: category.to_string(),
                    first_seen: now,
                    last_seen: now,
                    total_count: 1,
                    sample_output: Some(summary.clone()),
                    remediation_hint: hint.map(|s| s.to_string()),
                };
                let _ = db_for_task.upsert_error_signature(&sig_row).await;
                let date_str = now.format("%Y-%m-%d").to_string();
                let _ = db_for_task
                    .increment_error_signature_daily(&sig_row.id, &date_str)
                    .await;
            }
        }
        app_for_task.emit(
            "pool_updated",
            json!({"state": db_for_task.path().to_string_lossy()}),
        );
        append_event(
            &db_for_task,
            project_id,
            Some(lease_task_id),
            None,
            "agent",
            "AgentComplete",
            json!({
                "task_id": lease_task_id,
                "failed": failed,
                "handoff_summary": last_summary
            }),
        )
        .await;
    });

    if let Err(err) = adapter.send(&handle, payload).await {
        event_task.abort();
        drop(permit_holder.lock().expect("permit lock poisoned").take());

        let error = err.to_string();
        let failed_summary = redact_text(&error, &secret_values);

        if let Ok(Some(mut row)) = db.get_task(&task_id_uuid.to_string()).await {
            row.status = status_to_str(&TaskStatus::Failed).to_string();
            row.handoff_summary = Some(failed_summary.clone());
            row.updated_at = Utc::now();
            let _ = db.update_task(&row).await;
            emit_enriched_task_event(emitter, &db, &row.id).await;
        }

        let mut failed_session_row = agent_session_row.clone();
        failed_session_row.status = "failed".to_string();
        failed_session_row.last_heartbeat = Utc::now();
        let _ = db.upsert_session(&failed_session_row).await;

        let _ = cleanup_task_worktree(&db, &git, project_id, task_id_uuid, Some(emitter)).await;

        append_event(
            &db,
            project_id,
            Some(task_id_uuid),
            Some(handle.id),
            "agent",
            "AgentLaunchFailed",
            json!({"error": failed_summary}),
        )
        .await;
        return Err(error);
    }

    Ok("started".to_string())
}

pub async fn list_worktrees(state: &AppState) -> Result<Vec<WorktreeView>, String> {
    let (project_id, db) = {
        let current = state.current.lock().await;
        let ctx = current
            .as_ref()
            .ok_or_else(|| "no open project".to_string())?;
        (ctx.project_id, ctx.db.clone())
    };

    let rows = db
        .list_worktrees(&project_id.to_string())
        .await
        .map_err(|e| e.to_string())?;
    Ok(rows
        .into_iter()
        .map(|row| WorktreeView {
            id: row.id,
            task_id: row.task_id,
            path: row.path,
            branch: row.branch,
            lease_status: row.lease_status,
            lease_started: row.lease_started,
            last_active: row.last_active,
        })
        .collect())
}

pub async fn cleanup_worktree(
    task_id: String,
    emitter: &Arc<dyn EventEmitter>,
    state: &AppState,
) -> Result<(), String> {
    let (project_id, db, git) = {
        let current = state.current.lock().await;
        let ctx = current
            .as_ref()
            .ok_or_else(|| "no open project".to_string())?;
        (ctx.project_id, ctx.db.clone(), ctx.git.clone())
    };

    let task_uuid = Uuid::parse_str(&task_id).map_err(|e| e.to_string())?;
    cleanup_task_worktree(&db, &git, project_id, task_uuid, Some(emitter)).await
}

pub async fn get_task_cost(task_id: String, state: &AppState) -> Result<f64, String> {
    let current = state.current.lock().await;
    let ctx = current
        .as_ref()
        .ok_or_else(|| "no open project".to_string())?;
    ctx.db
        .task_cost_total(&task_id)
        .await
        .map_err(|e| e.to_string())
}

pub async fn get_project_cost(project_id: String, state: &AppState) -> Result<f64, String> {
    let current = state.current.lock().await;
    let ctx = current
        .as_ref()
        .ok_or_else(|| "no open project".to_string())?;

    let id = if project_id.is_empty() {
        ctx.project_id.to_string()
    } else {
        project_id
    };

    ctx.db
        .project_cost_total(&id)
        .await
        .map_err(|e| e.to_string())
}

// ── Story commands ─────────────────────────

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct TaskStoryView {
    pub id: String,
    pub task_id: String,
    pub sequence_number: i64,
    pub title: String,
    pub status: String,
    pub started_at: Option<DateTime<Utc>>,
    pub completed_at: Option<DateTime<Utc>>,
    pub output_summary: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct StoryProgressView {
    pub total: i64,
    pub completed: i64,
    pub failed: i64,
    pub in_progress: i64,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct CreateStoriesInput {
    pub task_id: String,
    pub stories: Vec<CreateStoryItem>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct CreateStoryItem {
    pub title: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct UpdateStoryStatusInput {
    pub id: String,
    pub status: String,
    pub output_summary: Option<String>,
}

pub async fn list_task_stories(
    task_id: String,
    state: &AppState,
) -> Result<Vec<TaskStoryView>, String> {
    let db = {
        let current = state.current.lock().await;
        let ctx = current.as_ref().ok_or("no open project")?;
        ctx.db.clone()
    };
    let rows = db
        .list_task_stories(&task_id)
        .await
        .map_err(|e| e.to_string())?;
    Ok(rows
        .into_iter()
        .map(|r| TaskStoryView {
            id: r.id,
            task_id: r.task_id,
            sequence_number: r.sequence_number,
            title: r.title,
            status: r.status,
            started_at: r.started_at,
            completed_at: r.completed_at,
            output_summary: r.output_summary,
        })
        .collect())
}

pub async fn create_stories_for_task(
    input: CreateStoriesInput,
    state: &AppState,
) -> Result<Vec<TaskStoryView>, String> {
    let db = {
        let current = state.current.lock().await;
        let ctx = current.as_ref().ok_or("no open project")?;
        ctx.db.clone()
    };
    let rows: Vec<pnevma_db::TaskStoryRow> = input
        .stories
        .iter()
        .enumerate()
        .map(|(i, s)| pnevma_db::TaskStoryRow {
            id: uuid::Uuid::new_v4().to_string(),
            task_id: input.task_id.clone(),
            sequence_number: i as i64,
            title: s.title.clone(),
            status: "pending".to_string(),
            started_at: None,
            completed_at: None,
            output_summary: None,
        })
        .collect();
    db.create_stories_batch(&rows)
        .await
        .map_err(|e| e.to_string())?;
    let result = db
        .list_task_stories(&input.task_id)
        .await
        .map_err(|e| e.to_string())?;
    Ok(result
        .into_iter()
        .map(|r| TaskStoryView {
            id: r.id,
            task_id: r.task_id,
            sequence_number: r.sequence_number,
            title: r.title,
            status: r.status,
            started_at: r.started_at,
            completed_at: r.completed_at,
            output_summary: r.output_summary,
        })
        .collect())
}

pub async fn update_story_status(
    input: UpdateStoryStatusInput,
    state: &AppState,
) -> Result<(), String> {
    let db = {
        let current = state.current.lock().await;
        let ctx = current.as_ref().ok_or("no open project")?;
        ctx.db.clone()
    };
    db.update_story_status(&input.id, &input.status, input.output_summary.as_deref())
        .await
        .map_err(|e| e.to_string())
}

pub async fn get_task_story_progress(
    task_id: String,
    state: &AppState,
) -> Result<StoryProgressView, String> {
    let db = {
        let current = state.current.lock().await;
        let ctx = current.as_ref().ok_or("no open project")?;
        ctx.db.clone()
    };
    let p = db
        .get_story_progress(&task_id)
        .await
        .map_err(|e| e.to_string())?;
    Ok(StoryProgressView {
        total: p.total,
        completed: p.completed,
        failed: p.failed,
        in_progress: p.in_progress,
    })
}
