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
    ProjectConfig, RemoteSection, RetentionSection, TrackerSection,
};
pub use error::CoreError;
pub use events::{
    EventFilter, EventRecord, EventSource, EventStore, EventType, InMemoryEventStore,
};
pub use orchestration::{DispatchOrchestrator, DispatchRequest, DispatchResult, PoolState};
pub use protected_actions::{ActionKind, ActionRiskInfo, RiskLevel};
pub use stories::{DetectedStory, StoryDetector, StoryStatus};
pub use task::{
    Check, CheckType, ContextManifestItem, ContextPack, Priority, TaskContract, TaskExternalSource,
    TaskStatus, TransitionError,
};
pub use workflow::{
    ExecutionMode, FailurePolicy, LoopConfig, LoopMode, StageResult, WorkflowDef, WorkflowInstance,
    WorkflowStatus, WorkflowStep,
};

pub use workflow_contract::{
    AgentDefaults, RetryDefaults, TrackerSettings, WorkflowDocument, WorkflowHooks,
    WorkflowMdConfig, WorkflowParseError,
};

pub type ProjectId = uuid::Uuid;
pub type TaskId = uuid::Uuid;
pub type SessionId = uuid::Uuid;
pub type TraceId = uuid::Uuid;
