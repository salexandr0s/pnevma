#![forbid(unsafe_code)]

pub mod config_parser;
pub mod error;
pub mod key_manager;
pub mod profile;
pub mod remote_helper;
pub mod tailscale;

pub use config_parser::parse_ssh_config;
pub use error::SshError;
pub use key_manager::{generate_key, list_ssh_keys, SshKeyInfo};
pub use profile::{build_ssh_command, validate_profile, validate_profile_fields, SshProfile};
pub use remote_helper::{
    build_remote_attach_command, create_remote_session, ensure_remote_helper,
    read_remote_scrollback_tail, remote_helper_health, remote_session_status,
    signal_remote_session, terminate_remote_session, RemoteHelperEnsureResult, RemoteHelperHealth,
    RemoteHelperInstallKind, RemoteSessionCreateResult, RemoteSessionStatus,
};
pub use tailscale::{discover_tailscale_devices, TailscaleDevice};

/// Shell-escapes a single argument for safe inclusion in a shell command string.
/// Wraps the argument in single quotes and escapes any embedded single quotes.
pub fn shell_escape_arg(arg: &str) -> String {
    // If the argument is empty, return a pair of single quotes
    if arg.is_empty() {
        return "''".to_string();
    }
    // Replace each ' with '\'' (end quote, escaped quote, start quote)
    let escaped = arg.replace('\'', "'\\''");
    format!("'{}'", escaped)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn shell_escape_plain_arg() {
        assert_eq!(shell_escape_arg("hello"), "'hello'");
    }

    #[test]
    fn shell_escape_empty_arg() {
        assert_eq!(shell_escape_arg(""), "''");
    }

    #[test]
    fn shell_escape_embedded_single_quote() {
        assert_eq!(shell_escape_arg("it's"), "'it'\\''s'");
    }

    #[test]
    fn shell_escape_metacharacters() {
        assert_eq!(shell_escape_arg("foo; rm -rf /"), "'foo; rm -rf /'");
        assert_eq!(shell_escape_arg("$(whoami)"), "'$(whoami)'");
        assert_eq!(shell_escape_arg("a`b`c"), "'a`b`c'");
        assert_eq!(shell_escape_arg("hello world"), "'hello world'");
    }
}
