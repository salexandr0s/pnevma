use super::*;

#[tokio::test]
async fn search_tasks_by_title() {
    let db = open_test_db().await;
    let pid = Uuid::new_v4().to_string();
    db.upsert_project(&pid, "test", "/tmp/test", None, None)
        .await
        .unwrap();

    db.create_task(&make_task(&pid, "Fix the widget renderer"))
        .await
        .unwrap();

    let hits = search_db("widget", 10, &db, &pid).await.unwrap();
    assert!(!hits.is_empty());
    assert_eq!(hits[0].source, "task");
    assert!(hits[0].title.contains("widget"));
}

#[tokio::test]
async fn search_no_results() {
    let db = open_test_db().await;
    let pid = Uuid::new_v4().to_string();
    db.upsert_project(&pid, "test", "/tmp/test", None, None)
        .await
        .unwrap();

    let hits = search_db("xyznonexistent", 10, &db, &pid).await.unwrap();
    assert!(hits.is_empty());
}

#[tokio::test]
async fn search_respects_limit() {
    let db = open_test_db().await;
    let pid = Uuid::new_v4().to_string();
    db.upsert_project(&pid, "test", "/tmp/test", None, None)
        .await
        .unwrap();

    for i in 0..5 {
        db.create_task(&make_task(&pid, &format!("Widget task {i}")))
            .await
            .unwrap();
    }

    let hits = search_db("widget", 2, &db, &pid).await.unwrap();
    assert_eq!(hits.len(), 2);
}

#[tokio::test]
async fn search_events_by_type() {
    let db = open_test_db().await;
    let pid = Uuid::new_v4().to_string();
    db.upsert_project(&pid, "test", "/tmp/test", None, None)
        .await
        .unwrap();

    let event = NewEvent {
        id: Uuid::new_v4().to_string(),
        project_id: pid.clone(),
        task_id: None,
        session_id: None,
        trace_id: Uuid::new_v4().to_string(),
        source: "system".to_string(),
        // Use space-separated words so FTS5 tokenizer can match individual terms.
        // CamelCase like "DeploymentStarted" is a single FTS token and won't
        // match a search for "deployment".
        event_type: "deployment started".to_string(),
        payload: serde_json::json!({"env": "staging"}),
    };
    db.append_event(event).await.unwrap();

    let hits = search_db("deployment", 10, &db, &pid).await.unwrap();
    assert!(!hits.is_empty());
    assert_eq!(hits[0].source, "event");
    assert!(hits[0].title.contains("deployment"));
}

#[tokio::test]
async fn fts_fallback_exercised() {
    let db = open_test_db().await;
    let pid = Uuid::new_v4().to_string();
    db.upsert_project(&pid, "test", "/tmp/test", None, None)
        .await
        .unwrap();

    // Insert data while FTS tables and triggers still exist.
    db.create_task(&make_task(&pid, "Fallback search target"))
        .await
        .unwrap();

    // Drop FTS triggers and tables to force the in-memory scan fallback path.
    // Triggers must go first — they reference the FTS tables and would fire
    // errors on any subsequent task/event mutations.
    for stmt in [
        "DROP TRIGGER IF EXISTS tasks_fts_insert",
        "DROP TRIGGER IF EXISTS tasks_fts_update",
        "DROP TRIGGER IF EXISTS tasks_fts_delete",
        "DROP TRIGGER IF EXISTS events_fts_insert",
        "DROP TABLE IF EXISTS tasks_fts",
        "DROP TABLE IF EXISTS events_fts",
    ] {
        sqlx::query(stmt).execute(db.pool()).await.unwrap();
    }

    let hits = search_db("Fallback", 10, &db, &pid).await.unwrap();
    assert!(!hits.is_empty());
    assert_eq!(hits[0].source, "task");
    assert!(hits[0].title.contains("Fallback"));
}

#[tokio::test]
async fn search_artifacts_by_path() {
    let db = open_test_db().await;
    let pid = Uuid::new_v4().to_string();
    db.upsert_project(&pid, "test", "/tmp/test", None, None)
        .await
        .unwrap();

    let artifact = ArtifactRow {
        id: Uuid::new_v4().to_string(),
        project_id: pid.clone(),
        task_id: None,
        r#type: "document".to_string(),
        path: "docs/architecture.md".to_string(),
        description: Some("System architecture overview".to_string()),
        created_at: chrono::Utc::now(),
    };
    db.create_artifact(&artifact).await.unwrap();

    let hits = search_db("architecture", 10, &db, &pid).await.unwrap();
    assert!(!hits.is_empty());
    assert_eq!(hits[0].source, "artifact");
}

#[tokio::test]
async fn search_does_not_leak_across_projects() {
    let db = open_test_db().await;
    let pid_a = Uuid::new_v4().to_string();
    let pid_b = Uuid::new_v4().to_string();
    db.upsert_project(&pid_a, "alpha", "/tmp/a", None, None)
        .await
        .unwrap();
    db.upsert_project(&pid_b, "beta", "/tmp/b", None, None)
        .await
        .unwrap();

    // Insert task in project A only
    db.create_task(&make_task(&pid_a, "Unique crosscheck"))
        .await
        .unwrap();

    // Search in project B via FTS path → should find nothing
    let hits = search_db("crosscheck", 10, &db, &pid_b).await.unwrap();
    assert!(hits.is_empty(), "FTS path must not leak across projects");

    // Drop FTS to verify fallback path also isolates by project
    sqlx::query("DROP TRIGGER IF EXISTS tasks_fts_insert")
        .execute(db.pool())
        .await
        .unwrap();
    sqlx::query("DROP TRIGGER IF EXISTS tasks_fts_update")
        .execute(db.pool())
        .await
        .unwrap();
    sqlx::query("DROP TRIGGER IF EXISTS tasks_fts_delete")
        .execute(db.pool())
        .await
        .unwrap();
    sqlx::query("DROP TABLE IF EXISTS tasks_fts")
        .execute(db.pool())
        .await
        .unwrap();
    let hits = search_db("crosscheck", 10, &db, &pid_b).await.unwrap();
    assert!(
        hits.is_empty(),
        "fallback path must not leak across projects"
    );
}

#[test]
fn validate_path_component_rejects_traversal() {
    assert!(validate_path_component("../etc", "test").is_err());
    assert!(validate_path_component("foo/bar", "test").is_err());
    assert!(validate_path_component("foo\\bar", "test").is_err());
    assert!(validate_path_component("", "test").is_err());
    assert!(validate_path_component("foo\0bar", "test").is_err());
    assert!(validate_path_component("valid-name", "test").is_ok());
    assert!(validate_path_component("task-123", "test").is_ok());
}

#[test]
fn session_and_path_inputs_are_bounded() {
    assert!(ensure_bounded_text_field("shell", "session name", MAX_SESSION_NAME_BYTES).is_ok());
    assert!(
        ensure_bounded_text_field("bad\nname", "session name", MAX_SESSION_NAME_BYTES).is_err()
    );
    assert!(ensure_safe_path_input("src/main.rs", "file path").is_ok());
    assert!(ensure_safe_path_input("src/\0main.rs", "file path").is_err());
    assert!(ensure_safe_session_input("pwd\n").is_ok());
    assert!(ensure_safe_session_input(&"x".repeat(MAX_SESSION_INPUT_BYTES + 1)).is_err());
}

#[tokio::test]
async fn list_project_file_tree_lists_directory_entries_including_hidden_entries() {
    let temp = tempfile::tempdir().expect("tempdir");
    let project_root = temp.path().join("project");
    std::fs::create_dir_all(project_root.join("src")).unwrap();
    std::fs::create_dir_all(project_root.join(".git")).unwrap();
    std::fs::create_dir_all(project_root.join(".pnevma/data")).unwrap();
    std::fs::write(project_root.join("src/lib.rs"), "pub fn tree() {}\n").unwrap();
    std::fs::write(project_root.join(".env"), "TOKEN=secret\n").unwrap();
    std::fs::write(project_root.join(".git/config"), "[core]\n").unwrap();
    std::fs::write(project_root.join(".pnevma/data/runtime.log"), "runtime\n").unwrap();

    let db = open_test_db().await;
    let project_id = Uuid::new_v4();
    db.upsert_project(
        &project_id.to_string(),
        "tree-test",
        project_root.to_string_lossy().as_ref(),
        None,
        None,
    )
    .await
    .unwrap();

    let sessions = SessionSupervisor::new(project_root.join(".pnevma/data"));
    let state = make_state_with_project(project_id, &project_root, db, sessions).await;
    let nodes = list_project_file_tree(None, &state)
        .await
        .expect("file tree should load");

    let src = nodes
        .iter()
        .find(|node| node.path == "src" && node.is_directory)
        .expect("src directory should be present");
    assert!(src.children.is_none(), "src should load lazily");
    assert!(nodes.iter().any(|node| node.path == ".env"));
    assert!(nodes.iter().any(|node| node.path == ".git"));
    assert!(nodes.iter().any(|node| node.path == ".pnevma"));
}

#[tokio::test]
async fn list_project_file_tree_loads_subdirectory_entries() {
    let temp = tempfile::tempdir().expect("tempdir");
    let project_root = temp.path().join("project");
    std::fs::create_dir_all(project_root.join("src")).unwrap();
    std::fs::write(project_root.join("src/lib.rs"), "pub fn preview() {}\n").unwrap();

    let db = open_test_db().await;
    let project_id = Uuid::new_v4();
    db.upsert_project(
        &project_id.to_string(),
        "tree-preview-test",
        project_root.to_string_lossy().as_ref(),
        None,
        None,
    )
    .await
    .unwrap();

    let sessions = SessionSupervisor::new(project_root.join(".pnevma/data"));
    let state = make_state_with_project(project_id, &project_root, db, sessions).await;
    let nodes = list_project_file_tree(
        Some(ListProjectFilesInput {
            query: None,
            limit: None,
            path: Some("src".to_string()),
            recursive: None,
        }),
        &state,
    )
    .await
    .expect("file tree should load");

    let lib_rs = nodes
        .iter()
        .find(|node| node.path == "src/lib.rs" && !node.is_directory)
        .expect("lib.rs should be present");

    assert_eq!(lib_rs.id, "src/lib.rs");
    assert_eq!(lib_rs.name, "lib.rs");
    assert!(lib_rs.size.unwrap_or_default() > 0);
    assert!(nodes.iter().all(|node| !node.path.starts_with(".git")));
}

#[tokio::test]
async fn open_file_target_accepts_path_from_file_tree() {
    let temp = tempfile::tempdir().expect("tempdir");
    let project_root = temp.path().join("project");
    std::fs::create_dir_all(project_root.join("src")).unwrap();
    std::fs::write(project_root.join("src/lib.rs"), "pub fn preview() {}\n").unwrap();

    let db = open_test_db().await;
    let project_id = Uuid::new_v4();
    db.upsert_project(
        &project_id.to_string(),
        "tree-preview-test",
        project_root.to_string_lossy().as_ref(),
        None,
        None,
    )
    .await
    .unwrap();

    let sessions = SessionSupervisor::new(project_root.join(".pnevma/data"));
    let state = make_state_with_project(project_id, &project_root, db, sessions).await;
    let nodes = list_project_file_tree(
        Some(ListProjectFilesInput {
            query: None,
            limit: None,
            path: Some("src".to_string()),
            recursive: None,
        }),
        &state,
    )
    .await
    .expect("file tree should load");
    let lib_rs_path = nodes
        .iter()
        .find(|node| node.path == "src/lib.rs" && !node.is_directory)
        .map(|node| node.path.clone())
        .expect("lib.rs path should be available");

    let opened = open_file_target(
        OpenFileTargetInput {
            path: lib_rs_path,
            mode: Some("preview".to_string()),
        },
        &state,
    )
    .await
    .expect("preview should load");

    assert_eq!(opened.path, "src/lib.rs");
    assert!(opened.content.contains("preview"));
}

#[tokio::test]
async fn list_project_file_tree_recursive_query_finds_ignored_files() {
    let temp = tempfile::tempdir().expect("tempdir");
    let project_root = temp.path().join("project");
    std::fs::create_dir_all(&project_root).unwrap();
    std::fs::write(project_root.join(".gitignore"), "AGENTS.md\n").unwrap();
    std::fs::write(project_root.join("AGENTS.md"), "ignored but visible\n").unwrap();

    let db = open_test_db().await;
    let project_id = Uuid::new_v4();
    db.upsert_project(
        &project_id.to_string(),
        "tree-search-test",
        project_root.to_string_lossy().as_ref(),
        None,
        None,
    )
    .await
    .unwrap();

    let sessions = SessionSupervisor::new(project_root.join(".pnevma/data"));
    let state = make_state_with_project(project_id, &project_root, db, sessions).await;
    let nodes = list_project_file_tree(
        Some(ListProjectFilesInput {
            query: Some("agents.md".to_string()),
            limit: None,
            path: None,
            recursive: Some(true),
        }),
        &state,
    )
    .await
    .expect("recursive file tree search should load");

    assert_eq!(nodes.len(), 1);
    let agents = nodes.first().expect("AGENTS.md should be returned");
    assert_eq!(agents.path, "AGENTS.md");
    assert!(!agents.is_directory);
}

#[tokio::test]
async fn list_project_file_tree_recursive_query_limit_is_deterministic() {
    let temp = tempfile::tempdir().expect("tempdir");
    let project_root = temp.path().join("project");
    std::fs::create_dir_all(&project_root).unwrap();
    std::fs::write(project_root.join("beta-match.txt"), "beta\n").unwrap();
    std::fs::write(project_root.join("alpha-match.txt"), "alpha\n").unwrap();
    std::fs::write(project_root.join("gamma-match.txt"), "gamma\n").unwrap();

    let db = open_test_db().await;
    let project_id = Uuid::new_v4();
    db.upsert_project(
        &project_id.to_string(),
        "tree-search-limit-test",
        project_root.to_string_lossy().as_ref(),
        None,
        None,
    )
    .await
    .unwrap();

    let sessions = SessionSupervisor::new(project_root.join(".pnevma/data"));
    let state = make_state_with_project(project_id, &project_root, db, sessions).await;
    let nodes = list_project_file_tree(
        Some(ListProjectFilesInput {
            query: Some("match".to_string()),
            limit: Some(1),
            path: None,
            recursive: Some(true),
        }),
        &state,
    )
    .await
    .expect("recursive limited file tree search should load");

    assert_eq!(nodes.len(), 1);
    assert_eq!(nodes[0].path, "alpha-match.txt");
}

#[cfg(unix)]
#[tokio::test]
async fn list_project_file_tree_recursive_query_preserves_symlink_alias_paths() {
    use std::os::unix::fs::symlink;

    let temp = tempfile::tempdir().expect("tempdir");
    let project_root = temp.path().join("project");
    std::fs::create_dir_all(project_root.join("docs")).unwrap();
    std::fs::write(project_root.join("docs/AGENTS.md"), "nested file\n").unwrap();
    symlink("docs", project_root.join("alias")).unwrap();

    let db = open_test_db().await;
    let project_id = Uuid::new_v4();
    db.upsert_project(
        &project_id.to_string(),
        "tree-search-alias-test",
        project_root.to_string_lossy().as_ref(),
        None,
        None,
    )
    .await
    .unwrap();

    let sessions = SessionSupervisor::new(project_root.join(".pnevma/data"));
    let state = make_state_with_project(project_id, &project_root, db, sessions).await;
    let nodes = list_project_file_tree(
        Some(ListProjectFilesInput {
            query: Some("agents.md".to_string()),
            limit: None,
            path: None,
            recursive: Some(true),
        }),
        &state,
    )
    .await
    .expect("recursive file tree search should preserve alias paths");

    let alias = nodes
        .iter()
        .find(|node| node.path == "alias")
        .expect("alias directory should be returned");
    let alias_children = alias
        .children
        .as_ref()
        .expect("alias should include matching children");
    assert!(alias_children
        .iter()
        .any(|node| node.path == "alias/AGENTS.md"));
    assert!(
        !alias_children
            .iter()
            .any(|node| node.path == "docs/AGENTS.md"),
        "alias subtree should not leak canonical child paths"
    );
}

#[cfg(unix)]
#[tokio::test]
async fn list_project_file_tree_recursive_query_skips_symlink_cycles() {
    use std::os::unix::fs::symlink;

    let temp = tempfile::tempdir().expect("tempdir");
    let project_root = temp.path().join("project");
    std::fs::create_dir_all(project_root.join("docs")).unwrap();
    std::fs::write(project_root.join("docs/AGENTS.md"), "nested file\n").unwrap();
    symlink(".", project_root.join("docs/loop")).unwrap();

    let db = open_test_db().await;
    let project_id = Uuid::new_v4();
    db.upsert_project(
        &project_id.to_string(),
        "tree-search-cycle-test",
        project_root.to_string_lossy().as_ref(),
        None,
        None,
    )
    .await
    .unwrap();

    let sessions = SessionSupervisor::new(project_root.join(".pnevma/data"));
    let state = make_state_with_project(project_id, &project_root, db, sessions).await;
    let nodes = list_project_file_tree(
        Some(ListProjectFilesInput {
            query: Some("agents.md".to_string()),
            limit: None,
            path: None,
            recursive: Some(true),
        }),
        &state,
    )
    .await
    .expect("recursive file tree search should skip cycles");

    assert_eq!(nodes.len(), 1);
    assert_eq!(nodes[0].path, "docs");
    let children = nodes[0]
        .children
        .as_ref()
        .expect("matching directory should include children");
    assert_eq!(children.len(), 1);
    assert_eq!(children[0].path, "docs/AGENTS.md");
}

#[tokio::test]
async fn open_file_target_reports_binary_preview_unavailable() {
    let temp = tempfile::tempdir().expect("tempdir");
    let project_root = temp.path().join("project");
    std::fs::create_dir_all(project_root.join("assets")).unwrap();
    std::fs::write(project_root.join("assets/icon.bin"), [0_u8, 159, 146, 150]).unwrap();

    let db = open_test_db().await;
    let project_id = Uuid::new_v4();
    db.upsert_project(
        &project_id.to_string(),
        "tree-binary-preview-test",
        project_root.to_string_lossy().as_ref(),
        None,
        None,
    )
    .await
    .unwrap();

    let sessions = SessionSupervisor::new(project_root.join(".pnevma/data"));
    let state = make_state_with_project(project_id, &project_root, db, sessions).await;

    let opened = open_file_target(
        OpenFileTargetInput {
            path: "assets/icon.bin".to_string(),
            mode: Some("preview".to_string()),
        },
        &state,
    )
    .await
    .expect("binary preview should return a placeholder");

    assert_eq!(opened.path, "assets/icon.bin");
    assert_eq!(opened.content, "[Binary file preview unavailable]");
    assert!(!opened.truncated);
}

#[tokio::test]
async fn list_workspace_changes_returns_only_dirty_entries() {
    let temp = tempfile::tempdir().expect("tempdir");
    let project_root = temp.path().join("project");
    std::fs::create_dir_all(project_root.join("src")).unwrap();

    run_git(&project_root, &["init"]);
    run_git(
        &project_root,
        &["config", "user.email", "tests@example.com"],
    );
    run_git(&project_root, &["config", "user.name", "Pnevma Tests"]);

    std::fs::write(project_root.join("src/lib.rs"), "pub fn clean() {}\n").unwrap();
    run_git(&project_root, &["add", "src/lib.rs"]);
    run_git(&project_root, &["commit", "-m", "initial"]);

    std::fs::write(project_root.join("src/lib.rs"), "pub fn dirty() {}\n").unwrap();
    std::fs::write(project_root.join("notes.txt"), "draft\n").unwrap();

    let db = open_test_db().await;
    let project_id = Uuid::new_v4();
    db.upsert_project(
        &project_id.to_string(),
        "workspace-changes-test",
        project_root.to_string_lossy().as_ref(),
        None,
        None,
    )
    .await
    .unwrap();

    let sessions = SessionSupervisor::new(project_root.join(".pnevma/data"));
    let state = make_state_with_project(project_id, &project_root, db, sessions).await;

    let changes = list_workspace_changes(&state)
        .await
        .expect("workspace changes should load");

    assert_eq!(changes.len(), 2);
    assert!(changes
        .iter()
        .any(|item| item.path == "src/lib.rs" && item.modified));
    assert!(changes
        .iter()
        .any(|item| item.path == "notes.txt" && item.untracked));
}

#[tokio::test]
async fn list_workspace_changes_includes_dirty_files_beyond_project_file_limit() {
    let temp = tempfile::tempdir().expect("tempdir");
    let project_root = temp.path().join("project");
    std::fs::create_dir_all(&project_root).unwrap();

    run_git(&project_root, &["init"]);
    run_git(
        &project_root,
        &["config", "user.email", "tests@example.com"],
    );
    run_git(&project_root, &["config", "user.name", "Pnevma Tests"]);

    for index in 0..=5_000 {
        let file_name = format!("file-{index:04}.txt");
        std::fs::write(project_root.join(file_name), "clean\n").unwrap();
    }
    std::fs::write(project_root.join("zzzz-dirty.txt"), "before\n").unwrap();
    run_git(&project_root, &["add", "."]);
    run_git(&project_root, &["commit", "-m", "initial"]);

    std::fs::write(project_root.join("zzzz-dirty.txt"), "after\n").unwrap();

    let db = open_test_db().await;
    let project_id = Uuid::new_v4();
    db.upsert_project(
        &project_id.to_string(),
        "workspace-changes-large-test",
        project_root.to_string_lossy().as_ref(),
        None,
        None,
    )
    .await
    .unwrap();

    let sessions = SessionSupervisor::new(project_root.join(".pnevma/data"));
    let state = make_state_with_project(project_id, &project_root, db, sessions).await;

    let changes = list_workspace_changes(&state)
        .await
        .expect("workspace changes should load");

    assert_eq!(changes.len(), 1);
    assert_eq!(changes[0].path, "zzzz-dirty.txt");
    assert!(changes[0].modified);
}

#[tokio::test]
async fn list_workspace_changes_expands_untracked_directories() {
    let temp = tempfile::tempdir().expect("tempdir");
    let project_root = temp.path().join("project");
    std::fs::create_dir_all(project_root.join("newdir/subdir")).unwrap();

    run_git(&project_root, &["init"]);
    run_git(
        &project_root,
        &["config", "user.email", "tests@example.com"],
    );
    run_git(&project_root, &["config", "user.name", "Pnevma Tests"]);

    std::fs::write(project_root.join("newdir/a.txt"), "a\n").unwrap();
    std::fs::write(project_root.join("newdir/subdir/b.txt"), "b\n").unwrap();

    let db = open_test_db().await;
    let project_id = Uuid::new_v4();
    db.upsert_project(
        &project_id.to_string(),
        "workspace-changes-untracked-dir-test",
        project_root.to_string_lossy().as_ref(),
        None,
        None,
    )
    .await
    .unwrap();

    let sessions = SessionSupervisor::new(project_root.join(".pnevma/data"));
    let state = make_state_with_project(project_id, &project_root, db, sessions).await;

    let changes = list_workspace_changes(&state)
        .await
        .expect("workspace changes should enumerate untracked files");

    assert_eq!(changes.len(), 2);
    assert!(changes
        .iter()
        .any(|item| item.path == "newdir/a.txt" && item.untracked));
    assert!(changes
        .iter()
        .any(|item| item.path == "newdir/subdir/b.txt" && item.untracked));
    assert!(!changes.iter().any(|item| item.path == "newdir/"));
}

#[tokio::test]
async fn workspace_changes_and_diff_support_paths_with_spaces() {
    let temp = tempfile::tempdir().expect("tempdir");
    let project_root = temp.path().join("project");
    std::fs::create_dir_all(&project_root).unwrap();

    run_git(&project_root, &["init"]);
    run_git(
        &project_root,
        &["config", "user.email", "tests@example.com"],
    );
    run_git(&project_root, &["config", "user.name", "Pnevma Tests"]);

    std::fs::write(project_root.join("hello world.txt"), "before\n").unwrap();

    let db = open_test_db().await;
    let project_id = Uuid::new_v4();
    db.upsert_project(
        &project_id.to_string(),
        "workspace-changes-spaces-test",
        project_root.to_string_lossy().as_ref(),
        None,
        None,
    )
    .await
    .unwrap();

    let sessions = SessionSupervisor::new(project_root.join(".pnevma/data"));
    let state = make_state_with_project(project_id, &project_root, db, sessions).await;

    let changes = list_workspace_changes(&state)
        .await
        .expect("workspace changes should load quoted paths");
    assert_eq!(changes.len(), 1);
    assert_eq!(changes[0].path, "hello world.txt");
    assert!(changes[0].untracked);

    let diff = get_workspace_change_diff(
        ProjectFilePathInput {
            path: "hello world.txt".to_string(),
        },
        &state,
    )
    .await
    .expect("workspace diff should load quoted paths")
    .expect("modified file should have diff");

    assert_eq!(diff.path, "hello world.txt");
    assert!(diff
        .hunks
        .iter()
        .flat_map(|hunk| hunk.lines.iter())
        .any(|line| line == "+before"));
}

#[tokio::test]
async fn list_workspace_changes_tracks_renamed_paths_once() {
    let temp = tempfile::tempdir().expect("tempdir");
    let project_root = temp.path().join("project");
    std::fs::create_dir_all(&project_root).unwrap();

    run_git(&project_root, &["init"]);
    run_git(
        &project_root,
        &["config", "user.email", "tests@example.com"],
    );
    run_git(&project_root, &["config", "user.name", "Pnevma Tests"]);

    std::fs::write(project_root.join("old.txt"), "before\n").unwrap();
    run_git(&project_root, &["add", "old.txt"]);
    run_git(&project_root, &["commit", "-m", "initial"]);
    run_git(&project_root, &["mv", "old.txt", "renamed file.txt"]);

    let db = open_test_db().await;
    let project_id = Uuid::new_v4();
    db.upsert_project(
        &project_id.to_string(),
        "workspace-changes-rename-test",
        project_root.to_string_lossy().as_ref(),
        None,
        None,
    )
    .await
    .unwrap();

    let sessions = SessionSupervisor::new(project_root.join(".pnevma/data"));
    let state = make_state_with_project(project_id, &project_root, db, sessions).await;

    let changes = list_workspace_changes(&state)
        .await
        .expect("workspace changes should load rename entries");

    assert_eq!(changes.len(), 1);
    assert_eq!(changes[0].path, "renamed file.txt");
    assert!(changes[0].staged);
}

#[tokio::test]
async fn workspace_change_diff_preserves_hunk_lines_starting_with_header_markers() {
    let temp = tempfile::tempdir().expect("tempdir");
    let project_root = temp.path().join("project");
    std::fs::create_dir_all(&project_root).unwrap();

    run_git(&project_root, &["init"]);
    run_git(
        &project_root,
        &["config", "user.email", "tests@example.com"],
    );
    run_git(&project_root, &["config", "user.name", "Pnevma Tests"]);

    std::fs::write(project_root.join("marker.txt"), "-- heading\n").unwrap();
    run_git(&project_root, &["add", "marker.txt"]);
    run_git(&project_root, &["commit", "-m", "initial"]);
    std::fs::write(project_root.join("marker.txt"), "++ heading\n").unwrap();

    let db = open_test_db().await;
    let project_id = Uuid::new_v4();
    db.upsert_project(
        &project_id.to_string(),
        "workspace-change-diff-marker-lines-test",
        project_root.to_string_lossy().as_ref(),
        None,
        None,
    )
    .await
    .unwrap();

    let sessions = SessionSupervisor::new(project_root.join(".pnevma/data"));
    let state = make_state_with_project(project_id, &project_root, db, sessions).await;

    let diff = get_workspace_change_diff(
        ProjectFilePathInput {
            path: "marker.txt".to_string(),
        },
        &state,
    )
    .await
    .expect("workspace diff should preserve header-like hunk lines")
    .expect("untracked file should have diff");

    let lines = diff
        .hunks
        .iter()
        .flat_map(|hunk| hunk.lines.iter())
        .cloned()
        .collect::<Vec<_>>();

    assert_eq!(diff.path, "marker.txt");
    assert!(lines.iter().any(|line| line == "+++ heading"));
    assert!(lines.iter().any(|line| line == "--- heading"));
}

#[tokio::test]
async fn get_workspace_change_diff_returns_untracked_file_patch() {
    let temp = tempfile::tempdir().expect("tempdir");
    let project_root = temp.path().join("project");
    std::fs::create_dir_all(&project_root).unwrap();

    run_git(&project_root, &["init"]);
    run_git(
        &project_root,
        &["config", "user.email", "tests@example.com"],
    );
    run_git(&project_root, &["config", "user.name", "Pnevma Tests"]);

    std::fs::write(project_root.join("draft.txt"), "hello\nworld\n").unwrap();

    let db = open_test_db().await;
    let project_id = Uuid::new_v4();
    db.upsert_project(
        &project_id.to_string(),
        "workspace-change-diff-test",
        project_root.to_string_lossy().as_ref(),
        None,
        None,
    )
    .await
    .unwrap();

    let sessions = SessionSupervisor::new(project_root.join(".pnevma/data"));
    let state = make_state_with_project(project_id, &project_root, db, sessions).await;

    let diff = get_workspace_change_diff(
        ProjectFilePathInput {
            path: "draft.txt".to_string(),
        },
        &state,
    )
    .await
    .expect("workspace change diff should load")
    .expect("untracked file should produce a diff");

    assert_eq!(diff.path, "draft.txt");
    assert!(diff
        .hunks
        .iter()
        .flat_map(|hunk| hunk.lines.iter())
        .any(|line| line == "+hello"));
    assert!(diff
        .hunks
        .iter()
        .flat_map(|hunk| hunk.lines.iter())
        .any(|line| line == "+world"));
}

#[tokio::test]
async fn write_file_target_writes_content_and_returns_bytes() {
    let temp = tempfile::tempdir().expect("tempdir");
    let project_root = temp.path().join("project");
    std::fs::create_dir_all(project_root.join("src")).unwrap();
    std::fs::write(project_root.join("src/lib.rs"), "old content\n").unwrap();

    let db = open_test_db().await;
    let project_id = Uuid::new_v4();
    db.upsert_project(
        &project_id.to_string(),
        "write-test",
        project_root.to_string_lossy().as_ref(),
        None,
        None,
    )
    .await
    .unwrap();

    let sessions = SessionSupervisor::new(project_root.join(".pnevma/data"));
    let state = make_state_with_project(project_id, &project_root, db, sessions).await;

    let result = write_file_target(
        WriteFileInput {
            path: "src/lib.rs".to_string(),
            content: "new content\n".to_string(),
        },
        &state,
    )
    .await
    .expect("write should succeed");

    assert_eq!(result.path, "src/lib.rs");
    assert_eq!(result.bytes_written, 12);
    let on_disk = std::fs::read_to_string(project_root.join("src/lib.rs")).unwrap();
    assert_eq!(on_disk, "new content\n");
}

#[tokio::test]
async fn write_file_target_accepts_empty_content() {
    let temp = tempfile::tempdir().expect("tempdir");
    let project_root = temp.path().join("project");
    std::fs::create_dir_all(&project_root).unwrap();
    std::fs::write(project_root.join("empty.txt"), "not empty yet").unwrap();

    let db = open_test_db().await;
    let project_id = Uuid::new_v4();
    db.upsert_project(
        &project_id.to_string(),
        "write-empty-test",
        project_root.to_string_lossy().as_ref(),
        None,
        None,
    )
    .await
    .unwrap();

    let sessions = SessionSupervisor::new(project_root.join(".pnevma/data"));
    let state = make_state_with_project(project_id, &project_root, db, sessions).await;

    let result = write_file_target(
        WriteFileInput {
            path: "empty.txt".to_string(),
            content: String::new(),
        },
        &state,
    )
    .await
    .expect("writing empty content should succeed");

    assert_eq!(result.bytes_written, 0);
    let on_disk = std::fs::read_to_string(project_root.join("empty.txt")).unwrap();
    assert_eq!(on_disk, "");
}

#[tokio::test]
async fn write_file_target_rejects_path_traversal() {
    let temp = tempfile::tempdir().expect("tempdir");
    let project_root = temp.path().join("project");
    std::fs::create_dir_all(&project_root).unwrap();
    std::fs::write(project_root.join("safe.txt"), "safe").unwrap();
    // Create a file outside the project
    std::fs::write(temp.path().join("secret.txt"), "secret").unwrap();

    let db = open_test_db().await;
    let project_id = Uuid::new_v4();
    db.upsert_project(
        &project_id.to_string(),
        "write-traversal-test",
        project_root.to_string_lossy().as_ref(),
        None,
        None,
    )
    .await
    .unwrap();

    let sessions = SessionSupervisor::new(project_root.join(".pnevma/data"));
    let state = make_state_with_project(project_id, &project_root, db, sessions).await;

    let err = write_file_target(
        WriteFileInput {
            path: "../secret.txt".to_string(),
            content: "hacked".to_string(),
        },
        &state,
    )
    .await
    .expect_err("path traversal should be rejected");

    assert!(
        err.contains("path") || err.contains("unsafe"),
        "error should mention path: {err}"
    );
    // Verify the file outside the project wasn't modified
    let on_disk = std::fs::read_to_string(temp.path().join("secret.txt")).unwrap();
    assert_eq!(on_disk, "secret");
}

#[tokio::test]
async fn write_file_target_rejects_nonexistent_file() {
    let temp = tempfile::tempdir().expect("tempdir");
    let project_root = temp.path().join("project");
    std::fs::create_dir_all(&project_root).unwrap();

    let db = open_test_db().await;
    let project_id = Uuid::new_v4();
    db.upsert_project(
        &project_id.to_string(),
        "write-nonexistent-test",
        project_root.to_string_lossy().as_ref(),
        None,
        None,
    )
    .await
    .unwrap();

    let sessions = SessionSupervisor::new(project_root.join(".pnevma/data"));
    let state = make_state_with_project(project_id, &project_root, db, sessions).await;

    let err = write_file_target(
        WriteFileInput {
            path: "does_not_exist.txt".to_string(),
            content: "anything".to_string(),
        },
        &state,
    )
    .await
    .expect_err("writing to nonexistent file should fail");

    assert!(
        err.contains("not found"),
        "error should say not found: {err}"
    );
}
