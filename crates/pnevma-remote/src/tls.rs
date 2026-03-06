use rcgen::generate_simple_self_signed;
use rustls::ServerConfig;
use std::{net::IpAddr, sync::Once};
use tokio_rustls::rustls::pki_types::{CertificateDer, PrivateKeyDer, PrivatePkcs8KeyDer};

use crate::error::RemoteError;

static INSTALL_RUSTLS_PROVIDER: Once = Once::new();

/// Load TLS config according to `mode`.
///
/// `tailscale_ip` is forwarded to `generate_self_signed_cert` so the cert
/// includes the Tailscale IP as a Subject Alternative Name.
pub async fn load_tls_config(
    mode: &str,
    tailscale_ip: Option<IpAddr>,
    allow_self_signed_fallback: bool,
) -> Result<ServerConfig, RemoteError> {
    ensure_rustls_crypto_provider();

    match mode {
        "tailscale" => load_tailscale_cert(tailscale_ip, allow_self_signed_fallback).await,
        "self-signed" => generate_self_signed_cert(tailscale_ip),
        other => Err(RemoteError::Tls(format!("Unknown TLS mode: {other}"))),
    }
}

fn ensure_rustls_crypto_provider() {
    INSTALL_RUSTLS_PROVIDER.call_once(|| {
        let _ = rustls::crypto::aws_lc_rs::default_provider().install_default();
    });
}

async fn load_tailscale_cert(
    tailscale_ip: Option<IpAddr>,
    allow_self_signed_fallback: bool,
) -> Result<ServerConfig, RemoteError> {
    // Tailscale stores certs in /var/lib/tailscale/certs/ or ~/.local/share/tailscale/certs/
    let candidates = [
        "/var/lib/tailscale/certs".to_string(),
        format!(
            "{}/.local/share/tailscale/certs",
            std::env::var("HOME").unwrap_or_default()
        ),
        "/Library/Tailscale".to_string(),
    ];

    for dir in &candidates {
        let path = std::path::Path::new(dir);
        if !path.exists() {
            continue;
        }
        // Look for .crt and .key files
        let mut cert_path = None;
        let mut key_path = None;
        if let Ok(entries) = std::fs::read_dir(path) {
            for entry in entries.flatten() {
                let name = entry.file_name();
                let name = name.to_string_lossy();
                if name.ends_with(".crt") {
                    cert_path = Some(entry.path());
                } else if name.ends_with(".key") {
                    key_path = Some(entry.path());
                }
            }
        }
        if let (Some(cert_path), Some(key_path)) = (cert_path, key_path) {
            let cert_pem = tokio::fs::read(&cert_path).await.map_err(|e| {
                RemoteError::Tls(format!("Failed to read cert {}: {e}", cert_path.display()))
            })?;
            let key_pem = tokio::fs::read(&key_path).await.map_err(|e| {
                RemoteError::Tls(format!("Failed to read key {}: {e}", key_path.display()))
            })?;
            return build_rustls_config_from_pem(&cert_pem, &key_pem);
        }
    }

    // Fall back to self-signed if tailscale certs not found
    if allow_self_signed_fallback {
        tracing::error!("Tailscale certs not found — falling back to self-signed certificate");
        generate_self_signed_cert(tailscale_ip)
    } else {
        tracing::error!("Tailscale certs not found and self-signed fallback is disabled");
        Err(RemoteError::Tls(
            "Tailscale TLS certificates not found and self-signed fallback is disabled".to_string(),
        ))
    }
}

fn build_rustls_config_from_pem(
    cert_pem: &[u8],
    key_pem: &[u8],
) -> Result<ServerConfig, RemoteError> {
    use rustls_pki_types::pem::PemObject;

    let certs: Vec<CertificateDer<'static>> = CertificateDer::pem_slice_iter(cert_pem)
        .collect::<Result<Vec<_>, _>>()
        .map_err(|e| RemoteError::Tls(format!("Failed to parse certs: {e}")))?;

    let key = PrivateKeyDer::from_pem_slice(key_pem)
        .map_err(|e| RemoteError::Tls(format!("Failed to parse key: {e}")))?;

    build_server_config(certs, key)
}

fn generate_self_signed_cert(tailscale_ip: Option<IpAddr>) -> Result<ServerConfig, RemoteError> {
    let mut subject_alt_names = vec!["localhost".to_string(), "127.0.0.1".to_string()];
    if let Some(ip) = tailscale_ip {
        subject_alt_names.push(ip.to_string());
    }

    let cert = generate_simple_self_signed(subject_alt_names)
        .map_err(|e| RemoteError::Tls(format!("rcgen error: {e}")))?;

    let cert_der = CertificateDer::from(cert.cert.der().to_vec());
    let key_der = PrivateKeyDer::Pkcs8(PrivatePkcs8KeyDer::from(cert.key_pair.serialize_der()));

    {
        use sha2::{Digest, Sha256};
        let fingerprint = hex::encode(Sha256::digest(cert_der.as_ref()));
        tracing::info!(fingerprint = %fingerprint, "Generated self-signed TLS certificate");
    }

    build_server_config(vec![cert_der], key_der)
}

fn build_server_config(
    certs: Vec<CertificateDer<'static>>,
    key: PrivateKeyDer<'static>,
) -> Result<ServerConfig, RemoteError> {
    ensure_rustls_crypto_provider();

    ServerConfig::builder()
        .with_no_client_auth()
        .with_single_cert(certs, key)
        .map_err(|e| RemoteError::Tls(format!("rustls config error: {e}")))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn self_signed_tls_config_builds_without_preinstalled_provider() {
        let _config = generate_self_signed_cert(None).expect("self-signed TLS config should build");
    }
}
