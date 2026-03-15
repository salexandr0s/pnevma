#![forbid(unsafe_code)]

pub mod error;
pub mod hooks;
pub mod lease;
pub mod service;

pub use error::GitError;
pub use hooks::{
    parse_hook_defs, run_hooks, run_single_hook, validate_hook_binary, HookDef, HookError,
    HookPhase, HookResult,
};
pub use lease::{LeaseStatus, WorktreeLease};
pub use service::GitService;
