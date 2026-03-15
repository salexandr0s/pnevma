#![forbid(unsafe_code)]

pub mod adapter;
pub mod error;
pub mod linear;
pub mod poll;
pub mod types;

pub use adapter::TrackerAdapter;
pub use error::TrackerError;
pub use types::{ExternalState, StateTransition, TrackerFilter, TrackerItem};
