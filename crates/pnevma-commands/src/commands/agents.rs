use super::*;

// ─── Agent Profile views ──────────────────────────────────────────────────────

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct AgentProfileView {
    pub id: String,
    pub name: String,
    pub provider: String,
    pub model: String,
    pub token_budget: i64,
    pub timeout_minutes: i64,
    pub max_concurrent: i64,
    pub stations: Vec<String>,
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
        provider: row.provider,
        model: row.model,
        token_budget: row.token_budget,
        timeout_minutes: row.timeout_minutes,
        max_concurrent: row.max_concurrent,
        stations,
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
