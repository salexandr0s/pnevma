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
auto_approve = false
allow_npx = false
npx_allowed_packages = []

[agents.codex]
model = "gpt-5-codex"
token_budget = 24000
timeout_minutes = 30
auto_approve = false

[branches]
target = "main"
naming = "task/{{id}}-{{slug}}"

[automation]
socket_enabled = true
socket_path = ".pnevma/run/control.sock"
socket_auth = "same-user"
socket_rate_limit_rpm = 300
auto_dispatch = false
auto_dispatch_interval_seconds = 30
allowed_commands = ["zsh", "bash", "sh", "fish", "claude-code", "codex"]

[retention]
enabled = false
artifact_days = 30
review_days = 30
scrollback_days = 14

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
allow_session_input = false

[redaction]
extra_patterns = []
enable_entropy_guard = false

[tracker]
enabled = false
kind = "linear"
poll_interval_seconds = 120

[rules]
paths = [".pnevma/rules/*.md"]

[conventions]
paths = [".pnevma/conventions/*.md"]
```

## Sections

### `[project]`

- `name` (string, required): display name.
- `brief` (string, required): short project context shown in the app.

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
- `auto_approve` (bool, default `false`): allow the provider to skip permission prompts where the adapter supports it
- `allow_npx` (bool, default `false`): allow `npm exec` or `npx` use for auto-approved sessions where applicable
- `npx_allowed_packages` (array of strings, default `[]`): required allowlist when `allow_npx = true`

`allow_npx` and `npx_allowed_packages` are primarily relevant for provider runtimes that can invoke npm-based tooling during auto-approved execution. The configuration fails closed when package allowlisting is required.

### `[branches]`

- `target` (string, default `main`)
- `naming` (string, required): branch name template.

### `[automation]`

- `socket_enabled` (bool, default `true`)
- `socket_path` (string, default `.pnevma/run/control.sock`)
- `socket_auth` (string, `same-user` or `password`, default `same-user`)
- `socket_rate_limit_rpm` (integer, default `300`)
- `auto_dispatch` (bool, default `false`)
- `auto_dispatch_interval_seconds` (integer, default `30`)
- `allowed_commands` (array of strings): allowlist for session launch commands routed through the backend

### `[retention]`

- `enabled` (bool, default `false`): run retention cleanup automatically when a project is opened
- `artifact_days` (integer, default `30`): prune knowledge artifacts and feedback attachments older than this threshold
- `review_days` (integer, default `30`): prune review packs for terminal tasks older than this threshold
- `scrollback_days` (integer, default `14`): prune completed or failed session scrollback older than this threshold

### `[remote]`

- `enabled` (bool, default `false`): enable the HTTPS/WS remote server.
- `port` (integer, default `8443`)
- `tls_mode` (string, `tailscale` or `self-signed`, default `tailscale`)
- `token_ttl_hours` (integer, default `24`, must be greater than `0`)
- `rate_limit_rpm` (integer, default `60`, must be greater than `0`)
- `max_ws_per_ip` (integer, default `2`, must be greater than `0`)
- `serve_frontend` (bool, default `true`): serve bundled frontend assets when the remote server is configured with a static frontend directory
- `allowed_origins` (array of origin strings): must be bare `http://` or `https://` origins only, without paths, query strings, fragments, or userinfo
- `tls_allow_self_signed_fallback` (bool, default `false`): only valid when `tls_mode = "tailscale"`; intended for local fallback, not production
- `allow_session_input` (bool, default `false`): opt in to remote terminal input for live sessions

### `[redaction]`

- `extra_patterns` (array of strings, default `[]`): additional regex patterns to redact from output paths
- `enable_entropy_guard` (bool, default `false`): enable catch-all high-entropy secret detection

### `[tracker]`

- `enabled` (bool, default `false`)
- `kind` (string, currently `linear`, default `linear`)
- `team_id` (string, optional): team or workspace identifier for the tracker integration
- `labels` (array of strings, default `[]`): labels used to scope discovered work
- `poll_interval_seconds` (integer, default `120`)
- `api_key_secret` (string, optional): name of the stored secret containing tracker credentials

### `[rules]` and `[conventions]`

- `paths` (array of strings): markdown file patterns to include in context packs.

## Global config (`~/.config/pnevma/config.toml`)

User-level config currently supports:

- `default_provider` (optional string)
- `theme` (optional string)
- `telemetry_opt_in` (bool, default `false`)
- `crash_reports_opt_in` (bool, default `false`)
- `socket_auth_mode` (optional string, `same-user` or `password`)
- `socket_password_file` (optional string)
- `auto_save_workspace_on_quit` (bool, default `true`)
- `restore_windows_on_launch` (bool, default `true`)
- `auto_update` (bool, default `true`)
- `default_shell` (optional string)
- `terminal_font` (string, default `SF Mono`)
- `terminal_font_size` (integer, default `13`)
- `scrollback_lines` (integer, default `10000`)
- `sidebar_background_offset` (float, default `0.05`)
- `bottom_tool_bar_auto_hide` (bool, default `false`)
- `focus_border_enabled` (bool, default `true`)
- `focus_border_opacity` (float, default `0.4`)
- `focus_border_width` (float, default `2.0`)
- `focus_border_color` (optional string)
- `[usage_providers]` with `refresh_interval_seconds` (default `120`)
- `[usage_providers.codex]` and `[usage_providers.claude]` with `source`, `web_extras_enabled`, and `keychain_prompt_policy`
- `[keybindings]` table of action -> shortcut

## Security notes

- Remote auth password lookup order is: `PNEVMA_REMOTE_PASSWORD`, Keychain item `com.pnevma.remote-access/shared-password`, then `~/.config/pnevma/remote-password`.
- Socket password lookup order is: `PNEVMA_SOCKET_PASSWORD`, Keychain item `com.pnevma.control-plane/shared-password`, then `socket_password_file`.
- Password files must be regular files owned by the current user and not readable by group or others (`0600` or stricter on Unix).
- Leaving `remote.allowed_origins` empty keeps the server on its default localhost-compatible CORS fallback.
- `remote.allow_session_input` defaults to `false`; do not enable it unless you intentionally want remote clients to inject terminal input into live sessions.

## See also

- [Product Tour](./product-tour.md)
- [Getting Started](./getting-started.md)
- [Security Deployment Guide](./security-deployment.md)
- [Remote Access Guide](./remote-access.md)
