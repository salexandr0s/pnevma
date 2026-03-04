# Pnevma v2 — Build Orchestration
# Three-stage build: Ghostty (Zig) → Rust staticlib (Cargo) → Xcode (Swift)

set shell := ["zsh", "-cu"]

# Default target
default: build

# ── Configuration ──────────────────────────────────────────────────────────────

rust_target := "aarch64-apple-darwin"
build_mode := "debug"
xcode_scheme := "Pnevma"
xcode_project := "native/Pnevma.xcodeproj"

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
    cd vendor/ghostty && zig build -Demit-xcframework=true -Doptimize=ReleaseFast
    @echo "Ghostty xcframework built at vendor/ghostty/zig-out/"

# ── Stage 2: Rust staticlib (Cargo) ──────────────────────────────────────────

rust-check:
    cargo fmt --check
    cargo clippy --workspace --all-targets -- -D warnings

rust-build:
    @echo "Building Rust staticlib..."
    cargo build -p pnevma-bridge --target {{rust_target}}
    @echo "Rust staticlib built"

rust-build-release:
    @echo "Building Rust staticlib (release)..."
    cargo build -p pnevma-bridge --target {{rust_target}} --release
    @echo "Rust staticlib built (release)"

rust-test:
    cargo test --workspace

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
xcode-build: rust-build
    @echo "Building native macOS app..."
    xcodebuild -project {{xcode_project}} -scheme {{xcode_scheme}} -configuration Debug build
    @echo "Native app built"

xcode-build-release: rust-build-release
    @echo "Building native macOS app (release)..."
    xcodebuild -project {{xcode_project}} -scheme {{xcode_scheme}} -configuration Release build
    @echo "Native app built (release)"

xcode-test:
    xcodebuild -project {{xcode_project}} -scheme {{xcode_scheme}} test

# SPM build path (alternative to xcodebuild)
spm-build: rust-build
    @echo "Building via Swift Package Manager..."
    cd native && swift build -c debug
    @echo "SPM build complete"

spm-test: rust-build
    @echo "Running tests via Swift Package Manager..."
    cd native && swift test
    @echo "SPM tests complete"

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
check: rust-check rust-test
    @echo "All checks passed"

# Run all tests
test: rust-test xcode-test
    @echo "All tests passed"

# Clean all build artifacts
clean:
    cargo clean
    rm -rf native/build/
    @echo "Cleaned"

# ── Utilities ────────────────────────────────────────────────────────────────

# Check FFI coverage — tauri commands vs bridge exports
ffi-coverage:
    @echo "Checking FFI command coverage..."
    @./scripts/check-ffi-coverage.sh

# Format all code
fmt:
    cargo fmt
    @echo "Formatted"
