pub mod adapters;
pub mod env;
pub mod error;
pub mod model;
pub mod pool;
pub mod profiles;
pub mod registry;

pub use env::{
    build_agent_environment, is_blocked_agent_env_name, is_reserved_agent_env_name,
    validate_agent_env_entry, validate_agent_env_name, MAX_AGENT_ENV_NAME_BYTES,
    MAX_AGENT_ENV_VALUE_BYTES,
};
pub use error::AgentError;
pub use model::{
    AgentAdapter, AgentConfig, AgentEvent, AgentHandle, AgentStatus, CostRecord, TaskPayload,
};
pub use pool::{DispatchPermit, DispatchPool, QueuedDispatch};
pub use profiles::{AgentProfile, DispatchRecommendation};
pub use registry::AdapterRegistry;
