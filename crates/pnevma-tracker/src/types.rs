use chrono::{DateTime, Utc};
use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct TrackerItem {
    pub kind: String,
    pub external_id: String,
    /// Human-readable identifier like "PRJ-123"
    pub identifier: String,
    pub title: String,
    pub description: Option<String>,
    pub url: String,
    pub state: ExternalState,
    pub priority: Option<f64>,
    pub labels: Vec<String>,
    pub assignee: Option<String>,
    pub updated_at: DateTime<Utc>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub enum ExternalState {
    Triage,
    Backlog,
    Todo,
    InProgress,
    InReview,
    Done,
    Cancelled,
    Custom(String),
}

impl std::fmt::Display for ExternalState {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            ExternalState::Triage => write!(f, "triage"),
            ExternalState::Backlog => write!(f, "backlog"),
            ExternalState::Todo => write!(f, "todo"),
            ExternalState::InProgress => write!(f, "in progress"),
            ExternalState::InReview => write!(f, "in review"),
            ExternalState::Done => write!(f, "done"),
            ExternalState::Cancelled => write!(f, "cancelled"),
            ExternalState::Custom(s) => write!(f, "{s}"),
        }
    }
}

impl ExternalState {
    /// Parse a display-formatted string back into an ExternalState.
    pub fn from_display(s: &str) -> Self {
        Self::from_linear_state(s)
    }

    /// Map external state to a suggested Pnevma task status string.
    pub fn to_task_status(&self) -> &str {
        match self {
            ExternalState::Triage | ExternalState::Backlog => "Draft",
            ExternalState::Todo => "Ready",
            ExternalState::InProgress => "InProgress",
            ExternalState::InReview => "Review",
            ExternalState::Done => "Done",
            ExternalState::Cancelled => "Cancelled",
            ExternalState::Custom(_) => "Draft",
        }
    }

    pub fn from_linear_state(name: &str) -> Self {
        match name.to_lowercase().as_str() {
            "triage" => ExternalState::Triage,
            "backlog" => ExternalState::Backlog,
            "todo" | "unstarted" => ExternalState::Todo,
            "in progress" | "started" => ExternalState::InProgress,
            "in review" | "review" => ExternalState::InReview,
            "done" | "completed" => ExternalState::Done,
            "cancelled" | "canceled" => ExternalState::Cancelled,
            other => ExternalState::Custom(other.to_string()),
        }
    }
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct StateTransition {
    pub external_id: String,
    pub kind: String,
    pub from_state: ExternalState,
    pub to_state: ExternalState,
    pub comment: Option<String>,
}

#[derive(Debug, Clone, Default, Serialize, Deserialize)]
pub struct TrackerFilter {
    pub team_id: Option<String>,
    pub project_id: Option<String>,
    pub labels: Vec<String>,
    pub states: Vec<ExternalState>,
    pub updated_since: Option<DateTime<Utc>>,
    pub limit: Option<usize>,
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn triage_maps_to_draft() {
        assert_eq!(ExternalState::Triage.to_task_status(), "Draft");
    }

    #[test]
    fn backlog_maps_to_draft() {
        assert_eq!(ExternalState::Backlog.to_task_status(), "Draft");
    }

    #[test]
    fn todo_maps_to_ready() {
        assert_eq!(ExternalState::Todo.to_task_status(), "Ready");
    }

    #[test]
    fn in_progress_maps_to_in_progress() {
        assert_eq!(ExternalState::InProgress.to_task_status(), "InProgress");
    }

    #[test]
    fn in_review_maps_to_review() {
        assert_eq!(ExternalState::InReview.to_task_status(), "Review");
    }

    #[test]
    fn done_maps_to_done() {
        assert_eq!(ExternalState::Done.to_task_status(), "Done");
    }

    #[test]
    fn cancelled_maps_to_cancelled() {
        assert_eq!(ExternalState::Cancelled.to_task_status(), "Cancelled");
    }

    #[test]
    fn custom_maps_to_draft() {
        assert_eq!(
            ExternalState::Custom("Waiting".to_string()).to_task_status(),
            "Draft"
        );
    }

    #[test]
    fn from_linear_state_known_variants() {
        assert_eq!(
            ExternalState::from_linear_state("Triage"),
            ExternalState::Triage
        );
        assert_eq!(
            ExternalState::from_linear_state("Backlog"),
            ExternalState::Backlog
        );
        assert_eq!(
            ExternalState::from_linear_state("Todo"),
            ExternalState::Todo
        );
        assert_eq!(
            ExternalState::from_linear_state("Unstarted"),
            ExternalState::Todo
        );
        assert_eq!(
            ExternalState::from_linear_state("In Progress"),
            ExternalState::InProgress
        );
        assert_eq!(
            ExternalState::from_linear_state("Started"),
            ExternalState::InProgress
        );
        assert_eq!(
            ExternalState::from_linear_state("In Review"),
            ExternalState::InReview
        );
        assert_eq!(
            ExternalState::from_linear_state("Review"),
            ExternalState::InReview
        );
        assert_eq!(
            ExternalState::from_linear_state("Done"),
            ExternalState::Done
        );
        assert_eq!(
            ExternalState::from_linear_state("Completed"),
            ExternalState::Done
        );
        assert_eq!(
            ExternalState::from_linear_state("Cancelled"),
            ExternalState::Cancelled
        );
        assert_eq!(
            ExternalState::from_linear_state("Canceled"),
            ExternalState::Cancelled
        );
    }

    #[test]
    fn from_linear_state_case_insensitive() {
        assert_eq!(
            ExternalState::from_linear_state("IN PROGRESS"),
            ExternalState::InProgress
        );
        assert_eq!(
            ExternalState::from_linear_state("DONE"),
            ExternalState::Done
        );
        assert_eq!(
            ExternalState::from_linear_state("backlog"),
            ExternalState::Backlog
        );
    }

    #[test]
    fn from_linear_state_unknown_becomes_custom() {
        assert_eq!(
            ExternalState::from_linear_state("Awaiting Deployment"),
            ExternalState::Custom("awaiting deployment".to_string()),
        );
    }

    #[test]
    fn custom_state_value_is_preserved() {
        let state = ExternalState::from_linear_state("My Custom State");
        assert_eq!(state, ExternalState::Custom("my custom state".to_string()));
    }

    #[test]
    fn tracker_filter_default_construction() {
        let filter = TrackerFilter::default();
        assert!(filter.team_id.is_none());
        assert!(filter.project_id.is_none());
        assert!(filter.labels.is_empty());
        assert!(filter.states.is_empty());
        assert!(filter.updated_since.is_none());
        assert!(filter.limit.is_none());
    }

    #[test]
    fn state_transition_round_trip() {
        let transition = StateTransition {
            external_id: "issue-1".to_string(),
            kind: "linear".to_string(),
            from_state: ExternalState::Todo,
            to_state: ExternalState::InProgress,
            comment: Some("starting work".to_string()),
        };
        assert_eq!(transition.from_state, ExternalState::Todo);
        assert_eq!(transition.to_state, ExternalState::InProgress);
        assert_eq!(transition.comment.as_deref(), Some("starting work"));
    }
}
