# Graveyard — Dead Code Archive

Moved here on 2026-03-11 after a full dead code audit with verification.
Each item was confirmed to have zero production callers before removal.

## Entire Files Moved

| File | Original Location | Reason |
|------|-------------------|--------|
| `swift/ProtectedActionSheet.swift` | `native/Pnevma/Chrome/` | Class never instantiated or referenced |
| `swift/OnboardingFlow.swift` | `native/Pnevma/Chrome/` | OnboardingWindow/View/ViewModel never wired into AppDelegate |
| `swift/BrowserToolBridge.swift` | `native/Pnevma/Panes/Browser/` | Singleton `.shared` never accessed; bridge never activated |

## Code Extracted From Source Files

### Swift (`swift/extracted_dead_code.swift`)

| Source File | What Was Removed | Reason |
|-------------|-----------------|--------|
| `TerminalSurface.swift` | `refresh()`, `draw()`, `setOcclusion()`, `hasSelection()`, `getSelection()` + stub equivalents | Zero callers — Ghostty drives rendering via C callbacks |
| `GhosttyConfigController.swift` | `ensureIncludeBlock()`, `restoreMainFile()`, `restoreManagedFile()`, `changedKeys()` | Private/static methods with zero callers |
| `PnevmaBridge.swift` | `setSessionOutputCallback(_:ctx:)` | Public but never called; init sets callback directly |
| `ContentAreaView.swift` | `isZoomed` property | Zero callers anywhere |

### Rust (`rust/extracted_dead_code.rs`)

| Source File | What Was Removed | Reason |
|-------------|-----------------|--------|
| `pnevma-core/src/stories.rs` | `StoryDetector`, `DetectedStory`, `StoryStatus::as_str()`, regex helpers | Exported but never used outside the file |
| `pnevma-context/src/compiler.rs` | `ContextCompileMode::V1` variant + `compile_v1()` | V1 never constructed; entire code path unreachable |
| `pnevma-remote/src/lib.rs` | `RemoteServerHandle::wait()` | Zero callers anywhere |
| `pnevma-git/src/lib.rs` | `MergeQueue`, `HookSeverity` re-exports | Never imported outside crate |

## Other Cleanup

| Item | Action |
|------|--------|
| `frontend/node_modules/` (~150MB) | Deleted — orphaned after React/Tauri→Swift migration |

## Not Moved (test-only callers — kept for test coverage)

These items are only called from `#[cfg(test)]` / test targets but were kept in place
because removing them would require deleting or rewriting tests:

- `PaneLayoutEngine.resizeSplit(containing:delta:parentSize:)` — test-only
- `Workspace.closeTab(id:)` — test-only
- `ContentAreaView.paneCount` — test-only
- `StallDetector::stall_count()` — test-only
- `GlobalDb::path()` — test-only
- `AppState::new()` — test-only
- `current_runtime_redaction_settings()` — test-only
- `parse_ssh_config_str()` — test-only
- `ExecutionMode::as_str()`, `FailurePolicy::as_str()` — test-only
- `TrackerAdapter::fetch_states()` — trait method, all callers in tests
- `LeaseStatus::Released` — enum variant only set in tests
