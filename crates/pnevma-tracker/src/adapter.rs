use crate::error::TrackerError;
use crate::types::{StateTransition, TrackerFilter, TrackerItem};
use async_trait::async_trait;

#[async_trait]
pub trait TrackerAdapter: Send + Sync {
    /// Poll for candidate issues matching the filter.
    async fn poll_candidates(
        &self,
        filter: &TrackerFilter,
    ) -> Result<Vec<TrackerItem>, TrackerError>;

    /// Fetch current states for specific external IDs.
    async fn fetch_states(&self, ids: &[String]) -> Result<Vec<TrackerItem>, TrackerError>;

    /// Transition an item to a new state.
    async fn transition_item(&self, transition: &StateTransition) -> Result<(), TrackerError>;

    /// Post a comment on an item.
    async fn post_comment(&self, external_id: &str, body: &str) -> Result<(), TrackerError>;
}
