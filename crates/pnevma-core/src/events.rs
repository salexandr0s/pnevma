use crate::{ProjectId, SessionId, TaskId, TraceId};
use chrono::{DateTime, Utc};
use serde::{Deserialize, Serialize};
use serde_json::Value;
use std::sync::Arc;
use tokio::sync::RwLock;
use uuid::Uuid;

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum EventType {
    SessionSpawned,
    SessionExited,
    SessionReattached,
    SessionHealthChanged,
    TaskCreated,
    TaskStatusChanged,
    TaskDispatched,
    TaskCompleted,
    TaskFailed,
    AgentSpawned,
    AgentOutput,
    AgentToolUse,
    AgentError,
    AgentComplete,
    AgentUsageUpdate,
    WorktreeCreated,
    WorktreeRemoved,
    BranchCreated,
    MergeStarted,
    MergeCompleted,
    MergeFailed,
    ConflictDetected,
    AcceptanceCheckRun,
    ReviewPackGenerated,
    ReviewApproved,
    ReviewRejected,
    CheckpointCreated,
    CheckpointRestored,
    ProjectOpened,
    ProjectClosed,
    ProtectedActionApproved,
    ProtectedActionRejected,
    WorkflowDispatched,
    WorkflowStageStarted,
    WorkflowStageCompleted,
    WorkflowStageFailed,
    WorkflowStageSkipped,
    WorkflowCompleted,
    WorkflowFailed,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum EventSource {
    Core,
    Session,
    Agent,
    Git,
    Review,
    System,
    Ui,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct EventRecord {
    pub id: Uuid,
    pub project_id: ProjectId,
    #[serde(default)]
    pub task_id: Option<TaskId>,
    #[serde(default)]
    pub session_id: Option<SessionId>,
    pub trace_id: TraceId,
    pub source: EventSource,
    pub event_type: EventType,
    pub payload: Value,
    pub timestamp: DateTime<Utc>,
}

#[derive(Debug, Clone, Default)]
pub struct EventFilter {
    pub project_id: Option<ProjectId>,
    pub task_id: Option<TaskId>,
    pub session_id: Option<SessionId>,
    pub event_type: Option<EventType>,
    pub from: Option<DateTime<Utc>>,
    pub to: Option<DateTime<Utc>>,
}

impl EventFilter {
    fn matches(&self, e: &EventRecord) -> bool {
        if let Some(project_id) = self.project_id {
            if e.project_id != project_id {
                return false;
            }
        }
        if let Some(task_id) = self.task_id {
            if e.task_id != Some(task_id) {
                return false;
            }
        }
        if let Some(session_id) = self.session_id {
            if e.session_id != Some(session_id) {
                return false;
            }
        }
        if let Some(ref event_type) = self.event_type {
            if &e.event_type != event_type {
                return false;
            }
        }
        if let Some(from) = self.from {
            if e.timestamp < from {
                return false;
            }
        }
        if let Some(to) = self.to {
            if e.timestamp > to {
                return false;
            }
        }
        true
    }
}

#[async_trait::async_trait]
pub trait EventStore: Send + Sync {
    async fn append(&self, event: EventRecord);
    async fn query(&self, filter: EventFilter) -> Vec<EventRecord>;
}

#[derive(Debug, Default, Clone)]
pub struct InMemoryEventStore {
    inner: Arc<RwLock<Vec<EventRecord>>>,
}

#[async_trait::async_trait]
impl EventStore for InMemoryEventStore {
    async fn append(&self, event: EventRecord) {
        self.inner.write().await.push(event);
    }

    async fn query(&self, filter: EventFilter) -> Vec<EventRecord> {
        let mut out: Vec<_> = self
            .inner
            .read()
            .await
            .iter()
            .filter(|e| filter.matches(e))
            .cloned()
            .collect();
        out.sort_by_key(|e| e.timestamp);
        out
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use chrono::Duration;

    #[tokio::test]
    async fn filter_by_project_and_type() {
        let store = InMemoryEventStore::default();
        let p1 = Uuid::new_v4();
        let p2 = Uuid::new_v4();
        let now = Utc::now();

        store
            .append(EventRecord {
                id: Uuid::new_v4(),
                project_id: p1,
                task_id: None,
                session_id: None,
                trace_id: Uuid::new_v4(),
                source: EventSource::Core,
                event_type: EventType::TaskCreated,
                payload: Value::Null,
                timestamp: now,
            })
            .await;

        store
            .append(EventRecord {
                id: Uuid::new_v4(),
                project_id: p2,
                task_id: None,
                session_id: None,
                trace_id: Uuid::new_v4(),
                source: EventSource::Core,
                event_type: EventType::TaskDispatched,
                payload: Value::Null,
                timestamp: now + Duration::seconds(1),
            })
            .await;

        let records = store
            .query(EventFilter {
                project_id: Some(p1),
                event_type: Some(EventType::TaskCreated),
                ..Default::default()
            })
            .await;

        assert_eq!(records.len(), 1);
        assert_eq!(records[0].project_id, p1);
        assert_eq!(records[0].event_type, EventType::TaskCreated);
    }
}
