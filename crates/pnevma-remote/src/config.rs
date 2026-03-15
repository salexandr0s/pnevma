use serde::{Deserialize, Serialize};

fn default_port() -> u16 {
    8443
}

fn default_tls_mode() -> String {
    "tailscale".to_string()
}

fn default_token_ttl() -> u64 {
    24
}

fn default_rate_limit() -> u32 {
    60
}

fn default_max_ws() -> usize {
    2
}

fn default_serve_frontend() -> bool {
    true
}

fn default_hsts_max_age() -> u64 {
    86400
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct RemoteAccessConfig {
    #[serde(default)]
    pub enabled: bool,
    #[serde(default = "default_port")]
    pub port: u16,
    #[serde(default = "default_tls_mode")]
    pub tls_mode: String,
    #[serde(default = "default_token_ttl")]
    pub token_ttl_hours: u64,
    #[serde(default = "default_rate_limit")]
    pub rate_limit_rpm: u32,
    #[serde(default = "default_max_ws")]
    pub max_ws_per_ip: usize,
    #[serde(default = "default_serve_frontend")]
    pub serve_frontend: bool,
    #[serde(default = "default_hsts_max_age")]
    pub hsts_max_age: u64,
    #[serde(default)]
    pub allowed_origins: Vec<String>,
    #[serde(default)]
    pub tls_allow_self_signed_fallback: bool,
    #[serde(default)]
    pub allow_session_input: bool,
}

impl Default for RemoteAccessConfig {
    fn default() -> Self {
        Self {
            enabled: false,
            port: default_port(),
            tls_mode: default_tls_mode(),
            token_ttl_hours: default_token_ttl(),
            rate_limit_rpm: default_rate_limit(),
            max_ws_per_ip: default_max_ws(),
            serve_frontend: default_serve_frontend(),
            hsts_max_age: default_hsts_max_age(),
            allowed_origins: vec![],
            tls_allow_self_signed_fallback: false,
            allow_session_input: false,
        }
    }
}
