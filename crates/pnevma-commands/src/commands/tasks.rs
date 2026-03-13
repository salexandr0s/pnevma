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

    let mut dirty = git_output(&worktree_path, &["status", "--porcelain"]).await?;
    let mut repair_error: Option<String> = None;
    if task_row.status == "Review" && task.branch.is_some() {
        match prepare_task_branch_for_review(&worktree_path, task_uuid, &task.title, &target_branch)
            .await
        {
            Ok(commit_result) => {
                append_event(
                    &db,
                    project_id,
                    Some(task_uuid),
                    None,
                    "git",
                    "AgentChangesCommitted",
                    json!({
                        "task_id": task_id,
                        "branch": task.branch.clone(),
                        "commit_sha": commit_result.commit_sha,
                        "commit_message": commit_result.commit_message,
                        "source": "merge_queue_repair",
                    }),
                )
                .await;
                dirty = git_output(&worktree_path, &["status", "--porcelain"]).await?;
            }
            Err(error) => {
                repair_error = Some(error.clone());
                append_event(
                    &db,
                    project_id,
                    Some(task_uuid),
                    None,
                    "git",
                    "AgentOutputNotMergeReady",
                    json!({
                        "task_id": task_id,
                        "error": error,
                        "source": "merge_queue_repair",
                    }),
                )
                .await;
            }
        }
    }
    if !dirty.trim().is_empty() {
        let reason = repair_error
            .as_deref()
            .filter(|value| !value.trim().is_empty())
            .map(|value| format!("{value}; remaining dirty paths: {}", dirty.trim()))
            .unwrap_or_else(|| "worktree has uncommitted changes".to_string());
        queue_item.status = "Blocked".to_string();
        queue_item.blocked_reason = Some(reason.clone());
        db.upsert_merge_queue_item(&queue_item)
            .await
            .map_err(|e| e.to_string())?;
        notify_merge_queue_blocked(&db, emitter, project_id, task_uuid, &task.title, &reason).await;
        emitter.emit(
            "merge_queue_updated",
            json!({"task_id": task_id, "status": "Blocked"}),
        );
        return Err(format!("merge blocked: {reason}"));
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
        notify_merge_queue_blocked(
            &db,
            emitter,
            project_id,
            task_uuid,
            &task.title,
            &format!("rebasing onto '{target_branch}' produced conflicts"),
        )
        .await;
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
        notify_merge_queue_blocked(
            &db,
            emitter,
            project_id,
            task_uuid,
            &task.title,
            "automated checks failed after rebase",
        )
        .await;
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
    cleanup_task_worktree_and_branch(
        &db,
        &git,
        project_id,
        task_uuid,
        Some(emitter),
        Some(&project_path),
    )
    .await?;
    if git_ref_exists(&project_path, &format!("refs/heads/{}", worktree.branch)).await? {
        return Err(format!(
            "merged branch still exists after cleanup: {}",
            worktree.branch
        ));
    }
    super::refresh_dependency_states_after_completion(
        &db,
        project_id,
        task_uuid,
        Some(emitter),
        state,
    )
    .await?;
    check_workflow_completion(&db, &task_id, Some(emitter)).await;

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
    notify_merge_completed(
        &db,
        emitter,
        project_id,
        task_uuid,
        &task.title,
        &target_branch,
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
        external_source: None,
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
    notify_task_status_transition(
        &db,
        emitter,
        project_id,
        task.id,
        &row.title,
        &previous_status,
        &task.status,
        row.handoff_summary.as_deref(),
    )
    .await;
    refresh_dependency_states(&db, project_id, Some(emitter), state).await?;
    emit_task_updated(&db, project_id, task.id).await;
    emit_enriched_task_event(emitter, &db, &row.id).await;
    if previous_status != task.status && is_terminal_task_status(&task.status) {
        cleanup_task_worktree(
            &db,
            &git,
            project_id,
            task.id,
            Some(emitter),
            Some(&project_path),
        )
        .await?;
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
            check_workflow_completion(&db, &row.id, Some(emitter)).await;
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
        let _ = cleanup_task_worktree(&db, &git, project_id, task_uuid, Some(emitter), None).await;
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
    use crate::automation::runner;
    use crate::automation::DispatchOrigin;

    let prepared =
        match runner::prepare(task_id.clone(), emitter, state, DispatchOrigin::Manual).await {
            Ok(p) => p,
            Err(runner::RunnerError::Queued(pos)) => return Ok(format!("queued:{pos}")),
            Err(e) => return Err(e.to_string()),
        };

    let manual_run_id = Uuid::new_v4();
    let _db_run_id = runner::create_automation_run_record(&prepared, manual_run_id, 1)
        .await
        .map_err(|e| e.to_string())?;
    let running = match runner::start(&prepared).await {
        Ok(running) => running,
        Err(e) => {
            let error = e.to_string();
            runner::handle_start_failure(&prepared, &error).await;
            return Err(error);
        }
    };

    // Register manual dispatch with coordinator if available
    {
        let current = state.current.lock().await;
        if let Some(ctx) = current.as_ref() {
            if let Some(ref coordinator) = ctx.coordinator {
                coordinator
                    .register_manual_run(
                        Uuid::parse_str(&task_id).unwrap_or_default(),
                        running.session_id,
                        running.handle.clone(),
                        prepared.adapter.clone(),
                    )
                    .await;
            }
        }
    }

    runner::send_payload(&prepared, &running).await?;

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
    cleanup_task_worktree(&db, &git, project_id, task_uuid, Some(emitter), None).await
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
