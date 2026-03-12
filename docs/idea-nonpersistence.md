# Optional Workspace Session Persistence

## Summary

Add a per-workspace terminal mode so manual workspace terminals can run either:

- `Persistent` (current behavior): backend-managed, tmux-backed, replay/recovery capable
- `Non-persistent`: plain local Ghostty shell rooted in the workspace project, with no tmux session, no backend session row, and no terminal replay/recovery

The choice is made every time the user manually opens a workspace. The open flow becomes a single `Open Workspace` panel with:

- directory picker
- checkbox: `Enable session persistence`
- short helper text explaining the tradeoff

This is an adaptive-terminal feature, not a full workspace architecture split. Project tools such as Files, Search, Diff, Task Board, Review, Merge Queue, and project metadata continue to work because they depend on the open project context, not on tmux.

## Implementation Changes

### 1. Workspace open flow

- Change `native/Pnevma/App/AppDelegate.swift` `openProject()` from a plain `NSOpenPanel` into an `NSOpenPanel` with an accessory view.
- Use `panel.prompt = "Open Workspace"` and add:
  - checkbox, default `checked`, labeled `Enable session persistence`
  - helper copy:
    - checked: terminal can be restored/replayed and is backend-managed
    - unchecked: terminal is local-only and resets when closed or app quits
- Pass the selected mode into workspace creation:
  - `workspaceManager.createWorkspace(name:projectPath:terminalMode:)`

### 2. Workspace state and persistence

- Extend `native/Pnevma/Core/Workspace.swift` with a workspace-level enum:
  - `WorkspaceTerminalMode.persistent`
  - `WorkspaceTerminalMode.nonPersistent`
- Persist this on `Workspace` and `Workspace.Snapshot`.
- Backward compatibility:
  - if an older snapshot has no mode, default to `.persistent`
- All newly created terminal panes in a workspace inherit the workspace's mode.
- Keep the existing app/window/workspace restore system unchanged apart from serializing the new field.

### 3. Terminal pane launch policy

- Extend `native/Pnevma/Panes/PaneProtocol.swift` terminal creation APIs to carry launch intent:
  - `TerminalLaunchMode.managedSession`
  - `TerminalLaunchMode.localEphemeral`
  - `TerminalAutoStartBehavior.immediate`
  - `TerminalAutoStartBehavior.deferUntilActivate`
- Encode terminal-specific mode in `PersistedPane.metadataJSON` via a typed payload, for example:
  - `launchMode`
  - `deferredStart`
- Update all terminal creation call sites to pass workspace mode:
  - initial seeded terminal after `project.open`
  - `New Terminal`
  - `New Tab`
  - `openToolPane("terminal")`
  - root-pane reconstruction for active workspace

### 4. Managed vs local terminal behavior

- Keep current persistent behavior unchanged:
  - `TerminalPaneView` calls `SessionBridge.createSession`
  - Rust `session.new` continues to create tmux-backed sessions
- For non-persistent mode:
  - `TerminalPaneView` must bypass `SessionBridge.createSession`
  - create a plain local Ghostty shell using the workspace `projectPath` as `workingDirectory`
  - do not assign `sessionID`
  - do not create backend session rows, scrollback, replay, or recovery actions
- Reuse the existing local-shell path already present in `TerminalPaneView`, but make it an intentional project-scoped mode rather than only a "no project open" fallback.
- Closing a non-persistent terminal should behave like any local shell today: closing the process closes the pane surface; re-opening the pane starts a fresh shell.

### 5. Restore behavior for non-persistent workspaces

- Preserve the user's workspace, tabs, and layout on app relaunch.
- For non-persistent terminal panes restored from snapshot:
  - restore the pane shell state as `not running`
  - do not auto-start a local shell during app launch
  - start a fresh local shell when the pane first becomes active or when the user explicitly opens a new terminal
- Use a distinct idle state message for restored non-persistent panes, for example:
  - `Local terminal will start when this pane is activated.`
- Persistent workspaces keep current restore behavior.

### 6. Session-aware UI adaptation

- Do not change unrelated project tools.
- Adapt only session-oriented surfaces so they are not misleading for local terminals:
  - terminal pane loading text must say `Local terminal` / `Not persisted`
  - recovery actions must never appear for local terminals
  - replay must not suggest local terminals are replayable
  - session manager continues to list only backend-managed sessions; local terminals simply do not appear there
- Add a lightweight workspace-level visual indicator in the sidebar row or workspace header:
  - `Persistent` or `Local`
- This prevents confusion after the workspace is opened.

### 7. Rust/backend scope

- No RPC contract change is required for v1.
- No change to `project.open`, `session.new`, or `SessionSupervisor` semantics.
- Agent/task runs remain unchanged in v1:
  - they continue to use the existing adapter/event pipeline
  - they may still appear as managed sessions where that pipeline already does so
- This keeps the feature isolated to manual workspace terminal behavior and UI state.

## Important Interfaces and Types

- Add Swift enum: `WorkspaceTerminalMode`
- Add Swift enum: `TerminalLaunchMode`
- Add Swift enum: `TerminalAutoStartBehavior`
- Extend `WorkspaceManager.createWorkspace` to accept `terminalMode`
- Extend `Workspace.Snapshot` with `terminalMode`
- Add typed terminal metadata payload stored in `PersistedPane.metadataJSON`
- No external CLI, RPC, or API changes in v1

## Test Plan

### Swift unit and integration coverage

- Opening a workspace with persistence checked creates a persistent workspace and the first terminal goes through managed-session startup.
- Opening a workspace with persistence unchecked creates a non-persistent workspace and the first terminal starts as a local shell in the project directory.
- `New Terminal`, `New Tab`, and command-palette terminal creation inherit the active workspace mode.
- Restoring an old snapshot with no `terminalMode` defaults to persistent and does not break restore.
- Restoring a non-persistent workspace restores layout but does not auto-launch a shell until activation.
- Switching between persistent and non-persistent workspaces does not leak launch mode across panes.
- Terminal pane serialization and deserialization preserve launch mode and deferred-start state.

### UI behavior checks

- Sidebar or header shows the correct mode label after open and after restore.
- Non-persistent panes never show `Connecting to backend terminal session`.
- Non-persistent panes never expose replay or recovery affordances.
- Session manager shows backend sessions only; opening local terminals does not create phantom entries.

### Regression checks

- Files, Search, Diff, Task Board, Review, Merge Queue, and Notifications work identically in a non-persistent workspace.
- Agent dispatch still functions inside a non-persistent workspace and continues to create the expected agent session and review state.
- App quit warning still appears if a non-persistent local shell is running.

## Assumptions and Defaults

- Default checkbox state is `checked` to preserve current behavior.
- The choice is asked on every manual workspace open; no global default and no per-project memory in v1.
- Non-persistent mode applies only to manual workspace terminals and their session-related UI, not to the whole backend or project architecture.
- Restored non-persistent panes defer shell creation until first activation.
- No Rust changes are needed unless a later phase wants agent and task sessions to also honor workspace terminal mode.
