use super::*;

// ─── Global Workflow views ────────────────────────────────────────────────────

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct GlobalWorkflowView {
    pub id: String,
    pub name: String,
    pub description: Option<String>,
    pub source: String,
    pub created_at: DateTime<Utc>,
    pub updated_at: DateTime<Utc>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct CreateGlobalWorkflowInput {
    pub name: String,
    pub description: Option<String>,
    pub definition_yaml: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct UpdateGlobalWorkflowInput {
    pub id: String,
    pub name: Option<String>,
    pub description: Option<String>,
    pub definition_yaml: Option<String>,
}

// ─── Commands ────────────────────────────────────────────────────────────────

pub async fn list_global_workflows(state: &AppState) -> Result<Vec<GlobalWorkflowView>, String> {
    let global_db = state.global_db()?;
    let rows = global_db
        .list_global_workflows()
        .await
        .map_err(|e| e.to_string())?;
    Ok(rows
        .into_iter()
        .map(|r| GlobalWorkflowView {
            id: r.id,
            name: r.name,
            description: r.description,
            source: r.source,
            created_at: r.created_at,
            updated_at: r.updated_at,
        })
        .collect())
}

pub async fn get_global_workflow(
    id: String,
    state: &AppState,
) -> Result<GlobalWorkflowView, String> {
    let global_db = state.global_db()?;
    let row = global_db
        .get_global_workflow(&id)
        .await
        .map_err(|e| e.to_string())?
        .ok_or_else(|| format!("global workflow '{id}' not found"))?;
    Ok(GlobalWorkflowView {
        id: row.id,
        name: row.name,
        description: row.description,
        source: row.source,
        created_at: row.created_at,
        updated_at: row.updated_at,
    })
}

pub async fn create_global_workflow(
    input: CreateGlobalWorkflowInput,
    state: &AppState,
) -> Result<GlobalWorkflowView, String> {
    let global_db = state.global_db()?;

    // Validate YAML before storing
    WorkflowDef::from_yaml(&input.definition_yaml).map_err(|e| e.to_string())?;

    let now = Utc::now();
    let id = Uuid::new_v4().to_string();
    let row = pnevma_db::GlobalWorkflowRow {
        id: id.clone(),
        name: input.name.clone(),
        description: input.description.clone(),
        definition_yaml: input.definition_yaml,
        source: "user".to_string(),
        created_at: now,
        updated_at: now,
    };
    global_db
        .create_global_workflow(&row)
        .await
        .map_err(|e| e.to_string())?;
    Ok(GlobalWorkflowView {
        id,
        name: row.name,
        description: row.description,
        source: row.source,
        created_at: now,
        updated_at: now,
    })
}

pub async fn update_global_workflow(
    input: UpdateGlobalWorkflowInput,
    state: &AppState,
) -> Result<GlobalWorkflowView, String> {
    let global_db = state.global_db()?;

    let existing = global_db
        .get_global_workflow(&input.id)
        .await
        .map_err(|e| e.to_string())?
        .ok_or_else(|| format!("global workflow '{}' not found", input.id))?;

    let new_yaml = input.definition_yaml.unwrap_or(existing.definition_yaml);
    WorkflowDef::from_yaml(&new_yaml).map_err(|e| e.to_string())?;

    let now = Utc::now();
    let updated = pnevma_db::GlobalWorkflowRow {
        id: existing.id,
        name: input.name.unwrap_or(existing.name),
        description: input.description.or(existing.description),
        definition_yaml: new_yaml,
        source: existing.source,
        created_at: existing.created_at,
        updated_at: now,
    };
    global_db
        .update_global_workflow(&updated)
        .await
        .map_err(|e| e.to_string())?;
    Ok(GlobalWorkflowView {
        id: updated.id,
        name: updated.name,
        description: updated.description,
        source: updated.source,
        created_at: updated.created_at,
        updated_at: now,
    })
}

pub async fn delete_global_workflow(id: String, state: &AppState) -> Result<(), String> {
    let global_db = state.global_db()?;
    global_db
        .delete_global_workflow(&id)
        .await
        .map_err(|e| e.to_string())?;
    Ok(())
}

pub async fn copy_global_workflow_to_project(
    id: String,
    state: &AppState,
) -> Result<String, String> {
    let global_db = state.global_db()?;
    let global_row = global_db
        .get_global_workflow(&id)
        .await
        .map_err(|e| e.to_string())?
        .ok_or_else(|| format!("global workflow '{id}' not found"))?;

    let (project_id, db) = {
        let current = state.current.lock().await;
        let ctx = current
            .as_ref()
            .ok_or_else(|| "no open project".to_string())?;
        (ctx.project_id, ctx.db.clone())
    };

    let now = Utc::now();
    let new_id = Uuid::new_v4().to_string();
    let row = WorkflowRow {
        id: new_id.clone(),
        project_id: project_id.to_string(),
        name: global_row.name,
        description: global_row.description,
        definition_yaml: global_row.definition_yaml,
        source: "user".to_string(),
        created_at: now,
        updated_at: now,
    };
    db.create_workflow(&row).await.map_err(|e| e.to_string())?;
    Ok(new_id)
}

/// List all workflows from both global and project scopes, merged.
pub async fn list_all_workflows(state: &AppState) -> Result<Vec<serde_json::Value>, String> {
    let global_db = state.global_db()?;
    let mut result_map: HashMap<String, serde_json::Value> = HashMap::new();

    // Always load global workflows
    let global_rows = global_db
        .list_global_workflows()
        .await
        .map_err(|e| e.to_string())?;
    for r in global_rows {
        result_map.insert(
            r.name.clone(),
            json!({
                "id": r.id,
                "name": r.name,
                "description": r.description,
                "source": r.source,
                "scope": "global",
                "created_at": r.created_at,
                "updated_at": r.updated_at,
            }),
        );
    }

    // If a project is open, also load project workflows (project wins on name collision)
    let (project_id_opt, db_opt, project_path_opt) = {
        let current = state.current.lock().await;
        if let Some(ctx) = current.as_ref() {
            (
                Some(ctx.project_id.to_string()),
                Some(ctx.db.clone()),
                Some(ctx.project_path.clone()),
            )
        } else {
            (None, None, None)
        }
    };

    if let (Some(project_id), Some(db), Some(project_path)) =
        (project_id_opt, db_opt, project_path_opt)
    {
        // YAML file definitions
        let workflows_dir = project_path.join(".pnevma").join("workflows");
        if let Ok(yaml_defs) = WorkflowDef::load_all(&workflows_dir) {
            for d in yaml_defs {
                result_map.insert(
                    d.name.clone(),
                    json!({
                        "name": d.name,
                        "description": d.description,
                        "source": "yaml",
                        "scope": "project",
                    }),
                );
            }
        }

        // DB definitions (project DB wins)
        match db.list_workflows(&project_id).await {
            Ok(db_rows) => {
                for row in db_rows {
                    result_map.insert(
                        row.name.clone(),
                        json!({
                            "id": row.id,
                            "name": row.name,
                            "description": row.description,
                            "source": row.source,
                            "scope": "project",
                            "created_at": row.created_at,
                            "updated_at": row.updated_at,
                        }),
                    );
                }
            }
            Err(e) => {
                tracing::warn!("failed to load project workflows: {e}");
            }
        }
    }

    let mut views: Vec<serde_json::Value> = result_map.into_values().collect();
    views.sort_by(|a, b| {
        let a_name = a.get("name").and_then(|v| v.as_str()).unwrap_or("");
        let b_name = b.get("name").and_then(|v| v.as_str()).unwrap_or("");
        a_name.cmp(b_name)
    });
    Ok(views)
}
