use super::*;
use pnevma_db::{CiPipelineRow, DeploymentRow};

// ── Input/View types ────────────────────────────────────────────────────────

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct CiSyncInput {
    pub limit: Option<usize>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct CiGetInput {
    pub id: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct CiPipelineView {
    pub id: String,
    pub task_id: Option<String>,
    pub pr_id: Option<String>,
    pub provider: String,
    pub run_number: Option<i64>,
    pub workflow_name: Option<String>,
    pub head_sha: Option<String>,
    pub status: String,
    pub conclusion: Option<String>,
    pub html_url: Option<String>,
    pub created_at: String,
}

impl From<CiPipelineRow> for CiPipelineView {
    fn from(row: CiPipelineRow) -> Self {
        Self {
            id: row.id,
            task_id: row.task_id,
            pr_id: row.pr_id,
            provider: row.provider,
            run_number: row.run_number,
            workflow_name: row.workflow_name,
            head_sha: row.head_sha,
            status: row.status,
            conclusion: row.conclusion,
            html_url: row.html_url,
            created_at: row.created_at,
        }
    }
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct DeploymentView {
    pub id: String,
    pub task_id: Option<String>,
    pub environment: String,
    pub status: String,
    pub ref_name: Option<String>,
    pub sha: Option<String>,
    pub url: Option<String>,
    pub created_at: String,
}

impl From<DeploymentRow> for DeploymentView {
    fn from(row: DeploymentRow) -> Self {
        Self {
            id: row.id,
            task_id: row.task_id,
            environment: row.environment,
            status: row.status,
            ref_name: row.ref_name,
            sha: row.sha,
            url: row.url,
            created_at: row.created_at,
        }
    }
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct CiSummaryView {
    pub total_pipelines: usize,
    pub success: usize,
    pub failure: usize,
    pub in_progress: usize,
    pub recent: Vec<CiPipelineView>,
}

// ── Command functions ───────────────────────────────────────────────────────

pub async fn ci_sync(input: CiSyncInput, state: &AppState) -> Result<Vec<CiPipelineView>, String> {
    let (db, project_id, project_path) = {
        let current = state.current.lock().await;
        let ctx = current
            .as_ref()
            .ok_or_else(|| "no open project".to_string())?;
        (
            ctx.db.clone(),
            ctx.project_id.to_string(),
            ctx.project_path.clone(),
        )
    };

    let limit = input.limit.unwrap_or(20);
    let runs = crate::ci_service::CiService::list_runs(&project_path, limit).await?;

    let mut views = Vec::new();
    for run in runs {
        let now = chrono::Utc::now().to_rfc3339();
        let row = CiPipelineRow {
            id: Uuid::new_v4().to_string(),
            project_id: project_id.clone(),
            task_id: None,
            pr_id: None,
            provider: "github".to_string(),
            run_number: Some(run.run_number),
            workflow_name: Some(run.name),
            head_sha: Some(run.head_sha),
            status: run.status,
            conclusion: if run.conclusion.is_empty() {
                None
            } else {
                Some(run.conclusion)
            },
            html_url: Some(run.html_url),
            started_at: None,
            completed_at: None,
            created_at: now.clone(),
            updated_at: now,
        };
        let _ = db.create_ci_pipeline(&row).await;
        views.push(CiPipelineView::from(row));
    }

    Ok(views)
}

pub async fn ci_list(state: &AppState) -> Result<Vec<CiPipelineView>, String> {
    let (db, project_id) = {
        let current = state.current.lock().await;
        let ctx = current
            .as_ref()
            .ok_or_else(|| "no open project".to_string())?;
        (ctx.db.clone(), ctx.project_id.to_string())
    };

    let rows = db
        .list_ci_pipelines(&project_id)
        .await
        .map_err(|e| e.to_string())?;

    Ok(rows.into_iter().map(CiPipelineView::from).collect())
}

pub async fn ci_get(input: CiGetInput, state: &AppState) -> Result<Option<CiPipelineView>, String> {
    let db = {
        let current = state.current.lock().await;
        let ctx = current
            .as_ref()
            .ok_or_else(|| "no open project".to_string())?;
        ctx.db.clone()
    };

    let row = db
        .get_ci_pipeline(&input.id)
        .await
        .map_err(|e| e.to_string())?;

    Ok(row.map(CiPipelineView::from))
}

pub async fn ci_summary(state: &AppState) -> Result<CiSummaryView, String> {
    let (db, project_id) = {
        let current = state.current.lock().await;
        let ctx = current
            .as_ref()
            .ok_or_else(|| "no open project".to_string())?;
        (ctx.db.clone(), ctx.project_id.to_string())
    };

    let rows = db
        .list_ci_pipelines(&project_id)
        .await
        .map_err(|e| e.to_string())?;

    let total_pipelines = rows.len();
    let success = rows
        .iter()
        .filter(|r| r.conclusion.as_deref() == Some("success"))
        .count();
    let failure = rows
        .iter()
        .filter(|r| r.conclusion.as_deref() == Some("failure"))
        .count();
    let in_progress = rows
        .iter()
        .filter(|r| r.status == "in_progress" || r.status == "queued")
        .count();

    let recent: Vec<CiPipelineView> = rows
        .into_iter()
        .take(10)
        .map(CiPipelineView::from)
        .collect();

    Ok(CiSummaryView {
        total_pipelines,
        success,
        failure,
        in_progress,
        recent,
    })
}

pub async fn deployment_list(state: &AppState) -> Result<Vec<DeploymentView>, String> {
    let (db, project_id) = {
        let current = state.current.lock().await;
        let ctx = current
            .as_ref()
            .ok_or_else(|| "no open project".to_string())?;
        (ctx.db.clone(), ctx.project_id.to_string())
    };

    let rows = db
        .list_deployments(&project_id)
        .await
        .map_err(|e| e.to_string())?;

    Ok(rows.into_iter().map(DeploymentView::from).collect())
}
