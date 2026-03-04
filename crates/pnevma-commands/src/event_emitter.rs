use serde_json::Value;

/// Abstraction over event broadcasting — replaces Tauri's `AppHandle.emit()`.
/// The native macOS app will provide its own implementation that forwards events
/// to Swift via a C callback.
pub trait EventEmitter: Send + Sync + 'static {
    fn emit(&self, event: &str, payload: Value);
}

/// No-op emitter for tests and headless usage.
pub struct NullEmitter;

impl EventEmitter for NullEmitter {
    fn emit(&self, _event: &str, _payload: Value) {}
}
