# Pnevma v2 — GPU-Accelerated Terminal + Orchestration Platform

## Vision

A single native macOS application that combines Ghostty-level GPU-accelerated terminal rendering with Pnevma's full orchestration platform: task lifecycle, agent dispatch, merge queues, workflows, analytics, remote access, and more. One app for all agentic development.

---

## Design Language — Apple Minimal

The visual design follows cmux's lead: terminal-first, minimal chrome, native macOS feel. The terminal is the hero — everything else stays out of the way until needed.

### Design Principles

1. **Content is the UI** — The terminal dominates. No decorative borders, no heavy toolbars, no gratuitous gradients. The content area is the interface.
2. **Invisible until needed** — Orchestration features (task board, analytics, merge queue) live in panes that appear on demand. The default view is just terminal + sidebar.
3. **Native macOS** — Use system colors, SF Symbols, standard macOS controls. No custom chrome that fights the OS. Respect dark/light mode, accent color, and accessibility settings.
4. **Quiet information density** — The sidebar shows rich metadata (git branch, task count, cost, notifications) in a compact, scannable format. No icons where text suffices. No text where absence suffices.
5. **Motion as feedback, not decoration** — Animations only when they communicate state changes (notification ring flash, pane focus transition, task status change). 120–220ms durations. No bouncing, no sliding panels.

### Color System

```
Background:      System background (NSColor.windowBackgroundColor)
Sidebar:         System sidebar (NSVisualEffectView, .sidebar material)
Terminal:        User's Ghostty theme (inherits ~/.config/ghostty/config)
Text:            System label colors (primary, secondary, tertiary)
Accent:          System accent color (user's preference in System Settings)
Borders:         1px, NSColor.separatorColor (barely visible)
Notification:    System blue (NSColor.systemBlue) — ring flash only
Error:           System red (NSColor.systemRed)
Success:         System green (NSColor.systemGreen)
```

No custom colors. Everything derives from the system palette so it adapts automatically to dark mode, light mode, increased contrast, and reduced transparency.

### Typography

```
Terminal:        User's Ghostty font (default: SF Mono or Menlo)
UI labels:       SF Pro Text (system font, automatic)
UI headings:     SF Pro Text Semibold
Monospace (non-terminal): SF Mono
Sizes:           System dynamic type scale — .body, .callout, .caption, .title3
```

No hardcoded font sizes. Use SwiftUI's `.font(.body)` etc. so the app respects accessibility text size settings.

### Spacing & Layout

```
Sidebar width:   220pt (collapsible to 0 with ⌘B)
Pane dividers:   1px, draggable, NSColor.separatorColor
Pane padding:    0 for terminals (edge-to-edge), 16pt for orchestration panes
Card padding:    12pt (task cards, notification items)
List row height: 32pt (standard macOS)
Corner radii:    System default (NSVisualEffectView handles this)
```

### Sidebar Design

Modeled after cmux's vertical tabs but extended with Pnevma metadata:

```
┌──────────────────────┐
│  P N E V M A         │  ← App wordmark, muted, .caption weight
│                      │
│  ● pnevma            │  ← Active workspace (accent dot)
│    main              │     Git branch, .caption, secondary color
│    2 agents · $0.31  │     Live metadata, .caption2
│                      │
│  ○ frontend          │  ← Inactive workspace (hollow dot)
│    feat/auth         │
│    1 task            │
│                      │
│  ○ api          🔵 3 │  ← Notification badge (system blue)
│    main              │
│    idle              │
│                      │
│                      │
│                      │
│                      │
│  ──────────────────  │
│  + Open Project      │  ← Muted, .callout
│  ⚙ Settings          │
└──────────────────────┘
```

- No icons in the workspace list (text is clearer)
- Accent-colored dot for active workspace, hollow for inactive
- Metadata lines use secondary/tertiary label colors
- Notification badge is a small pill, system blue, white count
- Bottom section: open project + settings, separated by a thin divider
- Sidebar uses `NSVisualEffectView` with `.sidebar` material (native vibrancy)

### Orchestration Panes

When the user opens a non-terminal pane (task board, analytics, etc.), it appears as a split alongside their terminals. The design follows macOS conventions:

- **Task Board**: Column headers in `.headline` weight. Task cards are flat rectangles with 1px border, no shadows. Priority shown as a small colored dot (P0=red, P1=orange, P2=blue, P3=gray). Status badges use system colors.
- **Analytics**: Swift Charts with system colors. No custom chart styling. Minimal labels.
- **Daily Brief**: Clean list layout. Metrics as large `.title` numbers with `.caption` labels below.
- **Notifications**: Standard list rows. Unread items have a blue dot (like Mail.app). Timestamp in `.caption2`, secondary color.
- **Diff View**: Monospace text. Green/red line backgrounds at 10% opacity (standard diff colors). No syntax highlighting beyond the diff markers.
- **Search**: Search field at top (standard NSSearchField). Results as list rows with source badge and snippet.

### Command Palette

Floating panel, centered, 500pt wide:

```
┌──────────────────────────────────────┐
│  🔍 Type a command...                │
│──────────────────────────────────────│
│  Open Task Board               ⌘1   │
│  Open Daily Brief              ⌘2   │
│  Dispatch Task: Fix auth bug         │
│  Split Pane Right              ⌘D   │
│  New Terminal                  ⌘N   │
└──────────────────────────────────────┘
```

- No category headers, just a flat ranked list
- Fuzzy search, most relevant first
- Keyboard shortcut shown right-aligned in secondary color
- Dismiss with Escape or clicking outside

### Notification Ring

When an agent completes or needs attention, the relevant pane border flashes:

- 2px border, system blue, corner radius matching the pane
- Animation: opacity [0 → 1 → 0 → 1 → 0] over 0.9s
- Easing: ease-out on flash in, ease-in on flash out
- Only on the pane that received the notification, not the whole window

### What we explicitly avoid

- Custom title bars or window chrome
- Gradient backgrounds
- Drop shadows on cards or panels
- Colored backgrounds on sections (let the content breathe)
- Rounded corners on everything (only where macOS uses them natively)
- Hamburger menus or custom navigation paradigms
- Loading spinners (use subtle skeleton states or no indicator for fast operations)
- Tooltips except where the icon has no label
- Confirmation dialogs for non-destructive actions

---

## Architecture Decision

### Why not fork cmux directly?

- **License conflict**: cmux is AGPL-3.0 (copyleft). Copying code would force Pnevma to adopt AGPL.
- **Limited overlap**: cmux provides terminal + notifications + browser. Pnevma needs 15+ pane types, a full task lifecycle, agent dispatch, merge queues, workflows, analytics, remote access, etc. cmux's orchestration layer is effectively nonexistent.
- **Architecture mismatch**: cmux is a monolithic 50K-line Swift app. Pnevma's value is in its modular Rust crates.

### What we take from cmux (architecture patterns, not code)

- **libghostty integration pattern**: Use Ghostty's xcframework build, Swift bridging header, Metal surface hosting
- **Split pane architecture**: Binary tree layout engine (we'll build our own, informed by Bonsplit's approach)
- **Sidebar design**: Vertical workspace tabs with metadata (git branch, ports, notifications)
- **Notification ring UX**: OSC 9/99/777 detection, blue ring flash animation, sidebar badges
- **Socket API pattern**: Unix socket for CLI automation (maps to our existing control plane)
- **Session persistence**: Auto-save layout + scrollback on interval, restore on launch

### Target architecture

```
┌─────────────────────────────────────────────────────────────┐
│                    Native macOS App (Swift/AppKit)           │
│                                                             │
│  ┌──────────┐  ┌──────────────────────────────────────────┐ │
│  │ Sidebar  │  │           Content Area                   │ │
│  │          │  │  ┌────────────────┬──────────────────┐   │ │
│  │ Workspace│  │  │  Terminal Pane │  Task Board Pane │   │ │
│  │ Tabs     │  │  │  (libghostty  │  (SwiftUI /      │   │ │
│  │          │  │  │   + Metal)    │   AppKit)        │   │ │
│  │ ─────── │  │  ├────────────────┼──────────────────┤   │ │
│  │ Git info │  │  │  Terminal Pane │  Analytics Pane  │   │ │
│  │ Notifs   │  │  │  (libghostty) │  (SwiftUI)       │   │ │
│  │ Status   │  │  └────────────────┴──────────────────┘   │ │
│  └──────────┘  └──────────────────────────────────────────┘ │
│                                                             │
│  ┌─────────────────────────────────────────────────────────┐│
│  │              Command Palette (⌘K)                       ││
│  └─────────────────────────────────────────────────────────┘│
└─────────────────────────────────────────────────────────────┘
        │                    │                    │
        │ Swift ↔ Rust FFI   │                    │
        │ (C-ABI / UniFFI)   │                    │
        ▼                    ▼                    ▼
┌─────────────────────────────────────────────────────────────┐
│                    Rust Backend (unchanged)                  │
│                                                             │
│  pnevma-app    pnevma-agents   pnevma-session               │
│  pnevma-core   pnevma-db       pnevma-git                   │
│  pnevma-remote pnevma-context  pnevma-ssh                   │
└─────────────────────────────────────────────────────────────┘
```

**Key insight**: The Rust backend crates are 100% reusable. We replace only the Tauri shell + React frontend with a native Swift/AppKit shell that calls into Rust via FFI.

---

## Technology Stack

| Layer              | Current (v1)     | New (v2)                    | Why                                              |
| ------------------ | ---------------- | --------------------------- | ------------------------------------------------ |
| App shell          | Tauri (webview)  | Native Swift/AppKit         | Required for libghostty Metal integration        |
| Terminal rendering | xterm.js         | libghostty + Metal          | GPU-accelerated, Ghostty-level performance       |
| UI framework       | React/TypeScript | SwiftUI + AppKit            | Native controls, no webview overhead             |
| Backend            | Rust crates      | Rust crates (unchanged)     | All business logic preserved                     |
| FFI bridge         | Tauri IPC (JSON) | UniFFI or C-ABI             | Direct function calls, no serialization overhead |
| Split panes        | CSS flexbox      | Custom AppKit layout engine | Native resize handles, proper focus management   |
| Build system       | Vite + Cargo     | Xcode + Cargo + Zig         | xcframework for libghostty, staticlib for Rust   |

---

## Phase 0 — Foundation (Weeks 1–2)

### 0.1 Set up Xcode project

Create a new native macOS app project alongside the existing Tauri app.

```
pnevma/
├── crates/                    # Existing Rust crates (unchanged)
├── frontend/                  # Existing React frontend (deprecated in v2)
├── native/                    # NEW: Native macOS app
│   ├── Pnevma.xcodeproj
│   ├── Pnevma/
│   │   ├── App/
│   │   │   ├── PnevmaApp.swift          # @main entry point
│   │   │   └── AppDelegate.swift        # NSApplicationDelegate
│   │   ├── Bridge/
│   │   │   ├── pnevma-bridge.h          # C-ABI header for Rust backend
│   │   │   ├── ghostty.h               # libghostty FFI header
│   │   │   └── Pnevma-Bridging-Header.h
│   │   ├── Core/
│   │   │   ├── WorkspaceManager.swift   # Workspace lifecycle
│   │   │   ├── PaneLayoutEngine.swift   # Binary tree split layout
│   │   │   ├── SessionBridge.swift      # Rust SessionSupervisor wrapper
│   │   │   └── CommandBus.swift         # Swift → Rust command dispatch
│   │   ├── Terminal/
│   │   │   ├── TerminalSurface.swift    # libghostty surface wrapper
│   │   │   ├── TerminalHostView.swift   # AppKit hosting view
│   │   │   └── TerminalConfig.swift     # Ghostty config loader
│   │   ├── Panes/
│   │   │   ├── PaneProtocol.swift       # Shared pane interface
│   │   │   ├── TerminalPane.swift
│   │   │   ├── TaskBoardPane.swift
│   │   │   ├── ReviewPane.swift
│   │   │   ├── AnalyticsPane.swift
│   │   │   ├── DailyBriefPane.swift
│   │   │   ├── MergeQueuePane.swift
│   │   │   ├── NotificationsPane.swift
│   │   │   ├── SearchPane.swift
│   │   │   ├── DiffPane.swift
│   │   │   ├── FileBrowserPane.swift
│   │   │   ├── RulesManagerPane.swift
│   │   │   ├── SettingsPane.swift
│   │   │   ├── WorkflowPane.swift
│   │   │   ├── ReplayPane.swift
│   │   │   └── SshManagerPane.swift
│   │   ├── Sidebar/
│   │   │   ├── SidebarView.swift        # Vertical workspace tabs
│   │   │   ├── WorkspaceTab.swift       # Individual tab with metadata
│   │   │   └── NotificationBadge.swift
│   │   ├── Chrome/
│   │   │   ├── CommandPalette.swift     # ⌘K command search
│   │   │   ├── StatusBar.swift
│   │   │   └── ProtectedActionSheet.swift
│   │   └── Shared/
│   │       ├── DesignTokens.swift       # Colors, spacing, typography
│   │       └── Extensions.swift
│   ├── Pnevma.entitlements
│   └── Info.plist
├── rust-bridge/                # NEW: Rust → C-ABI bridge crate
│   ├── Cargo.toml
│   ├── src/
│   │   ├── lib.rs              # Top-level exports
│   │   ├── commands.rs         # All command functions as C-ABI
│   │   ├── types.rs            # Shared types (C-repr structs)
│   │   ├── callbacks.rs        # Event callbacks from Rust → Swift
│   │   └── session.rs          # Session-specific bridge (PTY data)
│   └── build.rs               # Generate C header + staticlib
└── ghostty/                    # Git submodule: ghostty-org/ghostty
```

### 0.2 Build libghostty xcframework

```bash
# Add Ghostty as a submodule (upstream, not cmux's fork)
git submodule add https://github.com/ghostty-org/ghostty.git ghostty

# Build xcframework
cd ghostty
zig build -Demit-xcframework=true -Doptimize=ReleaseFast
# Output: zig-out/lib/GhosttyKit.xcframework
```

Link the xcframework in Xcode build phases.

### 0.3 Build Rust bridge static library

Create `rust-bridge` crate that exposes Pnevma's backend as C-ABI functions.

**Cargo.toml:**

```toml
[package]
name = "pnevma-bridge"
version = "0.1.0"
edition = "2021"

[lib]
crate-type = ["staticlib"]

[dependencies]
pnevma-app = { path = "../crates/pnevma-app" }
pnevma-core = { path = "../crates/pnevma-core" }
pnevma-db = { path = "../crates/pnevma-db" }
pnevma-session = { path = "../crates/pnevma-session" }
pnevma-agents = { path = "../crates/pnevma-agents" }
pnevma-git = { path = "../crates/pnevma-git" }
pnevma-remote = { path = "../crates/pnevma-remote" }
pnevma-context = { path = "../crates/pnevma-context" }
pnevma-ssh = { path = "../crates/pnevma-ssh" }
tokio = { version = "1", features = ["full"] }
serde_json = "1"
```

**Bridge pattern** (for each command):

```rust
// rust-bridge/src/commands.rs

/// Opaque handle to the Rust runtime + app state.
pub struct PnevmaHandle { /* tokio runtime, AppState, etc. */ }

#[no_mangle]
pub extern "C" fn pnevma_init(project_path: *const c_char) -> *mut PnevmaHandle { ... }

#[no_mangle]
pub extern "C" fn pnevma_destroy(handle: *mut PnevmaHandle) { ... }

/// Returns JSON string (caller must free with pnevma_free_string).
#[no_mangle]
pub extern "C" fn pnevma_list_tasks(handle: *mut PnevmaHandle) -> *mut c_char { ... }

#[no_mangle]
pub extern "C" fn pnevma_create_task(handle: *mut PnevmaHandle, json: *const c_char) -> *mut c_char { ... }

// ... one function per command

/// Register a callback for events (Rust → Swift).
#[no_mangle]
pub extern "C" fn pnevma_set_event_callback(
    handle: *mut PnevmaHandle,
    callback: extern "C" fn(*const c_char, *mut c_void),
    context: *mut c_void,
) { ... }

#[no_mangle]
pub extern "C" fn pnevma_free_string(s: *mut c_char) { ... }
```

**Build script** generates `pnevma-bridge.h` header automatically.

### 0.4 Verify end-to-end: Swift app → Rust backend → SQLite

Milestone: A bare Swift window that calls `pnevma_init()`, `pnevma_list_tasks()`, and prints results.

---

## Phase 1 — Terminal Core (Weeks 3–5)

### 1.1 libghostty surface wrapper

`TerminalSurface.swift` — Wraps libghostty's `ghostty_surface_t`:

```swift
final class TerminalSurface {
    private var app: ghostty_app_t
    private var surface: ghostty_surface_t
    private let metalLayer: CAMetalLayer

    init(config: TerminalConfig) {
        // Create ghostty app instance (one per application)
        // Create surface with config (font, colors, scrollback)
        // Attach Metal layer for GPU rendering
    }

    func sendKey(_ event: NSEvent) { ghostty_surface_key(...) }
    func sendText(_ text: String) { ghostty_surface_text(...) }
    func sendMouse(_ event: NSEvent) { ghostty_surface_mouse_button(...) }
    func resize(cols: UInt16, rows: UInt16) { ghostty_surface_resize(...) }
    func getSelection() -> String? { ghostty_surface_read_selection(...) }
}
```

### 1.2 Terminal host view

`TerminalHostView.swift` — AppKit NSView that hosts the Metal-rendered terminal:

- Creates CAMetalLayer and attaches to libghostty surface
- Routes keyboard events to `ghostty_surface_key()`
- Routes mouse events to `ghostty_surface_mouse_button()`
- Handles IME input via `insertText(_:)`
- Manages focus ring and first responder status

### 1.3 Connect terminal to Pnevma sessions

Bridge libghostty's PTY to `pnevma-session`'s `SessionSupervisor`:

- When a terminal pane is created, call `pnevma_create_session()` via FFI
- The Rust side spawns the PTY process as before
- PTY output is forwarded to the Swift side via a callback
- Swift feeds the bytes to `ghostty_surface_write()`
- User keystrokes go: AppKit → libghostty (for key encoding) → Rust `send_session_input()`

### 1.4 Ghostty config integration

Read the user's existing Ghostty config (`~/.config/ghostty/config`):

- Font family, size
- Color theme (palette 0-15, background, foreground, cursor)
- Scrollback limit
- Unfocused split opacity

Fall back to sensible defaults. Users who already use Ghostty get their familiar setup.

### 1.5 Milestone

A native macOS window with a single GPU-accelerated terminal pane connected to a Pnevma session. Typing works, output renders, scrollback works.

---

## Phase 2 — Pane Layout Engine (Weeks 5–7)

### 2.1 Binary tree split layout

`PaneLayoutEngine.swift` — Custom layout engine (not using Bonsplit, to avoid AGPL dependency):

```swift
indirect enum SplitNode {
    case leaf(PaneID)
    case split(direction: SplitDirection, ratio: CGFloat, first: SplitNode, second: SplitNode)
}

enum SplitDirection { case horizontal, vertical }

class PaneLayoutEngine {
    var root: SplitNode

    func splitPane(_ id: PaneID, direction: SplitDirection) -> PaneID
    func closePane(_ id: PaneID)
    func resizeSplit(_ id: PaneID, ratio: CGFloat)
    func layout(in rect: NSRect) -> [(PaneID, NSRect)]
    func navigate(from: PaneID, direction: NavigationDirection) -> PaneID?

    // Persistence
    func serialize() -> Data
    static func deserialize(_ data: Data) -> PaneLayoutEngine
}
```

### 2.2 Pane protocol

Every pane type conforms to:

```swift
protocol PaneContent: NSView {
    var paneID: PaneID { get }
    var paneType: PaneType { get }
    var title: String { get }

    func activate()    // Called when pane gains focus
    func deactivate()  // Called when pane loses focus
    func dispose()     // Cleanup
}
```

### 2.3 Pane type registry

Map Pnevma's 15 pane types to native views:

| Pane Type       | Rendering Strategy                         |
| --------------- | ------------------------------------------ |
| `terminal`      | libghostty Metal surface (AppKit NSView)   |
| `task-board`    | SwiftUI hosted in NSHostingView            |
| `review`        | SwiftUI hosted in NSHostingView            |
| `merge-queue`   | SwiftUI hosted in NSHostingView            |
| `analytics`     | SwiftUI with Charts framework              |
| `daily-brief`   | SwiftUI hosted in NSHostingView            |
| `notifications` | SwiftUI hosted in NSHostingView            |
| `search`        | SwiftUI hosted in NSHostingView            |
| `diff`          | Custom NSTextView with syntax highlighting |
| `file-browser`  | NSOutlineView (native tree view)           |
| `rules-manager` | SwiftUI hosted in NSHostingView            |
| `settings`      | SwiftUI Settings scene                     |
| `workflow`      | Custom NSView (DAG/Gantt rendering)        |
| `replay`        | libghostty surface in read-only mode       |
| `ssh`           | SwiftUI hosted in NSHostingView            |

### 2.4 Split interactions

- **Keyboard**: `⌘D` split right, `⇧⌘D` split down, `⌘W` close pane
- **Navigation**: `⌥⌘←→↑↓` move focus between panes
- **Resize**: Drag dividers, or `⌃⌥←→↑↓` to resize
- **Divider styling**: 1px line from design tokens, resize cursor on hover

### 2.5 Milestone

Multiple terminal panes in splits, resizable, with keyboard navigation. One orchestration pane (e.g., task board) rendering via SwiftUI.

---

## Phase 3 — Sidebar & Workspaces (Weeks 7–9)

### 3.1 Workspace model

Each workspace = one project context + its pane layout:

```swift
class Workspace: Identifiable, ObservableObject {
    let id: UUID
    @Published var name: String
    @Published var projectPath: String
    var layoutEngine: PaneLayoutEngine
    var pnevmaHandle: PnevmaHandle  // Rust backend handle for this project

    // Sidebar metadata
    @Published var gitBranch: String?
    @Published var activeTasks: Int
    @Published var notifications: [PnevmaNotification]
    @Published var activeAgents: Int
    @Published var costToday: Double
}
```

### 3.2 Sidebar view

Vertical tab bar (left side) showing workspaces:

```
┌──────────────┐
│ ⬤ pnevma     │  ← active workspace (blue indicator)
│   main       │  ← git branch
│   3 tasks    │  ← active task count
│   $0.42      │  ← cost today
│              │
│ ○ frontend   │  ← inactive workspace
│   feat/auth  │
│   1 task     │
│   🔔 2       │  ← unread notification badge
│              │
│ ○ api        │
│   main       │
│   idle       │
│              │
│ [+] New      │  ← open project
└──────────────┘
```

### 3.3 Sidebar metadata sources

| Metadata      | Source                                       | Update Trigger              |
| ------------- | -------------------------------------------- | --------------------------- |
| Git branch    | `pnevma_project_status()`                    | File watch on `.git/HEAD`   |
| Active tasks  | `pnevma_list_tasks()` filtered by InProgress | Task status event           |
| Active agents | `pnevma_pool_state()`                        | Agent event callback        |
| Cost today    | `pnevma_get_usage_daily_trend()`             | Cost event callback         |
| Notifications | `pnevma_list_notifications()`                | Notification event callback |

### 3.4 Notification system

Pnevma already has a full notification system. Wire it to the native UI:

- **Notification ring**: Blue ring flash on the pane border when an agent completes or needs attention (same UX as cmux: [0, 1, 0, 1, 0] opacity over 0.9s)
- **Sidebar badge**: Unread count on workspace tab
- **macOS native**: Forward critical notifications to NSUserNotificationCenter
- **OSC sequences**: Detect OSC 9/99/777 in terminal output, create Pnevma notification via `pnevma_create_notification()`

### 3.5 Milestone

Multiple workspaces switchable via sidebar. Each workspace has its own project, pane layout, and notification state.

---

## Phase 4 — Orchestration Panes (Weeks 9–14)

Port each pane from React to SwiftUI. Priority order based on usage:

### 4.1 Task Board Pane (Week 9–10)

Kanban board: Planned → Ready → InProgress → Review → Done

- Drag-and-drop cards between columns (SwiftUI `.draggable` / `.dropDestination`)
- Task cards show: title, priority badge, assigned agent, cost, story progress bar
- Click card → detail sheet with full task contract
- Action buttons: Dispatch, Approve, Reject, Delete
- Real-time updates via Rust event callback

### 4.2 Daily Brief Pane (Week 10)

Dashboard with key metrics:

- Total/ready/blocked/failed tasks
- Cost last 24h
- Recent events timeline
- Recommended actions
- Top cost tasks

### 4.3 Notifications Pane (Week 10)

- Notification list with read/unread state
- Filter by level (info/warning/error)
- Click to navigate to related task/session
- Mark read, clear all

### 4.4 Analytics Pane (Week 11)

- Cost overview (Swift Charts)
- Model comparison bar chart
- Error hotspots with remediation hints
- Daily trend sparklines

### 4.5 Review Pane (Week 11–12)

- Show diff for task branch
- Acceptance criteria checklist
- Approve/reject buttons
- Reviewer notes text field

### 4.6 Merge Queue Pane (Week 12)

- Ordered queue of approved tasks
- Drag to reorder
- Execute merge button
- Conflict status indicators

### 4.7 Diff Pane (Week 12)

- Unified diff rendering with syntax highlighting
- File tree sidebar
- Hunk navigation

### 4.8 Search Pane (Week 13)

- Full-text search across tasks, events, artifacts
- Result list with source badges
- Click to navigate

### 4.9 Remaining Panes (Week 13–14)

- **File Browser**: NSOutlineView tree + file preview
- **Rules Manager**: List/edit/toggle rules and conventions
- **Workflow**: DAG visualization (custom Core Graphics rendering) + Gantt timeline
- **SSH Manager**: Profile list, connect button, Tailscale discovery
- **Settings**: Standard macOS Settings scene
- **Replay**: Read-only libghostty surface replaying session scrollback

### 4.10 Milestone

All 15 pane types functional in native UI.

---

## Phase 5 — Command Palette & Shortcuts (Week 14–15)

### 5.1 Command Palette (⌘K)

Floating search panel (like Raycast/Spotlight):

```swift
struct CommandPaletteEntry {
    let id: String
    let title: String
    let subtitle: String?
    let shortcut: String?
    let icon: String  // SF Symbol
    let action: () -> Void
}
```

Sources:

- All registered commands from `pnevma_list_registered_commands()`
- Pane open actions (e.g., "Open Task Board", "Open Analytics")
- Task quick actions (e.g., "Dispatch task: Fix auth bug")
- Recent files from `pnevma_list_project_files()`

### 5.2 Keyboard shortcuts

Port from current keybinding system. Map to native NSMenuItem key equivalents:

| Action           | Shortcut                    |
| ---------------- | --------------------------- |
| Command Palette  | ⌘K                          |
| New Terminal     | ⌘N                          |
| Split Right      | ⌘D                          |
| Split Down       | ⇧⌘D                         |
| Close Pane       | ⌘W                          |
| Navigate Panes   | ⌥⌘Arrow                     |
| Open Task Board  | ⌘1                          |
| Open Daily Brief | ⌘2                          |
| Toggle Sidebar   | ⌘B                          |
| Quick Search     | ⌘F (in pane), ⇧⌘F (project) |

Customizable via `pnevma_list_keybindings()` / `pnevma_set_keybinding()`.

---

## Phase 6 — Remote Access & Socket API (Week 15–16)

### 6.1 Remote server (unchanged)

`pnevma-remote` crate continues to work as-is. The Rust backend starts the Tailscale HTTPS server with token auth, rate limiting, and WebSocket support. No changes needed.

### 6.2 Socket API for CLI automation

Replace Tauri's IPC with a Unix socket API (similar to cmux's `TerminalController`):

```bash
# CLI tool (new binary in rust-bridge or separate crate)
pnevma workspace.list
pnevma task.create --title "Fix auth" --priority P1
pnevma session.new --command "zsh" --cwd .
pnevma pane.split-right
pnevma notify --title "Done" --body "Task completed"
```

The socket server is already implemented in `pnevma-app`'s control plane. Just ensure the CLI binary can talk to it.

### 6.3 Agent hooks

Support agent notification hooks (like cmux's `cmux notify`):

```bash
# In .claude/hooks/post-tool-use.sh
pnevma notify --title "Tool used" --body "$TOOL_NAME" --session-id "$SESSION_ID"
```

---

## Phase 7 — Session Persistence & Polish (Week 16–17)

### 7.1 Session persistence

Auto-save every 8 seconds (matching cmux's approach):

- Window position and size
- Workspace list and active workspace
- Per-workspace: pane layout tree, pane types, pane metadata
- Per-terminal: session ID, scrollback (capped at 4000 lines), CWD
- Restore on app launch

Store in `~/.config/pnevma/session.json` or SQLite.

### 7.2 Protected action sheets

Native NSAlert for dangerous operations:

- Merge to target branch
- Delete worktree with changes
- Force push
- Checkpoint restore

Confirmation phrases from existing `ActionKind` system.

### 7.3 Onboarding flow

Native welcome window:

1. Detect environment readiness (git, agents, config)
2. Guide through `pnevma.toml` creation
3. Show first-project tutorial
4. Open main window with default layout

### 7.4 Auto-updater

Replace Tauri updater with Sparkle (standard macOS update framework):

- Signed updates via Ed25519 (replace the placeholder pubkey)
- Update check on launch + configurable interval
- Delta updates for fast downloads

---

## Phase 8 — Distribution (Week 17–18)

### 8.1 Build pipeline

```yaml
# .github/workflows/release.yml
- Build libghostty xcframework (zig build)
- Build Rust staticlib (cargo build --release)
- Build macOS app (xcodebuild)
- Code sign + notarize
- Create DMG
- Upload to GitHub Releases
- Update Homebrew cask
- Trigger Sparkle update feed
```

### 8.2 Distribution channels

- **DMG** on GitHub Releases
- **Homebrew**: `brew install --cask pnevma`
- **Sparkle** auto-update from within the app

---

## Migration Path

### What stays the same

- **All Rust crates**: Zero changes to pnevma-app, pnevma-core, pnevma-db, pnevma-agents, pnevma-session, pnevma-git, pnevma-remote, pnevma-context, pnevma-ssh
- **Database**: Same SQLite schema, same migrations
- **Config**: Same `pnevma.toml` format
- **Remote API**: Same HTTP/WebSocket endpoints
- **Control plane**: Same Unix socket protocol

### What gets replaced

| v1 (Tauri)                           | v2 (Native)                       |
| ------------------------------------ | --------------------------------- |
| Tauri shell + webview                | Swift/AppKit app                  |
| React/TypeScript frontend            | SwiftUI + AppKit views            |
| xterm.js terminal                    | libghostty + Metal                |
| CSS flexbox layouts                  | Custom split layout engine        |
| Tauri IPC (JSON over webview bridge) | C-ABI FFI (direct function calls) |
| Tauri updater                        | Sparkle                           |

### What gets added

- GPU-accelerated terminal rendering
- Native macOS feel (menus, sheets, window management)
- Vertical workspace sidebar with rich metadata
- Notification rings on pane borders
- OSC sequence detection for agent awareness
- CLI tool for external automation
- Ghostty config compatibility

### Data migration

None required. The SQLite database and `pnevma.toml` config are backend concerns — they work identically regardless of frontend.

---

## Risk Assessment

| Risk                                          | Severity | Mitigation                                                                       |
| --------------------------------------------- | -------- | -------------------------------------------------------------------------------- |
| libghostty API instability                    | High     | Pin to specific Ghostty commit; wrap all calls in a thin Swift layer we control  |
| Swift ↔ Rust FFI complexity                   | Medium   | Start with JSON-over-C-ABI (simple); optimize hot paths later with typed structs |
| SwiftUI limitations for complex UI            | Medium   | Use AppKit directly where SwiftUI falls short (diff view, workflow DAG)          |
| macOS-only limitation                         | Medium   | Accept for v2; cross-platform (Linux) is a future v3 goal via GTK + libghostty   |
| Build system complexity (Zig + Cargo + Xcode) | Medium   | Script the full build; CI validates end-to-end                                   |
| Feature parity during migration               | High     | Keep v1 Tauri app working until v2 reaches parity; parallel development          |

---

## Success Criteria

1. **Terminal performance**: Renders at 120fps, handles `cat large-file.txt` without lag
2. **Feature parity**: All 15 pane types, all commands, full task lifecycle
3. **Stability**: No crashes in 8-hour continuous agent dispatch session
4. **Startup time**: < 500ms to first terminal prompt
5. **Memory**: < 200MB RSS with 5 terminal sessions
6. **Native feel**: Respects macOS conventions (menus, shortcuts, dark mode, accent colors)

---

## Timeline Summary

| Phase                   | Duration      | Deliverable                                            |
| ----------------------- | ------------- | ------------------------------------------------------ |
| 0: Foundation           | 2 weeks       | Xcode project, libghostty xcframework, Rust FFI bridge |
| 1: Terminal Core        | 3 weeks       | GPU-rendered terminal connected to Pnevma sessions     |
| 2: Pane Layout          | 2 weeks       | Split panes with keyboard navigation                   |
| 3: Sidebar & Workspaces | 2 weeks       | Multi-workspace sidebar with metadata                  |
| 4: Orchestration Panes  | 5 weeks       | All 15 pane types ported to SwiftUI/AppKit             |
| 5: Command Palette      | 1 week        | ⌘K palette + keyboard shortcuts                        |
| 6: Remote & Socket      | 2 weeks       | CLI tool, socket API, agent hooks                      |
| 7: Persistence & Polish | 2 weeks       | Session restore, onboarding, updater                   |
| 8: Distribution         | 1 week        | Build pipeline, DMG, Homebrew                          |
| **Total**               | **~18 weeks** |                                                        |

---

## Open Questions

1. **UniFFI vs raw C-ABI**: UniFFI generates Swift bindings automatically but adds a build step. Raw C-ABI is simpler but requires manual header maintenance. Recommend starting with raw C-ABI for control, evaluate UniFFI later.

2. **Ghostty fork vs upstream**: cmux uses a fork (`manaflow-ai/ghostty`). We should use upstream (`ghostty-org/ghostty`) directly and only fork if we need patches that aren't accepted upstream.

3. **Parallel v1/v2 development**: Keep the Tauri app functional during migration? Or hard-switch? Recommend parallel — v1 is the safety net until v2 reaches feature parity.

4. **Linux support timeline**: libghostty supports Linux via GTK. A v3 could add Linux support by wrapping the same Rust backend with a GTK frontend. Not in scope for v2.

5. **iOS/iPadOS**: libghostty supports iOS (see Echo, VVTerm, Spectty). A companion iPad app is theoretically possible. Not in scope for v2.
