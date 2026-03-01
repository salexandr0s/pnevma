pub mod adapters;
pub mod error;
pub mod model;
pub mod pool;
pub mod registry;

pub use error::AgentError;
pub use model::{
    AgentAdapter, AgentConfig, AgentEvent, AgentHandle, AgentStatus, CostRecord, TaskPayload,
};
pub use pool::{DispatchPermit, DispatchPool, QueuedDispatch};
pub use registry::AdapterRegistry;
