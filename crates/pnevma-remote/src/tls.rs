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
///
/// Returns the `ServerConfig` and an optional hex-encoded SHA256 fingerprint.
/// The fingerprint is `Some` only for self-signed certificates; real certificates
/// (e.g. from Tailscale) return `None`.
pub async fn load_tls_config(
    mode: &str,
    tailscale_ip: Option<IpAddr>,
    allow_self_signed_fallback: bool,
) -> Result<(ServerConfig, Option<String>), RemoteError> {
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
) -> Result<(ServerConfig, Option<String>), RemoteError> {
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
        if !tokio::fs::try_exists(path).await.unwrap_or(false) {
            continue;
        }
        // Match .crt and .key files by base name to avoid pairing unrelated certs
        let mut cert_path = None;
        let mut key_path = None;
        // std::fs::read_dir is intentionally kept sync here — converting directory
        // iteration to async is complex and this runs once at startup with a small,
        // bounded directory.
        if let Ok(entries) = std::fs::read_dir(path) {
            for entry in entries.flatten() {
                let name = entry.file_name();
                let name_str = name.to_string_lossy();
                if name_str.ends_with(".crt") {
                    let stem = name_str.trim_end_matches(".crt");
                    let key_candidate = entry.path().with_file_name(format!("{stem}.key"));
                    if tokio::fs::try_exists(&key_candidate).await.unwrap_or(false) {
                        cert_path = Some(entry.path());
                        key_path = Some(key_candidate);
                        break;
                    }
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
            return build_rustls_config_from_pem(&cert_pem, &key_pem).map(|config| (config, None));
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

fn generate_self_signed_cert(
    tailscale_ip: Option<IpAddr>,
) -> Result<(ServerConfig, Option<String>), RemoteError> {
    let mut subject_alt_names = vec!["localhost".to_string(), "127.0.0.1".to_string()];
    if let Some(ip) = tailscale_ip {
        subject_alt_names.push(ip.to_string());
    }

    let cert = generate_simple_self_signed(subject_alt_names)
        .map_err(|e| RemoteError::Tls(format!("rcgen error: {e}")))?;

    let cert_der = CertificateDer::from(cert.cert.der().to_vec());
    let key_der = PrivateKeyDer::Pkcs8(PrivatePkcs8KeyDer::from(cert.key_pair.serialize_der()));

    let fingerprint = {
        use sha2::{Digest, Sha256};
        hex::encode(Sha256::digest(cert_der.as_ref()))
    };
    tracing::info!(fingerprint = %fingerprint, "Generated self-signed TLS certificate");

    let config = build_server_config(vec![cert_der], key_der)?;
    Ok((config, Some(fingerprint)))
}

fn build_server_config(
    certs: Vec<CertificateDer<'static>>,
    key: PrivateKeyDer<'static>,
) -> Result<ServerConfig, RemoteError> {
    ensure_rustls_crypto_provider();

    ServerConfig::builder_with_protocol_versions(&[&rustls::version::TLS13])
        .with_no_client_auth()
        .with_single_cert(certs, key)
        .map_err(|e| RemoteError::Tls(format!("rustls config error: {e}")))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn self_signed_tls_config_builds_without_preinstalled_provider() {
        let (_config, _fp) =
            generate_self_signed_cert(None).expect("self-signed TLS config should build");
    }

    #[test]
    fn self_signed_returns_fingerprint() {
        let (_config, fingerprint) =
            generate_self_signed_cert(None).expect("self-signed TLS config should build");
        let fp = fingerprint.expect("self-signed should return a fingerprint");
        assert_eq!(fp.len(), 64, "SHA256 fingerprint should be 64 hex chars");
        assert!(
            fp.chars().all(|c| c.is_ascii_hexdigit()),
            "fingerprint should be hex"
        );
    }

    #[test]
    fn self_signed_includes_localhost_san() {
        // generate_simple_self_signed embeds SANs in the DER certificate.
        // Verify "localhost" and "127.0.0.1" appear in the raw DER bytes.
        let subject_alt_names = vec!["localhost".to_string(), "127.0.0.1".to_string()];
        let cert =
            generate_simple_self_signed(subject_alt_names).expect("rcgen should generate cert");
        let der = cert.cert.der().as_ref();
        assert!(
            der.windows(b"localhost".len()).any(|w| w == b"localhost"),
            "cert DER should contain 'localhost' SAN"
        );
        // IPv4 127.0.0.1 is encoded as 4 raw bytes in SAN IPAddress: [127, 0, 0, 1]
        assert!(
            der.windows(4).any(|w| w == [127, 0, 0, 1]),
            "cert DER should contain 127.0.0.1 SAN as raw IP bytes"
        );
    }

    #[test]
    fn self_signed_includes_tailscale_ip_san() {
        let ip: IpAddr = "100.64.0.1".parse().unwrap();
        let mut subject_alt_names = vec!["localhost".to_string(), "127.0.0.1".to_string()];
        subject_alt_names.push(ip.to_string());
        let cert = generate_simple_self_signed(subject_alt_names)
            .expect("rcgen should generate cert with tailscale IP");
        let der = cert.cert.der().as_ref();
        // 100.64.0.1 encoded as raw bytes: [100, 64, 0, 1]
        assert!(
            der.windows(4).any(|w| w == [100, 64, 0, 1]),
            "cert DER should contain 100.64.0.1 SAN as raw IP bytes"
        );
    }

    #[test]
    fn self_signed_without_tailscale_ip() {
        let (_config, fp) =
            generate_self_signed_cert(None).expect("should build without tailscale IP");
        assert!(fp.is_some());
    }

    #[test]
    fn crypto_provider_install_is_idempotent() {
        ensure_rustls_crypto_provider();
        ensure_rustls_crypto_provider();
        // No panic = success
    }

    #[test]
    fn build_rustls_config_from_pem_rejects_invalid_cert() {
        ensure_rustls_crypto_provider();
        let result = build_rustls_config_from_pem(b"not a valid pem", b"not a key");
        assert!(result.is_err());
    }
}
