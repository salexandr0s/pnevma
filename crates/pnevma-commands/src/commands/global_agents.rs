use super::*;

// ─── Global Agent Profile views ───────────────────────────────────────────────

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct GlobalAgentProfileView {
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
pub struct CreateGlobalAgentInput {
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
pub struct UpdateGlobalAgentInput {
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

fn global_profile_row_to_view(row: pnevma_db::GlobalAgentProfileRow) -> GlobalAgentProfileView {
    let stations: Vec<String> = serde_json::from_str(&row.stations_json).unwrap_or_default();
    GlobalAgentProfileView {
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

pub async fn list_global_agents(state: &AppState) -> Result<Vec<GlobalAgentProfileView>, String> {
    let global_db = state.global_db()?;
    let rows = global_db
        .list_global_agent_profiles()
        .await
        .map_err(|e| e.to_string())?;
    Ok(rows.into_iter().map(global_profile_row_to_view).collect())
}

pub async fn get_global_agent(
    id: String,
    state: &AppState,
) -> Result<GlobalAgentProfileView, String> {
    let global_db = state.global_db()?;
    let row = global_db
        .get_global_agent_profile(&id)
        .await
        .map_err(|e| e.to_string())?
        .ok_or_else(|| format!("global agent profile '{id}' not found"))?;
    Ok(global_profile_row_to_view(row))
}

pub async fn create_global_agent(
    input: CreateGlobalAgentInput,
    state: &AppState,
) -> Result<GlobalAgentProfileView, String> {
    let global_db = state.global_db()?;

    let now = Utc::now();
    let id = Uuid::new_v4().to_string();
    let stations_json = serde_json::to_string(&input.stations.unwrap_or_default())
        .unwrap_or_else(|_| "[]".to_string());
    let row = pnevma_db::GlobalAgentProfileRow {
        id: id.clone(),
        name: input.name,
        role: input.role.unwrap_or_else(|| "build".to_string()),
        provider: input.provider.unwrap_or_else(|| "anthropic".to_string()),
        model: input
            .model
            .unwrap_or_else(|| "claude-sonnet-4-6".to_string()),
        token_budget: input.token_budget.unwrap_or(200000),
        timeout_minutes: input.timeout_minutes.unwrap_or(30),
        max_concurrent: input.max_concurrent.unwrap_or(2),
        stations_json,
        config_json: input.config_json.unwrap_or_else(|| "{}".to_string()),
        system_prompt: input.system_prompt,
        active: true,
        created_at: now,
        updated_at: now,
    };
    global_db
        .create_global_agent_profile(&row)
        .await
        .map_err(|e| e.to_string())?;
    Ok(global_profile_row_to_view(row))
}

pub async fn update_global_agent(
    input: UpdateGlobalAgentInput,
    state: &AppState,
) -> Result<GlobalAgentProfileView, String> {
    let global_db = state.global_db()?;

    let existing = global_db
        .get_global_agent_profile(&input.id)
        .await
        .map_err(|e| e.to_string())?
        .ok_or_else(|| format!("global agent profile '{}' not found", input.id))?;

    let now = Utc::now();
    let stations_json = input
        .stations
        .map(|s| serde_json::to_string(&s).unwrap_or_else(|_| "[]".to_string()))
        .unwrap_or(existing.stations_json);
    let updated = pnevma_db::GlobalAgentProfileRow {
        id: existing.id,
        name: input.name.unwrap_or(existing.name),
        role: input.role.unwrap_or(existing.role),
        provider: input.provider.unwrap_or(existing.provider),
        model: input.model.unwrap_or(existing.model),
        token_budget: input.token_budget.unwrap_or(existing.token_budget),
        timeout_minutes: input.timeout_minutes.unwrap_or(existing.timeout_minutes),
        max_concurrent: input.max_concurrent.unwrap_or(existing.max_concurrent),
        stations_json,
        config_json: input.config_json.unwrap_or(existing.config_json),
        system_prompt: input.system_prompt.or(existing.system_prompt),
        active: input.active.unwrap_or(existing.active),
        created_at: existing.created_at,
        updated_at: now,
    };
    global_db
        .update_global_agent_profile(&updated)
        .await
        .map_err(|e| e.to_string())?;
    Ok(global_profile_row_to_view(updated))
}

pub async fn delete_global_agent(id: String, state: &AppState) -> Result<(), String> {
    let global_db = state.global_db()?;
    global_db
        .delete_global_agent_profile(&id)
        .await
        .map_err(|e| e.to_string())?;
    Ok(())
}

pub async fn copy_global_agent_to_project(id: String, state: &AppState) -> Result<String, String> {
    let global_db = state.global_db()?;
    let global_row = global_db
        .get_global_agent_profile(&id)
        .await
        .map_err(|e| e.to_string())?
        .ok_or_else(|| format!("global agent profile '{id}' not found"))?;

    let (project_id, db) = {
        let current = state.current.lock().await;
        let ctx = current
            .as_ref()
            .ok_or_else(|| "no open project".to_string())?;
        (ctx.project_id, ctx.db.clone())
    };

    let now = Utc::now();
    let new_id = Uuid::new_v4().to_string();
    let row = pnevma_db::AgentProfileRow {
        id: new_id.clone(),
        project_id: project_id.to_string(),
        name: global_row.name,
        provider: global_row.provider,
        model: global_row.model,
        token_budget: global_row.token_budget,
        timeout_minutes: global_row.timeout_minutes,
        max_concurrent: global_row.max_concurrent,
        stations_json: global_row.stations_json,
        config_json: global_row.config_json,
        active: true,
        created_at: now,
        updated_at: now,
        role: global_row.role,
        system_prompt: global_row.system_prompt,
    };
    db.create_agent_profile(&row)
        .await
        .map_err(|e| e.to_string())?;
    Ok(new_id)
}

/// List all agent profiles from both global and project scopes, merged.
pub async fn list_all_agents(state: &AppState) -> Result<Vec<serde_json::Value>, String> {
    let global_db = state.global_db()?;
    let mut result_map: HashMap<String, serde_json::Value> = HashMap::new();

    // Always load global agents
    let global_rows = global_db
        .list_global_agent_profiles()
        .await
        .map_err(|e| e.to_string())?;
    for r in global_rows {
        let stations: Vec<String> = serde_json::from_str(&r.stations_json).unwrap_or_default();
        result_map.insert(
            r.name.clone(),
            json!({
                "id": r.id,
                "name": r.name,
                "role": r.role,
                "provider": r.provider,
                "model": r.model,
                "token_budget": r.token_budget,
                "timeout_minutes": r.timeout_minutes,
                "max_concurrent": r.max_concurrent,
                "stations": stations,
                "system_prompt": r.system_prompt,
                "active": r.active,
                "scope": "global",
                "created_at": r.created_at,
                "updated_at": r.updated_at,
            }),
        );
    }

    // If a project is open, project profiles override global by name
    let (project_id_opt, db_opt) = {
        let current = state.current.lock().await;
        if let Some(ctx) = current.as_ref() {
            (Some(ctx.project_id.to_string()), Some(ctx.db.clone()))
        } else {
            (None, None)
        }
    };

    if let (Some(project_id), Some(db)) = (project_id_opt, db_opt) {
        match db.list_agent_profiles(&project_id).await {
            Ok(rows) => {
                for r in rows {
                    let stations: Vec<String> =
                        serde_json::from_str(&r.stations_json).unwrap_or_default();
                    result_map.insert(
                        r.name.clone(),
                        json!({
                            "id": r.id,
                            "name": r.name,
                            "role": r.role,
                            "provider": r.provider,
                            "model": r.model,
                            "token_budget": r.token_budget,
                            "timeout_minutes": r.timeout_minutes,
                            "max_concurrent": r.max_concurrent,
                            "stations": stations,
                            "system_prompt": r.system_prompt,
                            "active": r.active,
                            "scope": "project",
                            "created_at": r.created_at,
                            "updated_at": r.updated_at,
                        }),
                    );
                }
            }
            Err(e) => {
                tracing::warn!("failed to load project agent profiles: {e}");
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
