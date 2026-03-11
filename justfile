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
native_log_dir := "native/build/logs"
xcode_derived_data := "native/DerivedData"

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
    @echo "Building Ghostty xcframework..."
    ./scripts/fetch-ghostty.sh
    cd vendor/ghostty && zig build -Demit-xcframework=true -Doptimize=ReleaseFast
    @echo "Ghostty xcframework built at vendor/ghostty/macos/GhosttyKit.xcframework"

# ── Stage 2: Rust staticlib (Cargo) ──────────────────────────────────────────

rust-check:
    {{rust_tool}} cargo fmt --check
    {{rust_tool}} cargo clippy --workspace --all-targets -- -D warnings

rust-build:
    @echo "Building Rust staticlib..."
    {{rust_tool}} cargo build -p pnevma-bridge --target {{rust_target}}
    @echo "Rust staticlib built"

rust-build-release:
    @echo "Building Rust staticlib (release)..."
    {{rust_tool}} cargo build -p pnevma-bridge --target {{rust_target}} --release
    @echo "Rust staticlib built (release)"

rust-test:
    {{rust_tool}} cargo test --workspace

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

# ── Stage 3: Xcode (Swift) ───────────────────────────────────────────────────

# Generate .xcodeproj from native/project.yml using xcodegen
xcodegen:
    @echo "Generating Xcode project from native/project.yml..."
    @if ! command -v xcodegen &>/dev/null; then \
      echo "ERROR: xcodegen not found. Install with: brew install xcodegen"; exit 1; \
    fi
    cd native && xcodegen generate --spec project.yml --project .
    @echo "Generated native/Pnevma.xcodeproj"

# Note: xcode-build depends on rust-build completing first
xcode-build: xcodegen rust-build
    @echo "Building native macOS app..."
    mkdir -p {{native_log_dir}}
    {{clean_log}} --log {{native_log_dir}}/xcode-build.log -- xcodebuild -project {{xcode_project}} -scheme {{xcode_scheme}} -configuration Debug -destination {{xcode_destination}} -derivedDataPath {{xcode_derived_data}} SYMROOT="$PWD/native/build" CODE_SIGNING_ALLOWED=NO ONLY_ACTIVE_ARCH=YES build
    @echo "Native app built"

xcode-build-release: xcodegen rust-build-release
    @echo "Building native macOS app (release)..."
    mkdir -p {{native_log_dir}}
    {{clean_log}} --log {{native_log_dir}}/xcode-build-release.log -- xcodebuild -project {{xcode_project}} -scheme {{xcode_scheme}} -configuration Release -destination {{xcode_destination}} -derivedDataPath {{xcode_derived_data}} SYMROOT="$PWD/native/build" CODE_SIGNING_ALLOWED=NO ONLY_ACTIVE_ARCH=YES build
    @echo "Native app built (release)"

xcode-test: xcodegen rust-build
    rm -rf {{xcode_derived_data}}
    rm -rf native/build/Debug
    mkdir -p {{native_log_dir}}
    {{clean_log}} --log {{native_log_dir}}/xcode-test.log -- xcodebuild -project {{xcode_project}} -scheme {{xcode_test_scheme}} -destination {{xcode_destination}} -derivedDataPath {{xcode_derived_data}} SYMROOT="$PWD/native/build" CODE_SIGNING_ALLOWED=NO ONLY_ACTIVE_ARCH=YES test

xcode-ui-test: xcodegen rust-build
    mkdir -p {{native_log_dir}}
    {{clean_log}} --log {{native_log_dir}}/xcode-ui-test.log -- xcodebuild -project {{xcode_project}} -scheme PnevmaUITests -destination {{xcode_destination}} -derivedDataPath {{xcode_derived_data}} CODE_SIGN_IDENTITY=- ENABLE_HARDENED_RUNTIME=NO test

# SPM build path (alternative to xcodebuild)
spm-build: rust-build
    @echo "Building via Swift Package Manager..."
    cd native && swift build -c debug
    @echo "SPM build complete"

spm-test: rust-build
    @echo "Running tests via Swift Package Manager..."
    cd native && swift test
    @echo "SPM tests complete"

spm-test-clean: rust-build
    @echo "Running clean Swift Package Manager test gate..."
    mkdir -p {{native_log_dir}}
    {{clean_log}} --log {{native_log_dir}}/swift-test.log -- zsh -lc 'cd native && swift test'
    @echo "SPM tests complete"

ghostty-smoke: ghostty-build xcode-build
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
    @echo "Running E2E smoke test..."
    ./scripts/ipc-e2e-smoke.sh
    @echo "Running E2E recovery test..."
    ./scripts/ipc-e2e-recovery.sh
    @echo "All tests passed"

# Clean all build artifacts
clean:
    cargo clean
    rm -rf native/build/
    @echo "Cleaned"

# ── Utilities ────────────────────────────────────────────────────────────────

# Check FFI coverage — RPC command routes vs bridge exports
ffi-coverage:
    @echo "Checking FFI command coverage..."
    @./scripts/check-ffi-coverage.sh

# Format all code
fmt:
    {{rust_tool}} cargo fmt
    @echo "Formatted"
