pub mod config;
pub mod error;
pub mod events;
pub mod orchestration;
pub mod task;

pub use config::{
    global_config_path, load_global_config, load_project_config, save_global_config, GlobalConfig,
    ProjectConfig,
};
pub use error::CoreError;
pub use events::{
    EventFilter, EventRecord, EventSource, EventStore, EventType, InMemoryEventStore,
};
pub use orchestration::{DispatchOrchestrator, DispatchRequest, DispatchResult, PoolState};
pub use task::{
    Check, CheckType, ContextManifestItem, ContextPack, Priority, TaskContract, TaskStatus,
    TransitionError,
};

pub type ProjectId = uuid::Uuid;
pub type TaskId = uuid::Uuid;
pub type SessionId = uuid::Uuid;
pub type TraceId = uuid::Uuid;
