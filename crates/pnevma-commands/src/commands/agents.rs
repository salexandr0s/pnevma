use super::*;

// ─── Agent Profile views ──────────────────────────────────────────────────────

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct AgentProfileView {
    pub id: String,
    pub name: String,
    pub role: String,
    pub provider: String,
    pub model: String,
    pub token_budget: i64,
    pub timeout_minutes: i64,
    pub max_concurrent: i64,
    pub stations: Vec<String>,
    pub config_json: String,
    pub system_prompt: Option<String>,
    pub active: bool,
    pub created_at: DateTime<Utc>,
    pub updated_at: DateTime<Utc>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct DispatchRecommendationView {
    pub profile_name: String,
    pub score: i32,
    pub reason: String,
}

fn profile_row_to_view(row: pnevma_db::AgentProfileRow) -> AgentProfileView {
    let stations: Vec<String> = serde_json::from_str(&row.stations_json).unwrap_or_default();
    AgentProfileView {
        id: row.id,
        name: row.name,
        role: row.role,
        provider: row.provider,
        model: row.model,
        token_budget: row.token_budget,
        timeout_minutes: row.timeout_minutes,
        max_concurrent: row.max_concurrent,
        stations,
        config_json: row.config_json,
        system_prompt: row.system_prompt,
        active: row.active,
        created_at: row.created_at,
        updated_at: row.updated_at,
    }
}

// ─── Commands ────────────────────────────────────────────────────────────────

pub async fn list_agent_profiles(state: &AppState) -> Result<Vec<AgentProfileView>, String> {
    let (project_id, db) = {
        let current = state.current.lock().await;
        let ctx = current
            .as_ref()
            .ok_or_else(|| "no open project".to_string())?;
        (ctx.project_id.to_string(), ctx.db.clone())
    };
    let rows = db
        .list_agent_profiles(&project_id)
        .await
        .map_err(|e| e.to_string())?;
    Ok(rows.into_iter().map(profile_row_to_view).collect())
}

pub async fn get_dispatch_recommendation(
    task_id: String,
    state: &AppState,
) -> Result<Vec<DispatchRecommendationView>, String> {
    let (project_id, db) = {
        let current = state.current.lock().await;
        let ctx = current
            .as_ref()
            .ok_or_else(|| "no open project".to_string())?;
        (ctx.project_id.to_string(), ctx.db.clone())
    };

    let task_row = db
        .get_task(&task_id)
        .await
        .map_err(|e| e.to_string())?
        .ok_or_else(|| format!("task not found: {task_id}"))?;

    let task_scope: Vec<String> = serde_json::from_str(&task_row.scope_json).unwrap_or_default();

    let profile_rows = db
        .list_agent_profiles(&project_id)
        .await
        .map_err(|e| e.to_string())?;

    let profiles: Vec<pnevma_agents::AgentProfile> = profile_rows
        .into_iter()
        .map(|row| {
            let stations: Vec<String> =
                serde_json::from_str(&row.stations_json).unwrap_or_default();
            pnevma_agents::AgentProfile {
                name: row.name,
                provider: row.provider,
                model: row.model,
                token_budget: row.token_budget,
                timeout_minutes: row.timeout_minutes,
                max_concurrent: row.max_concurrent,
                stations,
            }
        })
        .collect();

    let recommendations =
        pnevma_agents::profiles::recommend_profile(&task_scope, &task_row.priority, &profiles);

    Ok(recommendations
        .into_iter()
        .map(|r| DispatchRecommendationView {
            profile_name: r.profile_name,
            score: r.score,
            reason: r.reason,
        })
        .collect())
}

pub async fn override_task_profile(
    task_id: String,
    profile_name: String,
    state: &AppState,
) -> Result<String, String> {
    let (project_id, db) = {
        let current = state.current.lock().await;
        let ctx = current
            .as_ref()
            .ok_or_else(|| "no open project".to_string())?;
        (ctx.project_id.to_string(), ctx.db.clone())
    };

    // Validate that the task exists
    db.get_task(&task_id)
        .await
        .map_err(|e| e.to_string())?
        .ok_or_else(|| format!("task not found: {task_id}"))?;

    // Validate that the profile exists for this project
    db.get_agent_profile_by_name(&project_id, &profile_name)
        .await
        .map_err(|e| e.to_string())?
        .ok_or_else(|| format!("profile not found: {profile_name}"))?;

    // Persist the override to the tasks table.
    db.update_task_profile_override(&task_id, Some(&profile_name))
        .await
        .map_err(|e| e.to_string())?;

    Ok(format!(
        "Profile override set to '{profile_name}' for task {task_id}"
    ))
}

pub async fn get_agent_team(state: &AppState) -> Result<Vec<AgentProfileView>, String> {
    let (project_id, db) = {
        let current = state.current.lock().await;
        let ctx = current
            .as_ref()
            .ok_or_else(|| "no open project".to_string())?;
        (ctx.project_id.to_string(), ctx.db.clone())
    };
    let rows = db
        .list_agent_profiles(&project_id)
        .await
        .map_err(|e| e.to_string())?;
    Ok(rows.into_iter().map(profile_row_to_view).collect())
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct CreateAgentProfileInput {
    pub name: String,
    pub role: Option<String>,
    pub provider: Option<String>,
    pub model: Option<String>,
    pub token_budget: Option<i64>,
    pub timeout_minutes: Option<i64>,
    pub max_concurrent: Option<i64>,
    pub stations: Option<Vec<String>>,
    pub config_json: Option<String>,
    pub system_prompt: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct UpdateAgentProfileInput {
    pub id: String,
    pub name: Option<String>,
    pub role: Option<String>,
    pub provider: Option<String>,
    pub model: Option<String>,
    pub token_budget: Option<i64>,
    pub timeout_minutes: Option<i64>,
    pub max_concurrent: Option<i64>,
    pub stations: Option<Vec<String>>,
    pub config_json: Option<String>,
    pub system_prompt: Option<String>,
    pub active: Option<bool>,
}

pub async fn get_agent_profile(id: String, state: &AppState) -> Result<AgentProfileView, String> {
    let db = {
        let current = state.current.lock().await;
        let ctx = current
            .as_ref()
            .ok_or_else(|| "no open project".to_string())?;
        ctx.db.clone()
    };
    let row = db
        .get_agent_profile(&id)
        .await
        .map_err(|e| e.to_string())?
        .ok_or_else(|| format!("agent profile '{id}' not found"))?;
    Ok(profile_row_to_view(row))
}

pub async fn create_agent_profile(
    input: CreateAgentProfileInput,
    state: &AppState,
) -> Result<AgentProfileView, String> {
    let (project_id, db) = {
        let current = state.current.lock().await;
        let ctx = current
            .as_ref()
            .ok_or_else(|| "no open project".to_string())?;
        (ctx.project_id.to_string(), ctx.db.clone())
    };

    let now = Utc::now();
    let id = Uuid::new_v4().to_string();
    let stations_json = serde_json::to_string(&input.stations.unwrap_or_default())
        .unwrap_or_else(|_| "[]".to_string());
    let row = pnevma_db::AgentProfileRow {
        id: id.clone(),
        project_id,
        name: input.name,
        provider: input.provider.unwrap_or_else(|| "anthropic".to_string()),
        model: input
            .model
            .unwrap_or_else(|| "claude-sonnet-4-6".to_string()),
        token_budget: input.token_budget.unwrap_or(200000),
        timeout_minutes: input.timeout_minutes.unwrap_or(30),
        max_concurrent: input.max_concurrent.unwrap_or(2),
        stations_json,
        config_json: input.config_json.unwrap_or_else(|| "{}".to_string()),
        active: true,
        created_at: now,
        updated_at: now,
        role: input.role.unwrap_or_else(|| "build".to_string()),
        system_prompt: input.system_prompt,
    };
    db.create_agent_profile(&row)
        .await
        .map_err(|e| e.to_string())?;
    Ok(profile_row_to_view(row))
}

pub async fn update_agent_profile(
    input: UpdateAgentProfileInput,
    state: &AppState,
) -> Result<AgentProfileView, String> {
    let db = {
        let current = state.current.lock().await;
        let ctx = current
            .as_ref()
            .ok_or_else(|| "no open project".to_string())?;
        ctx.db.clone()
    };

    let existing = db
        .get_agent_profile(&input.id)
        .await
        .map_err(|e| e.to_string())?
        .ok_or_else(|| format!("agent profile '{}' not found", input.id))?;

    let now = Utc::now();
    let stations_json = input
        .stations
        .map(|s| serde_json::to_string(&s).unwrap_or_else(|_| "[]".to_string()))
        .unwrap_or(existing.stations_json);
    let updated = pnevma_db::AgentProfileRow {
        id: existing.id,
        project_id: existing.project_id,
        name: input.name.unwrap_or(existing.name),
        provider: input.provider.unwrap_or(existing.provider),
        model: input.model.unwrap_or(existing.model),
        token_budget: input.token_budget.unwrap_or(existing.token_budget),
        timeout_minutes: input.timeout_minutes.unwrap_or(existing.timeout_minutes),
        max_concurrent: input.max_concurrent.unwrap_or(existing.max_concurrent),
        stations_json,
        config_json: input.config_json.unwrap_or(existing.config_json),
        active: input.active.unwrap_or(existing.active),
        created_at: existing.created_at,
        updated_at: now,
        role: input.role.unwrap_or(existing.role),
        system_prompt: input.system_prompt.or(existing.system_prompt),
    };
    db.update_agent_profile(&updated)
        .await
        .map_err(|e| e.to_string())?;
    Ok(profile_row_to_view(updated))
}

pub async fn delete_agent_profile(id: String, state: &AppState) -> Result<(), String> {
    let db = {
        let current = state.current.lock().await;
        let ctx = current
            .as_ref()
            .ok_or_else(|| "no open project".to_string())?;
        ctx.db.clone()
    };
    db.delete_agent_profile(&id)
        .await
        .map_err(|e| e.to_string())?;
    Ok(())
}

pub async fn copy_agent_to_global(id: String, state: &AppState) -> Result<String, String> {
    let db = {
        let current = state.current.lock().await;
        let ctx = current
            .as_ref()
            .ok_or_else(|| "no open project".to_string())?;
        ctx.db.clone()
    };
    let project_row = db
        .get_agent_profile(&id)
        .await
        .map_err(|e| e.to_string())?
        .ok_or_else(|| format!("agent profile '{id}' not found"))?;

    let global_db = state.global_db()?;
    let now = Utc::now();
    let new_id = Uuid::new_v4().to_string();
    let row = pnevma_db::GlobalAgentProfileRow {
        id: new_id.clone(),
        name: project_row.name,
        role: project_row.role,
        provider: project_row.provider,
        model: project_row.model,
        token_budget: project_row.token_budget,
        timeout_minutes: project_row.timeout_minutes,
        max_concurrent: project_row.max_concurrent,
        stations_json: project_row.stations_json,
        config_json: project_row.config_json,
        system_prompt: project_row.system_prompt,
        active: true,
        created_at: now,
        updated_at: now,
    };
    global_db
        .create_global_agent_profile(&row)
        .await
        .map_err(|e| e.to_string())?;
    Ok(new_id)
}
