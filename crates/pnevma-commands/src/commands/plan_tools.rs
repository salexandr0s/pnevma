use pnevma_agents::DynamicToolDef;
use serde_json::{json, Value};
use std::path::Path;
use tracing::debug;

/// Dynamic tool definitions for plan management.
pub fn plan_tool_defs() -> Vec<DynamicToolDef> {
    vec![
        DynamicToolDef {
            name: "plan.create".to_string(),
            description: "Create a plan file with YAML frontmatter and markdown content. Plans are stored at {project_root}/.pnevma/plans/{id}.md.".to_string(),
            parameters_schema: json!({
                "type": "object",
                "properties": {
                    "id": { "type": "string", "description": "Plan identifier (used as filename, e.g. 'refactor-auth')" },
                    "title": { "type": "string", "description": "Human-readable plan title" },
                    "content": { "type": "string", "description": "Plan content in markdown" }
                },
                "required": ["id", "title", "content"]
            }),
        },
        DynamicToolDef {
            name: "plan.update".to_string(),
            description: "Update an existing plan file. Can update status (draft, approved, in_progress, complete) and/or content.".to_string(),
            parameters_schema: json!({
                "type": "object",
                "properties": {
                    "id": { "type": "string", "description": "Plan identifier" },
                    "status": { "type": "string", "description": "New status: draft, approved, in_progress, complete" },
                    "content": { "type": "string", "description": "Updated plan content (replaces body, preserves frontmatter)" }
                },
                "required": ["id"]
            }),
        },
        DynamicToolDef {
            name: "plan.read".to_string(),
            description: "Read a plan file and return its frontmatter and content.".to_string(),
            parameters_schema: json!({
                "type": "object",
                "properties": {
                    "id": { "type": "string", "description": "Plan identifier" }
                },
                "required": ["id"]
            }),
        },
    ]
}

/// Handle a plan tool call from the agent.
pub async fn handle_plan_tool_call(
    call_id: &str,
    tool_name: &str,
    params: &Value,
    project_path: &Path,
) -> Value {
    debug!(
        call_id = %call_id,
        tool_name = %tool_name,
        "handling plan tool call"
    );

    match tool_name {
        "plan.create" => handle_plan_create(params, project_path).await,
        "plan.update" => handle_plan_update(params, project_path).await,
        "plan.read" => handle_plan_read(params, project_path).await,
        _ => {
            json!({
                "error": format!("unknown plan tool: {}", tool_name),
                "success": false
            })
        }
    }
}

fn plans_dir(project_path: &Path) -> std::path::PathBuf {
    project_path.join(".pnevma/plans")
}

fn sanitize_id(id: &str) -> Result<String, Value> {
    let id = id.trim();
    if id.is_empty() {
        return Err(json!({"error": "plan id cannot be empty", "success": false}));
    }
    // Prevent path traversal
    if id.contains("..") || id.contains('/') || id.contains('\\') {
        return Err(json!({"error": "plan id contains invalid characters", "success": false}));
    }
    Ok(id.to_string())
}

async fn handle_plan_create(params: &Value, project_path: &Path) -> Value {
    let id = match params.get("id").and_then(|v| v.as_str()) {
        Some(id) => match sanitize_id(id) {
            Ok(id) => id,
            Err(e) => return e,
        },
        None => return json!({"error": "missing required parameter: id", "success": false}),
    };

    let title = match params.get("title").and_then(|v| v.as_str()) {
        Some(t) => t.to_string(),
        None => return json!({"error": "missing required parameter: title", "success": false}),
    };

    let content = match params.get("content").and_then(|v| v.as_str()) {
        Some(c) => c.to_string(),
        None => return json!({"error": "missing required parameter: content", "success": false}),
    };

    let dir = plans_dir(project_path);
    if let Err(e) = tokio::fs::create_dir_all(&dir).await {
        return json!({"error": format!("failed to create plans directory: {e}"), "success": false});
    }

    let path = dir.join(format!("{id}.md"));
    if path.is_file() {
        return json!({"error": format!("plan '{id}' already exists"), "success": false});
    }

    let now = chrono::Utc::now().to_rfc3339();
    let file_content = format!(
        "---\ntitle: {title}\nstatus: draft\ncreated_at: {now}\n---\n{content}\n",
        title = title,
        now = now,
        content = content
    );

    match tokio::fs::write(&path, &file_content).await {
        Ok(()) => {
            debug!(plan_id = %id, "created plan");
            json!({
                "success": true,
                "id": id,
                "path": path.to_string_lossy(),
                "status": "draft"
            })
        }
        Err(e) => json!({"error": format!("failed to write plan: {e}"), "success": false}),
    }
}

async fn handle_plan_update(params: &Value, project_path: &Path) -> Value {
    let id = match params.get("id").and_then(|v| v.as_str()) {
        Some(id) => match sanitize_id(id) {
            Ok(id) => id,
            Err(e) => return e,
        },
        None => return json!({"error": "missing required parameter: id", "success": false}),
    };

    let path = plans_dir(project_path).join(format!("{id}.md"));
    if !path.is_file() {
        return json!({"error": format!("plan '{id}' not found"), "success": false});
    }

    let existing = match tokio::fs::read_to_string(&path).await {
        Ok(c) => c,
        Err(e) => return json!({"error": format!("failed to read plan: {e}"), "success": false}),
    };

    // Parse existing frontmatter
    let (mut frontmatter, existing_body) = parse_plan_frontmatter(&existing);

    // Update title if provided
    if let Some(new_title) = params.get("title").and_then(|v| v.as_str()) {
        frontmatter.insert("title".to_string(), new_title.to_string());
    }

    // Update status if provided
    if let Some(new_status) = params.get("status").and_then(|v| v.as_str()) {
        match new_status {
            "draft" | "approved" | "in_progress" | "complete" => {
                frontmatter.insert("status".to_string(), new_status.to_string());
            }
            _ => {
                return json!({
                    "error": format!("invalid status: {new_status}. Must be draft, approved, in_progress, or complete"),
                    "success": false
                });
            }
        }
    }

    // Use new content if provided, otherwise keep existing body
    let body = params
        .get("content")
        .and_then(|v| v.as_str())
        .unwrap_or(&existing_body);

    // Rebuild the file
    let mut fm_lines = Vec::new();
    // Preserve key order: title, status, created_at, then any others
    for key in &["title", "status", "created_at"] {
        if let Some(val) = frontmatter.get(*key) {
            fm_lines.push(format!("{key}: {val}"));
        }
    }
    for (key, val) in &frontmatter {
        if !matches!(key.as_str(), "title" | "status" | "created_at") {
            fm_lines.push(format!("{key}: {val}"));
        }
    }

    let file_content = format!("---\n{}\n---\n{}\n", fm_lines.join("\n"), body);

    match tokio::fs::write(&path, &file_content).await {
        Ok(()) => {
            debug!(plan_id = %id, "updated plan");
            json!({
                "success": true,
                "id": id,
                "status": frontmatter.get("status").cloned().unwrap_or_default()
            })
        }
        Err(e) => json!({"error": format!("failed to write plan: {e}"), "success": false}),
    }
}

async fn handle_plan_read(params: &Value, project_path: &Path) -> Value {
    let id = match params.get("id").and_then(|v| v.as_str()) {
        Some(id) => match sanitize_id(id) {
            Ok(id) => id,
            Err(e) => return e,
        },
        None => return json!({"error": "missing required parameter: id", "success": false}),
    };

    let path = plans_dir(project_path).join(format!("{id}.md"));
    if !path.is_file() {
        return json!({"error": format!("plan '{id}' not found"), "success": false});
    }

    let content = match tokio::fs::read_to_string(&path).await {
        Ok(c) => c,
        Err(e) => return json!({"error": format!("failed to read plan: {e}"), "success": false}),
    };

    let (frontmatter, body) = parse_plan_frontmatter(&content);

    json!({
        "success": true,
        "id": id,
        "title": frontmatter.get("title").cloned().unwrap_or_default(),
        "status": frontmatter.get("status").cloned().unwrap_or("draft".to_string()),
        "created_at": frontmatter.get("created_at").cloned().unwrap_or_default(),
        "content": body,
        "raw": content
    })
}

/// Parse simple YAML frontmatter from a plan file.
fn parse_plan_frontmatter(content: &str) -> (std::collections::HashMap<String, String>, String) {
    let mut frontmatter = std::collections::HashMap::new();
    let trimmed = content.trim_start();

    if !trimmed.starts_with("---") {
        return (frontmatter, content.to_string());
    }

    let after_open = &trimmed[3..];
    let after_open = after_open
        .strip_prefix('\n')
        .or_else(|| after_open.strip_prefix("\r\n"))
        .unwrap_or(after_open);

    let close_marker = "\n---";
    let close_pos = match after_open.find(close_marker) {
        Some(pos) => pos,
        None => return (frontmatter, content.to_string()),
    };

    let yaml_str = &after_open[..close_pos];
    let after_close = &after_open[close_pos + close_marker.len()..];
    let body = after_close
        .strip_prefix('\n')
        .or_else(|| after_close.strip_prefix("\r\n"))
        .unwrap_or(after_close)
        .to_string();

    // Simple key: value parsing
    for line in yaml_str.lines() {
        if let Some((key, val)) = line.split_once(':') {
            let key = key.trim().to_string();
            let val = val.trim().to_string();
            if !key.is_empty() {
                frontmatter.insert(key, val);
            }
        }
    }

    (frontmatter, body)
}

// ── RPC handlers for UI ─────────────────────────────────────────────────────

use crate::state::AppState;

#[derive(Debug, serde::Deserialize)]
pub struct PlanListInput {
    // No params needed — uses current project
}

pub async fn list_plans(state: &AppState) -> Result<Value, String> {
    let guard = state.current.lock().await;
    let ctx = guard.as_ref().ok_or("no open project")?;
    let dir = plans_dir(&ctx.project_path);

    if !dir.is_dir() {
        return Ok(json!({"plans": []}));
    }

    let mut plans = Vec::new();
    let mut read_dir = tokio::fs::read_dir(&dir)
        .await
        .map_err(|e| format!("failed to read plans dir: {e}"))?;

    while let Some(entry) = read_dir.next_entry().await.map_err(|e| e.to_string())? {
        let path = entry.path();
        if path.extension().and_then(|e| e.to_str()) != Some("md") {
            continue;
        }
        let id = path
            .file_stem()
            .unwrap_or_default()
            .to_string_lossy()
            .to_string();
        if let Ok(content) = tokio::fs::read_to_string(&path).await {
            let (fm, _) = parse_plan_frontmatter(&content);
            plans.push(json!({
                "id": id,
                "title": fm.get("title").cloned().unwrap_or_default(),
                "status": fm.get("status").cloned().unwrap_or("draft".to_string()),
                "created_at": fm.get("created_at").cloned().unwrap_or_default(),
            }));
        }
    }

    Ok(json!({"plans": plans}))
}

#[derive(Debug, serde::Deserialize)]
pub struct PlanReadInput {
    pub id: String,
}

pub async fn read_plan(input: PlanReadInput, state: &AppState) -> Result<Value, String> {
    let guard = state.current.lock().await;
    let ctx = guard.as_ref().ok_or("no open project")?;
    Ok(handle_plan_read(&json!({"id": input.id}), &ctx.project_path).await)
}

#[derive(Debug, serde::Deserialize)]
pub struct PlanWriteInput {
    pub id: String,
    pub title: Option<String>,
    pub status: Option<String>,
    pub content: Option<String>,
}

pub async fn write_plan(input: PlanWriteInput, state: &AppState) -> Result<Value, String> {
    let id = sanitize_id(&input.id).map_err(|e| e.to_string())?;
    let guard = state.current.lock().await;
    let ctx = guard.as_ref().ok_or("no open project")?;
    let project_path = ctx.project_path.clone();
    drop(guard);

    let plan_path = plans_dir(&project_path).join(format!("{id}.md"));

    // If file doesn't exist, create it
    if !plan_path.is_file() {
        let title = input.title.unwrap_or_else(|| id.clone());
        let content = input.content.unwrap_or_default();
        let params = json!({"id": id, "title": title, "content": content});
        return Ok(handle_plan_create(&params, &project_path).await);
    }

    // Update existing
    let mut params = json!({"id": id});
    if let Some(status) = input.status {
        params["status"] = json!(status);
    }
    if let Some(title) = input.title {
        params["title"] = json!(title);
    }
    if let Some(content) = input.content {
        params["content"] = json!(content);
    }
    Ok(handle_plan_update(&params, &project_path).await)
}

#[derive(Debug, serde::Deserialize)]
pub struct PlanDeleteInput {
    pub id: String,
}

pub async fn delete_plan(input: PlanDeleteInput, state: &AppState) -> Result<Value, String> {
    let guard = state.current.lock().await;
    let ctx = guard.as_ref().ok_or("no open project")?;
    let id = sanitize_id(&input.id).map_err(|e| e.to_string())?;
    let path = plans_dir(&ctx.project_path).join(format!("{id}.md"));

    if !path.is_file() {
        return Err(format!("plan '{id}' not found"));
    }

    tokio::fs::remove_file(&path)
        .await
        .map_err(|e| format!("failed to delete plan: {e}"))?;

    debug!(plan_id = %id, "deleted plan");
    Ok(json!({"ok": true, "id": id}))
}

// ── Tests ───────────────────────────────────────────────────────────────────

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_plan_tool_defs_count() {
        let defs = plan_tool_defs();
        assert_eq!(defs.len(), 3);
        assert_eq!(defs[0].name, "plan.create");
        assert_eq!(defs[1].name, "plan.update");
        assert_eq!(defs[2].name, "plan.read");
    }

    #[test]
    fn test_sanitize_id() {
        assert!(sanitize_id("valid-id").is_ok());
        assert!(sanitize_id("refactor-auth").is_ok());
        assert!(sanitize_id("").is_err());
        assert!(sanitize_id("../escape").is_err());
        assert!(sanitize_id("path/traverse").is_err());
    }

    #[test]
    fn test_parse_plan_frontmatter() {
        let content =
            "---\ntitle: My Plan\nstatus: draft\ncreated_at: 2026-01-01\n---\n# Content here\n";
        let (fm, body) = parse_plan_frontmatter(content);
        assert_eq!(fm.get("title").unwrap(), "My Plan");
        assert_eq!(fm.get("status").unwrap(), "draft");
        assert!(body.contains("# Content here"));
    }

    #[test]
    fn test_parse_no_frontmatter() {
        let content = "Just plain text";
        let (fm, body) = parse_plan_frontmatter(content);
        assert!(fm.is_empty());
        assert_eq!(body, "Just plain text");
    }

    #[tokio::test]
    async fn test_plan_create_and_read() {
        let tmp = tempfile::tempdir().expect("tempdir");
        let project_path = tmp.path();

        let create_result = handle_plan_create(
            &json!({
                "id": "test-plan",
                "title": "Test Plan",
                "content": "# Step 1\nDo the thing"
            }),
            project_path,
        )
        .await;
        assert!(create_result.get("success").unwrap().as_bool().unwrap());
        assert_eq!(
            create_result.get("id").unwrap().as_str().unwrap(),
            "test-plan"
        );

        let read_result = handle_plan_read(&json!({"id": "test-plan"}), project_path).await;
        assert!(read_result.get("success").unwrap().as_bool().unwrap());
        assert_eq!(
            read_result.get("title").unwrap().as_str().unwrap(),
            "Test Plan"
        );
        assert!(read_result
            .get("content")
            .unwrap()
            .as_str()
            .unwrap()
            .contains("Step 1"));
    }

    #[tokio::test]
    async fn test_plan_update_status() {
        let tmp = tempfile::tempdir().expect("tempdir");
        let project_path = tmp.path();

        handle_plan_create(
            &json!({"id": "status-test", "title": "Status Test", "content": "content"}),
            project_path,
        )
        .await;

        let update_result = handle_plan_update(
            &json!({"id": "status-test", "status": "approved"}),
            project_path,
        )
        .await;
        assert!(update_result.get("success").unwrap().as_bool().unwrap());
        assert_eq!(
            update_result.get("status").unwrap().as_str().unwrap(),
            "approved"
        );

        let read_result = handle_plan_read(&json!({"id": "status-test"}), project_path).await;
        assert_eq!(
            read_result.get("status").unwrap().as_str().unwrap(),
            "approved"
        );
    }

    #[tokio::test]
    async fn test_plan_create_duplicate_rejected() {
        let tmp = tempfile::tempdir().expect("tempdir");
        let project_path = tmp.path();

        handle_plan_create(
            &json!({"id": "dup", "title": "Dup", "content": "content"}),
            project_path,
        )
        .await;

        let result = handle_plan_create(
            &json!({"id": "dup", "title": "Dup 2", "content": "other"}),
            project_path,
        )
        .await;
        assert!(result.get("error").is_some());
    }
}
