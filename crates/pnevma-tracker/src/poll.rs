use crate::adapter::TrackerAdapter;
use crate::error::TrackerError;
use crate::types::{TrackerFilter, TrackerItem};
use chrono::{DateTime, Utc};
use std::sync::Arc;
use tokio::sync::RwLock;
use tracing::{debug, info, warn};

/// Coordinates polling from an external tracker and syncing items.
pub struct TrackerCoordinator {
    adapter: Arc<dyn TrackerAdapter>,
    filter: TrackerFilter,
    last_poll_at: RwLock<Option<DateTime<Utc>>>,
}

impl TrackerCoordinator {
    pub fn new(adapter: Arc<dyn TrackerAdapter>, filter: TrackerFilter) -> Self {
        Self {
            adapter,
            filter,
            last_poll_at: RwLock::new(None),
        }
    }

    /// Poll once for new/updated items from the tracker.
    pub async fn poll_once(&self) -> Result<Vec<TrackerItem>, TrackerError> {
        let mut filter = self.filter.clone();

        // Use last poll time as updated_since if available
        if let Some(last) = *self.last_poll_at.read().await {
            filter.updated_since = Some(last);
        }

        debug!("polling tracker for candidates");
        let items = self.adapter.poll_candidates(&filter).await?;

        // Update last poll time
        *self.last_poll_at.write().await = Some(Utc::now());

        info!(count = items.len(), "tracker poll returned items");
        Ok(items)
    }

    /// Sync outbound: push a Pnevma task status change to the tracker.
    pub async fn sync_outbound(
        &self,
        external_id: &str,
        from_state: crate::types::ExternalState,
        to_state: crate::types::ExternalState,
        comment: Option<String>,
    ) -> Result<(), TrackerError> {
        let transition = crate::types::StateTransition {
            external_id: external_id.to_string(),
            kind: "linear".to_string(),
            from_state,
            to_state,
            comment: comment.clone(),
        };

        self.adapter.transition_item(&transition).await?;

        if let Some(body) = comment {
            if let Err(e) = self.adapter.post_comment(external_id, &body).await {
                warn!(external_id = %external_id, error = %e, "failed to post comment");
            }
        }

        Ok(())
    }

    /// Get the underlying adapter.
    pub fn adapter(&self) -> &Arc<dyn TrackerAdapter> {
        &self.adapter
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::error::TrackerError;
    use crate::types::{ExternalState, StateTransition, TrackerItem};
    use async_trait::async_trait;

    struct MockAdapter {
        items: Vec<TrackerItem>,
    }

    #[async_trait]
    impl TrackerAdapter for MockAdapter {
        async fn poll_candidates(
            &self,
            _filter: &TrackerFilter,
        ) -> Result<Vec<TrackerItem>, TrackerError> {
            Ok(self.items.clone())
        }
        async fn fetch_states(&self, _ids: &[String]) -> Result<Vec<TrackerItem>, TrackerError> {
            Ok(vec![])
        }
        async fn transition_item(&self, _transition: &StateTransition) -> Result<(), TrackerError> {
            Ok(())
        }
        async fn post_comment(&self, _external_id: &str, _body: &str) -> Result<(), TrackerError> {
            Ok(())
        }
    }

    fn sample_item() -> TrackerItem {
        TrackerItem {
            kind: "linear".to_string(),
            external_id: "issue-1".to_string(),
            identifier: "PRJ-123".to_string(),
            title: "Fix bug".to_string(),
            description: Some("A bug fix".to_string()),
            url: "https://linear.app/issue/PRJ-123".to_string(),
            state: ExternalState::Todo,
            priority: Some(2.0),
            labels: vec!["bug".to_string()],
            assignee: None,
            updated_at: Utc::now(),
        }
    }

    #[tokio::test]
    async fn poll_once_returns_items_and_updates_last_poll() {
        let adapter = Arc::new(MockAdapter {
            items: vec![sample_item()],
        });
        let filter = TrackerFilter::default();
        let coordinator = TrackerCoordinator::new(adapter, filter);

        // Initially last_poll_at is None
        assert!(coordinator.last_poll_at.read().await.is_none());

        let items = coordinator.poll_once().await.unwrap();
        assert_eq!(items.len(), 1);
        assert_eq!(items[0].external_id, "issue-1");

        // last_poll_at should now be set
        assert!(coordinator.last_poll_at.read().await.is_some());
    }

    #[tokio::test]
    async fn poll_result_can_be_serialized() {
        let adapter = Arc::new(MockAdapter {
            items: vec![sample_item()],
        });
        let filter = TrackerFilter::default();
        let coordinator = TrackerCoordinator::new(adapter, filter);

        let items = coordinator.poll_once().await.unwrap();
        // Verify the result is serializable (for redaction pipeline)
        let json = serde_json::to_string(&items).unwrap();
        assert!(json.contains("PRJ-123"));
        assert!(json.contains("linear.app"));
    }

    #[tokio::test]
    async fn sync_outbound_succeeds() {
        let adapter = Arc::new(MockAdapter { items: vec![] });
        let filter = TrackerFilter::default();
        let coordinator = TrackerCoordinator::new(adapter, filter);

        let result = coordinator
            .sync_outbound(
                "issue-1",
                ExternalState::InProgress,
                ExternalState::Done,
                Some("completed".to_string()),
            )
            .await;
        assert!(result.is_ok());
    }
}
