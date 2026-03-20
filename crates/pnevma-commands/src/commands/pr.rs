use super::*;
use pnevma_db::PullRequestRow;

// ── Input/View types ────────────────────────────────────────────────────────

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct PrCreateInput {
    pub task_id: String,
    pub title: String,
    pub body: Option<String>,
    pub base: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct PrSyncInput {
    pub task_id: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct PrGetInput {
    pub id: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct PrMergeInput {
    pub id: String,
    pub method: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct PrCloseInput {
    pub id: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct PrView {
    pub id: String,
    pub task_id: Option<String>,
    pub number: i64,
    pub title: String,
    pub source_branch: String,
    pub target_branch: String,
    pub status: String,
    pub checks_status: Option<String>,
    pub review_status: Option<String>,
    pub mergeable: bool,
    pub head_sha: Option<String>,
    pub created_at: String,
    pub updated_at: String,
    pub merged_at: Option<String>,
}

impl From<PullRequestRow> for PrView {
    fn from(row: PullRequestRow) -> Self {
        Self {
            id: row.id,
            task_id: row.task_id,
            number: row.number,
            title: row.title,
            source_branch: row.source_branch,
            target_branch: row.target_branch,
            status: row.status,
            checks_status: row.checks_status,
            review_status: row.review_status,
            mergeable: row.mergeable,
            head_sha: row.head_sha,
            created_at: row.created_at,
            updated_at: row.updated_at,
            merged_at: row.merged_at,
        }
    }
}

// ── Command functions ───────────────────────────────────────────────────────

pub async fn pr_create(input: PrCreateInput, state: &AppState) -> Result<PrView, String> {
    let (db, project_id, checkout_path) = {
        let current = state.current.lock().await;
        let ctx = current
            .as_ref()
            .ok_or_else(|| "no open project".to_string())?;
        (
            ctx.db.clone(),
            ctx.project_id.to_string(),
            ctx.checkout_path.clone(),
        )
    };

    let task = db
        .get_task(&input.task_id)
        .await
        .map_err(|e| e.to_string())?
        .ok_or_else(|| "task not found".to_string())?;

    let head = task.branch.as_deref().unwrap_or("HEAD");
    let base = input.base.as_deref().unwrap_or("main");
    let body = input.body.as_deref().unwrap_or("");

    let pr_info =
        crate::pr_service::PrService::create(&checkout_path, &input.title, body, head, base)
            .await?;

    let now = chrono::Utc::now().to_rfc3339();
    let row = PullRequestRow {
        id: Uuid::new_v4().to_string(),
        project_id: project_id.clone(),
        task_id: Some(input.task_id),
        number: pr_info.number,
        title: pr_info.title,
        source_branch: pr_info.head_ref,
        target_branch: pr_info.base_ref,
        remote_url: pr_info.url,
        status: "open".to_string(),
        checks_status: None,
        review_status: None,
        mergeable: pr_info.mergeable != "CONFLICTING",
        head_sha: Some(pr_info.head_sha),
        created_at: now.clone(),
        updated_at: now,
        merged_at: None,
    };

    db.create_pull_request(&row)
        .await
        .map_err(|e| e.to_string())?;

    Ok(PrView::from(row))
}

pub async fn pr_sync(_input: PrSyncInput, state: &AppState) -> Result<Vec<PrView>, String> {
    let db = {
        let current = state.current.lock().await;
        let ctx = current
            .as_ref()
            .ok_or_else(|| "no open project".to_string())?;
        ctx.db.clone()
    };

    let project_id = {
        let current = state.current.lock().await;
        current.as_ref().unwrap().project_id.to_string()
    };

    let rows = db
        .list_pull_requests(&project_id)
        .await
        .map_err(|e| e.to_string())?;

    Ok(rows.into_iter().map(PrView::from).collect())
}

pub async fn pr_list(state: &AppState) -> Result<Vec<PrView>, String> {
    let (db, project_id) = {
        let current = state.current.lock().await;
        let ctx = current
            .as_ref()
            .ok_or_else(|| "no open project".to_string())?;
        (ctx.db.clone(), ctx.project_id.to_string())
    };

    let rows = db
        .list_pull_requests(&project_id)
        .await
        .map_err(|e| e.to_string())?;

    Ok(rows.into_iter().map(PrView::from).collect())
}

pub async fn pr_get(input: PrGetInput, state: &AppState) -> Result<Option<PrView>, String> {
    let db = {
        let current = state.current.lock().await;
        let ctx = current
            .as_ref()
            .ok_or_else(|| "no open project".to_string())?;
        ctx.db.clone()
    };

    let row = db
        .get_pull_request(&input.id)
        .await
        .map_err(|e| e.to_string())?;

    Ok(row.map(PrView::from))
}

pub async fn pr_merge(input: PrMergeInput, state: &AppState) -> Result<PrView, String> {
    let (db, checkout_path) = {
        let current = state.current.lock().await;
        let ctx = current
            .as_ref()
            .ok_or_else(|| "no open project".to_string())?;
        (ctx.db.clone(), ctx.checkout_path.clone())
    };

    let row = db
        .get_pull_request(&input.id)
        .await
        .map_err(|e| e.to_string())?
        .ok_or_else(|| "PR not found".to_string())?;

    let method = input.method.as_deref().unwrap_or("merge");
    crate::pr_service::PrService::merge(&checkout_path, row.number, method).await?;

    let now = chrono::Utc::now().to_rfc3339();
    db.update_pull_request_status(&input.id, "merged", Some(&now))
        .await
        .map_err(|e| e.to_string())?;

    let updated = db
        .get_pull_request(&input.id)
        .await
        .map_err(|e| e.to_string())?
        .ok_or_else(|| "PR not found after update".to_string())?;

    Ok(PrView::from(updated))
}

pub async fn pr_close(input: PrCloseInput, state: &AppState) -> Result<PrView, String> {
    let (db, checkout_path) = {
        let current = state.current.lock().await;
        let ctx = current
            .as_ref()
            .ok_or_else(|| "no open project".to_string())?;
        (ctx.db.clone(), ctx.checkout_path.clone())
    };

    let row = db
        .get_pull_request(&input.id)
        .await
        .map_err(|e| e.to_string())?
        .ok_or_else(|| "PR not found".to_string())?;

    crate::pr_service::PrService::close(&checkout_path, row.number).await?;

    db.update_pull_request_status(&input.id, "closed", None)
        .await
        .map_err(|e| e.to_string())?;

    let updated = db
        .get_pull_request(&input.id)
        .await
        .map_err(|e| e.to_string())?
        .ok_or_else(|| "PR not found after update".to_string())?;

    Ok(PrView::from(updated))
}
