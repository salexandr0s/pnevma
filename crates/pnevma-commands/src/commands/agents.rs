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
    pub source: String,
    pub source_path: Option<String>,
    pub user_modified: bool,
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
        source: row.source,
        source_path: row.source_path,
        user_modified: row.user_modified,
    }
}

// ─── Discovery sync ─────────────────────────────────────────────────────────

/// Sync project agents if a project is open; silently succeeds if not.
pub async fn sync_discovered_project_agents_if_open(state: &AppState) -> Result<(), String> {
    let has_project = state.current.lock().await.is_some();
    if !has_project {
        return Ok(());
    }
    sync_discovered_project_agents(state).await
}

async fn sync_discovered_project_agents(state: &AppState) -> Result<(), String> {
    let (project_id, project_path, db) = {
        let current = state.current.lock().await;
        let ctx = current
            .as_ref()
            .ok_or_else(|| "no open project".to_string())?;
        (
            ctx.project_id.to_string(),
            ctx.project_path.clone(),
            ctx.db.clone(),
        )
    };

    let discovered = pnevma_core::agent_discovery::discover_project_agents(&project_path);
    if discovered.is_empty() {
        return Ok(());
    }

    let now = Utc::now();

    for agent in discovered {
        let existing = db
            .get_agent_profile_by_source_path(&project_id, &agent.source_path)
            .await
            .map_err(|e| e.to_string())?;

        if let Some(existing) = existing {
            if existing.user_modified {
                continue;
            }
            let updated = pnevma_db::AgentProfileRow {
                id: existing.id,
                project_id: existing.project_id,
                name: agent.name,
                role: agent.role,
                provider: agent.provider,
                model: agent.model,
                token_budget: existing.token_budget,
                timeout_minutes: existing.timeout_minutes,
                max_concurrent: existing.max_concurrent,
                stations_json: existing.stations_json,
                config_json: existing.config_json,
                active: existing.active,
                created_at: existing.created_at,
                updated_at: now,
                system_prompt: agent.system_prompt,
                source: agent.source,
                source_path: Some(agent.source_path),
                user_modified: false,
                thinking_level: None,
                thinking_budget: None,
                tool_restrictions_json: None,
                extra_flags_json: None,
            };
            if let Err(e) = db.update_agent_profile(&updated).await {
                tracing::warn!(error = %e, "failed to update discovered project agent");
            }
        } else {
            // Check for name collision — skip if any existing record has that name
            // (could be user-created, or a soft-deleted discovered agent)
            if let Ok(Some(_)) = db.get_agent_profile_by_name(&project_id, &agent.name).await {
                continue;
            }

            let row = pnevma_db::AgentProfileRow {
                id: Uuid::new_v4().to_string(),
                project_id: project_id.clone(),
                name: agent.name,
                role: agent.role,
                provider: agent.provider,
                model: agent.model,
                token_budget: 200000,
                timeout_minutes: 30,
                max_concurrent: 2,
                stations_json: "[]".to_string(),
                config_json: "{}".to_string(),
                active: true,
                created_at: now,
                updated_at: now,
                system_prompt: agent.system_prompt,
                source: agent.source,
                source_path: Some(agent.source_path),
                user_modified: false,
                thinking_level: None,
                thinking_budget: None,
                tool_restrictions_json: None,
                extra_flags_json: None,
            };
            if let Err(e) = db.create_agent_profile(&row).await {
                tracing::warn!(error = %e, "failed to insert discovered project agent");
            }
        }
    }

    Ok(())
}

// ─── Commands ────────────────────────────────────────────────────────────────

pub async fn list_agent_profiles(state: &AppState) -> Result<Vec<AgentProfileView>, String> {
    // Sync discovered agents before listing (errors are non-fatal)
    if let Err(e) = sync_discovered_project_agents(state).await {
        tracing::warn!(error = %e, "project agent discovery sync failed");
    }

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
        system_prompt: input.system_prompt.filter(|s| !s.is_empty()),
        source: "user".to_string(),
        source_path: None,
        user_modified: false,
        thinking_level: None,
        thinking_budget: None,
        tool_restrictions_json: None,
        extra_flags_json: None,
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
        // Some("...") → set, Some("") → clear, None → keep existing
        system_prompt: match input.system_prompt {
            Some(ref s) if s.is_empty() => None,
            Some(s) => Some(s),
            None => existing.system_prompt,
        },
        source: existing.source,
        source_path: existing.source_path,
        user_modified: true,
        thinking_level: None,
        thinking_budget: None,
        tool_restrictions_json: None,
        extra_flags_json: None,
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

    let existing = db.get_agent_profile(&id).await.map_err(|e| e.to_string())?;

    // Discovered agents: soft-delete (active=false, user_modified=true) so sync won't re-import
    if let Some(row) = existing {
        if row.source != "user" {
            let mut updated = row;
            updated.active = false;
            updated.user_modified = true;
            updated.updated_at = Utc::now();
            db.update_agent_profile(&updated)
                .await
                .map_err(|e| e.to_string())?;
            return Ok(());
        }
    }

    // User-created agents: hard delete
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
        source: "user".to_string(),
        source_path: None,
        user_modified: false,
        thinking_level: None,
        thinking_budget: None,
        tool_restrictions_json: None,
        extra_flags_json: None,
    };
    global_db
        .create_global_agent_profile(&row)
        .await
        .map_err(|e| e.to_string())?;
    Ok(new_id)
}
