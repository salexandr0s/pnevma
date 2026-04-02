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

pub async fn list_workflows(state: &AppState) -> Result<Vec<WorkflowView>, String> {
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

pub async fn get_workflow(id: String, state: &AppState) -> Result<WorkflowView, String> {
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

pub async fn create_workflow(
    input: CreateWorkflowInput,
    state: &AppState,
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

pub async fn update_workflow(
    input: UpdateWorkflowInput,
    state: &AppState,
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

pub async fn delete_workflow(id: String, state: &AppState) -> Result<(), String> {
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

pub async fn dispatch_workflow(
    input: DispatchWorkflowInput,
    emitter: &Arc<dyn EventEmitter>,
    state: &AppState,
) -> Result<WorkflowInstanceView, String> {
    let (project_id, db, project_path) = {
        let current = state.current.lock().await;
        let ctx = current
            .as_ref()
            .ok_or_else(|| "no open project".to_string())?;
        (ctx.project_id, ctx.db.clone(), ctx.project_path.clone())
    };

    // Look up workflow def from DB first, then fall back to YAML files on disk,
    // then fall back to the global DB.
    let def = if let Some(row) = db
        .get_workflow_by_name(&project_id.to_string(), &input.workflow_name)
        .await
        .map_err(|e| e.to_string())?
    {
        WorkflowDef::from_yaml(&row.definition_yaml).map_err(|e| e.to_string())?
    } else {
        let workflows_dir = project_path.join(".pnevma").join("workflows");
        let defs = WorkflowDef::load_all(&workflows_dir).map_err(|e| e.to_string())?;
        if let Some(d) = defs.into_iter().find(|d| d.name == input.workflow_name) {
            d
        } else if let Some(global_db) = state.global_db.as_ref() {
            let global_row = global_db
                .get_global_workflow_by_name(&input.workflow_name)
                .await
                .map_err(|e| e.to_string())?
                .ok_or_else(|| format!("workflow '{}' not found", input.workflow_name))?;
            WorkflowDef::from_yaml(&global_row.definition_yaml).map_err(|e| e.to_string())?
        } else {
            return Err(format!("workflow '{}' not found", input.workflow_name));
        }
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
            agent_profile_override: step.agent_profile.clone(),
            execution_mode: Some(step.execution_mode.as_str().to_string()),
            timeout_minutes: step.timeout_minutes.map(|v| v as i64),
            max_retries: step.max_retries.map(|v| v as i64),
            loop_iteration: 0,
            loop_context_json: None,
            forked_from_task_id: None,
            lineage_summary: None,
            lineage_depth: 0,
        })
        .await
        .map_err(|e| e.to_string())?;

        if !deps_json.is_empty() {
            db.replace_task_dependencies(&task_id.to_string(), &deps_json)
                .await
                .map_err(|e| e.to_string())?;
        }

        db.add_workflow_task(&workflow_id.to_string(), i as i64, 0, &task_id.to_string())
            .await
            .map_err(|e| e.to_string())?;

        task_ids.push(task_id);
    }

    emitter.emit(
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
    pub id: Option<String>,
    pub name: String,
    pub description: Option<String>,
    pub source: String,
    pub steps: Vec<WorkflowStepView>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct LoopConfigView {
    pub target: usize,
    pub max_iterations: u32,
    pub mode: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct WorkflowStepView {
    pub title: String,
    pub goal: String,
    pub scope: Vec<String>,
    pub priority: Priority,
    pub depends_on: Vec<usize>,
    pub auto_dispatch: bool,
    pub agent_profile: Option<String>,
    pub execution_mode: String,
    pub timeout_minutes: Option<u64>,
    pub max_retries: Option<u32>,
    pub acceptance_criteria: Vec<String>,
    pub constraints: Vec<String>,
    pub on_failure: String,
    pub loop_config: Option<LoopConfigView>,
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

fn step_to_view(s: pnevma_core::WorkflowStep) -> WorkflowStepView {
    WorkflowStepView {
        title: s.title,
        goal: s.goal,
        scope: s.scope,
        priority: s.priority.parse().unwrap_or(Priority::P3),
        depends_on: s.depends_on,
        auto_dispatch: s.auto_dispatch,
        agent_profile: s.agent_profile,
        execution_mode: s.execution_mode.as_str().to_string(),
        timeout_minutes: s.timeout_minutes,
        max_retries: s.max_retries,
        acceptance_criteria: s.acceptance_criteria,
        constraints: s.constraints,
        on_failure: s.on_failure.as_str().to_string(),
        loop_config: s.loop_config.map(|lc| LoopConfigView {
            target: lc.target,
            max_iterations: lc.max_iterations,
            mode: match lc.mode {
                pnevma_core::LoopMode::OnFailure => "on_failure".to_string(),
                pnevma_core::LoopMode::UntilComplete => "until_complete".to_string(),
            },
        }),
    }
}

pub async fn list_workflow_defs(state: &AppState) -> Result<Vec<WorkflowDefView>, String> {
    let (project_id, db, project_path) = {
        let current = state.current.lock().await;
        let ctx = current
            .as_ref()
            .ok_or_else(|| "no open project".to_string())?;
        (ctx.project_id, ctx.db.clone(), ctx.project_path.clone())
    };

    let mut result_map: std::collections::HashMap<String, WorkflowDefView> =
        std::collections::HashMap::new();

    // Load YAML file definitions.
    let workflows_dir = project_path.join(".pnevma").join("workflows");
    let yaml_defs = WorkflowDef::load_all(&workflows_dir).map_err(|e| e.to_string())?;
    for d in yaml_defs {
        result_map.insert(
            d.name.clone(),
            WorkflowDefView {
                id: None,
                name: d.name,
                description: d.description,
                source: "yaml".to_string(),
                steps: d.steps.into_iter().map(step_to_view).collect(),
            },
        );
    }

    // Load DB definitions (DB wins on name collision).
    let db_rows = db
        .list_workflows(&project_id.to_string())
        .await
        .map_err(|e| e.to_string())?;
    for row in db_rows {
        if let Ok(def) = WorkflowDef::from_yaml(&row.definition_yaml) {
            result_map.insert(
                def.name.clone(),
                WorkflowDefView {
                    id: Some(row.id),
                    name: def.name,
                    description: row.description.or(def.description),
                    source: row.source,
                    steps: def.steps.into_iter().map(step_to_view).collect(),
                },
            );
        }
    }

    let mut views: Vec<WorkflowDefView> = result_map.into_values().collect();
    views.sort_by(|a, b| a.name.cmp(&b.name));
    Ok(views)
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct InstantiateWorkflowInput {
    pub workflow_name: String,
}

pub async fn instantiate_workflow(
    input: InstantiateWorkflowInput,
    emitter: &Arc<dyn EventEmitter>,
    state: &AppState,
) -> Result<WorkflowInstanceView, String> {
    let (project_id, db, project_path) = {
        let current = state.current.lock().await;
        let ctx = current
            .as_ref()
            .ok_or_else(|| "no open project".to_string())?;
        (ctx.project_id, ctx.db.clone(), ctx.project_path.clone())
    };

    // Check project DB first
    let def = if let Some(row) = db
        .get_workflow_by_name(&project_id.to_string(), &input.workflow_name)
        .await
        .map_err(|e| e.to_string())?
    {
        WorkflowDef::from_yaml(&row.definition_yaml).map_err(|e| e.to_string())?
    } else {
        // Then check YAML files
        let workflows_dir = project_path.join(".pnevma").join("workflows");
        let defs = WorkflowDef::load_all(&workflows_dir).map_err(|e| e.to_string())?;
        if let Some(d) = defs.into_iter().find(|d| d.name == input.workflow_name) {
            d
        } else if let Some(global_db) = state.global_db.as_ref() {
            // Then check global DB
            let global_row = global_db
                .get_global_workflow_by_name(&input.workflow_name)
                .await
                .map_err(|e| e.to_string())?
                .ok_or_else(|| format!("workflow '{}' not found", input.workflow_name))?;
            WorkflowDef::from_yaml(&global_row.definition_yaml).map_err(|e| e.to_string())?
        } else {
            return Err(format!("workflow '{}' not found", input.workflow_name));
        }
    };

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
            agent_profile_override: step.agent_profile.clone(),
            execution_mode: Some(step.execution_mode.as_str().to_string()),
            timeout_minutes: step.timeout_minutes.map(|v| v as i64),
            max_retries: step.max_retries.map(|v| v as i64),
            loop_iteration: 0,
            loop_context_json: None,
            forked_from_task_id: None,
            lineage_summary: None,
            lineage_depth: 0,
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
        db.add_workflow_task(&workflow_id.to_string(), i as i64, 0, &task_id.to_string())
            .await
            .map_err(|e| e.to_string())?;

        task_ids.push(task_id);
    }

    emitter.emit(
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

pub async fn list_workflow_instances(
    state: &AppState,
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

// ─── Workflow instance detail ──────────────────────────────────

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct WorkflowInstanceDetailView {
    pub id: String,
    pub workflow_name: String,
    pub description: Option<String>,
    pub status: String,
    pub steps: Vec<WorkflowInstanceStepView>,
    pub created_at: DateTime<Utc>,
    pub updated_at: DateTime<Utc>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct WorkflowInstanceStepView {
    pub step_index: i64,
    pub iteration: i64,
    pub task_id: String,
    pub title: String,
    pub goal: String,
    pub status: String,
    pub priority: Priority,
    pub depends_on: Vec<String>,
    pub agent_profile: Option<String>,
    pub execution_mode: String,
    pub branch: Option<String>,
    pub created_at: DateTime<Utc>,
    pub updated_at: DateTime<Utc>,
}

pub async fn get_workflow_instance(
    id: String,
    state: &AppState,
) -> Result<WorkflowInstanceDetailView, String> {
    let db = {
        let current = state.current.lock().await;
        let ctx = current
            .as_ref()
            .ok_or_else(|| "no open project".to_string())?;
        ctx.db.clone()
    };

    let inst = db
        .get_workflow_instance(&id)
        .await
        .map_err(|e| e.to_string())?
        .ok_or_else(|| format!("workflow instance '{id}' not found"))?;

    let wf_tasks = db
        .list_workflow_tasks(&inst.id)
        .await
        .map_err(|e| e.to_string())?;

    let mut steps = Vec::with_capacity(wf_tasks.len());
    for wt in wf_tasks {
        let task = db
            .get_task(&wt.task_id)
            .await
            .map_err(|e| e.to_string())?
            .ok_or_else(|| format!("task '{}' not found for workflow step", wt.task_id))?;
        let deps: Vec<String> = serde_json::from_str(&task.dependencies_json).unwrap_or_default();
        steps.push(WorkflowInstanceStepView {
            step_index: wt.step_index,
            iteration: wt.iteration,
            task_id: wt.task_id,
            title: task.title,
            goal: task.goal,
            status: task.status,
            priority: task.priority.parse().unwrap_or(Priority::P3),
            depends_on: deps,
            agent_profile: task.agent_profile_override,
            execution_mode: task
                .execution_mode
                .unwrap_or_else(|| "worktree".to_string()),
            branch: task.branch,
            created_at: task.created_at,
            updated_at: task.updated_at,
        });
    }

    Ok(WorkflowInstanceDetailView {
        id: inst.id,
        workflow_name: inst.workflow_name,
        description: inst.description,
        status: inst.status,
        steps,
        created_at: inst.created_at,
        updated_at: inst.updated_at,
    })
}

pub async fn copy_workflow_to_global(id: String, state: &AppState) -> Result<String, String> {
    let db = {
        let current = state.current.lock().await;
        let ctx = current
            .as_ref()
            .ok_or_else(|| "no open project".to_string())?;
        ctx.db.clone()
    };
    let project_row = db
        .get_workflow(&id)
        .await
        .map_err(|e| e.to_string())?
        .ok_or_else(|| format!("workflow '{id}' not found"))?;

    let global_db = state.global_db()?;
    let now = Utc::now();
    let new_id = Uuid::new_v4().to_string();
    let row = pnevma_db::GlobalWorkflowRow {
        id: new_id.clone(),
        name: project_row.name,
        description: project_row.description,
        definition_yaml: project_row.definition_yaml,
        source: "user".to_string(),
        created_at: now,
        updated_at: now,
    };
    global_db
        .create_global_workflow(&row)
        .await
        .map_err(|e| e.to_string())?;
    Ok(new_id)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::commands::tasks::merge_queue_execute;
    use crate::event_emitter::{EventEmitter, NullEmitter};
    use crate::state::{AppState, ProjectContext};
    use pnevma_agents::{AdapterRegistry, DispatchPool};
    use pnevma_core::config::{
        AgentsSection, AutomationSection, BranchesSection, PathSection, ProjectSection,
        RedactionSection, RetentionSection,
    };
    use pnevma_core::{GlobalConfig, ProjectConfig, RemoteSection, TrackerSection};
    use pnevma_db::{Db, MergeQueueRow, WorktreeRow};
    use pnevma_git::GitService;
    use pnevma_session::SessionSupervisor;
    use sqlx::sqlite::SqlitePoolOptions;
    use std::path::Path;
    use std::process::Command;
    use std::sync::Arc;
    use tokio::sync::Mutex;
    use uuid::Uuid;

    fn run_git(dir: &Path, args: &[&str]) -> String {
        let out = Command::new("git")
            .args(args)
            .current_dir(dir)
            .output()
            .expect("git command");
        if !out.status.success() {
            panic!(
                "git {} failed: {}",
                args.join(" "),
                String::from_utf8_lossy(&out.stderr).trim()
            );
        }
        String::from_utf8_lossy(&out.stdout).trim().to_string()
    }

    async fn open_test_db() -> Db {
        let pool = SqlitePoolOptions::new()
            .max_connections(1)
            .connect("sqlite::memory:")
            .await
            .expect("memory sqlite");
        let db = Db::from_pool_and_path(pool, std::path::PathBuf::from(":memory:"));
        db.migrate().await.expect("migrate");
        db
    }

    fn make_project_config() -> ProjectConfig {
        ProjectConfig {
            project: ProjectSection {
                name: "test-project".to_string(),
                brief: String::new(),
            },
            agents: AgentsSection {
                default_provider: "claude-code".to_string(),
                max_concurrent: 1,
                claude_code: None,
                codex: None,
            },
            automation: AutomationSection::default(),
            retention: RetentionSection::default(),
            branches: BranchesSection {
                target: "main".to_string(),
                naming: "feat/{slug}".to_string(),
            },
            rules: PathSection::default(),
            conventions: PathSection::default(),
            remote: RemoteSection::default(),
            tracker: TrackerSection::default(),
            redaction: RedactionSection::default(),
        }
    }

    async fn make_state_with_project() -> (AppState, Uuid, Db) {
        let db = open_test_db().await;
        let project_id = Uuid::new_v4();
        let tmp_path = std::env::temp_dir().join(format!("pnevma-wf-test-{}", project_id));
        std::fs::create_dir_all(&tmp_path).ok();

        db.upsert_project(
            &project_id.to_string(),
            "test",
            tmp_path.to_str().unwrap(),
            None,
            None,
        )
        .await
        .expect("seed project");

        let supervisor = SessionSupervisor::new(&tmp_path);
        let git = Arc::new(GitService::new(&tmp_path));
        let pool = DispatchPool::new(1);
        let adapters = AdapterRegistry::default();

        let (shutdown_tx, _shutdown_rx) = tokio::sync::watch::channel(false);
        let ctx = ProjectContext {
            project_id,
            project_root_path: tmp_path.clone(),
            project_path: tmp_path.clone(),
            checkout_path: tmp_path.clone(),
            config: make_project_config(),
            global_config: GlobalConfig::default(),
            db: db.clone(),
            sessions: supervisor,
            redaction_secrets: Arc::new(RwLock::new(Vec::new())),
            git,
            adapters,
            pool,
            tracker: None,
            workflow_store: Arc::new(crate::automation::workflow_store::WorkflowStore::new(
                &tmp_path,
            )),
            coordinator: None,
            shutdown_tx,
        };

        let (remote_events, _rx) = tokio::sync::broadcast::channel(2048);

        let state = AppState {
            current: Mutex::new(Some(ctx)),
            current_runtime: Mutex::new(None),
            global_db: None,
            recents: Mutex::new(Vec::new()),
            control_plane: Mutex::new(None),
            merge_branch_locks: Mutex::new(std::collections::HashMap::new()),
            remote_handle: Mutex::new(None),
            remote_events,
            emitter: Arc::new(NullEmitter),
            github_auth: crate::github_auth::GitHubAuthRuntimeState::default(),
            agent_teams: Arc::new(RwLock::new(crate::agent_teams::AgentTeamStore::default())),
            self_arc: std::sync::OnceLock::new(),
            browser_tool_pending: crate::commands::browser_tools::new_browser_tool_pending(),
        };

        (state, project_id, db)
    }

    // ── list_workflows — empty and after inserts ────────────────────────────

    #[tokio::test]
    async fn list_workflows_empty() {
        let (state, _pid, _db) = make_state_with_project().await;
        let result = list_workflows(&state).await.expect("list");
        assert!(result.is_empty());
    }

    #[tokio::test]
    async fn list_workflows_after_create() {
        let (state, _pid, _db) = make_state_with_project().await;

        let yaml = "name: test-wf\ndescription: Test\nsteps:\n  - title: Step 1\n    goal: Do step 1\n    priority: medium\n";
        create_workflow(
            CreateWorkflowInput {
                name: "test-wf".to_string(),
                description: Some("Test".to_string()),
                definition_yaml: yaml.to_string(),
            },
            &state,
        )
        .await
        .expect("create");

        let list = list_workflows(&state).await.expect("list after create");
        assert_eq!(list.len(), 1);
        assert_eq!(list[0].name, "test-wf");
        assert_eq!(list[0].description.as_deref(), Some("Test"));
        assert_eq!(list[0].source, "user");
    }

    // ── create_workflow — valid YAML, invalid YAML, duplicate name ──────────

    #[tokio::test]
    async fn create_workflow_valid_yaml() {
        let (state, _pid, _db) = make_state_with_project().await;
        let yaml = "name: build\ndescription: Build pipeline\nsteps:\n  - title: Compile\n    goal: compile code\n    priority: high\n";
        let view = create_workflow(
            CreateWorkflowInput {
                name: "build".to_string(),
                description: None,
                definition_yaml: yaml.to_string(),
            },
            &state,
        )
        .await
        .expect("create with valid yaml");
        assert!(!view.id.is_empty());
        assert_eq!(view.name, "build");
        assert_eq!(view.source, "user");
    }

    #[tokio::test]
    async fn create_workflow_invalid_yaml_returns_error() {
        let (state, _pid, _db) = make_state_with_project().await;
        let bad_yaml = "not: valid: workflow: yaml: {{{{";
        let result = create_workflow(
            CreateWorkflowInput {
                name: "broken".to_string(),
                description: None,
                definition_yaml: bad_yaml.to_string(),
            },
            &state,
        )
        .await;
        assert!(result.is_err(), "should fail on invalid yaml");
    }

    #[tokio::test]
    async fn create_workflow_duplicate_name_returns_error() {
        let (state, _pid, _db) = make_state_with_project().await;
        let yaml = "name: ci\ndescription: CI\nsteps:\n  - title: Test\n    goal: run tests\n    priority: medium\n";
        create_workflow(
            CreateWorkflowInput {
                name: "ci".to_string(),
                description: None,
                definition_yaml: yaml.to_string(),
            },
            &state,
        )
        .await
        .expect("first create");

        // Second create with same name should fail due to unique constraint
        let result = create_workflow(
            CreateWorkflowInput {
                name: "ci".to_string(),
                description: None,
                definition_yaml: yaml.to_string(),
            },
            &state,
        )
        .await;
        assert!(result.is_err(), "duplicate name should fail");
    }

    // ── get_workflow — existing, non-existent ───────────────────────────────

    #[tokio::test]
    async fn get_workflow_existing() {
        let (state, _pid, _db) = make_state_with_project().await;
        let yaml = "name: deploy\ndescription: Deploy\nsteps:\n  - title: Ship\n    goal: ship it\n    priority: high\n";
        let created = create_workflow(
            CreateWorkflowInput {
                name: "deploy".to_string(),
                description: Some("Deploy".to_string()),
                definition_yaml: yaml.to_string(),
            },
            &state,
        )
        .await
        .expect("create");

        let fetched = get_workflow(created.id.clone(), &state)
            .await
            .expect("get existing");
        assert_eq!(fetched.id, created.id);
        assert_eq!(fetched.name, "deploy");
    }

    #[tokio::test]
    async fn get_workflow_nonexistent_returns_error() {
        let (state, _pid, _db) = make_state_with_project().await;
        let result = get_workflow("no-such-id".to_string(), &state).await;
        assert!(result.is_err());
        assert!(result.unwrap_err().contains("not found"));
    }

    // ── update_workflow — modify steps, invalid update ──────────────────────

    #[tokio::test]
    async fn update_workflow_modify_name() {
        let (state, _pid, _db) = make_state_with_project().await;
        let yaml = "name: release\ndescription: Release\nsteps:\n  - title: Build\n    goal: build\n    priority: medium\n";
        let created = create_workflow(
            CreateWorkflowInput {
                name: "release".to_string(),
                description: Some("Release".to_string()),
                definition_yaml: yaml.to_string(),
            },
            &state,
        )
        .await
        .expect("create");

        let updated_yaml = "name: release-v2\ndescription: Release v2\nsteps:\n  - title: Build\n    goal: build\n    priority: medium\n  - title: Publish\n    goal: publish\n    priority: medium\n";
        let updated = update_workflow(
            UpdateWorkflowInput {
                id: created.id.clone(),
                name: Some("release-v2".to_string()),
                description: None,
                definition_yaml: Some(updated_yaml.to_string()),
            },
            &state,
        )
        .await
        .expect("update");

        assert_eq!(updated.name, "release-v2");
    }

    #[tokio::test]
    async fn update_workflow_invalid_yaml_returns_error() {
        let (state, _pid, _db) = make_state_with_project().await;
        let yaml = "name: pipeline\ndescription: Pipeline\nsteps:\n  - title: Step\n    goal: do step\n    priority: low\n";
        let created = create_workflow(
            CreateWorkflowInput {
                name: "pipeline".to_string(),
                description: None,
                definition_yaml: yaml.to_string(),
            },
            &state,
        )
        .await
        .expect("create");

        let result = update_workflow(
            UpdateWorkflowInput {
                id: created.id,
                name: None,
                description: None,
                definition_yaml: Some("definitely: not: valid: yaml: [[[".to_string()),
            },
            &state,
        )
        .await;
        assert!(result.is_err(), "invalid yaml should fail update");
    }

    // ── delete_workflow — existing, non-existent ────────────────────────────

    #[tokio::test]
    async fn delete_workflow_existing() {
        let (state, _pid, _db) = make_state_with_project().await;
        let yaml = "name: cleanup\ndescription: Cleanup\nsteps:\n  - title: Clean\n    goal: clean\n    priority: low\n";
        let created = create_workflow(
            CreateWorkflowInput {
                name: "cleanup".to_string(),
                description: None,
                definition_yaml: yaml.to_string(),
            },
            &state,
        )
        .await
        .expect("create");

        delete_workflow(created.id.clone(), &state)
            .await
            .expect("delete");

        let result = get_workflow(created.id, &state).await;
        assert!(result.is_err(), "should be gone after delete");
    }

    #[tokio::test]
    async fn delete_workflow_nonexistent_is_ok() {
        let (state, _pid, _db) = make_state_with_project().await;
        // delete of non-existent is a no-op (DELETE WHERE id = x with no match)
        let result = delete_workflow("ghost-id".to_string(), &state).await;
        assert!(result.is_ok());
    }

    // ── dispatch_workflow ───────────────────────────────────────────────────

    #[tokio::test]
    async fn dispatch_workflow_happy_path() {
        let (state, _pid, _db) = make_state_with_project().await;

        // First store a workflow def in DB so dispatch can find it by name
        let yaml = "name: smoke-test\ndescription: Smoke test\nsteps:\n  - title: Run tests\n    goal: run all tests\n    priority: high\n";
        create_workflow(
            CreateWorkflowInput {
                name: "smoke-test".to_string(),
                description: Some("Smoke test".to_string()),
                definition_yaml: yaml.to_string(),
            },
            &state,
        )
        .await
        .expect("create workflow");

        let emitter: Arc<dyn EventEmitter> = Arc::new(NullEmitter);
        let result = dispatch_workflow(
            DispatchWorkflowInput {
                workflow_name: "smoke-test".to_string(),
                params: None,
            },
            &emitter,
            &state,
        )
        .await
        .expect("dispatch");

        assert_eq!(result.workflow_name, "smoke-test");
        assert_eq!(result.status, "Running");
        assert_eq!(result.task_ids.len(), 1);
    }

    // ── get_workflow_instance / list_workflow_instances ─────────────────────

    #[tokio::test]
    async fn list_workflow_instances_empty() {
        let (state, _pid, _db) = make_state_with_project().await;
        let list = list_workflow_instances(&state).await.expect("list");
        assert!(list.is_empty());
    }

    #[tokio::test]
    async fn get_and_list_workflow_instances() {
        let (state, _pid, _db) = make_state_with_project().await;

        let yaml = "name: e2e\ndescription: E2E tests\nsteps:\n  - title: Setup\n    goal: setup env\n    priority: medium\n  - title: Run E2E\n    goal: run e2e tests\n    priority: high\n    depends_on: [0]\n";
        create_workflow(
            CreateWorkflowInput {
                name: "e2e".to_string(),
                description: None,
                definition_yaml: yaml.to_string(),
            },
            &state,
        )
        .await
        .expect("create");

        let emitter: Arc<dyn EventEmitter> = Arc::new(NullEmitter);
        let dispatched = dispatch_workflow(
            DispatchWorkflowInput {
                workflow_name: "e2e".to_string(),
                params: Some(serde_json::json!({"env": "ci"})),
            },
            &emitter,
            &state,
        )
        .await
        .expect("dispatch");

        // list_workflow_instances
        let list = list_workflow_instances(&state).await.expect("list");
        assert_eq!(list.len(), 1);
        assert_eq!(list[0].id, dispatched.id);
        assert_eq!(list[0].task_ids.len(), 2);

        // get_workflow_instance detail
        let detail = get_workflow_instance(dispatched.id.clone(), &state)
            .await
            .expect("get detail");
        assert_eq!(detail.id, dispatched.id);
        assert_eq!(detail.workflow_name, "e2e");
        assert_eq!(detail.steps.len(), 2);
        // first step should be Ready, second Blocked (has dependency)
        let statuses: Vec<&str> = detail.steps.iter().map(|s| s.status.as_str()).collect();
        assert!(statuses.contains(&"Ready"));
        assert!(statuses.contains(&"Blocked"));
    }

    #[tokio::test]
    async fn workflow_instance_fails_when_upstream_failed_and_only_blocked_dependents_remain() {
        let (state, _pid, db) = make_state_with_project().await;

        let yaml = "name: failing-chain\ndescription: Failure path\nsteps:\n  - title: Step 1\n    goal: fail first\n    priority: medium\n  - title: Step 2\n    goal: waits on step 1\n    priority: medium\n    depends_on: [0]\n";
        create_workflow(
            CreateWorkflowInput {
                name: "failing-chain".to_string(),
                description: None,
                definition_yaml: yaml.to_string(),
            },
            &state,
        )
        .await
        .expect("create");

        let emitter: Arc<dyn EventEmitter> = Arc::new(NullEmitter);
        let dispatched = dispatch_workflow(
            DispatchWorkflowInput {
                workflow_name: "failing-chain".to_string(),
                params: None,
            },
            &emitter,
            &state,
        )
        .await
        .expect("dispatch");

        let first_task_id = dispatched.task_ids.first().expect("first task id").clone();
        let mut first_task = db
            .get_task(&first_task_id)
            .await
            .expect("task lookup")
            .expect("task exists");
        first_task.status = "Failed".to_string();
        first_task.updated_at = Utc::now();
        db.update_task(&first_task)
            .await
            .expect("update failed task");

        crate::commands::check_workflow_completion(&db, &first_task_id, None).await;

        let instance = db
            .get_workflow_instance(&dispatched.id)
            .await
            .expect("workflow instance lookup")
            .expect("workflow instance exists");
        assert_eq!(instance.status, "Failed");
    }

    #[tokio::test]
    async fn merge_completion_unblocks_dependents_and_deletes_branch() {
        let (state, project_id, db) = make_state_with_project().await;
        let project_path = {
            let current = state.current.lock().await;
            current
                .as_ref()
                .expect("project context")
                .project_path
                .clone()
        };

        std::fs::write(project_path.join("README.md"), "# workflow merge\n").expect("seed readme");
        run_git(&project_path, &["init"]);
        run_git(&project_path, &["config", "user.name", "Pnevma Tests"]);
        run_git(
            &project_path,
            &["config", "user.email", "tests@pnevma.local"],
        );
        run_git(&project_path, &["checkout", "-b", "main"]);
        run_git(&project_path, &["add", "README.md"]);
        run_git(&project_path, &["commit", "-m", "initial"]);

        let yaml = "name: merge-chain\ndescription: Merge progression\nsteps:\n  - title: Step 1\n    goal: produce change\n    priority: medium\n  - title: Step 2\n    goal: waits for merge\n    priority: medium\n    depends_on: [0]\n";
        create_workflow(
            CreateWorkflowInput {
                name: "merge-chain".to_string(),
                description: None,
                definition_yaml: yaml.to_string(),
            },
            &state,
        )
        .await
        .expect("create workflow");

        let emitter: Arc<dyn EventEmitter> = Arc::new(NullEmitter);
        let dispatched = dispatch_workflow(
            DispatchWorkflowInput {
                workflow_name: "merge-chain".to_string(),
                params: None,
            },
            &emitter,
            &state,
        )
        .await
        .expect("dispatch workflow");

        let first_task_id = dispatched.task_ids[0].clone();
        let second_task_id = dispatched.task_ids[1].clone();
        let first_task_uuid = Uuid::parse_str(&first_task_id).expect("task uuid");

        let git = {
            let current = state.current.lock().await;
            current.as_ref().expect("project context").git.clone()
        };
        let lease = git
            .create_worktree(first_task_uuid, "main", "step-1")
            .await
            .expect("create worktree");

        std::fs::write(Path::new(&lease.path).join("step1.txt"), "done\n")
            .expect("write worktree file");
        run_git(Path::new(&lease.path), &["add", "step1.txt"]);
        run_git(
            Path::new(&lease.path),
            &[
                "-c",
                "user.name=Pnevma Tests",
                "-c",
                "user.email=tests@pnevma.local",
                "commit",
                "-m",
                "task output",
            ],
        );

        db.upsert_worktree(&WorktreeRow {
            id: lease.id.to_string(),
            project_id: project_id.to_string(),
            task_id: first_task_id.clone(),
            path: lease.path.clone(),
            branch: lease.branch.clone(),
            lease_status: "Active".to_string(),
            lease_started: lease.started_at,
            last_active: lease.last_active,
        })
        .await
        .expect("upsert worktree");

        let mut first_task = db
            .get_task(&first_task_id)
            .await
            .expect("get first task")
            .expect("first task exists");
        first_task.branch = Some(lease.branch.clone());
        first_task.worktree_id = Some(lease.id.to_string());
        first_task.status = "Review".to_string();
        first_task.updated_at = Utc::now();
        db.update_task(&first_task)
            .await
            .expect("update first task");

        db.upsert_merge_queue_item(&MergeQueueRow {
            id: Uuid::new_v4().to_string(),
            project_id: project_id.to_string(),
            task_id: first_task_id.clone(),
            status: "Queued".to_string(),
            blocked_reason: None,
            approved_at: Utc::now(),
            started_at: None,
            completed_at: None,
        })
        .await
        .expect("queue merge");

        merge_queue_execute(first_task_id.clone(), &emitter, &state)
            .await
            .expect("merge executes");

        let merged_first = db
            .get_task(&first_task_id)
            .await
            .expect("get merged task")
            .expect("merged task exists");
        assert_eq!(merged_first.status, "Done");
        assert!(merged_first.branch.is_none());
        assert!(merged_first.worktree_id.is_none());

        let second = db
            .get_task(&second_task_id)
            .await
            .expect("get dependent task")
            .expect("dependent task exists");
        assert_eq!(second.status, "Ready");

        let instance = db
            .get_workflow_instance(&dispatched.id)
            .await
            .expect("workflow instance lookup")
            .expect("workflow instance exists");
        assert_eq!(instance.status, "Running");

        assert!(db
            .find_worktree_by_task(&first_task_id)
            .await
            .expect("worktree lookup")
            .is_none());
        assert!(
            run_git(&project_path, &["branch", "--list", &lease.branch]).is_empty(),
            "merged task branch should be deleted"
        );

        let notifications = db
            .list_notifications(&project_id.to_string(), false)
            .await
            .expect("list notifications");
        assert!(
            notifications
                .iter()
                .any(|row| row.title == "Merge completed"),
            "merge completion should create a notification"
        );
    }

    #[tokio::test]
    async fn get_workflow_instance_nonexistent_returns_error() {
        let (state, _pid, _db) = make_state_with_project().await;
        let result = get_workflow_instance("ghost".to_string(), &state).await;
        assert!(result.is_err());
        assert!(result.unwrap_err().contains("not found"));
    }
}
