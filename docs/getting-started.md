# Getting Started

This guide gets a local source build running, then walks through the first workspace flow in the current native app.

## Prerequisites

1. Apple Silicon Mac running macOS 15+.
2. Rust via `rustup` using the repo-pinned toolchain in `rust-toolchain.toml`.
3. Zig matching `.zig-version`.
4. `just` (`brew install just`).
5. XcodeGen (`brew install xcodegen`).
6. Xcode 26+ with the macOS SDK. CI uses the `macos-26` runner line and the local build should match that toolchain baseline.
7. `git` on `PATH`.
8. At least one supported agent CLI on `PATH` (`claude-code` or `codex`).

## Bootstrap

From repo root:

```bash
# Installs the repo-pinned rustup toolchain if needed.
./scripts/bootstrap-dev.sh
just xcodegen
just build
just ghostty-smoke
```

`just build` generates the Xcode project if needed, builds the Rust bridge static library, builds the native Swift/AppKit app, and bundles the packaged remote helper artifacts into the app bundle. It does not use Tauri, npm, or a web frontend.

## Run The App

For interactive development, open the generated Xcode project and run the `Pnevma` scheme:

```bash
open native/Pnevma.xcodeproj
```

For command-line verification, use:

```bash
just xcode-build
just ghostty-smoke
```

## First Workspace Flow

Before you dispatch an agent: Pnevma isolates work by git worktree, not by OS sandbox. Agent commands still run with your user account's filesystem and network access.

1. Launch Pnevma and complete the first-launch setup panel if global config or scaffold files are missing.
2. Use the **Workspace Opener** to start from a local folder, prompt, GitHub issue, GitHub pull request, GitHub branch, or remote SSH target.
3. Initialize `pnevma.toml` and `.pnevma/` support files if prompted.
4. Review the workspace summary and **Task Board** so you know the current branch, task, and session state before dispatch.
5. Use the command palette (`Mod+K`) or the task board to create, draft, or dispatch work.
6. Monitor live execution in terminal panes, replay surfaces, and the surrounding tool chrome.
7. Use **Review**, diffs, checks, and the **Merge Queue** before merging finished work.

Useful shortcuts during this flow:

- `Mod+K`: command palette
- `Mod+Shift+K`: command center
- `Mod+Shift+N`: create task
- `Mod+Shift+D`: dispatch next ready task

## Quality gates

Before shipping changes:

```bash
just check
just spm-test-clean
just xcode-test
```

The `just` targets invoke the repo-pinned rustup toolchain directly, so local builds stay aligned with CI and the native linker sees a consistent Rust stdlib.

`just ghostty-smoke` is the required terminal-runtime gate. Placeholder rendering is not enough.

If your change touches the Swift/Rust boundary, packaged runtime behavior, SSH helper packaging, or release-affecting flows, run the additional build or smoke commands described in the release and operator docs.

## See also

- [Product Tour](./product-tour.md)
- [Architecture Overview](./architecture-overview.md)
- [`pnevma.toml` Reference](./pnevma-toml-reference.md)
- [Implementation Status](./implementation-status.md)
