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

[automation]
socket_enabled = true
socket_path = ".pnevma/run/control.sock"
socket_auth = "same-user"

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

### `[automation]`

- `socket_enabled` (bool, default `true`)
- `socket_path` (string, default `.pnevma/run/control.sock`)
- `socket_auth` (string, `same-user` or `password`, default `same-user`)

### `[rules]` and `[conventions]`

- `paths` (array of strings): markdown file patterns to include in context packs.

## Global config (`~/.config/pnevma/config.toml`)

User-level config currently supports:

- `default_provider` (optional string)
- `theme` (optional string)
- `telemetry_opt_in` (bool, default `false`)
- `socket_auth_mode` (optional string)
- `socket_password_file` (optional string)
- `[keybindings]` table of action -> shortcut
