pub mod config;
pub mod error;
pub mod error_signatures;
pub mod events;
pub mod orchestration;
pub mod protected_actions;
pub mod stories;
pub mod task;
pub mod workflow;

pub use config::{
    global_config_path, load_global_config, load_project_config, save_global_config, GlobalConfig,
    ProjectConfig, RemoteSection,
};
pub use error::CoreError;
pub use events::{
    EventFilter, EventRecord, EventSource, EventStore, EventType, InMemoryEventStore,
};
pub use orchestration::{DispatchOrchestrator, DispatchRequest, DispatchResult, PoolState};
pub use protected_actions::{ActionKind, ActionRiskInfo, RiskLevel};
pub use stories::{DetectedStory, StoryDetector, StoryStatus};
pub use task::{
    Check, CheckType, ContextManifestItem, ContextPack, Priority, TaskContract, TaskStatus,
    TransitionError,
};
pub use workflow::{
    FailurePolicy, StageResult, WorkflowDef, WorkflowInstance, WorkflowStatus, WorkflowStep,
};

pub type ProjectId = uuid::Uuid;
pub type TaskId = uuid::Uuid;
pub type SessionId = uuid::Uuid;
pub type TraceId = uuid::Uuid;
