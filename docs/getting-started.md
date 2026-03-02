# Getting Started

## Prerequisites

1. Rust toolchain (stable).
2. Node.js + npm.
3. `cargo-tauri`:

```bash
cargo install tauri-cli
```

4. At least one supported agent CLI on `PATH` (`claude` or `codex`).
5. `git` available on `PATH`.

## Bootstrap

From repo root:

```bash
./scripts/bootstrap-dev.sh
cargo build --workspace
cd frontend && npm install
```

## Run the app

From repo root:

```bash
cargo tauri dev --manifest-path crates/pnevma-app/Cargo.toml
```

## First project flow

1. Use the **First Launch Setup** panel.
2. Enter project path.
3. Click `Initialize Global Config` if needed.
4. Click `Initialize Project Scaffold` to create:
   - `pnevma.toml`
   - `.pnevma/` directories
   - seed rules/conventions markdown files
5. Click `Open Project`.
6. Use command palette (`Mod+K`) to draft/create tasks.
7. Dispatch a ready task and follow review/merge.

## Quality gates

Before shipping changes:

```bash
cargo fmt --all
cargo check --workspace
cargo clippy --workspace --all-targets -- -D warnings
cargo test --workspace
cd frontend && npx tsc --noEmit && npx eslint . && npx vite build
```
