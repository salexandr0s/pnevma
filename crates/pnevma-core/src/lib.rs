#![forbid(unsafe_code)]

pub mod agent_discovery;
pub mod config;
pub mod error;
pub mod error_signatures;
pub mod events;
pub mod orchestration;
pub mod protected_actions;
pub mod stories;
pub mod task;
pub mod workflow;
pub mod workflow_contract;

pub use config::{
    global_config_path, load_global_config, load_project_config, save_global_config, GlobalConfig,
    ProjectConfig, RemoteSection, RetentionSection, SocketAuth, TlsMode, TrackerKind,
    TrackerSection, UsageProviderConfig, UsageProvidersConfig,
};
pub use error::CoreError;
pub use events::{
    EventFilter, EventRecord, EventSource, EventStore, EventType, InMemoryEventStore,
};
pub use orchestration::{DispatchOrchestrator, DispatchRequest, DispatchResult, PoolState};
pub use protected_actions::{ActionKind, ActionRiskInfo, RiskLevel};
pub use stories::StoryStatus;
pub use task::{
    Check, CheckType, ContextManifestItem, ContextPack, LeaseStatus, Priority, TaskContract,
    TaskExternalSource, TaskStatus, TransitionError,
};
pub use workflow::{
    ExecutionMode, FailurePolicy, LoopConfig, LoopMode, StageResult, WorkflowDef, WorkflowInstance,
    WorkflowStatus, WorkflowStep,
};

pub use workflow_contract::{
    AgentDefaults, RetryDefaults, TrackerSettings, VerificationHook, WorkflowDocument,
    WorkflowHooks, WorkflowMdConfig, WorkflowParseError,
};

pub type ProjectId = uuid::Uuid;
pub type TaskId = uuid::Uuid;
pub type SessionId = uuid::Uuid;
pub type TraceId = uuid::Uuid;

/// Truncate a `String` in-place to at most `max_bytes`, ensuring the result
/// ends on a valid UTF-8 character boundary. If the string is already within
/// the limit, it is left unchanged.
pub fn truncate_utf8_safe(s: &mut String, max_bytes: usize) {
    if s.len() <= max_bytes {
        return;
    }
    let truncation_point = s
        .char_indices()
        .map(|(i, _)| i)
        .take_while(|&i| i <= max_bytes)
        .last()
        .unwrap_or(0);
    s.truncate(truncation_point);
}
