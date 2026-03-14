use super::*;
use pnevma_tracker::types::{ExternalState, TrackerItem};

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct TrackerPollInput {
    pub limit: Option<usize>,
    pub labels: Option<Vec<String>>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct TrackerItemView {
    pub kind: String,
    pub external_id: String,
    pub identifier: String,
    pub title: String,
    pub description: Option<String>,
    pub url: String,
    pub state: String,
    pub priority: Option<f64>,
    pub labels: Vec<String>,
    pub assignee: Option<String>,
    pub updated_at: DateTime<Utc>,
}

impl From<TrackerItem> for TrackerItemView {
    fn from(item: TrackerItem) -> Self {
        let state = match &item.state {
            ExternalState::Triage => "Triage".to_string(),
            ExternalState::Backlog => "Backlog".to_string(),
            ExternalState::Todo => "Todo".to_string(),
            ExternalState::InProgress => "InProgress".to_string(),
            ExternalState::InReview => "InReview".to_string(),
            ExternalState::Done => "Done".to_string(),
            ExternalState::Cancelled => "Cancelled".to_string(),
            ExternalState::Custom(s) => s.clone(),
        };
        Self {
            kind: item.kind,
            external_id: item.external_id,
            identifier: item.identifier,
            title: item.title,
            description: item.description,
            url: item.url,
            state,
            priority: item.priority,
            labels: item.labels,
            assignee: item.assignee,
            updated_at: item.updated_at,
        }
    }
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct TrackerStatusView {
    pub enabled: bool,
    pub kind: String,
    pub team_id: Option<String>,
    pub labels: Vec<String>,
    pub poll_interval_seconds: u64,
    pub coordinator_active: bool,
}

pub async fn tracker_poll(
    _input: TrackerPollInput,
    state: &AppState,
) -> Result<Vec<TrackerItemView>, String> {
    let coordinator = {
        let current = state.current.lock().await;
        let ctx = current
            .as_ref()
            .ok_or_else(|| "no open project".to_string())?;
        ctx.tracker.clone()
    };

    let coordinator =
        coordinator.ok_or_else(|| "tracker is not enabled for this project".to_string())?;

    // tracker_poll always uses the coordinator's configured filter (set at project open time).
    // Input fields (limit, labels) are accepted for API compatibility but are not applied here.
    let items = coordinator.poll_once().await.map_err(|e| e.to_string())?;

    Ok(items.into_iter().map(TrackerItemView::from).collect())
}

pub async fn tracker_status(state: &AppState) -> Result<TrackerStatusView, String> {
    let (config_section, coordinator) = {
        let current = state.current.lock().await;
        let ctx = current
            .as_ref()
            .ok_or_else(|| "no open project".to_string())?;
        (ctx.config.tracker.clone(), ctx.tracker.clone())
    };

    Ok(TrackerStatusView {
        enabled: config_section.enabled,
        kind: config_section.kind.to_string(),
        team_id: config_section.team_id,
        labels: config_section.labels,
        poll_interval_seconds: config_section.poll_interval_seconds,
        coordinator_active: coordinator.is_some(),
    })
}
