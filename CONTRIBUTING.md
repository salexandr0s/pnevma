# Contributing to Pnevma

Thanks for your interest in contributing to Pnevma.

Pnevma is a native macOS application with a Swift/AppKit UI and a Rust backend. Keep contributions focused, testable, and aligned with the rule that workflow logic belongs in Rust rather than UI-side shortcuts.

## Development Setup

### Prerequisites

- Apple Silicon Mac running macOS 15+
- Rust via the repo-pinned toolchain
- Xcode 26+ with Command Line Tools
- [just](https://github.com/casey/just) (command runner)
- [XcodeGen](https://github.com/yonaskolb/XcodeGen)
- [Zig](https://ziglang.org/) (for building the Ghostty terminal dependency)
- `git`

### Getting Started

```bash
git clone https://github.com/salexandr0s/pnevma.git
cd pnevma
./scripts/bootstrap-dev.sh
just build
just ghostty-smoke
```

See [`docs/getting-started.md`](docs/getting-started.md) for detailed setup instructions.

## Build & Test Commands

```bash
just check        # fmt --check + clippy + tests + audit
just test         # cargo test + xcodebuild test
just xcode-build  # build the native macOS app
just xcode-test   # run native XCTest suites
just ghostty-smoke
```

Run `just check` before submitting a PR.

Also run the targeted native or packaged smoke gates when your change affects:

- the Swift/Rust FFI boundary
- Ghostty integration or terminal runtime behavior
- SSH helper packaging or remote durable session flows
- release packaging, signing, or notarization docs and scripts

## Making Changes

### Branches And Commits

Use a focused branch for a focused change. Descriptive names such as `feat/...`, `fix/...`, `docs/...`, or `refactor/...` are fine.

Commit messages should follow a conventional format:

```text
type(scope): short description
```

Common types:

- `feat(session): add scrollback persistence`
- `fix(bridge): handle nil config gracefully`
- `chore(ci): update Rust toolchain to 1.78`

### Code Style

- **Rust**: treat Rust as the system-of-record layer for workflow behavior, persistence, safety rules, and orchestration.
- **Swift**: preserve the thin-view-layer boundary. UI code should render state and forward intent, not reimplement backend logic.
- **Docs**: keep release, security, and operator claims aligned with the current repo truth.

## Pull Request Process

1. Create a focused branch from `main`.
2. Make your changes in small, focused commits
3. Run the required verification commands for the touched surface
4. Open a PR with a clear description of what changed and why
5. Update docs when behavior, UX, config, security posture, or release steps changed
6. Address review feedback

### PR Checklist

- [ ] `just check` passes
- [ ] Changes are covered by tests where applicable
- [ ] Native or packaged smoke gates were run when the touched surface required them
- [ ] No new `TODO`/`FIXME` without a linked issue
- [ ] Documentation updated if behavior changed

## Architecture Overview

Pnevma is a Rust workspace with a thin Swift/AppKit native layer:

- **Rust crates** (`pnevma-core`, `pnevma-session`, etc.) contain all business logic
- **Swift app** (`native/`) is the macOS UI, linked via FFI (`pnevma-bridge`)
- **Ghostty** (vendored) provides the terminal emulator

See [`docs/architecture-overview.md`](docs/architecture-overview.md) for details.

## Questions?

Open an issue or draft PR in [salexandr0s/pnevma](https://github.com/salexandr0s/pnevma).
