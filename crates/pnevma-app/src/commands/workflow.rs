use super::*;

// ─── Workflow commands ──────────────────────────────────────────

// ─── Saved workflow CRUD ────────────────────────────────────────

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct WorkflowView {
    pub id: String,
    pub name: String,
    pub description: Option<String>,
    pub source: String,
    pub created_at: DateTime<Utc>,
    pub updated_at: DateTime<Utc>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct CreateWorkflowInput {
    pub name: String,
    pub description: Option<String>,
    pub definition_yaml: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct UpdateWorkflowInput {
    pub id: String,
    pub name: Option<String>,
    pub description: Option<String>,
    pub definition_yaml: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct DispatchWorkflowInput {
    pub workflow_name: String,
    pub params: Option<serde_json::Value>,
}

#[tauri::command]
pub async fn list_workflows(state: State<'_, AppState>) -> Result<Vec<WorkflowView>, String> {
    let (project_id, db) = {
        let current = state.current.lock().await;
        let ctx = current
            .as_ref()
            .ok_or_else(|| "no open project".to_string())?;
        (ctx.project_id, ctx.db.clone())
    };
    let rows = db
        .list_workflows(&project_id.to_string())
        .await
        .map_err(|e| e.to_string())?;
    Ok(rows
        .into_iter()
        .map(|r| WorkflowView {
            id: r.id,
            name: r.name,
            description: r.description,
            source: r.source,
            created_at: r.created_at,
            updated_at: r.updated_at,
        })
        .collect())
}

#[tauri::command]
pub async fn get_workflow(id: String, state: State<'_, AppState>) -> Result<WorkflowView, String> {
    let db = {
        let current = state.current.lock().await;
        let ctx = current
            .as_ref()
            .ok_or_else(|| "no open project".to_string())?;
        ctx.db.clone()
    };
    let row = db
        .get_workflow(&id)
        .await
        .map_err(|e| e.to_string())?
        .ok_or_else(|| format!("workflow '{id}' not found"))?;
    Ok(WorkflowView {
        id: row.id,
        name: row.name,
        description: row.description,
        source: row.source,
        created_at: row.created_at,
        updated_at: row.updated_at,
    })
}

#[tauri::command]
pub async fn create_workflow(
    input: CreateWorkflowInput,
    state: State<'_, AppState>,
) -> Result<WorkflowView, String> {
    let (project_id, db) = {
        let current = state.current.lock().await;
        let ctx = current
            .as_ref()
            .ok_or_else(|| "no open project".to_string())?;
        (ctx.project_id, ctx.db.clone())
    };

    // Validate the YAML before storing.
    WorkflowDef::from_yaml(&input.definition_yaml).map_err(|e| e.to_string())?;

    let now = Utc::now();
    let id = Uuid::new_v4().to_string();
    let row = WorkflowRow {
        id: id.clone(),
        project_id: project_id.to_string(),
        name: input.name.clone(),
        description: input.description.clone(),
        definition_yaml: input.definition_yaml,
        source: "user".to_string(),
        created_at: now,
        updated_at: now,
    };
    db.create_workflow(&row).await.map_err(|e| e.to_string())?;
    Ok(WorkflowView {
        id,
        name: row.name,
        description: row.description,
        source: row.source,
        created_at: now,
        updated_at: now,
    })
}

#[tauri::command]
pub async fn update_workflow(
    input: UpdateWorkflowInput,
    state: State<'_, AppState>,
) -> Result<WorkflowView, String> {
    let db = {
        let current = state.current.lock().await;
        let ctx = current
            .as_ref()
            .ok_or_else(|| "no open project".to_string())?;
        ctx.db.clone()
    };

    let existing = db
        .get_workflow(&input.id)
        .await
        .map_err(|e| e.to_string())?
        .ok_or_else(|| format!("workflow '{}' not found", input.id))?;

    let new_yaml = input
        .definition_yaml
        .clone()
        .unwrap_or(existing.definition_yaml.clone());
    // Validate updated YAML.
    WorkflowDef::from_yaml(&new_yaml).map_err(|e| e.to_string())?;

    let now = Utc::now();
    let updated = WorkflowRow {
        id: existing.id.clone(),
        project_id: existing.project_id.clone(),
        name: input.name.unwrap_or(existing.name),
        description: input.description.or(existing.description),
        definition_yaml: new_yaml,
        source: existing.source,
        created_at: existing.created_at,
        updated_at: now,
    };
    db.update_workflow(&updated)
        .await
        .map_err(|e| e.to_string())?;
    Ok(WorkflowView {
        id: updated.id,
        name: updated.name,
        description: updated.description,
        source: updated.source,
        created_at: updated.created_at,
        updated_at: now,
    })
}

#[tauri::command]
pub async fn delete_workflow(id: String, state: State<'_, AppState>) -> Result<(), String> {
    let db = {
        let current = state.current.lock().await;
        let ctx = current
            .as_ref()
            .ok_or_else(|| "no open project".to_string())?;
        ctx.db.clone()
    };
    db.delete_workflow(&id).await.map_err(|e| e.to_string())?;
    Ok(())
}

#[tauri::command]
pub async fn dispatch_workflow(
    input: DispatchWorkflowInput,
    app: AppHandle,
    state: State<'_, AppState>,
) -> Result<WorkflowInstanceView, String> {
    let (project_id, db, project_path) = {
        let current = state.current.lock().await;
        let ctx = current
            .as_ref()
            .ok_or_else(|| "no open project".to_string())?;
        (ctx.project_id, ctx.db.clone(), ctx.project_path.clone())
    };

    // Look up workflow def from DB first, then fall back to YAML files on disk.
    let def = if let Some(row) = db
        .get_workflow_by_name(&project_id.to_string(), &input.workflow_name)
        .await
        .map_err(|e| e.to_string())?
    {
        WorkflowDef::from_yaml(&row.definition_yaml).map_err(|e| e.to_string())?
    } else {
        let workflows_dir = project_path.join(".pnevma").join("workflows");
        let defs = WorkflowDef::load_all(&workflows_dir).map_err(|e| e.to_string())?;
        defs.into_iter()
            .find(|d| d.name == input.workflow_name)
            .ok_or_else(|| format!("workflow '{}' not found", input.workflow_name))?
    };

    let workflow_id = Uuid::new_v4();
    let now = Utc::now();
    let params_json = input
        .params
        .as_ref()
        .map(|p| serde_json::to_string(p).unwrap_or_else(|_| "null".to_string()));

    db.create_workflow_instance(&WorkflowInstanceRow {
        id: workflow_id.to_string(),
        project_id: project_id.to_string(),
        workflow_name: def.name.clone(),
        description: def.description.clone(),
        status: "Running".to_string(),
        created_at: now,
        updated_at: now,
        params_json: params_json.clone(),
        stage_results_json: None,
        expanded_steps_json: None,
    })
    .await
    .map_err(|e| e.to_string())?;

    let mut task_ids: Vec<Uuid> = Vec::with_capacity(def.steps.len());

    for (i, step) in def.steps.iter().enumerate() {
        let task_id = Uuid::new_v4();
        let deps_json: Vec<String> = step
            .depends_on
            .iter()
            .filter_map(|&idx| task_ids.get(idx).map(|id| id.to_string()))
            .collect();
        let checks: Vec<serde_json::Value> = step
            .acceptance_criteria
            .iter()
            .map(|desc| {
                serde_json::json!({
                    "description": desc,
                    "check_type": "ManualApproval",
                })
            })
            .collect();
        let has_deps = !step.depends_on.is_empty();
        let initial_status = if has_deps { "Blocked" } else { "Ready" };

        db.create_task(&TaskRow {
            id: task_id.to_string(),
            project_id: project_id.to_string(),
            title: step.title.clone(),
            goal: step.goal.clone(),
            scope_json: serde_json::to_string(&step.scope).unwrap_or_else(|_| "[]".to_string()),
            dependencies_json: serde_json::to_string(&deps_json)
                .unwrap_or_else(|_| "[]".to_string()),
            acceptance_json: serde_json::to_string(&checks).unwrap_or_else(|_| "[]".to_string()),
            constraints_json: serde_json::to_string(&step.constraints)
                .unwrap_or_else(|_| "[]".to_string()),
            priority: step.priority.clone(),
            status: initial_status.to_string(),
            branch: None,
            worktree_id: None,
            handoff_summary: None,
            created_at: now,
            updated_at: now,
            auto_dispatch: step.auto_dispatch,
            agent_profile_override: None,
        })
        .await
        .map_err(|e| e.to_string())?;

        if !deps_json.is_empty() {
            db.replace_task_dependencies(&task_id.to_string(), &deps_json)
                .await
                .map_err(|e| e.to_string())?;
        }

        db.add_workflow_task(&workflow_id.to_string(), i as i64, &task_id.to_string())
            .await
            .map_err(|e| e.to_string())?;

        task_ids.push(task_id);
    }

    let _ = app.emit(
        "workflow_dispatched",
        serde_json::json!({
            "workflow_id": workflow_id.to_string(),
            "workflow_name": def.name,
        }),
    );

    Ok(WorkflowInstanceView {
        id: workflow_id.to_string(),
        workflow_name: def.name,
        description: def.description,
        status: "Running".to_string(),
        task_ids: task_ids.iter().map(|id| id.to_string()).collect(),
        created_at: now,
        updated_at: now,
    })
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct WorkflowDefView {
    pub name: String,
    pub description: Option<String>,
    pub steps: Vec<WorkflowStepView>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct WorkflowStepView {
    pub title: String,
    pub goal: String,
    pub scope: Vec<String>,
    pub priority: String,
    pub depends_on: Vec<usize>,
    pub auto_dispatch: bool,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct WorkflowInstanceView {
    pub id: String,
    pub workflow_name: String,
    pub description: Option<String>,
    pub status: String,
    pub task_ids: Vec<String>,
    pub created_at: DateTime<Utc>,
    pub updated_at: DateTime<Utc>,
}

#[tauri::command]
pub async fn list_workflow_defs(
    state: State<'_, AppState>,
) -> Result<Vec<WorkflowDefView>, String> {
    let current = state.current.lock().await;
    let ctx = current
        .as_ref()
        .ok_or_else(|| "no open project".to_string())?;
    let workflows_dir = ctx.project_path.join(".pnevma").join("workflows");
    let defs = WorkflowDef::load_all(&workflows_dir).map_err(|e| e.to_string())?;
    Ok(defs
        .into_iter()
        .map(|d| WorkflowDefView {
            name: d.name,
            description: d.description,
            steps: d
                .steps
                .into_iter()
                .map(|s| WorkflowStepView {
                    title: s.title,
                    goal: s.goal,
                    scope: s.scope,
                    priority: s.priority,
                    depends_on: s.depends_on,
                    auto_dispatch: s.auto_dispatch,
                })
                .collect(),
        })
        .collect())
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct InstantiateWorkflowInput {
    pub workflow_name: String,
}

#[tauri::command]
pub async fn instantiate_workflow(
    input: InstantiateWorkflowInput,
    app: AppHandle,
    state: State<'_, AppState>,
) -> Result<WorkflowInstanceView, String> {
    let (project_id, db, project_path) = {
        let current = state.current.lock().await;
        let ctx = current
            .as_ref()
            .ok_or_else(|| "no open project".to_string())?;
        (ctx.project_id, ctx.db.clone(), ctx.project_path.clone())
    };

    let workflows_dir = project_path.join(".pnevma").join("workflows");
    let defs = WorkflowDef::load_all(&workflows_dir).map_err(|e| e.to_string())?;
    let def = defs
        .into_iter()
        .find(|d| d.name == input.workflow_name)
        .ok_or_else(|| format!("workflow '{}' not found", input.workflow_name))?;

    let workflow_id = Uuid::new_v4();
    let now = Utc::now();

    // Create the workflow instance row.
    db.create_workflow_instance(&WorkflowInstanceRow {
        id: workflow_id.to_string(),
        project_id: project_id.to_string(),
        workflow_name: def.name.clone(),
        description: def.description.clone(),
        status: "Running".to_string(),
        created_at: now,
        updated_at: now,
        params_json: None,
        stage_results_json: None,
        expanded_steps_json: None,
    })
    .await
    .map_err(|e| e.to_string())?;

    // Create a task for each step, collecting IDs.
    let mut task_ids: Vec<Uuid> = Vec::with_capacity(def.steps.len());

    for (i, step) in def.steps.iter().enumerate() {
        let task_id = Uuid::new_v4();
        let deps_json: Vec<String> = step
            .depends_on
            .iter()
            .filter_map(|&idx| task_ids.get(idx).map(|id| id.to_string()))
            .collect();
        let checks: Vec<serde_json::Value> = step
            .acceptance_criteria
            .iter()
            .map(|desc| {
                serde_json::json!({
                    "description": desc,
                    "check_type": "ManualApproval",
                })
            })
            .collect();
        let has_deps = !step.depends_on.is_empty();
        let initial_status = if has_deps { "Blocked" } else { "Ready" };

        db.create_task(&TaskRow {
            id: task_id.to_string(),
            project_id: project_id.to_string(),
            title: step.title.clone(),
            goal: step.goal.clone(),
            scope_json: serde_json::to_string(&step.scope).unwrap_or_else(|_| "[]".to_string()),
            dependencies_json: serde_json::to_string(&deps_json)
                .unwrap_or_else(|_| "[]".to_string()),
            acceptance_json: serde_json::to_string(&checks).unwrap_or_else(|_| "[]".to_string()),
            constraints_json: serde_json::to_string(&step.constraints)
                .unwrap_or_else(|_| "[]".to_string()),
            priority: step.priority.clone(),
            status: initial_status.to_string(),
            branch: None,
            worktree_id: None,
            handoff_summary: None,
            created_at: now,
            updated_at: now,
            auto_dispatch: step.auto_dispatch,
            agent_profile_override: None,
        })
        .await
        .map_err(|e| e.to_string())?;

        // Set task dependencies in the join table.
        if !deps_json.is_empty() {
            db.replace_task_dependencies(&task_id.to_string(), &deps_json)
                .await
                .map_err(|e| e.to_string())?;
        }

        // Link task to workflow instance.
        db.add_workflow_task(&workflow_id.to_string(), i as i64, &task_id.to_string())
            .await
            .map_err(|e| e.to_string())?;

        task_ids.push(task_id);
    }

    let _ = app.emit(
        "task_updated",
        serde_json::json!({"workflow_id": workflow_id.to_string()}),
    );

    Ok(WorkflowInstanceView {
        id: workflow_id.to_string(),
        workflow_name: def.name,
        description: def.description,
        status: "Running".to_string(),
        task_ids: task_ids.iter().map(|id| id.to_string()).collect(),
        created_at: now,
        updated_at: now,
    })
}

#[tauri::command]
pub async fn list_workflow_instances(
    state: State<'_, AppState>,
) -> Result<Vec<WorkflowInstanceView>, String> {
    let (project_id, db) = {
        let current = state.current.lock().await;
        let ctx = current
            .as_ref()
            .ok_or_else(|| "no open project".to_string())?;
        (ctx.project_id, ctx.db.clone())
    };

    let instances = db
        .list_workflow_instances(&project_id.to_string())
        .await
        .map_err(|e| e.to_string())?;

    let mut views = Vec::new();
    for inst in instances {
        let tasks = db
            .list_workflow_tasks(&inst.id)
            .await
            .map_err(|e| e.to_string())?;
        views.push(WorkflowInstanceView {
            id: inst.id,
            workflow_name: inst.workflow_name,
            description: inst.description,
            status: inst.status,
            task_ids: tasks.into_iter().map(|t| t.task_id).collect(),
            created_at: inst.created_at,
            updated_at: inst.updated_at,
        });
    }

    Ok(views)
}
