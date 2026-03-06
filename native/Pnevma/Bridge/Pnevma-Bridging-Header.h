// Bridging header — imports the Rust FFI header and the Ghostty C API.
#include "../../../crates/pnevma-bridge/pnevma-bridge.h"

// Ghostty library header — from the vendored Ghostty source tree.
// `just ghostty-build` compiles the xcframework at
// vendor/ghostty/macos/GhosttyKit.xcframework, and the vendored checkout
// provides the matching C header at vendor/ghostty/include/ghostty.h.
//
// The #include below is guarded at the preprocessor level: if the file does not
// exist yet (e.g. before the ghostty build step has run), the Swift compiler will
// fail with a clear error rather than silently producing a broken binary.
// Use `#if canImport(GhosttyKit)` in Swift files to guard ghostty-specific code.
#if __has_include("../../../vendor/ghostty/include/ghostty.h")
#include "../../../vendor/ghostty/include/ghostty.h"
#endif
