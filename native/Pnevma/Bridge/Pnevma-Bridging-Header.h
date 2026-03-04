// Bridging header — imports the Rust FFI header and the Ghostty C API.
#include "../../crates/pnevma-bridge/pnevma-bridge.h"

// Ghostty library header — from vendor/ghostty/include/
// This file is produced by `just ghostty-build` which compiles ghostty via Zig
// and emits the XCFramework + header at vendor/ghostty/zig-out/lib/libghostty.xcframework
// and vendor/ghostty/include/ghostty.h respectively.
//
// The #include below is guarded at the preprocessor level: if the file does not
// exist yet (e.g. before the ghostty build step has run), the Swift compiler will
// fail with a clear error rather than silently producing a broken binary.
// Use `#if canImport(GhosttyKit)` in Swift files to guard ghostty-specific code.
#include "../../vendor/ghostty/include/ghostty.h"
