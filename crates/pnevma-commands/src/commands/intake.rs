use super::*;
use pnevma_db::IntakeQueueRow;

// ── Input/View types ────────────────────────────────────────────────────────

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct IntakeListInput {
    pub status: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct IntakeAcceptInput {
    pub id: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct IntakeRejectInput {
    pub id: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct IntakeItemView {
    pub id: String,
    pub kind: String,
    pub external_id: String,
    pub identifier: String,
    pub title: String,
    pub url: String,
    pub state: String,
    pub priority: Option<String>,
    pub labels: serde_json::Value,
    pub status: String,
    pub promoted_task_id: Option<String>,
    pub ingested_at: String,
}

impl From<IntakeQueueRow> for IntakeItemView {
    fn from(row: IntakeQueueRow) -> Self {
        let labels = serde_json::from_str(&row.labels_json).unwrap_or(json!([]));
        Self {
            id: row.id,
            kind: row.kind,
            external_id: row.external_id,
            identifier: row.identifier,
            title: row.title,
            url: row.url,
            state: row.state,
            priority: row.priority,
            labels,
            status: row.status,
            promoted_task_id: row.promoted_task_id,
            ingested_at: row.ingested_at,
        }
    }
}

// ── Command functions ───────────────────────────────────────────────────────

pub async fn intake_list(
    input: IntakeListInput,
    state: &AppState,
) -> Result<Vec<IntakeItemView>, String> {
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
        .list_intake_items(&project_id, input.status.as_deref())
        .await
        .map_err(|e| e.to_string())?;

    Ok(rows.into_iter().map(IntakeItemView::from).collect())
}

pub async fn intake_accept(
    input: IntakeAcceptInput,
    state: &AppState,
) -> Result<IntakeItemView, String> {
    let db = {
        let current = state.current.lock().await;
        let ctx = current
            .as_ref()
            .ok_or_else(|| "no open project".to_string())?;
        ctx.db.clone()
    };

    db.update_intake_status(&input.id, "accepted", None)
        .await
        .map_err(|e| e.to_string())?;

    let row = db
        .get_intake_item(&input.id)
        .await
        .map_err(|e| e.to_string())?
        .ok_or_else(|| "intake item not found".to_string())?;

    Ok(IntakeItemView::from(row))
}

pub async fn intake_reject(
    input: IntakeRejectInput,
    state: &AppState,
) -> Result<IntakeItemView, String> {
    let db = {
        let current = state.current.lock().await;
        let ctx = current
            .as_ref()
            .ok_or_else(|| "no open project".to_string())?;
        ctx.db.clone()
    };

    db.update_intake_status(&input.id, "rejected", None)
        .await
        .map_err(|e| e.to_string())?;

    let row = db
        .get_intake_item(&input.id)
        .await
        .map_err(|e| e.to_string())?
        .ok_or_else(|| "intake item not found".to_string())?;

    Ok(IntakeItemView::from(row))
}

pub async fn intake_status(state: &AppState) -> Result<serde_json::Value, String> {
    let (db, project_id) = {
        let current = state.current.lock().await;
        let ctx = current
            .as_ref()
            .ok_or_else(|| "no open project".to_string())?;
        (ctx.db.clone(), ctx.project_id.to_string())
    };

    let pending = db
        .list_intake_items(&project_id, Some("pending"))
        .await
        .map_err(|e| e.to_string())?
        .len();
    let accepted = db
        .list_intake_items(&project_id, Some("accepted"))
        .await
        .map_err(|e| e.to_string())?
        .len();
    let rejected = db
        .list_intake_items(&project_id, Some("rejected"))
        .await
        .map_err(|e| e.to_string())?
        .len();

    Ok(json!({
        "pending": pending,
        "accepted": accepted,
        "rejected": rejected,
        "total": pending + accepted + rejected,
    }))
}
