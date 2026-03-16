use crate::{ProjectId, SessionId, TaskId, TraceId};
use chrono::{DateTime, Utc};
use serde::{Deserialize, Serialize};
use serde_json::Value;
use std::collections::VecDeque;
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
    // ── Feature upgrade event types ─────────────────────────────────────────
    IntakeItemDiscovered,
    IntakeItemPromoted,
    IntakeItemRejected,
    PrCreated,
    PrStatusChanged,
    PrChecksUpdated,
    PrReviewReceived,
    PrMerged,
    PrClosed,
    CiPipelineCompleted,
    CiCheckFailed,
    DeploymentCompleted,
    FleetSnapshotCaptured,
    SessionRestoreStarted,
    SessionRestoreCompleted,
    SessionOrphaned,
    AttentionRuleTriggered,
    ReviewFileStatusChanged,
    ReviewCommentCreated,
    ReviewChecklistToggled,
    BulkActionExecuted,
    AgentHookExecuted,
    TaskForked,
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
    Intake,
    Pr,
    Ci,
    Telemetry,
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

/// Maximum number of events retained in the in-memory store.
const MAX_IN_MEMORY_EVENTS: usize = 10_000;

#[derive(Debug, Default, Clone)]
pub struct InMemoryEventStore {
    inner: Arc<RwLock<VecDeque<EventRecord>>>,
}

#[async_trait::async_trait]
impl EventStore for InMemoryEventStore {
    async fn append(&self, event: EventRecord) {
        let mut store = self.inner.write().await;
        if store.len() >= MAX_IN_MEMORY_EVENTS {
            store.pop_front();
        }
        store.push_back(event);
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
    use serde_json::json;

    fn make_event(
        project_id: Uuid,
        event_type: EventType,
        timestamp: DateTime<Utc>,
    ) -> EventRecord {
        EventRecord {
            id: Uuid::new_v4(),
            project_id,
            task_id: None,
            session_id: None,
            trace_id: Uuid::new_v4(),
            source: EventSource::Core,
            event_type,
            payload: Value::Null,
            timestamp,
        }
    }

    #[tokio::test]
    async fn filter_by_project_and_type() {
        let store = InMemoryEventStore::default();
        let p1 = Uuid::new_v4();
        let p2 = Uuid::new_v4();
        let now = Utc::now();

        store
            .append(make_event(p1, EventType::TaskCreated, now))
            .await;

        store
            .append(make_event(
                p2,
                EventType::TaskDispatched,
                now + Duration::seconds(1),
            ))
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

    // ── Serialization roundtrip ──────────────────────────────────────────────

    #[test]
    fn event_type_serde_roundtrip() {
        let variants = [
            EventType::SessionSpawned,
            EventType::TaskCreated,
            EventType::AgentOutput,
            EventType::WorkflowCompleted,
            EventType::ReviewApproved,
        ];
        for variant in variants {
            let serialized = serde_json::to_string(&variant).expect("serialize");
            let deserialized: EventType = serde_json::from_str(&serialized).expect("deserialize");
            assert_eq!(deserialized, variant);
        }
    }

    #[test]
    fn event_source_serde_roundtrip() {
        let sources = [
            EventSource::Core,
            EventSource::Session,
            EventSource::Agent,
            EventSource::Git,
            EventSource::Review,
            EventSource::System,
            EventSource::Ui,
            EventSource::Intake,
            EventSource::Pr,
            EventSource::Ci,
            EventSource::Telemetry,
        ];
        for source in sources {
            let s = serde_json::to_string(&source).expect("serialize source");
            let d: EventSource = serde_json::from_str(&s).expect("deserialize source");
            assert_eq!(d, source);
        }
    }

    #[test]
    fn event_record_serde_roundtrip() {
        let now = Utc::now();
        let pid = Uuid::new_v4();
        let record = EventRecord {
            id: Uuid::new_v4(),
            project_id: pid,
            task_id: Some(Uuid::new_v4()),
            session_id: None,
            trace_id: Uuid::new_v4(),
            source: EventSource::Agent,
            event_type: EventType::AgentToolUse,
            payload: json!({"tool": "bash", "exit_code": 0}),
            timestamp: now,
        };

        let serialized = serde_json::to_string(&record).expect("serialize record");
        let deserialized: EventRecord =
            serde_json::from_str(&serialized).expect("deserialize record");

        assert_eq!(deserialized.id, record.id);
        assert_eq!(deserialized.project_id, pid);
        assert_eq!(deserialized.event_type, EventType::AgentToolUse);
        assert_eq!(deserialized.source, EventSource::Agent);
        assert!(deserialized.task_id.is_some());
        assert!(deserialized.session_id.is_none());
    }

    // ── Filter by date range ─────────────────────────────────────────────────

    #[tokio::test]
    async fn filter_by_time_range() {
        let store = InMemoryEventStore::default();
        let pid = Uuid::new_v4();
        let base = Utc::now();

        // t=0, t=10, t=20
        store
            .append(make_event(pid, EventType::SessionSpawned, base))
            .await;
        store
            .append(make_event(
                pid,
                EventType::TaskCreated,
                base + Duration::seconds(10),
            ))
            .await;
        store
            .append(make_event(
                pid,
                EventType::TaskCompleted,
                base + Duration::seconds(20),
            ))
            .await;

        // query [t=5 .. t=15] — only the middle event
        let records = store
            .query(EventFilter {
                project_id: Some(pid),
                from: Some(base + Duration::seconds(5)),
                to: Some(base + Duration::seconds(15)),
                ..Default::default()
            })
            .await;

        assert_eq!(records.len(), 1);
        assert_eq!(records[0].event_type, EventType::TaskCreated);
    }

    #[tokio::test]
    async fn query_returns_events_sorted_by_timestamp() {
        let store = InMemoryEventStore::default();
        let pid = Uuid::new_v4();
        let base = Utc::now();

        // Insert in reverse order
        store
            .append(make_event(
                pid,
                EventType::TaskCompleted,
                base + Duration::seconds(2),
            ))
            .await;
        store
            .append(make_event(pid, EventType::TaskCreated, base))
            .await;
        store
            .append(make_event(
                pid,
                EventType::TaskDispatched,
                base + Duration::seconds(1),
            ))
            .await;

        let records = store
            .query(EventFilter {
                project_id: Some(pid),
                ..Default::default()
            })
            .await;

        assert_eq!(records.len(), 3);
        // Verify ascending order
        assert!(records[0].timestamp <= records[1].timestamp);
        assert!(records[1].timestamp <= records[2].timestamp);
    }

    // ── Append-only invariant ────────────────────────────────────────────────

    #[tokio::test]
    async fn appended_events_are_immutable_in_store() {
        let store = InMemoryEventStore::default();
        let pid = Uuid::new_v4();
        let now = Utc::now();
        let event_id = Uuid::new_v4();

        let event = EventRecord {
            id: event_id,
            project_id: pid,
            task_id: None,
            session_id: None,
            trace_id: Uuid::new_v4(),
            source: EventSource::Core,
            event_type: EventType::TaskCreated,
            payload: json!({"status": "initial"}),
            timestamp: now,
        };
        store.append(event).await;

        // Appending a second event with same ID is allowed (store is append-only, no upsert)
        let event2 = EventRecord {
            id: event_id, // same id — store does not deduplicate
            project_id: pid,
            task_id: None,
            session_id: None,
            trace_id: Uuid::new_v4(),
            source: EventSource::Core,
            event_type: EventType::TaskCreated,
            payload: json!({"status": "second"}),
            timestamp: now,
        };
        store.append(event2).await;

        let all = store
            .query(EventFilter {
                project_id: Some(pid),
                ..Default::default()
            })
            .await;
        // Append-only: both events are present
        assert_eq!(all.len(), 2);
    }

    // ── Filter by task/session ───────────────────────────────────────────────

    #[tokio::test]
    async fn filter_by_task_id() {
        let store = InMemoryEventStore::default();
        let pid = Uuid::new_v4();
        let task_id = Uuid::new_v4();
        let now = Utc::now();

        let with_task = EventRecord {
            id: Uuid::new_v4(),
            project_id: pid,
            task_id: Some(task_id),
            session_id: None,
            trace_id: Uuid::new_v4(),
            source: EventSource::Agent,
            event_type: EventType::AgentSpawned,
            payload: Value::Null,
            timestamp: now,
        };
        let without_task = make_event(pid, EventType::ProjectOpened, now);

        store.append(with_task).await;
        store.append(without_task).await;

        let results = store
            .query(EventFilter {
                project_id: Some(pid),
                task_id: Some(task_id),
                ..Default::default()
            })
            .await;

        assert_eq!(results.len(), 1);
        assert_eq!(results[0].task_id, Some(task_id));
    }

    #[tokio::test]
    async fn empty_store_returns_no_events() {
        let store = InMemoryEventStore::default();
        let pid = Uuid::new_v4();
        let results = store
            .query(EventFilter {
                project_id: Some(pid),
                ..Default::default()
            })
            .await;
        assert!(results.is_empty());
    }
}
