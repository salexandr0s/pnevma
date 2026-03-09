mod auth_secret;
pub mod automation;
pub mod command_registry;
pub mod commands;
pub mod control;
pub mod cost_aggregation;
pub mod event_emitter;
pub mod remote_bridge;
pub mod state;

pub use control::route_method;
pub use event_emitter::{EventEmitter, NullEmitter};
pub use state::{AppState, ProjectContext, RecentProject};
