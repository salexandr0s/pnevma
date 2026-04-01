# Pnevma v2 — Build Orchestration
# Three-stage build: Ghostty (Zig) → Rust staticlib (Cargo) → Xcode (Swift)

set shell := ["zsh", "-cu"]

# Default target
default: build

# ── Configuration ──────────────────────────────────────────────────────────────

rust_target := "aarch64-apple-darwin"
build_mode := "debug"
xcode_scheme := "Pnevma"
xcode_test_scheme := "PnevmaTests"
xcode_project := "native/Pnevma.xcodeproj"
xcode_destination := "'platform=macOS,arch=arm64'"
rust_tool := "./scripts/with-rust-toolchain.sh"
clean_log := "./scripts/assert-clean-command-log.sh"
native_env_tool := "./scripts/prepare-native-build-env.sh"
native_lock_tool := "./scripts/with-native-build-lock.sh"
native_log_dir := "native/build/logs"
xcode_derived_data := "native/DerivedData"
ghostty_xcframework_target := env_var_or_default("GHOSTTY_XCFRAMEWORK_TARGET", "native")

# ── Stage 1: Ghostty xcframework (Zig) ────────────────────────────────────────

ghostty-check:
    @echo "Checking Zig version..."
    @if [ ! -f .zig-version ]; then echo "ERROR: .zig-version not found"; exit 1; fi
    @expected=$(cat .zig-version); \
     actual=$(zig version 2>/dev/null || echo "not-found"); \
     if [ "$actual" != "$expected" ]; then \
       echo "ERROR: Expected Zig $expected, got $actual"; \
       exit 1; \
     fi

ghostty-build: ghostty-check
    @echo "Building Ghostty xcframework (target={{ghostty_xcframework_target}})..."
    mkdir -p {{native_log_dir}}
    ./scripts/fetch-ghostty.sh
    @if [ -d vendor/ghostty/.zig-cache ]; then find vendor/ghostty/.zig-cache -mindepth 1 -delete; fi
    log="$PWD/{{native_log_dir}}/ghostty-build.log"; \
      cd vendor/ghostty; \
      set -o pipefail; \
      zig build -Demit-xcframework=true -Dxcframework-target={{ghostty_xcframework_target}} -Doptimize=ReleaseFast 2>&1 | tee "$log"
    python3 ./scripts/normalize-static-archive.py vendor/ghostty/macos/GhosttyKit.xcframework/macos-arm64/libghostty-fat.a
    python3 ./scripts/normalize-ghostty-modulemap.py vendor/ghostty/macos/GhosttyKit.xcframework/macos-arm64/Headers/module.modulemap
    @echo "Ghostty xcframework built at vendor/ghostty/macos/GhosttyKit.xcframework"

# ── Stage 2: Rust staticlib (Cargo) ──────────────────────────────────────────

rust-check:
    {{rust_tool}} cargo fmt --check
    {{rust_tool}} cargo clippy --workspace --all-targets -- -D warnings

rust-build:
    @echo "Building Rust staticlib..."
    {{rust_tool}} cargo build -p pnevma-bridge --target {{rust_target}}
    @echo "Building session proxy..."
    {{rust_tool}} cargo build -p pnevma-session --bin pnevma-session-proxy --target {{rust_target}}
    @echo "Building remote helper..."
    {{rust_tool}} cargo build -p pnevma-remote-helper --target {{rust_target}}
    @echo "Rust staticlib built"

rust-build-release:
    @echo "Building Rust staticlib (release)..."
    {{rust_tool}} cargo build -p pnevma-bridge --target {{rust_target}} --release
    @echo "Building session proxy (release)..."
    {{rust_tool}} cargo build -p pnevma-session --bin pnevma-session-proxy --target {{rust_target}} --release
    @echo "Building remote helper (release)..."
    {{rust_tool}} cargo build -p pnevma-remote-helper --target {{rust_target}} --release
    @echo "Rust staticlib built (release)"

remote-helper-build:
    @echo "Building remote helper artifacts..."
    ./scripts/build-remote-helper-artifacts.sh
    @echo "Remote helper artifacts built"

remote-helper-build-release:
    @echo "Building remote helper artifacts (release)..."
    ./scripts/build-remote-helper-artifacts.sh --release
    @echo "Remote helper artifacts built (release)"

rust-test:
    {{rust_tool}} cargo test --workspace --exclude pnevma-bridge
    {{rust_tool}} cargo test -p pnevma-bridge -- --test-threads=1

rust-audit:
    @if command -v cargo-audit >/dev/null 2>&1 || {{rust_tool}} cargo audit --version >/dev/null 2>&1; then \
      {{rust_tool}} cargo audit; \
    else \
      echo "WARNING: cargo-audit not installed — skipping vulnerability scan"; \
      echo "Install with: cargo install cargo-audit --locked"; \
      exit 1; \
    fi

migration-checksums:
    ./scripts/check-migration-checksums.sh

release-version-check:
    ./scripts/release-version.sh check

release-signed-candidate:
    ./scripts/release-signed-candidate.sh

release-entitlement-probe:
    ./scripts/probe-disable-library-validation.sh

release-remote-validation:
    ./scripts/release-remote-validation.sh

release-ci-green-runs:
    ./scripts/release-ci-green-runs.sh

migration-checksums-update:
    ./scripts/update-migration-checksums.sh

# ── Stage 3: Xcode (Swift) ───────────────────────────────────────────────────

# Generate .xcodeproj from native/project.yml using xcodegen
xcodegen:
    @echo "Generating Xcode project from native/project.yml..."
    @if ! command -v xcodegen &>/dev/null; then \
      echo "ERROR: xcodegen not found. Install with: brew install xcodegen"; exit 1; \
    fi
    cd native && xcodegen generate --spec project.yml --project .
    @echo "Generated native/Pnevma.xcodeproj"

xcodegen-check: xcodegen
    @echo "Verifying generated Xcode project is in sync..."
    git diff --exit-code -- native/Pnevma.xcodeproj
    @echo "Xcode project is in sync"

# Note: xcode-build depends on rust-build completing first
xcode-build: xcodegen rust-build
    @echo "Building native macOS app..."
    {{native_lock_tool}} xcode-build zsh -lc '{{native_env_tool}} {{xcode_derived_data}} && {{clean_log}} --log {{native_log_dir}}/xcode-build.log -- xcodebuild -project {{xcode_project}} -scheme {{xcode_scheme}} -configuration Debug -destination {{xcode_destination}} -derivedDataPath {{xcode_derived_data}} SYMROOT="$PWD/native/build" CODE_SIGNING_ALLOWED=NO ONLY_ACTIVE_ARCH=YES build'
    app_path="$PWD/native/build/Debug/Pnevma.app"; \
      if [ ! -d "$app_path" ]; then app_path="$PWD/native/build/Build/Products/Debug/Pnevma.app"; fi; \
      test -d "$app_path"; \
      ./scripts/build-remote-helper-artifacts.sh --bundle-app "$app_path"
    @echo "Native app built"

xcode-build-release: xcodegen rust-build-release
    @echo "Building native macOS app (release)..."
    {{native_lock_tool}} xcode-build-release zsh -lc '{{native_env_tool}} {{xcode_derived_data}} && {{clean_log}} --log {{native_log_dir}}/xcode-build-release.log -- xcodebuild -project {{xcode_project}} -scheme {{xcode_scheme}} -configuration Release -destination {{xcode_destination}} -derivedDataPath {{xcode_derived_data}} SYMROOT="$PWD/native/build" CODE_SIGNING_ALLOWED=NO ONLY_ACTIVE_ARCH=YES build'
    app_path="$PWD/native/build/Release/Pnevma.app"; \
      if [ ! -d "$app_path" ]; then app_path="$PWD/native/build/Build/Products/Release/Pnevma.app"; fi; \
      test -d "$app_path"; \
      ./scripts/build-remote-helper-artifacts.sh --release --bundle-app "$app_path"
    @echo "Native app built (release)"

xcode-test: xcodegen rust-build
    {{native_lock_tool}} xcode-test zsh -lc '{{native_env_tool}} {{xcode_derived_data}} && rm -rf native/build/Debug && {{clean_log}} --log {{native_log_dir}}/xcode-test.log -- xcodebuild -project {{xcode_project}} -scheme {{xcode_test_scheme}} -destination {{xcode_destination}} -derivedDataPath {{xcode_derived_data}} SYMROOT="$PWD/native/build" CODE_SIGNING_ALLOWED=NO ONLY_ACTIVE_ARCH=YES test'

xcode-ui-test: xcodegen rust-build
    {{native_lock_tool}} xcode-ui-test zsh -lc '{{native_env_tool}} {{xcode_derived_data}} && {{clean_log}} --log {{native_log_dir}}/xcode-ui-test.log -- caffeinate -dimu -t 7200 xcodebuild -project {{xcode_project}} -scheme PnevmaUITests -destination {{xcode_destination}} -derivedDataPath {{xcode_derived_data}} CODE_SIGN_IDENTITY=- ENABLE_HARDENED_RUNTIME=NO test'

# SPM build path (alternative to xcodebuild)
spm-build: rust-build
    @echo "Building via Swift Package Manager..."
    @if [ ! -d vendor/ghostty/macos/GhosttyKit.xcframework ]; then just ghostty-build; fi
    cd native && swift build -c debug
    @echo "SPM build complete"

spm-test: rust-build
    @echo "Running tests via Swift Package Manager..."
    @if [ ! -d vendor/ghostty/macos/GhosttyKit.xcframework ]; then just ghostty-build; fi
    cd native && swift test
    @echo "SPM tests complete"

spm-test-clean: rust-build
    @echo "Running clean Swift Package Manager test gate..."
    @if [ ! -d vendor/ghostty/macos/GhosttyKit.xcframework ]; then just ghostty-build; fi
    rm -rf native/.build
    mkdir -p {{native_log_dir}}
    {{clean_log}} --log {{native_log_dir}}/swift-test.log -- zsh -lc 'cd native && swift test'
    @echo "SPM tests complete"

ghostty-smoke: xcode-build
    @if [ ! -d vendor/ghostty/macos/GhosttyKit.xcframework ]; then       echo "error: missing vendor/ghostty/macos/GhosttyKit.xcframework; run just ghostty-build first" >&2;       exit 1;     fi
    @echo "Running Ghostty runtime smoke..."
    ./scripts/run-ghostty-smoke.sh
    @echo "Ghostty smoke passed"

# ── Composite targets ────────────────────────────────────────────────────────

# Full debug build (stages run sequentially as needed)
build: rust-build xcode-build
    @echo "Build complete"

# Full release build
release: rust-build-release xcode-build-release
    @echo "Release build complete"

# Development mode — just Rust + app, skip Ghostty rebuild
dev: rust-build xcode-build
    @echo "Dev build complete"

# Run all checks
check: rust-check rust-test rust-audit migration-checksums
    @echo "All checks passed"

# Run all tests
test: rust-test xcode-test
    @echo "All tests passed"

# Run all tests including E2E
test-all: rust-test xcode-test
    @echo "Running self-bootstrapping IPC E2E harness..."
    ./scripts/run-ipc-e2e-with-app.sh
    @echo "All tests passed"

workflow-check:
    @echo "Running GitHub workflow parity checks..."
    ./scripts/run-gitleaks.sh --working-tree
    @if ! command -v shellcheck >/dev/null 2>&1; then \
      echo "ERROR: shellcheck not found. Install with: brew install shellcheck"; exit 1; \
    fi
    shellcheck -x scripts/*.sh scripts/fixtures/remote-helper/*.sh
    @if ! command -v actionlint >/dev/null 2>&1; then \
      echo "ERROR: actionlint not found. Install with: brew install actionlint"; exit 1; \
    fi
    actionlint
    ./scripts/install-zig-ci.sh --verify-only
    just release-version-check
    just check
    @echo "Workflow parity checks passed"

ci-local: workflow-check
    @echo "CI-local checks passed"

# Clean all build artifacts
clean:
    cargo clean
    rm -rf artifacts/remote-helper/
    rm -rf native/build/
    @echo "Cleaned"

# ── Utilities ────────────────────────────────────────────────────────────────

# Check FFI coverage — RPC command routes vs bridge exports
ffi-coverage:
    @echo "Checking FFI command coverage..."
    @./scripts/check-ffi-coverage.sh

# Code coverage report
coverage:
    cargo llvm-cov --workspace --html --output-dir target/coverage
    @echo "Coverage report: target/coverage/html/index.html"

# Format all code
fmt:
    {{rust_tool}} cargo fmt
    @echo "Formatted"
