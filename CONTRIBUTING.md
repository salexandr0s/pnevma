# Contributing to Pnevma

Thanks for your interest in contributing to Pnevma! This guide will help you get started.

## Development Setup

### Prerequisites

- macOS (Pnevma is a native macOS application)
- Rust (latest stable)
- Xcode 15+ with Command Line Tools
- [just](https://github.com/casey/just) (command runner)
- [Zig](https://ziglang.org/) (for building the Ghostty terminal dependency)

### Getting Started

```bash
git clone https://github.com/pnevma/pnevma.git
cd pnevma
./scripts/bootstrap-dev.sh
just build
```

See [`docs/getting-started.md`](docs/getting-started.md) for detailed setup instructions.

## Build & Test Commands

```bash
just check        # fmt --check + clippy + tests + audit
just test         # cargo test + xcodebuild test
just xcode-build  # build the native macOS app
cargo fmt         # format Rust code
cargo clippy      # lint Rust code
```

Run `just check` before submitting a PR.

## Making Changes

### Branch Naming

- `feat/short-description` — new features
- `fix/short-description` — bug fixes
- `chore/short-description` — maintenance, docs, CI

### Commit Messages

Follow the conventional commit format:

```
type(scope): short description
```

**Types**: `feat`, `fix`, `chore`, `refactor`, `test`, `docs`, `style`, `perf`

**Examples**:
- `feat(session): add scrollback persistence`
- `fix(bridge): handle nil config gracefully`
- `chore(ci): update Rust toolchain to 1.78`

### Code Style

- **Rust**: Run `cargo fmt` before committing. Follow standard Rust conventions.
- **Swift**: Follow AppKit conventions. The Swift layer is intentionally thin — all workflow logic lives in Rust.

## Pull Request Process

1. Create a feature branch from `main`
2. Make your changes in small, focused commits
3. Run `just check` and ensure all checks pass
4. Open a PR with a clear description of what and why
5. Address review feedback

### PR Checklist

- [ ] `just check` passes
- [ ] Changes are covered by tests where applicable
- [ ] No new `TODO`/`FIXME` without a linked issue
- [ ] Documentation updated if behavior changed

## Architecture Overview

Pnevma is a Rust workspace with a thin Swift/AppKit native layer:

- **Rust crates** (`pnevma-core`, `pnevma-session`, etc.) contain all business logic
- **Swift app** (`native/`) is the macOS UI, linked via FFI (`pnevma-bridge`)
- **Ghostty** (vendored) provides the terminal emulator

See [`docs/architecture-overview.md`](docs/architecture-overview.md) for details.

## Questions?

Open a [discussion](https://github.com/pnevma/pnevma/discussions) or file an issue.
