# Security Deployment Guide

This guide covers the supported deployment posture for Pnevma's remote server and local control plane.

## Supported production posture

- Remote access is intended to stay Tailscale-reachable.
- `pnevma-remote` binds to the machine's Tailscale IP; test and document it with that address or a Tailscale MagicDNS name, not `localhost`.
- `remote.tls_mode = "tailscale"` is the production default.
- `remote.tls_allow_self_signed_fallback = true` is a development fallback only.
- Local automation should prefer `same-user` socket auth unless password mode is explicitly needed.
- Passwords should come from the environment or Keychain before plaintext files.
- Shared-password remote auth is intended for a single operator or a tightly controlled admin group, not broad multi-user access.
- Worktrees isolate git state only. Agent processes still run with the current user's filesystem and network privileges.

## Password source precedence

### Remote access

Lookup order:

1. `PNEVMA_REMOTE_PASSWORD`
2. Keychain item:
   - service: `com.pnevma.remote-access`
   - account: `shared-password`
3. `~/.config/pnevma/remote-password`

### Local control plane

Lookup order:

1. `PNEVMA_SOCKET_PASSWORD`
2. Keychain item:
   - service: `com.pnevma.control-plane`
   - account: `shared-password`
3. `socket_password_file` from `~/.config/pnevma/config.toml`

## Keychain setup

Store the remote password:

```bash
security add-generic-password \
  -U \
  -a "shared-password" \
  -s "com.pnevma.remote-access" \
  -w "replace-with-strong-password"
```

Store the control-plane password:

```bash
security add-generic-password \
  -U \
  -a "shared-password" \
  -s "com.pnevma.control-plane" \
  -w "replace-with-strong-password"
```

## Password-file rules

If you use a password file instead of Keychain:

- it must be a regular file,
- it must not be a symlink,
- it must be owned by the current user,
- it must not be readable by group or others (`0600` or stricter on Unix).

Example:

```bash
mkdir -p "$HOME/.config/pnevma"
printf 'replace-with-strong-password\n' > "$HOME/.config/pnevma/remote-password"
chmod 0600 "$HOME/.config/pnevma/remote-password"
```

## Recommended project config

```toml
[automation]
socket_enabled = true
socket_path = ".pnevma/run/control.sock"
socket_auth = "same-user"

[remote]
enabled = true
port = 8443
tls_mode = "tailscale"
token_ttl_hours = 24
rate_limit_rpm = 60
max_ws_per_ip = 2
allowed_origins = ["https://<tailscale-hostname-or-ip>"]
tls_allow_self_signed_fallback = false
```

## Recommended global config for password socket mode

```toml
socket_auth_mode = "password"
socket_password_file = "/Users/you/.config/pnevma/control-password"
```

If `socket_auth_mode = "password"`, set the password through `PNEVMA_SOCKET_PASSWORD` or the Keychain item first. Use `socket_password_file` only if you must keep a file-based secret.

## Remote audit attribution

- Successful remote token issuance, authenticated requests, WebSocket upgrades, and token revocations now log a `subject` and safe `token_id`.
- The default subject is `shared-password` unless stronger operator identity is wired in front of the remote server.
- Raw passwords and raw bearer tokens must never appear in audit logs.
- Treat this as correlation and accountability aid, not full per-user identity.

## Validation rules

Pnevma now fails startup when:

- `remote.tls_mode` is not `tailscale` or `self-signed`,
- `remote.token_ttl_hours`, `remote.rate_limit_rpm`, or `remote.max_ws_per_ip` are `0`,
- `remote.tls_allow_self_signed_fallback = true` is paired with `tls_mode = "self-signed"`,
- `remote.allowed_origins` contains paths, query strings, fragments, or malformed origins,
- password-file ownership or permissions are unsafe.

## Local control plane abuse controls

- **Per-UID auth failure tracking**: after 5 failed auth attempts within 60 seconds from the same peer UID, an `AutomationAuthThresholdExceeded` event is written to the project database. A `tracing::warn!` log entry fires at the same threshold. The tracker fires exactly once per window to avoid log flooding.
- **Audit payload enrichment**: all `Automation*` database audit events now include `peer_uid` (the Unix peer credential UID) and `auth_mode` (`same-user` or `password`) in their JSON payload. No schema migration is needed — `payload_json` is a free-form JSON column.
- **Per-UID rate limiting**: `socket_rate_limit_rpm` applies independently per peer UID (sliding window). Requests beyond the limit receive a `rate_limited` error response.
- **Debug redaction**: `ControlAuthMode::Password` uses a manual `Debug` impl that prints `[REDACTED]` instead of the raw password. This prevents accidental password leakage in debug logs or panic messages.
- See manual tests in `docs/manual-security-tests.md` section **G5c** for verification procedures.

## Operational checks

- Verify file modes with `ls -l ~/.config/pnevma/remote-password`.
- Verify Keychain entries with `security find-generic-password -s com.pnevma.remote-access -a shared-password -w`.
- Issue a token, make one authenticated request, revoke the token, and verify the logs contain `subject` and `token_id` but not the raw token or password.
- Use `docs/manual-security-tests.md` to validate remote auth, rate limits, allowlists, and password-file hardening before external rollout.

## Security defaults

The following defaults are enforced by `RemoteAccessConfig::default()` and verified by the `default_config_security_posture` unit test:

- `enabled = false` — remote access is opt-in
- `tls_mode = "tailscale"` — production-grade TLS by default
- `tls_allow_self_signed_fallback = false` — no development fallback unless explicitly enabled
- `allow_session_input = false` — remote terminal input is opt-in only

## Session input posture

Remote session input (`SessionInput` over WebSocket) is gated by three independent checks:

1. **Config gate** — `allow_session_input` must be `true` (default: `false`)
2. **Subscription gate** — the client must be subscribed to the target session channel
3. **RBAC gate** — the client's token must have the `Operator` role

A `ReadOnly` token holder cannot send session input even if the config allows it and the client is subscribed. The RPC path (`session.send_input` via `WsClientMessage::Rpc`) has always required `Operator`; the `SessionInput` shortcut message now matches.

## Entitlements

### `disable-library-validation`

The `com.apple.security.cs.disable-library-validation` entitlement is required because Pnevma loads GhosttyKit as an xcframework at runtime. Without this entitlement, macOS rejects the unsigned dynamic library load. Ghostty's own macOS application retains the same entitlement for the same reason.

**Compensating control:** `scripts/check-entitlements.sh` runs in CI on every build and fails if any entitlement is added beyond the approved set. This prevents entitlement creep while retaining the one exception needed for Ghostty integration.

## See also

- [`pnevma.toml` Reference](./pnevma-toml-reference.md)
- [Remote Access Guide](./remote-access.md)
- [macOS Release Runbook](./macos-release.md)
