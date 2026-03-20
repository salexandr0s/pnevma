use super::*;

pub async fn query_events(
    input: QueryEventsInput,
    state: &AppState,
) -> Result<Vec<EventRow>, String> {
    let (db, project_id) = state
        .with_project("query_events", |ctx| (ctx.db.clone(), ctx.project_id))
        .await?;

    db.query_events(EventQueryFilter {
        project_id: project_id.to_string(),
        task_id: input.task_id,
        session_id: input.session_id,
        event_type: input.event_type,
        from: parse_dt(input.from),
        to: parse_dt(input.to),
        limit: input.limit,
    })
    .await
    .map_err(|e| e.to_string())
}

/// Testable core of search_project — searches tasks, events, and artifacts in the DB.
/// Does not search git commits or session scrollback (those require filesystem/process access).
pub(crate) async fn search_db(
    query: &str,
    limit: usize,
    db: &Db,
    project_id: &str,
) -> Result<Vec<SearchResultView>, String> {
    let mut hits = Vec::new();

    // Use FTS5 for task search when available, falling back to in-memory scan.
    // Wrap query in double-quotes for FTS5 phrase matching; inner quotes are
    // escaped by doubling them per the FTS5 tokenizer grammar.
    let fts_query = format!("\"{}\"", query.replace('"', "\"\""));
    let fts_result: Result<Vec<TaskRow>, _> = sqlx::query_as(
        r#"SELECT t.id, t.project_id, t.title, t.goal, t.scope_json, t.dependencies_json,
                  t.acceptance_json, t.constraints_json, t.priority, t.status, t.branch,
                  t.worktree_id, t.handoff_summary, t.created_at, t.updated_at,
                  t.auto_dispatch, t.agent_profile_override, t.execution_mode,
                  t.timeout_minutes, t.max_retries, t.loop_iteration, t.loop_context_json
           FROM tasks_fts f
           JOIN tasks t ON t.rowid = f.rowid
           WHERE tasks_fts MATCH ?1 AND t.project_id = ?3
           ORDER BY rank
           LIMIT ?2"#,
    )
    .bind(&fts_query)
    .bind(limit as i64)
    .bind(project_id)
    .fetch_all(db.pool())
    .await;
    let fts_available = fts_result.is_ok();
    let fts_task_results: Vec<TaskRow> = fts_result.unwrap_or_default();

    if fts_available {
        for task in fts_task_results {
            let body = format!("{}\n{}", task.title, task.goal);
            hits.push(SearchResultView {
                id: format!("task:{}", task.id),
                source: "task".to_string(),
                title: task.title.clone(),
                snippet: summarize_match(&body, query),
                path: None,
                task_id: Some(task.id),
                session_id: None,
                timestamp: Some(task.updated_at),
            });
            if hits.len() >= limit {
                return Ok(hits);
            }
        }
    } else {
        // Fallback: in-memory scan if FTS table doesn't exist yet.
        let tasks = db.list_tasks(project_id).await.map_err(|e| e.to_string())?;
        for task in tasks {
            let body = format!(
                "{}\n{}\n{}\n{}\n{}",
                task.title, task.goal, task.scope_json, task.constraints_json, task.acceptance_json
            );
            if contains_case_insensitive(&body, query) {
                hits.push(SearchResultView {
                    id: format!("task:{}", task.id),
                    source: "task".to_string(),
                    title: task.title.clone(),
                    snippet: summarize_match(&body, query),
                    path: None,
                    task_id: Some(task.id),
                    session_id: None,
                    timestamp: Some(task.updated_at),
                });
            }
            if hits.len() >= limit {
                return Ok(hits);
            }
        }
    }

    // Use FTS5 for event search when available, falling back to in-memory scan.
    let fts_event_result: Result<Vec<EventRow>, _> = sqlx::query_as(
        r#"SELECT e.id, e.project_id, e.task_id, e.session_id, e.trace_id,
                  e.source, e.event_type, e.payload_json, e.timestamp
           FROM events_fts f
           JOIN events e ON e.rowid = f.rowid
           WHERE events_fts MATCH ?1 AND e.project_id = ?3
           ORDER BY rank
           LIMIT ?2"#,
    )
    .bind(&fts_query)
    .bind(limit as i64)
    .bind(project_id)
    .fetch_all(db.pool())
    .await;
    let fts_events_available = fts_event_result.is_ok();
    let fts_event_results: Vec<EventRow> = fts_event_result.unwrap_or_default();

    if fts_events_available {
        for event in fts_event_results {
            let body = format!(
                "{}\n{}\n{}",
                event.event_type, event.source, event.payload_json
            );
            hits.push(SearchResultView {
                id: format!("event:{}", event.id),
                source: "event".to_string(),
                title: event.event_type.clone(),
                snippet: summarize_match(&body, query),
                path: None,
                task_id: event.task_id.clone(),
                session_id: event.session_id.clone(),
                timestamp: Some(event.timestamp),
            });
            if hits.len() >= limit {
                return Ok(hits);
            }
        }
    } else {
        // Fallback: in-memory scan.
        let events = db
            .list_recent_events(project_id, 4_000)
            .await
            .map_err(|e| e.to_string())?;
        for event in events {
            let body = format!(
                "{}\n{}\n{}",
                event.event_type, event.source, event.payload_json
            );
            if contains_case_insensitive(&body, query) {
                hits.push(SearchResultView {
                    id: format!("event:{}", event.id),
                    source: "event".to_string(),
                    title: event.event_type.clone(),
                    snippet: summarize_match(&body, query),
                    path: None,
                    task_id: event.task_id.clone(),
                    session_id: event.session_id.clone(),
                    timestamp: Some(event.timestamp),
                });
            }
            if hits.len() >= limit {
                return Ok(hits);
            }
        }
    }

    let artifacts = db
        .list_artifacts(project_id)
        .await
        .map_err(|e| e.to_string())?;
    for artifact in artifacts {
        let body = format!(
            "{}\n{}\n{}",
            artifact.r#type,
            artifact.path,
            artifact.description.clone().unwrap_or_default()
        );
        if contains_case_insensitive(&body, query) {
            hits.push(SearchResultView {
                id: format!("artifact:{}", artifact.id),
                source: "artifact".to_string(),
                title: format!("{} · {}", artifact.r#type, artifact.path),
                snippet: summarize_match(&body, query),
                path: Some(artifact.path.clone()),
                task_id: artifact.task_id.clone(),
                session_id: None,
                timestamp: Some(artifact.created_at),
            });
        }
        if hits.len() >= limit {
            return Ok(hits);
        }
    }

    Ok(hits)
}

pub async fn search_project(
    input: SearchProjectInput,
    state: &AppState,
) -> Result<Vec<SearchResultView>, String> {
    let query = input.query.trim().to_string();
    if query.is_empty() {
        return Ok(Vec::new());
    }

    let (db, project_id, checkout_path, sessions) = state
        .with_project("search_project", |ctx| {
            (
                ctx.db.clone(),
                ctx.project_id,
                ctx.checkout_path.clone(),
                ctx.sessions.clone(),
            )
        })
        .await?;

    let limit = input.limit.unwrap_or(120).clamp(1, 500);

    // Search tasks, events, and artifacts in the DB.
    let mut hits = search_db(&query, limit, &db, &project_id.to_string()).await?;
    if hits.len() >= limit {
        return Ok(hits);
    }

    let commit_log = git_output(
        &checkout_path,
        &["log", "--pretty=format:%H%x1f%ct%x1f%s", "-n", "300"],
    )
    .await
    .unwrap_or_default();
    for line in commit_log.lines() {
        let mut parts = line.split('\x1f');
        let hash = parts.next().unwrap_or_default();
        let ts = parts
            .next()
            .and_then(|v| v.parse::<i64>().ok())
            .and_then(|secs| DateTime::<Utc>::from_timestamp(secs, 0));
        let subject = parts.next().unwrap_or_default();
        if hash.is_empty() || subject.is_empty() {
            continue;
        }
        if contains_case_insensitive(subject, &query) {
            hits.push(SearchResultView {
                id: format!("commit:{hash}"),
                source: "commit".to_string(),
                title: format!("commit {}", hash.chars().take(8).collect::<String>()),
                snippet: subject.to_string(),
                path: None,
                task_id: None,
                session_id: None,
                timestamp: ts,
            });
        }
        if hits.len() >= limit {
            return Ok(hits);
        }
    }

    let metas = sessions.list().await;
    for meta in metas {
        let slice = sessions
            .read_scrollback(meta.id, 0, 128 * 1024)
            .await
            .unwrap_or(ScrollbackSlice {
                session_id: meta.id,
                start_offset: 0,
                end_offset: 0,
                total_bytes: 0,
                data: String::new(),
            });
        if slice.data.is_empty() || !contains_case_insensitive(&slice.data, &query) {
            continue;
        }
        hits.push(SearchResultView {
            id: format!("scrollback:{}", meta.id),
            source: "scrollback".to_string(),
            title: format!("session {}", meta.name),
            snippet: summarize_match(&slice.data, &query),
            path: Some(meta.scrollback_path.clone()),
            task_id: None,
            session_id: Some(meta.id.to_string()),
            timestamp: Some(meta.last_heartbeat),
        });
        if hits.len() >= limit {
            return Ok(hits);
        }
    }

    Ok(hits)
}

fn normalize_relative_path(path: &Path) -> String {
    path.to_string_lossy().replace('\\', "/")
}

fn compare_file_tree_nodes(a: &FileTreeNodeView, b: &FileTreeNodeView) -> std::cmp::Ordering {
    match (a.is_directory, b.is_directory) {
        (true, false) => std::cmp::Ordering::Less,
        (false, true) => std::cmp::Ordering::Greater,
        _ => a
            .name
            .to_ascii_lowercase()
            .cmp(&b.name.to_ascii_lowercase())
            .then_with(|| a.name.cmp(&b.name)),
    }
}

fn sort_file_tree_nodes(nodes: &mut [FileTreeNodeView]) {
    nodes.sort_by(compare_file_tree_nodes);
}

fn resolve_project_tree_directory(
    project_path: &Path,
    requested_path: Option<&str>,
) -> Result<(PathBuf, PathBuf), String> {
    let root_dir = std::fs::canonicalize(project_path)
        .map_err(|e| format!("failed to canonicalize project path: {e}"))?;

    let current_dir = match requested_path
        .map(str::trim)
        .filter(|value| !value.is_empty())
    {
        Some(path) => {
            let relative_path = path.trim_start_matches('/');
            ensure_safe_path_input(relative_path, "file tree path")?;
            if relative_path.is_empty() {
                return Err("invalid path".to_string());
            }

            let directory = root_dir.join(relative_path);
            if !directory.exists() {
                return Err(format!("directory not found: {path}"));
            }

            let canonical = directory.canonicalize().map_err(|e| e.to_string())?;
            if !canonical.starts_with(&root_dir) {
                return Err("path escapes project directory".to_string());
            }
            if !canonical.is_dir() {
                return Err("path is not a directory".to_string());
            }

            directory
        }
        None => root_dir.clone(),
    };

    Ok((root_dir, current_dir))
}

fn list_project_directory_entries(
    current_dir: &Path,
    root_dir: &Path,
) -> Result<Vec<FileTreeNodeView>, String> {
    let entries = std::fs::read_dir(current_dir)
        .map_err(|e| format!("failed to read {}: {e}", current_dir.display()))?;
    let mut nodes = Vec::new();

    for entry in entries {
        let Ok(entry) = entry else {
            continue;
        };
        let entry_path = entry.path();
        let Ok(relative_path) = entry_path.strip_prefix(root_dir) else {
            continue;
        };
        if relative_path.as_os_str().is_empty() {
            continue;
        }

        let name = entry.file_name().to_string_lossy().to_string();
        let path = normalize_relative_path(relative_path);
        let metadata = match std::fs::symlink_metadata(&entry_path) {
            Ok(metadata) => metadata,
            Err(_) => continue,
        };
        let file_type = metadata.file_type();

        if file_type.is_symlink() {
            let Ok(canonical_target) = entry_path.canonicalize() else {
                continue;
            };
            if !canonical_target.starts_with(root_dir) {
                continue;
            }
            let Ok(target_metadata) = std::fs::metadata(&canonical_target) else {
                continue;
            };
            if target_metadata.is_dir() {
                nodes.push(FileTreeNodeView {
                    id: path.clone(),
                    name,
                    path,
                    is_directory: true,
                    children: None,
                    size: None,
                });
            } else if target_metadata.is_file() {
                nodes.push(FileTreeNodeView {
                    id: path.clone(),
                    name,
                    path,
                    is_directory: false,
                    children: None,
                    size: i64::try_from(target_metadata.len()).ok(),
                });
            }
            continue;
        }

        if metadata.is_dir() {
            let Ok(canonical_dir) = entry_path.canonicalize() else {
                continue;
            };
            if !canonical_dir.starts_with(root_dir) {
                continue;
            }
            nodes.push(FileTreeNodeView {
                id: path.clone(),
                name,
                path,
                is_directory: true,
                children: None,
                size: None,
            });
            continue;
        }

        if metadata.is_file() {
            nodes.push(FileTreeNodeView {
                id: path.clone(),
                name,
                path,
                is_directory: false,
                children: None,
                size: i64::try_from(metadata.len()).ok(),
            });
        }
    }

    sort_file_tree_nodes(&mut nodes);
    Ok(nodes)
}

struct ProjectTreeSearchCandidate {
    node: FileTreeNodeView,
    child_dir: Option<PathBuf>,
    logical_path: PathBuf,
}

fn project_tree_search_candidate_for_path(
    entry_path: &Path,
    logical_parent: Option<&Path>,
    root_dir: &Path,
) -> Option<ProjectTreeSearchCandidate> {
    let name = entry_path.file_name()?.to_string_lossy().to_string();
    let logical_path = logical_parent
        .map(|parent| parent.join(&name))
        .unwrap_or_else(|| PathBuf::from(&name));
    let path = normalize_relative_path(&logical_path);
    let metadata = std::fs::symlink_metadata(entry_path).ok()?;
    let file_type = metadata.file_type();

    if file_type.is_symlink() {
        let canonical_target = entry_path.canonicalize().ok()?;
        if !canonical_target.starts_with(root_dir) {
            return None;
        }
        let target_metadata = std::fs::metadata(&canonical_target).ok()?;
        if target_metadata.is_dir() {
            return Some(ProjectTreeSearchCandidate {
                node: FileTreeNodeView {
                    id: path.clone(),
                    name,
                    path,
                    is_directory: true,
                    children: None,
                    size: None,
                },
                child_dir: Some(canonical_target),
                logical_path,
            });
        }
        if target_metadata.is_file() {
            return Some(ProjectTreeSearchCandidate {
                node: FileTreeNodeView {
                    id: path.clone(),
                    name,
                    path,
                    is_directory: false,
                    children: None,
                    size: i64::try_from(target_metadata.len()).ok(),
                },
                child_dir: None,
                logical_path,
            });
        }
        return None;
    }

    if metadata.is_dir() {
        let canonical_dir = entry_path.canonicalize().ok()?;
        if !canonical_dir.starts_with(root_dir) {
            return None;
        }
        return Some(ProjectTreeSearchCandidate {
            node: FileTreeNodeView {
                id: path.clone(),
                name,
                path,
                is_directory: true,
                children: None,
                size: None,
            },
            child_dir: Some(canonical_dir),
            logical_path,
        });
    }

    if metadata.is_file() {
        return Some(ProjectTreeSearchCandidate {
            node: FileTreeNodeView {
                id: path.clone(),
                name,
                path,
                is_directory: false,
                children: None,
                size: i64::try_from(metadata.len()).ok(),
            },
            child_dir: None,
            logical_path,
        });
    }

    None
}

fn search_project_directory_entries(
    current_dir: &Path,
    logical_parent: Option<&Path>,
    root_dir: &Path,
    query: &str,
    remaining_matches: &mut usize,
    visited_dirs: &mut std::collections::HashSet<PathBuf>,
) -> Result<Vec<FileTreeNodeView>, String> {
    if query.is_empty() || *remaining_matches == 0 {
        return Ok(Vec::new());
    }

    let entries = std::fs::read_dir(current_dir)
        .map_err(|e| format!("failed to read {}: {e}", current_dir.display()))?;
    let mut candidates = Vec::new();

    for entry in entries {
        let Ok(entry) = entry else {
            continue;
        };
        let entry_path = entry.path();
        if let Some(candidate) =
            project_tree_search_candidate_for_path(&entry_path, logical_parent, root_dir)
        {
            candidates.push(candidate);
        }
    }

    candidates.sort_by(|left, right| compare_file_tree_nodes(&left.node, &right.node));
    let mut nodes = Vec::new();

    for candidate in candidates {
        if *remaining_matches == 0 {
            break;
        }

        let mut node = candidate.node;
        let matches_self = node.name.to_ascii_lowercase().contains(query)
            || node.path.to_ascii_lowercase().contains(query);

        if node.is_directory {
            let children = if let Some(directory_path) = candidate.child_dir {
                if visited_dirs.insert(directory_path.clone()) {
                    let children = search_project_directory_entries(
                        &directory_path,
                        Some(&candidate.logical_path),
                        root_dir,
                        query,
                        remaining_matches,
                        visited_dirs,
                    )?;
                    visited_dirs.remove(&directory_path);
                    children
                } else {
                    Vec::new()
                }
            } else {
                Vec::new()
            };

            if matches_self || !children.is_empty() {
                node.children = Some(children);
                nodes.push(node);
                if matches_self && *remaining_matches > 0 {
                    *remaining_matches -= 1;
                }
            }
        } else if matches_self {
            nodes.push(node);
            *remaining_matches -= 1;
        }
    }

    sort_file_tree_nodes(&mut nodes);
    Ok(nodes)
}

fn filter_project_file_tree(
    mut nodes: Vec<FileTreeNodeView>,
    query: &str,
) -> Vec<FileTreeNodeView> {
    if query.is_empty() {
        return nodes;
    }

    nodes.retain(|node| {
        node.name.to_ascii_lowercase().contains(query)
            || node.path.to_ascii_lowercase().contains(query)
    });
    nodes
}

pub async fn list_project_files(
    input: Option<ListProjectFilesInput>,
    state: &AppState,
) -> Result<Vec<ProjectFileView>, String> {
    let (project_path, query) = state
        .with_project("list_project_files", |ctx| {
            (
                ctx.checkout_path.clone(),
                input
                    .as_ref()
                    .and_then(|v| v.query.clone())
                    .unwrap_or_default(),
            )
        })
        .await?;

    let limit = input.and_then(|v| v.limit).unwrap_or(1_000).clamp(1, 5_000);
    let mut all_paths = HashSet::new();
    let tracked = git_output(&project_path, &["ls-files"])
        .await
        .unwrap_or_default();
    for line in tracked.lines().map(str::trim).filter(|v| !v.is_empty()) {
        all_paths.insert(line.to_string());
    }
    let untracked = git_output(
        &project_path,
        &["ls-files", "--others", "--exclude-standard"],
    )
    .await
    .unwrap_or_default();
    for line in untracked.lines().map(str::trim).filter(|v| !v.is_empty()) {
        all_paths.insert(line.to_string());
    }

    let mut statuses = HashMap::<String, String>::new();
    let porcelain = git_output(&project_path, &["status", "--porcelain"])
        .await
        .unwrap_or_default();
    for line in porcelain.lines() {
        if let Some((path, status)) = parse_porcelain_status_line(line) {
            statuses.insert(path, status);
        }
    }

    let query = query.trim().to_ascii_lowercase();
    let mut files = all_paths
        .into_iter()
        .filter(|path| query.is_empty() || path.to_ascii_lowercase().contains(&query))
        .map(|path| {
            let status = statuses
                .get(&path)
                .cloned()
                .unwrap_or_else(|| "  ".to_string());
            project_file_view(path, status)
        })
        .collect::<Vec<_>>();
    files.sort_by(|a, b| a.path.cmp(&b.path));
    if files.len() > limit {
        files.truncate(limit);
    }
    Ok(files)
}

pub async fn list_workspace_changes(state: &AppState) -> Result<Vec<ProjectFileView>, String> {
    let project_path = state
        .with_project("list_workspace_changes", |ctx| ctx.checkout_path.clone())
        .await?;

    let porcelain = git_output(&project_path, &["status", "--porcelain", "-z", "-uall"]).await?;
    let mut files = parse_porcelain_status_z(&porcelain)
        .into_iter()
        .map(|(path, status)| project_file_view(path, status))
        .collect::<Vec<_>>();

    // Merge diff stats (additions/deletions) from numstat
    let mut stats: std::collections::HashMap<String, (i64, i64)> = std::collections::HashMap::new();
    // Unstaged changes
    if let Ok(numstat) = git_output(&project_path, &["diff", "--numstat"]).await {
        parse_numstat_into(&numstat, &mut stats);
    }
    // Staged changes
    if let Ok(numstat) = git_output(&project_path, &["diff", "--cached", "--numstat"]).await {
        parse_numstat_into(&numstat, &mut stats);
    }
    for file in &mut files {
        if let Some(&(add, del)) = stats.get(&file.path) {
            file.additions = Some(add);
            file.deletions = Some(del);
        }
    }

    files.sort_by(|a, b| a.path.cmp(&b.path));
    Ok(files)
}

async fn workspace_change_for_path(
    project_path: &Path,
    rel: &str,
) -> Result<Option<ProjectFileView>, String> {
    let porcelain = git_output(
        project_path,
        &["status", "--porcelain", "-z", "-uall", "--", rel],
    )
    .await?;

    Ok(parse_porcelain_status_z(&porcelain)
        .into_iter()
        .map(|(path, status)| project_file_view(path, status))
        .find(|item| item.path == rel))
}

pub async fn get_workspace_change_diff(
    input: ProjectFilePathInput,
    state: &AppState,
) -> Result<Option<DiffFileView>, String> {
    let project_path = state
        .with_project("get_workspace_change_diff", |ctx| ctx.checkout_path.clone())
        .await?;

    let rel = input.path.trim().trim_start_matches('/');
    ensure_safe_path_input(rel, "file path")?;
    if rel.is_empty() {
        return Err("invalid path".to_string());
    }

    let file_opt = workspace_change_for_path(&project_path, rel).await?;
    let file = file_opt
        .as_ref()
        .ok_or_else(|| format!("changed file not found: {}", input.path))?;

    let mut patch_chunks = Vec::new();
    if file.staged {
        let patch = git_output(
            &project_path,
            &["diff", "--cached", "--no-ext-diff", "--", rel],
        )
        .await?;
        if !patch.trim().is_empty() {
            patch_chunks.push(patch);
        }
    }
    if file.modified || file.conflicted {
        let patch = git_output(&project_path, &["diff", "--no-ext-diff", "--", rel]).await?;
        if !patch.trim().is_empty() {
            patch_chunks.push(patch);
        }
    }
    if file.untracked {
        let patch = git_diff_no_index_output(&project_path, rel).await?;
        if !patch.trim().is_empty() {
            patch_chunks.push(patch);
        }
    }

    let patch = patch_chunks.join("\n");
    if patch.trim().is_empty() {
        return Ok(None);
    }

    let mut files = parse_diff_patch(&patch);
    if files.is_empty() {
        return Ok(None);
    }

    let mut merged = files.remove(0);
    for extra in files {
        if extra.path == merged.path {
            merged.hunks.extend(extra.hunks);
        }
    }
    Ok(Some(merged))
}

fn parse_numstat_into(numstat: &str, stats: &mut std::collections::HashMap<String, (i64, i64)>) {
    for line in numstat.lines() {
        let parts: Vec<&str> = line.splitn(3, '\t').collect();
        if parts.len() == 3 {
            // Binary files show "-\t-\tpath" — skip them so they stay as None
            if parts[0] == "-" || parts[1] == "-" {
                continue;
            }
            let add = parts[0].parse::<i64>().unwrap_or(0);
            let del = parts[1].parse::<i64>().unwrap_or(0);
            // Renames show paths like "{old => new}/file.txt" — normalize to new path
            let path = normalize_numstat_path(parts[2]);
            let entry = stats.entry(path).or_insert((0, 0));
            entry.0 += add;
            entry.1 += del;
        }
    }
}

/// Normalize numstat rename paths like `{old => new}/file.txt` to `new/file.txt`.
fn normalize_numstat_path(raw: &str) -> String {
    if !raw.contains(" => ") {
        return raw.to_string();
    }
    // Pattern: prefix{old => new}suffix  or  old => new (no braces)
    if let Some(start) = raw.find('{') {
        if let Some(end) = raw.find('}') {
            let prefix = &raw[..start];
            let suffix = &raw[end + 1..];
            let inner = &raw[start + 1..end];
            if let Some(arrow) = inner.find(" => ") {
                let new_part = &inner[arrow + 4..];
                return format!("{prefix}{new_part}{suffix}");
            }
        }
    }
    // Bare "old => new" without braces
    if let Some(arrow) = raw.find(" => ") {
        return raw[arrow + 4..].to_string();
    }
    raw.to_string()
}

fn project_file_view(path: String, status: String) -> ProjectFileView {
    let staged = status.chars().next().is_some_and(|c| c != ' ' && c != '?');
    let modified = status.chars().nth(1).is_some_and(|c| c != ' ' && c != '?');
    let conflicted = status.contains('U');
    let untracked = status.starts_with("??");
    ProjectFileView {
        path,
        status,
        modified,
        staged,
        conflicted,
        untracked,
        additions: None,
        deletions: None,
    }
}

pub async fn list_project_file_tree(
    input: Option<ListProjectFilesInput>,
    state: &AppState,
) -> Result<Vec<FileTreeNodeView>, String> {
    let (project_path, query, limit, requested_path, recursive) = state
        .with_project("list_project_file_tree", |ctx| {
            (
                ctx.checkout_path.clone(),
                input
                    .as_ref()
                    .and_then(|value| value.query.clone())
                    .unwrap_or_default()
                    .trim()
                    .to_ascii_lowercase(),
                input.as_ref().and_then(|value| value.limit),
                input.as_ref().and_then(|value| value.path.clone()),
                input
                    .as_ref()
                    .and_then(|value| value.recursive)
                    .unwrap_or(false),
            )
        })
        .await?;

    tokio::task::spawn_blocking(move || {
        let (root_dir, current_dir) =
            resolve_project_tree_directory(&project_path, requested_path.as_deref())?;
        let nodes = if recursive && !query.is_empty() {
            let mut remaining_matches = limit.unwrap_or(10_000).clamp(1, 10_000);
            let mut visited_dirs =
                std::collections::HashSet::from([current_dir.canonicalize().map_err(|e| {
                    format!(
                        "failed to canonicalize search root {}: {e}",
                        current_dir.display()
                    )
                })?]);
            search_project_directory_entries(
                &current_dir,
                requested_path.as_deref().map(Path::new),
                &root_dir,
                &query,
                &mut remaining_matches,
                &mut visited_dirs,
            )?
        } else {
            let mut nodes = list_project_directory_entries(&current_dir, &root_dir)?;
            nodes = filter_project_file_tree(nodes, &query);
            if let Some(limit) = limit {
                nodes.truncate(limit.clamp(1, 10_000));
            }
            nodes
        };
        Ok(nodes)
    })
    .await
    .map_err(|e| format!("failed to list file tree entries: {e}"))?
}

pub async fn open_file_target(
    input: OpenFileTargetInput,
    state: &AppState,
) -> Result<FileOpenResultView, String> {
    let project_path = state
        .with_project("open_file_target", |ctx| ctx.checkout_path.clone())
        .await?;
    let rel = input.path.trim().trim_start_matches('/');
    ensure_safe_path_input(rel, "file path")?;
    if rel.is_empty() {
        return Err("invalid path".to_string());
    }
    let abs = project_path.join(rel);
    if !abs.exists() {
        return Err(format!("file not found: {}", input.path));
    }
    let canonical = abs.canonicalize().map_err(|e| e.to_string())?;
    let canonical_project = project_path.canonicalize().map_err(|e| e.to_string())?;
    if !canonical.starts_with(&canonical_project) {
        return Err("path escapes project directory".to_string());
    }
    if !canonical.is_file() {
        return Err("path is not a file".to_string());
    }

    let editor_mode = input.mode.as_deref().unwrap_or("preview") == "editor";
    let launched_editor = if editor_mode {
        if let Ok(editor) = std::env::var("EDITOR") {
            if !editor.trim().is_empty() {
                // Validate $EDITOR: resolve to an absolute path and verify it exists.
                // This prevents spawning arbitrary scripts from a poisoned env var.
                let editor_path = std::path::Path::new(editor.trim());
                let resolved = if editor_path.is_absolute() {
                    Some(editor_path.to_path_buf())
                } else {
                    // Search PATH for the binary
                    std::env::var("PATH").ok().and_then(|path_var| {
                        path_var.split(':').find_map(|dir| {
                            let candidate = std::path::Path::new(dir).join(editor.trim());
                            if candidate.is_file() {
                                Some(candidate)
                            } else {
                                None
                            }
                        })
                    })
                };
                if let Some(ref path) = resolved {
                    if path.is_file() {
                        TokioCommand::new(path)
                            .arg(&abs)
                            .current_dir(&project_path)
                            .spawn()
                            .is_ok()
                    } else {
                        tracing::warn!(editor = %editor, "EDITOR binary not found, skipping");
                        false
                    }
                } else {
                    tracing::warn!(editor = %editor, "EDITOR binary not found on PATH, skipping");
                    false
                }
            } else {
                false
            }
        } else {
            false
        }
    } else {
        false
    };

    let raw = tokio::fs::read(&abs).await.map_err(|e| e.to_string())?;
    let raw = match String::from_utf8(raw) {
        Ok(text) => text,
        Err(_) => {
            return Ok(FileOpenResultView {
                path: rel.to_string(),
                content: "[Binary file preview unavailable]".to_string(),
                truncated: false,
                launched_editor,
                is_binary: true,
            });
        }
    };
    let max_chars = 20_000usize;
    let truncated = raw.chars().count() > max_chars;
    let content = if truncated {
        raw.chars().take(max_chars).collect::<String>()
    } else {
        raw
    };

    Ok(FileOpenResultView {
        path: rel.to_string(),
        content,
        truncated,
        launched_editor,
        is_binary: false,
    })
}

async fn git_diff_no_index_output(project_path: &Path, rel_path: &str) -> Result<String, String> {
    let out = TokioCommand::new("git")
        .args(["diff", "--no-index", "--", "/dev/null", rel_path])
        .current_dir(project_path)
        .output()
        .await
        .map_err(|e| e.to_string())?;

    if out.status.success() || out.status.code() == Some(1) {
        return Ok(String::from_utf8_lossy(&out.stdout).to_string());
    }

    Err(String::from_utf8_lossy(&out.stderr).trim().to_string())
}

pub async fn write_file_target(
    input: WriteFileInput,
    state: &AppState,
) -> Result<FileWriteResultView, String> {
    let project_path = state
        .with_project("write_file_target", |ctx| ctx.checkout_path.clone())
        .await?;
    let rel = input.path.trim().trim_start_matches('/');
    ensure_safe_path_input(rel, "file path")?;
    if rel.is_empty() {
        return Err("invalid path".to_string());
    }
    let abs = project_path.join(rel);
    // The file must already exist — we don't create new files through this endpoint.
    if !abs.exists() {
        return Err(format!("file not found: {}", input.path));
    }
    let canonical = abs.canonicalize().map_err(|e| e.to_string())?;
    let canonical_project = project_path.canonicalize().map_err(|e| e.to_string())?;
    if !canonical.starts_with(&canonical_project) {
        return Err("path escapes project directory".to_string());
    }
    if !canonical.is_file() {
        return Err("path is not a file".to_string());
    }

    let bytes = input.content.as_bytes();
    let bytes_written = bytes.len() as u64;
    tokio::fs::write(&canonical, bytes)
        .await
        .map_err(|e| e.to_string())?;

    Ok(FileWriteResultView {
        path: rel.to_string(),
        bytes_written,
    })
}

pub async fn list_rules(state: &AppState) -> Result<Vec<RuleView>, String> {
    let (db, project_id, project_path, config) = state
        .with_project("list_rules", |ctx| {
            (
                ctx.db.clone(),
                ctx.project_id,
                ctx.project_path.clone(),
                ctx.config.clone(),
            )
        })
        .await?;
    ensure_scope_rows_from_config(&db, project_id, &project_path, &config, "rule").await?;
    let rows = db
        .list_rules(&project_id.to_string(), Some("rule"))
        .await
        .map_err(|e| e.to_string())?;
    let mut out = Vec::with_capacity(rows.len());
    for row in rows {
        out.push(rule_row_to_view(row, &project_path).await);
    }
    Ok(out)
}

pub async fn list_conventions(state: &AppState) -> Result<Vec<RuleView>, String> {
    let (db, project_id, project_path, config) = state
        .with_project("list_conventions", |ctx| {
            (
                ctx.db.clone(),
                ctx.project_id,
                ctx.project_path.clone(),
                ctx.config.clone(),
            )
        })
        .await?;
    ensure_scope_rows_from_config(&db, project_id, &project_path, &config, "convention").await?;
    let rows = db
        .list_rules(&project_id.to_string(), Some("convention"))
        .await
        .map_err(|e| e.to_string())?;
    let mut out = Vec::with_capacity(rows.len());
    for row in rows {
        out.push(rule_row_to_view(row, &project_path).await);
    }
    Ok(out)
}

async fn upsert_scope_item(
    input: RuleUpsertInput,
    scope: &str,
    emitter: &Arc<dyn EventEmitter>,
    state: &&AppState,
) -> Result<RuleView, String> {
    let (db, project_id, project_path) = state
        .with_project("upsert_scope_item", |ctx| {
            (ctx.db.clone(), ctx.project_id, ctx.project_path.clone())
        })
        .await?;
    let scope = normalize_rule_scope(scope);
    let mut row = if let Some(id) = input.id.clone() {
        db.get_rule(&id)
            .await
            .map_err(|e| e.to_string())?
            .unwrap_or(RuleRow {
                id,
                project_id: project_id.to_string(),
                name: input.name.clone(),
                path: String::new(),
                scope: Some(scope.to_string()),
                active: input.active.unwrap_or(true),
            })
    } else {
        RuleRow {
            id: Uuid::new_v4().to_string(),
            project_id: project_id.to_string(),
            name: input.name.clone(),
            path: String::new(),
            scope: Some(scope.to_string()),
            active: input.active.unwrap_or(true),
        }
    };

    row.name = input.name.trim().to_string();
    row.scope = Some(scope.to_string());
    row.active = input.active.unwrap_or(row.active);

    if row.path.trim().is_empty() {
        let dir = project_path.join(scope_default_dir(scope));
        tokio::fs::create_dir_all(&dir)
            .await
            .map_err(|e| e.to_string())?;
        let mut candidate = dir.join(format!("{}.md", slugify_with_fallback(&row.name, "entry")));
        if candidate.exists() {
            candidate = dir.join(format!(
                "{}-{}.md",
                slugify_with_fallback(&row.name, "entry"),
                &row.id.chars().take(8).collect::<String>()
            ));
        }
        row.path = candidate
            .strip_prefix(&project_path)
            .unwrap_or(&candidate)
            .to_string_lossy()
            .to_string();
    }

    let absolute = project_path.join(&row.path);
    // M2: Validate that the resolved path stays within the project directory.
    if let Some(parent) = absolute.parent() {
        if parent.exists() {
            let canonical_parent = parent.canonicalize().map_err(|e| e.to_string())?;
            let project_canonical = project_path.canonicalize().map_err(|e| e.to_string())?;
            if !canonical_parent.starts_with(&project_canonical) {
                return Err("rule path escapes project directory".to_string());
            }
        }
    }
    if let Some(parent) = absolute.parent() {
        tokio::fs::create_dir_all(parent)
            .await
            .map_err(|e| e.to_string())?;
    }
    tokio::fs::write(&absolute, input.content.as_bytes())
        .await
        .map_err(|e| e.to_string())?;
    db.upsert_rule(&row).await.map_err(|e| e.to_string())?;
    append_event(
        &db,
        project_id,
        None,
        None,
        "rules",
        "RuleUpdated",
        json!({"rule_id": row.id, "scope": scope, "active": row.active}),
    )
    .await;
    emitter.emit("project_refreshed", json!({"reason": "rules_updated"}));
    Ok(rule_row_to_view(row, &project_path).await)
}

pub async fn upsert_rule(
    input: RuleUpsertInput,
    emitter: &Arc<dyn EventEmitter>,
    state: &AppState,
) -> Result<RuleView, String> {
    upsert_scope_item(input, "rule", emitter, &state).await
}

pub async fn upsert_convention(
    input: RuleUpsertInput,
    emitter: &Arc<dyn EventEmitter>,
    state: &AppState,
) -> Result<RuleView, String> {
    upsert_scope_item(input, "convention", emitter, &state).await
}

async fn toggle_scope_item(
    input: RuleToggleInput,
    expected_scope: &str,
    emitter: &Arc<dyn EventEmitter>,
    state: &&AppState,
) -> Result<RuleView, String> {
    let (db, project_id, project_path) = state
        .with_project("toggle_scope_item", |ctx| {
            (ctx.db.clone(), ctx.project_id, ctx.project_path.clone())
        })
        .await?;
    let mut row = db
        .get_rule(&input.id)
        .await
        .map_err(|e| e.to_string())?
        .ok_or_else(|| format!("rule not found: {}", input.id))?;
    let scope = row.scope.clone().unwrap_or_else(|| "rule".to_string());
    if normalize_rule_scope(&scope) != normalize_rule_scope(expected_scope) {
        return Err(format!("entry scope mismatch: expected {expected_scope}"));
    }
    row.active = input.active;
    db.upsert_rule(&row).await.map_err(|e| e.to_string())?;
    append_event(
        &db,
        project_id,
        None,
        None,
        "rules",
        "RuleToggled",
        json!({"rule_id": row.id, "active": row.active}),
    )
    .await;
    emitter.emit("project_refreshed", json!({"reason": "rules_updated"}));
    Ok(rule_row_to_view(row, &project_path).await)
}

pub async fn toggle_rule(
    input: RuleToggleInput,
    emitter: &Arc<dyn EventEmitter>,
    state: &AppState,
) -> Result<RuleView, String> {
    toggle_scope_item(input, "rule", emitter, &state).await
}

pub async fn toggle_convention(
    input: RuleToggleInput,
    emitter: &Arc<dyn EventEmitter>,
    state: &AppState,
) -> Result<RuleView, String> {
    toggle_scope_item(input, "convention", emitter, &state).await
}

async fn delete_scope_item(
    id: String,
    expected_scope: &str,
    emitter: &Arc<dyn EventEmitter>,
    state: &&AppState,
) -> Result<(), String> {
    let (db, project_id, project_path) = state
        .with_project("delete_scope_item", |ctx| {
            (ctx.db.clone(), ctx.project_id, ctx.project_path.clone())
        })
        .await?;
    let row = db
        .get_rule(&id)
        .await
        .map_err(|e| e.to_string())?
        .ok_or_else(|| format!("rule not found: {id}"))?;
    let scope = row.scope.clone().unwrap_or_else(|| "rule".to_string());
    if normalize_rule_scope(&scope) != normalize_rule_scope(expected_scope) {
        return Err(format!("entry scope mismatch: expected {expected_scope}"));
    }
    let path = project_path.join(&row.path);
    // M1: Containment check — prevent deleting files outside the project.
    if let Ok(canonical) = tokio::fs::canonicalize(&path).await {
        let project_canonical = project_path.canonicalize().map_err(|e| e.to_string())?;
        if !canonical.starts_with(&project_canonical) {
            return Err("rule path escapes project directory".to_string());
        }
        let _ = tokio::fs::remove_file(canonical).await;
    }
    // If canonicalize fails, the file doesn't exist — skip silently.
    db.delete_rule(&id).await.map_err(|e| e.to_string())?;
    append_event(
        &db,
        project_id,
        None,
        None,
        "rules",
        "RuleDeleted",
        json!({"rule_id": id}),
    )
    .await;
    emitter.emit("project_refreshed", json!({"reason": "rules_updated"}));
    Ok(())
}

pub async fn delete_rule(
    id: String,
    emitter: &Arc<dyn EventEmitter>,
    state: &AppState,
) -> Result<(), String> {
    delete_scope_item(id, "rule", emitter, &state).await
}

pub async fn delete_convention(
    id: String,
    emitter: &Arc<dyn EventEmitter>,
    state: &AppState,
) -> Result<(), String> {
    delete_scope_item(id, "convention", emitter, &state).await
}

pub async fn list_rule_usage(
    input: RuleUsageInput,
    state: &AppState,
) -> Result<Vec<RuleUsageView>, String> {
    let (db, project_id) = state
        .with_project("list_rule_usage", |ctx| (ctx.db.clone(), ctx.project_id))
        .await?;
    let rows = db
        .list_context_rule_usage(
            &project_id.to_string(),
            &input.rule_id,
            input.limit.unwrap_or(100).max(1),
        )
        .await
        .map_err(|e| e.to_string())?;
    Ok(rows
        .into_iter()
        .map(|row| RuleUsageView {
            run_id: row.run_id,
            included: row.included,
            reason: row.reason,
            created_at: row.created_at,
        })
        .collect())
}

pub async fn capture_knowledge(
    input: KnowledgeCaptureInput,
    emitter: &Arc<dyn EventEmitter>,
    state: &AppState,
) -> Result<ArtifactView, String> {
    let (db, project_id, project_path, global_config) = state
        .with_project("capture_knowledge", |ctx| {
            (
                ctx.db.clone(),
                ctx.project_id,
                ctx.project_path.clone(),
                ctx.global_config.clone(),
            )
        })
        .await?;
    let kind = input.kind.trim().to_ascii_lowercase();
    if kind != "adr" && kind != "changelog" && kind != "convention-update" {
        return Err("kind must be one of: adr, changelog, convention-update".to_string());
    }
    // M4: Validate task_id to prevent directory traversal.
    if let Some(ref tid) = input.task_id {
        validate_path_component(tid, "task_id")?;
    }
    let artifact_id = Uuid::new_v4().to_string();
    let now = Utc::now();
    let task_folder = input
        .task_id
        .clone()
        .unwrap_or_else(|| "general".to_string());
    let dir = project_path
        .join(".pnevma")
        .join("data")
        .join("artifacts")
        .join(task_folder);
    tokio::fs::create_dir_all(&dir)
        .await
        .map_err(|e| e.to_string())?;
    let filename = format!(
        "{}-{}.md",
        slugify_with_fallback(&kind, "entry"),
        now.format("%Y%m%d-%H%M%S")
    );
    let file_path = dir.join(filename);
    let title = input
        .title
        .clone()
        .unwrap_or_else(|| format!("{} capture", kind));
    let body = format!(
        "# {title}\n\nkind: {kind}\ncreated_at: {}\n\n{}\n",
        now.to_rfc3339(),
        input.content
    );
    tokio::fs::write(&file_path, body.as_bytes())
        .await
        .map_err(|e| e.to_string())?;
    let rel = file_path
        .strip_prefix(&project_path)
        .unwrap_or(&file_path)
        .to_string_lossy()
        .to_string();
    let row = ArtifactRow {
        id: artifact_id,
        project_id: project_id.to_string(),
        task_id: input.task_id.clone(),
        r#type: kind.clone(),
        path: rel.clone(),
        description: Some(title.clone()),
        created_at: now,
    };
    db.create_artifact(&row).await.map_err(|e| e.to_string())?;
    append_event(
        &db,
        project_id,
        input
            .task_id
            .as_deref()
            .and_then(|raw| Uuid::parse_str(raw).ok()),
        None,
        "knowledge",
        "KnowledgeCaptured",
        json!({"artifact_id": row.id, "type": kind, "path": rel}),
    )
    .await;
    append_telemetry_event(
        &db,
        project_id,
        &global_config,
        "knowledge.capture",
        json!({"artifact_id": row.id, "kind": row.r#type}),
    )
    .await;
    emitter.emit(
        "knowledge_captured",
        json!({"artifact_id": row.id, "path": row.path, "type": row.r#type}),
    );
    Ok(ArtifactView {
        id: row.id,
        task_id: row.task_id,
        r#type: row.r#type,
        path: row.path,
        description: row.description,
        created_at: row.created_at,
    })
}

pub async fn list_artifacts(state: &AppState) -> Result<Vec<ArtifactView>, String> {
    let (db, project_id) = state
        .with_project("list_artifacts", |ctx| (ctx.db.clone(), ctx.project_id))
        .await?;
    let rows = db
        .list_artifacts(&project_id.to_string())
        .await
        .map_err(|e| e.to_string())?;
    Ok(rows
        .into_iter()
        .map(|row| ArtifactView {
            id: row.id,
            task_id: row.task_id,
            r#type: row.r#type,
            path: row.path,
            description: row.description,
            created_at: row.created_at,
        })
        .collect())
}

pub async fn get_environment_readiness(
    input: Option<EnvironmentReadinessInput>,
    state: &AppState,
) -> Result<EnvironmentReadinessView, String> {
    let current_project_path = state
        .with_project("get_environment_readiness", |ctx| ctx.project_path.clone())
        .await
        .ok();
    let requested_path = match input.and_then(|value| value.path) {
        Some(path) => Some(normalize_scaffold_path(&path)?),
        None => current_project_path,
    };
    let git_available = is_git_available();
    let detected_adapters = pnevma_agents::AdapterRegistry::detect().await.available();
    let global_path = global_config_path();
    let global_config_exists = global_path.exists();
    let project_initialized = requested_path
        .as_deref()
        .map(project_is_initialized)
        .unwrap_or(false);

    let mut missing_steps = Vec::new();
    if !git_available {
        missing_steps.push("install_git".to_string());
    }
    if detected_adapters.is_empty() {
        missing_steps.push("install_agent_cli".to_string());
    }
    if !global_config_exists {
        missing_steps.push("initialize_global_config".to_string());
    }
    if requested_path.is_none() {
        missing_steps.push("select_project_path".to_string());
    } else if !project_initialized {
        missing_steps.push("initialize_project_scaffold".to_string());
    }

    Ok(EnvironmentReadinessView {
        git_available,
        detected_adapters,
        global_config_path: global_path.to_string_lossy().to_string(),
        global_config_exists,
        project_path: requested_path.map(|path| path.to_string_lossy().to_string()),
        project_initialized,
        missing_steps,
    })
}

pub async fn initialize_global_config(
    input: Option<InitializeGlobalConfigInput>,
    state: &AppState,
) -> Result<InitGlobalConfigResultView, String> {
    let path = global_config_path();
    let mut created = false;
    if !path.exists() {
        let mut config = GlobalConfig::default();
        if let Some(provider) = input
            .as_ref()
            .and_then(|value| value.default_provider.as_deref())
            .map(str::trim)
            .filter(|value| !value.is_empty())
        {
            config.default_provider = Some(provider.to_string());
        }
        save_global_config(&config).map_err(|e| e.to_string())?;
        created = true;
    }

    if let Ok(latest_config) = load_global_config() {
        let _ = state
            .with_project_mut("initialize_global_config", |ctx| {
                ctx.global_config = latest_config;
            })
            .await;
    }

    Ok(InitGlobalConfigResultView {
        created,
        path: path.to_string_lossy().to_string(),
    })
}

pub async fn initialize_project_scaffold(
    input: InitializeProjectScaffoldInput,
    state: &AppState,
) -> Result<InitProjectScaffoldResultView, String> {
    let root = normalize_scaffold_path(&input.path)?;
    let metadata = tokio::fs::metadata(&root)
        .await
        .map_err(|e| format!("project path is not accessible: {e}"))?;
    if !metadata.is_dir() {
        return Err("project path must be a directory".to_string());
    }

    let mut created_paths = Vec::new();
    for rel in [
        ".pnevma",
        ".pnevma/data",
        ".pnevma/rules",
        ".pnevma/conventions",
    ] {
        let path = root.join(rel);
        if !path.exists() {
            tokio::fs::create_dir_all(&path)
                .await
                .map_err(|e| e.to_string())?;
            created_paths.push(path.to_string_lossy().to_string());
        }
    }

    let global = load_global_config().unwrap_or_default();
    let default_provider = normalize_default_provider(
        input
            .default_provider
            .as_deref()
            .or(global.default_provider.as_deref()),
    );

    let config_path = root.join("pnevma.toml");
    if !config_path.exists() {
        let content = build_default_project_toml(
            &root,
            input.project_name.as_deref(),
            input.project_brief.as_deref(),
            &default_provider,
        );
        tokio::fs::write(&config_path, content.as_bytes())
            .await
            .map_err(|e| e.to_string())?;
        created_paths.push(config_path.to_string_lossy().to_string());
    }

    let rule_seed = root.join(".pnevma/rules/project-rules.md");
    if !rule_seed.exists() {
        let content = "\
# Project Rules

- Keep work scoped to the active task contract.
- Prefer deterministic checks before requesting review.
";
        tokio::fs::write(&rule_seed, content.as_bytes())
            .await
            .map_err(|e| e.to_string())?;
        created_paths.push(rule_seed.to_string_lossy().to_string());
    }

    let convention_seed = root.join(".pnevma/conventions/conventions.md");
    if !convention_seed.exists() {
        let content = "\
# Conventions

- Write concise commit messages in imperative mood.
- Capture reusable decisions in ADR knowledge artifacts.
";
        tokio::fs::write(&convention_seed, content.as_bytes())
            .await
            .map_err(|e| e.to_string())?;
        created_paths.push(convention_seed.to_string_lossy().to_string());
    }

    {
        let _ = state
            .with_project_mut("initialize_project_scaffold", |ctx| {
                if ctx.project_path == root {
                    if let Ok(cfg) = load_project_config(&config_path) {
                        ctx.config = cfg;
                    }
                }
            })
            .await;
    }

    Ok(InitProjectScaffoldResultView {
        root_path: root.to_string_lossy().to_string(),
        already_initialized: created_paths.is_empty(),
        created_paths,
    })
}
