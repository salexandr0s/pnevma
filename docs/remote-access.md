# Remote Access Guide

Pnevma's remote access server provides an HTTPS/WebSocket interface for accessing project data and controlling sessions from other devices. This guide covers configuration for operators.

## TLS Configuration

The server supports two TLS modes:

### Tailscale mode (`tls_mode = "tailscale"`)

Uses certificates provisioned by Tailscale. The server searches for `.crt`/`.key` pairs in:
- `/var/lib/tailscale/certs/`
- `~/.local/share/tailscale/certs/`
- `/Library/Tailscale/`

If Tailscale certs are not found and `allow_self_signed_fallback = true`, falls back to self-signed.

### Self-signed mode (`tls_mode = "self-signed"`)

Generates a self-signed certificate at startup. The certificate includes `localhost` and `127.0.0.1` as SANs, plus the Tailscale IP if available.

The server returns an `X-TLS-Fingerprint: sha256:<hex>` header on every response. Clients should pin this fingerprint after first connection (TOFU model) for identity verification.

Verify with:
```bash
curl -kv https://localhost:<port>/health 2>&1 | grep X-TLS-Fingerprint
```

## CORS Configuration

Cross-Origin Resource Sharing (CORS) is enforced on all requests.

### Default behavior

By default, only `https://localhost` is allowed as an origin. Credentials (cookies, Authorization headers) are not included in CORS responses by default.

### Configuring allowed origins

In your `pnevma.toml` remote access section:

```toml
[remote]
allowed_origins = [
    "https://localhost",
    "https://your-tailscale-hostname.ts.net",
]
```

**Security implications**:
- Each origin you add can make authenticated cross-origin requests to the Pnevma API
- Only add origins you control and trust
- Wildcard (`*`) origins are not supported — each origin must be explicitly listed
- The origin check is exact-match; `https://example.com` does not match `https://sub.example.com`

### WebSocket origin validation

WebSocket upgrade requests validate the `Origin` header against the same `allowed_origins` list. Connections from unlisted origins are rejected.

## Rate Limiting

- API endpoints: configurable via `rate_limit_rpm` (default: 60 requests/minute per IP)
- Auth endpoints: fixed at 5 requests/minute per IP
- Rate limit state is cleaned up periodically to prevent unbounded memory growth

## Authentication

All API endpoints (except `/health`) require a Bearer token. Tokens are issued via `POST /api/auth/token` with the shared password.

- Tokens have a configurable TTL (default: 24 hours)
- Token revocation: `DELETE /api/auth/revoke` (requires valid bearer token)
- WebSocket connections accept the token via `?token=` query parameter (restricted to upgrade requests only)

## Log Rotation

The remote server emits structured JSON logs via the `tracing` framework. For long-running deployments, configure log rotation to prevent unbounded disk usage.

### Using system logrotate (recommended)

Create `/etc/logrotate.d/pnevma`:

```
/path/to/pnevma/logs/*.log {
    daily
    rotate 14
    compress
    delaycompress
    missingok
    notifempty
    copytruncate
}
```

### Using tracing-appender (built-in)

If the application is configured to use `tracing-appender` for file logging, daily rotation is available. Configure via `pnevma.toml`:

```toml
[logging]
directory = "~/.local/share/pnevma/logs"
rotation = "daily"
```

### Monitoring log size

For deployments without rotation configured, monitor disk usage:

```bash
du -sh ~/.local/share/pnevma/logs/
```
