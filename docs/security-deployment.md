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

## Operational checks

- Verify file modes with `ls -l ~/.config/pnevma/remote-password`.
- Verify Keychain entries with `security find-generic-password -s com.pnevma.remote-access -a shared-password -w`.
- Issue a token, make one authenticated request, revoke the token, and verify the logs contain `subject` and `token_id` but not the raw token or password.
- Use `scripts/manual-security-tests.md` to validate remote auth, rate limits, allowlists, and password-file hardening before external rollout.
