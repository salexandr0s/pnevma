# Getting Started

## Prerequisites

1. Rust via `rustup` using the repo-pinned toolchain in `rust-toolchain.toml`.
2. Zig matching `.zig-version`.
3. `just` (`brew install just`).
4. XcodeGen (`brew install xcodegen`).
5. Xcode 26+ with the macOS SDK (CI uses `macos-26` runners).
6. `git` on `PATH`.
7. At least one supported agent CLI on `PATH` (`claude-code` or `codex`).

## Bootstrap

From repo root:

```bash
# Installs the repo-pinned rustup toolchain if needed.
./scripts/bootstrap-dev.sh
just xcodegen
just build
just ghostty-smoke
```

`just build` compiles the Rust bridge static library and the native Swift/AppKit app. It does not use Tauri, npm, or a web frontend.

## Run the app

For interactive development, open the generated Xcode project and run the `Pnevma` scheme:

```bash
open native/Pnevma.xcodeproj
```

For command-line verification, use:

```bash
just xcode-build
just ghostty-smoke
```

## First project flow

Before you dispatch an agent: Pnevma isolates work by git worktree, not by OS sandbox. Agent commands still run with your user account's filesystem and network access.

1. Launch Pnevma and use the first-launch setup panel if global config or scaffold files are missing.
2. Open a repository root.
3. Initialize `pnevma.toml` and `.pnevma/` support files if prompted.
4. Use the command palette (`Mod+K`) to create or draft tasks.
5. Dispatch a ready task and review live progress in the task board and pane layout.
6. Review the resulting diff, checks, and review pack before merge.

## Quality gates

Before shipping changes:

```bash
just check
just spm-test-clean
just xcode-test
```

The `just` targets invoke the repo-pinned rustup toolchain directly, so local builds stay aligned with CI and the native linker sees a consistent Rust stdlib. `just ghostty-smoke` is the required terminal-runtime gate; placeholder rendering does not satisfy it.

## See also

- [Architecture Overview](./architecture-overview.md)
- [`pnevma.toml` Reference](./pnevma-toml-reference.md)
- [Implementation Status](./implementation-status.md)
