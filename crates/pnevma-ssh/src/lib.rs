pub mod config_parser;
pub mod error;
pub mod key_manager;
pub mod profile;
pub mod tailscale;

pub use config_parser::parse_ssh_config;
pub use error::SshError;
pub use key_manager::{generate_key, list_ssh_keys, SshKeyInfo};
pub use profile::{build_ssh_command, SshProfile};
pub use tailscale::discover_tailscale_devices;
