# Keyboard UX Audit (Phase 5.7)

## Scope audited

- Command palette open/search/execute
- Pane focus cycling
- Pane creation actions via command palette
- Task draft/create/dispatch/review/merge actions via command palette
- Rules manager and settings access via command palette

## Default keybindings

- `command_palette.toggle`: `Mod+K`
- `command_palette.next`: `ArrowDown`
- `command_palette.prev`: `ArrowUp`
- `command_palette.execute`: `Enter`
- `pane.focus_next`: `Mod+]`
- `pane.focus_prev`: `Mod+[`
- `task.new`: `Mod+Shift+N`
- `task.dispatch_next_ready`: `Mod+Shift+D`
- `review.approve_next`: `Mod+Shift+A`

## Customization

Keybindings are user-configurable from Settings and persisted to:

- `~/.config/pnevma/config.toml`

Runtime consumers currently honoring customized bindings:

- Command palette toggle
- Command palette navigation
- Command palette execution
- Pane focus next/previous
- New task quick action
- Dispatch-next-ready quick action
- Approve-next-review quick action

## Primary-flow check

All primary actions are reachable within two keystrokes from the command palette:

1. `Mod+K`
2. Type command label (or a short prefix) + `Enter`

## Remaining audit follow-up

- Add keyboard-accessible command palette selection index indicator for screen-reader parity.
