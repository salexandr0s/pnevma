pub mod coordinator;
pub mod runner;
pub mod workflow_store;

use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub enum DispatchOrigin {
    Manual,
    AutoDispatch,
    Workflow,
}
