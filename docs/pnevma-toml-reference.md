# `pnevma.toml` Reference

Project config lives at `<project>/pnevma.toml`.

## Example

```toml
[project]
name = "Pnevma"
brief = "Terminal-first execution workspace"

[agents]
default_provider = "claude-code"
max_concurrent = 4

[agents.claude-code]
model = "sonnet"
token_budget = 24000
timeout_minutes = 30

[agents.codex]
model = "gpt-5-codex"
token_budget = 24000
timeout_minutes = 30

[branches]
target = "main"
naming = "task/{{id}}-{{slug}}"

[retention]
enabled = false
artifact_days = 30
review_days = 30
scrollback_days = 14

[automation]
socket_enabled = true
socket_path = ".pnevma/run/control.sock"
socket_auth = "same-user"
auto_dispatch = false
auto_dispatch_interval_seconds = 30
allowed_commands = ["zsh", "bash", "sh", "fish", "claude-code", "codex"]

[remote]
enabled = false
port = 8443
tls_mode = "tailscale"
token_ttl_hours = 24
rate_limit_rpm = 60
max_ws_per_ip = 2
serve_frontend = true
allowed_origins = []
tls_allow_self_signed_fallback = false

[rules]
paths = [".pnevma/rules/*.md"]

[conventions]
paths = [".pnevma/conventions/*.md"]
```

## Sections

### `[project]`

- `name` (string, required): display name.
- `brief` (string, required): short project context shown in app.

### `[agents]`

- `default_provider` (string, required): provider ID used by default.
- `max_concurrent` (integer, default `4`): max concurrent agent sessions.

Optional provider-specific sections:

- `[agents.claude-code]`
- `[agents.codex]`

Each supports:

- `model` (string, optional)
- `token_budget` (integer, required if section present)
- `timeout_minutes` (integer, required if section present)

### `[branches]`

- `target` (string, default `main`)
- `naming` (string, required): branch name template.

### `[retention]`

- `enabled` (bool, default `false`): run retention cleanup automatically when a project is opened
- `artifact_days` (integer, default `30`): prune knowledge artifacts and feedback attachments older than this threshold
- `review_days` (integer, default `30`): prune review packs for terminal tasks older than this threshold
- `scrollback_days` (integer, default `14`): prune completed/failed session scrollback older than this threshold

### `[automation]`

- `socket_enabled` (bool, default `true`)
- `socket_path` (string, default `.pnevma/run/control.sock`)
- `socket_auth` (string, `same-user` or `password`, default `same-user`)
- `auto_dispatch` (bool, default `false`)
- `auto_dispatch_interval_seconds` (integer, default `30`)
- `allowed_commands` (array of strings): allowlist for session launch commands routed through the backend

### `[remote]`

- `enabled` (bool, default `false`): enable the HTTPS/WS remote server.
- `port` (integer, default `8443`)
- `tls_mode` (string, `tailscale` or `self-signed`, default `tailscale`)
- `token_ttl_hours` (integer, default `24`, must be greater than `0`)
- `rate_limit_rpm` (integer, default `60`, must be greater than `0`)
- `max_ws_per_ip` (integer, default `2`, must be greater than `0`)
- `serve_frontend` (bool, default `true`)
- `allowed_origins` (array of origin strings): must be bare `http://` or `https://` origins only, without paths, query strings, fragments, or userinfo
- `tls_allow_self_signed_fallback` (bool, default `false`): only valid when `tls_mode = "tailscale"`; intended for local fallback, not production

### `[rules]` and `[conventions]`

- `paths` (array of strings): markdown file patterns to include in context packs.

## Global config (`~/.config/pnevma/config.toml`)

User-level config currently supports:

- `default_provider` (optional string)
- `theme` (optional string)
- `telemetry_opt_in` (bool, default `false`)
- `socket_auth_mode` (optional string, `same-user` or `password`)
- `socket_password_file` (optional string)
- `[keybindings]` table of action -> shortcut

## Security notes

- Remote auth password lookup order is: `PNEVMA_REMOTE_PASSWORD`, Keychain item `com.pnevma.remote-access/shared-password`, then `~/.config/pnevma/remote-password`.
- Socket password lookup order is: `PNEVMA_SOCKET_PASSWORD`, Keychain item `com.pnevma.control-plane/shared-password`, then `socket_password_file`.
- Password files must be regular files owned by the current user and not readable by group or others (`0600` or stricter on Unix).
- Leaving `remote.allowed_origins` empty keeps the server on its default localhost-compatible CORS fallback.
