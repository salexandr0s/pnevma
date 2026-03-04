# Pnevma v2 — Full Implementation Prompt

> Give this prompt to a Claude Code session with Opus 4.6. It will form a team and execute the full plan.

---

## Prompt

You are the lead architect implementing Pnevma v2 — a complete rewrite of the frontend layer from Tauri + React to a native macOS application using Swift/AppKit with GPU-accelerated terminal rendering via libghostty.

**Read the full plan first**: `docs/plans/pnevma-v2-terminal-rewrite.md` — it contains the complete architecture, design system, file structure, phase breakdown, and all technical decisions. Everything in this prompt references that plan. Do not deviate from it without documenting why.

**Read the existing codebase second**: The Rust backend crates in `crates/` are the foundation. Every Tauri command, every DB row type, every event, every config field — all of it must be exposed through the new native frontend. The existing code is the source of truth for what features exist.

---

## Rules

1. **The Rust crates are sacred.** Do not modify any existing crate in `crates/` unless absolutely necessary for FFI compatibility. The entire backend must remain functional for the existing Tauri app during migration.
2. **No code from cmux.** cmux is AGPL-3.0. We study its architecture patterns but write all code from scratch. Do not fetch, read, or reference cmux source files. The plan already documents everything we learned from it.
3. **Use upstream Ghostty.** Submodule `ghostty-org/ghostty`, not any fork. Pin to a specific stable commit.
4. **Apple design language.** Follow the design system in the plan exactly. System colors, system fonts, no custom chrome. When in doubt, look at how Apple's own apps (Terminal.app, Xcode, Finder) handle the same UI pattern.
5. **Build must pass at every phase gate.** The app must compile and launch (even with stub panes) before moving to the next phase.
6. **Test what you build.** Each component needs at minimum: one unit test for logic, one snapshot/UI test for visual components. The Rust bridge needs integration tests that verify round-trip calls.
7. **Commit per logical unit.** Follow the commit conventions in CLAUDE.md: `type(scope): description`. Never commit a broken build.

---

## Team Structure

Form a team with these agents. All agents use Opus 4.6. All agents work in isolated worktrees to avoid conflicts.

### Team Lead — `architect`

- **Role**: Orchestrates phases, reviews all code before merge, manages task dependencies, communicates with user
- **Agent type**: `team-lead`
- **Mode**: `plan` (requires approval for implementation)

### Foundation Team (Phase 0)

#### `build-engineer`

- **Role**: Xcode project setup, build system (Zig + Cargo + Xcode), CI pipeline, code signing
- **Agent type**: `coder`
- **Tasks**:
  - Create `native/` directory with Xcode project structure per the plan
  - Add `ghostty-org/ghostty` as git submodule, write build script for xcframework
  - Create `rust-bridge/` crate with `Cargo.toml`, `build.rs` that generates C header
  - Write `Makefile` or `justfile` that builds: ghostty xcframework → Rust staticlib → Xcode app
  - Set up entitlements file per the plan
  - Verify end-to-end: `just build` produces a launchable .app

#### `ffi-engineer`

- **Role**: Rust-to-Swift bridge layer, all C-ABI functions, callback system
- **Agent type**: `coder`
- **Tasks**:
  - Implement `rust-bridge/src/lib.rs` — `PnevmaHandle`, init/destroy lifecycle
  - Implement `rust-bridge/src/commands.rs` — one `extern "C"` function per Tauri command (JSON in → JSON out)
  - Implement `rust-bridge/src/callbacks.rs` — event callback registration (Rust pushes events to Swift)
  - Implement `rust-bridge/src/session.rs` — PTY data streaming bridge (high-frequency, binary safe)
  - Generate `pnevma-bridge.h` header via `cbindgen` in `build.rs`
  - Write integration tests: init handle → call command → verify JSON response → destroy handle
  - **Critical**: Every `#[tauri::command]` in the existing codebase must have a corresponding `extern "C"` bridge function. Use `grep -r "#\[tauri::command\]" crates/` to find them all. Missing commands = missing features.

### Terminal Team (Phase 1)

#### `terminal-engineer`

- **Role**: libghostty integration, Metal rendering, terminal input/output
- **Agent type**: `coder`
- **Depends on**: `build-engineer` (xcframework must exist), `ffi-engineer` (session bridge must exist)
- **Tasks**:
  - Implement `TerminalSurface.swift` — wraps `ghostty_app_t` and `ghostty_surface_t`
  - Implement `TerminalHostView.swift` — AppKit NSView with CAMetalLayer, keyboard/mouse routing
  - Implement `TerminalConfig.swift` — reads `~/.config/ghostty/config`, parses font/colors/theme
  - Connect PTY data flow: Rust `SessionSupervisor` → FFI callback → `ghostty_surface_write()`
  - Connect input flow: `NSEvent` → `ghostty_surface_key()` → key encoding → Rust `send_session_input()`
  - Handle resize: view frame change → `ghostty_surface_resize()` → Rust `resize_session()`
  - Implement scrollback: `ghostty_surface_read_text()` for selection, scroll events for navigation
  - Test: launch app, type commands, verify output renders, verify scrollback works

### Layout Team (Phase 2)

#### `layout-engineer`

- **Role**: Split pane engine, pane protocol, focus management
- **Agent type**: `coder`
- **Depends on**: `terminal-engineer` (need at least one renderable pane type)
- **Tasks**:
  - Implement `PaneLayoutEngine.swift` — binary tree split model (`SplitNode` enum per the plan)
  - Implement `PaneProtocol.swift` — `PaneContent` protocol that all pane types conform to
  - Implement split operations: `splitPane()`, `closePane()`, `resizeSplit()`, `navigate()`
  - Implement divider rendering: 1px `NSColor.separatorColor`, resize cursor regions, drag handling
  - Implement keyboard navigation: `⌘D` split right, `⇧⌘D` split down, `⌘W` close, `⌥⌘Arrow` navigate
  - Implement serialization: `serialize()` / `deserialize()` for session persistence
  - Implement `ContentAreaView.swift` — the main content area that hosts the split tree
  - Test: open app, split terminal 3 ways, navigate between them, resize, close one

### Sidebar Team (Phase 3)

#### `sidebar-engineer`

- **Role**: Workspace model, sidebar UI, notification system
- **Agent type**: `coder`
- **Depends on**: `layout-engineer` (workspaces own layout engines), `ffi-engineer` (metadata comes from Rust)
- **Tasks**:
  - Implement `Workspace.swift` — model class per the plan (id, name, project path, layout engine, metadata)
  - Implement `WorkspaceManager.swift` — create/switch/close workspaces, one `PnevmaHandle` per workspace
  - Implement `SidebarView.swift` — SwiftUI sidebar with `NSVisualEffectView` vibrancy per the design system
  - Implement `WorkspaceTab.swift` — individual tab: name, git branch, task count, cost, notification badge
  - Implement metadata polling: subscribe to Rust event callbacks, update `@Published` properties
  - Implement notification ring: 2px system blue border, [0→1→0→1→0] opacity over 0.9s on pane border
  - Implement OSC detection: parse OSC 9/99/777 from terminal output, create Pnevma notification
  - Implement sidebar collapse: `⌘B` toggles sidebar visibility
  - Implement new workspace: "+" button opens project picker (NSOpenPanel for directory)
  - Test: open two projects, switch between them, verify metadata updates, trigger notification

### Pane Team (Phase 4) — Largest team, parallelize heavily

All pane engineers work in parallel. Each implements one or more SwiftUI pane views that call into the Rust backend via FFI.

#### `pane-taskboard`

- **Role**: Task Board pane (Kanban)
- **Agent type**: `coder`
- **Tasks**:
  - Implement `TaskBoardPane.swift` — SwiftUI view in NSHostingView
  - 5 columns: Planned, Ready, InProgress, Review, Done
  - Task cards: title, priority dot (P0=red, P1=orange, P2=blue, P3=gray), agent name, cost, story progress bar
  - Drag-and-drop between columns (calls `pnevma_update_task` to change status)
  - Card click → detail sheet with full task contract, acceptance criteria, action buttons
  - Real-time updates via event callback
  - Action buttons: Dispatch, Approve, Reject, Delete (with protected action confirmation for destructive ones)

#### `pane-analytics`

- **Role**: Analytics + Daily Brief + Notifications panes
- **Agent type**: `coder`
- **Tasks**:
  - `AnalyticsPane.swift` — Swift Charts: cost overview bar chart, model comparison, error hotspots table, daily trend sparklines. Data from `pnevma_get_usage_breakdown`, `pnevma_get_usage_by_model`, `pnevma_list_error_signatures`, `pnevma_get_usage_daily_trend`
  - `DailyBriefPane.swift` — Metrics dashboard: large `.title` numbers for total/ready/blocked/failed tasks, cost last 24h, recent events timeline, recommended actions list. Data from `pnevma_get_daily_brief`
  - `NotificationsPane.swift` — List with unread blue dot (like Mail.app). Filter by level. Mark read/clear all. Click navigates to related task/session. Data from `pnevma_list_notifications`

#### `pane-review`

- **Role**: Review + Merge Queue + Diff panes
- **Agent type**: `coder`
- **Tasks**:
  - `ReviewPane.swift` — Show task diff, acceptance criteria checklist, approve/reject buttons, reviewer notes. Data from `pnevma_get_review_pack`, `pnevma_get_task_diff`
  - `MergeQueuePane.swift` — Ordered list of approved tasks, drag to reorder, execute merge button, conflict status. Data from `pnevma_list_merge_queue`
  - `DiffPane.swift` — Unified diff rendering in monospace NSTextView. Green/red line backgrounds at 10% opacity. File tree sidebar for multi-file diffs. Data from `pnevma_get_task_diff`

#### `pane-utilities`

- **Role**: Search, File Browser, Rules Manager, Settings, Workflow, SSH, Replay panes
- **Agent type**: `coder`
- **Tasks**:
  - `SearchPane.swift` — NSSearchField + results list with source badges and snippets. Data from `pnevma_search_project`
  - `FileBrowserPane.swift` — NSOutlineView tree + file preview. Data from `pnevma_list_project_files`, `pnevma_open_file_target`
  - `RulesManagerPane.swift` — List/edit/toggle rules and conventions. Data from `pnevma_list_rules`, `pnevma_upsert_rule`, `pnevma_toggle_rule`, `pnevma_delete_rule` (and same for conventions)
  - `SettingsPane.swift` — Standard macOS Settings scene. Global config + project config editing. Keybindings panel. Telemetry opt-in. Data from `pnevma_list_keybindings`, `pnevma_set_keybinding`, config read/write
  - `WorkflowPane.swift` — DAG visualization (Core Graphics) + Gantt timeline. Data from `pnevma_list_workflows`, `pnevma_list_workflow_instances`
  - `SshManagerPane.swift` — Profile list, connect button, Tailscale discovery, key management. Data from `pnevma_list_ssh_profiles`, `pnevma_discover_tailscale`, `pnevma_connect_ssh`
  - `ReplayPane.swift` — Read-only libghostty surface replaying session scrollback. Data from `pnevma_get_scrollback`

### Chrome Team (Phase 5)

#### `chrome-engineer`

- **Role**: Command palette, keyboard shortcuts, window chrome, menus
- **Agent type**: `coder`
- **Depends on**: All pane engineers (palette needs to reference all pane types)
- **Tasks**:
  - Implement `CommandPalette.swift` — floating NSPanel, 500pt wide, centered. Fuzzy search over: registered commands, pane open actions, task quick actions, recent files. Keyboard: ⌘K to open, arrows to navigate, enter to execute, escape to dismiss.
  - Implement `AppDelegate.swift` — NSMenu setup with all shortcuts per the plan. Window management (new window, close, minimize). Recent projects submenu.
  - Implement `StatusBar.swift` — optional bottom bar showing: current git branch, active agents count, pool utilization
  - Implement `ProtectedActionSheet.swift` — native NSAlert for dangerous operations. Confirmation phrase input for Danger-level actions per the `ActionKind` system.

### Integration Team (Phase 6–7)

#### `integration-engineer`

- **Role**: Remote access, socket API, session persistence, onboarding, auto-updater
- **Agent type**: `coder`
- **Depends on**: All previous phases
- **Tasks**:
  - Verify `pnevma-remote` works unchanged (Rust crate starts its own HTTP server — just call `pnevma_start_remote` from Swift on launch if config enables it)
  - Implement CLI binary: `pnevma` command that talks to the Unix socket control plane. Commands: `workspace.list`, `task.create`, `session.new`, `pane.split-right`, `notify`. Reuse existing control plane protocol.
  - Implement agent notification hooks: document how to use `pnevma notify` from `.claude/hooks/`
  - Implement `SessionPersistence.swift` — auto-save every 8 seconds: window frame, workspace list, per-workspace pane layout + pane metadata, per-terminal session ID + CWD. Restore on launch.
  - Implement `OnboardingFlow.swift` — native welcome window: environment readiness check, pnevma.toml creation, first-project tutorial. Data from `pnevma_get_environment_readiness`, `pnevma_initialize_project_scaffold`
  - Integrate Sparkle framework for auto-updates. Replace the Tauri updater pubkey placeholder with a real Ed25519 key.

### Quality Team (cross-cutting)

#### `qa-engineer`

- **Role**: Testing, verification, quality gates
- **Agent type**: `reviewer`
- **Tasks** (runs after each phase gate):
  - Verify the app builds cleanly: `just build` succeeds
  - Verify the app launches without crashes
  - Run all Rust tests: `cargo test --workspace` passes
  - Run Swift tests: `xcodebuild test` passes
  - Check for missing features: compare the list of `#[tauri::command]` functions against `pnevma-bridge.h` exports
  - Verify design compliance: no custom colors, no hardcoded font sizes, system controls used
  - Verify no cmux code was copied (no AGPL contamination)
  - Memory profile: ensure < 200MB RSS with 5 terminal sessions

---

## Phase Execution Order & Dependencies

```
Phase 0 (Foundation):
  build-engineer ──┐
  ffi-engineer   ──┤── GATE: app compiles, Rust bridge returns data
                   │
Phase 1 (Terminal): │
  terminal-engineer ── GATE: GPU terminal renders, typing works
                   │
Phase 2 (Layout):  │
  layout-engineer  ── GATE: splits work, keyboard navigation works
                   │
Phase 3 (Sidebar): │
  sidebar-engineer ── GATE: multi-workspace switching, notifications
                   │
Phase 4 (Panes) — all in parallel:
  pane-taskboard  ─┐
  pane-analytics  ─┤
  pane-review     ─┤── GATE: all 15 pane types render with real data
  pane-utilities  ─┘
                   │
Phase 5 (Chrome):  │
  chrome-engineer  ── GATE: ⌘K palette works, all shortcuts wired
                   │
Phase 6-7 (Integration):
  integration-engineer ── GATE: persistence works, CLI works, onboarding works
                   │
Cross-cutting:     │
  qa-engineer      ── runs at every GATE
```

**Parallelism strategy**: Phase 0's two engineers work in parallel. Phases 1–3 are sequential (each depends on the previous). Phase 4's four pane engineers all work in parallel. Phase 5–7 are sequential after Phase 4.

Maximum concurrent agents at peak (Phase 4): **4 pane engineers + 1 qa-engineer = 5 agents**.

---

## File Naming & Swift Conventions

- **Files**: PascalCase matching the primary type (`TerminalSurface.swift`, `PaneLayoutEngine.swift`)
- **SwiftUI views**: Suffix with `View` only for top-level views (`SidebarView.swift`), not for subcomponents
- **Panes**: Suffix with `Pane` (`TaskBoardPane.swift`)
- **Protocols**: Suffix with `Protocol` or use adjective naming (`PaneContent`)
- **Extensions**: `TypeName+Feature.swift` (`NSColor+Pnevma.swift`)
- **Tests**: `TypeNameTests.swift` in `PnevmaTests/` target
- **No comments on obvious code**. Comment only: non-obvious FFI safety invariants, performance-critical decisions, workarounds for known issues.

---

## Verification Commands

After each phase, run:

```bash
# Rust backend (must always pass)
cargo fmt --check
cargo clippy --workspace --all-targets -- -D warnings
cargo test --workspace

# Native app
just build            # or: cd native && xcodebuild build
just test             # or: cd native && xcodebuild test

# Feature parity check
./scripts/check-ffi-coverage.sh   # compares tauri commands vs bridge exports
```

---

## What "Done" Looks Like

The final deliverable is a native macOS .app that:

1. Opens with a single GPU-accelerated terminal in the main pane
2. Has a sidebar showing the workspace with git branch, task count, cost, and notification badges
3. Supports split panes (⌘D/⇧⌘D) with keyboard navigation (⌥⌘Arrow)
4. Opens any of the 15 pane types via ⌘K command palette or keyboard shortcuts
5. Renders task board, analytics, daily brief, notifications, review, merge queue, diff, search, file browser, rules, settings, workflows, SSH, and replay — all with real data from the Rust backend
6. Shows notification rings when agents complete tasks or need attention
7. Persists session layout across restarts
8. Reads the user's Ghostty config for terminal theming
9. Supports remote access via Tailscale (existing Rust server, unchanged)
10. Has a CLI tool (`pnevma`) for automation from external scripts/hooks
11. Passes all Rust and Swift tests
12. Uses zero custom colors — everything is system-derived
13. Feels like a native Apple app that happens to be incredibly powerful

Start by reading `docs/plans/pnevma-v2-terminal-rewrite.md`, then form the team and begin Phase 0.
