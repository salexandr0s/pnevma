use pnevma_remote::RemoteEventEnvelope;
use serde_json::Value;
use std::sync::Arc;
use tokio::sync::broadcast;

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

/// Emitter wrapper that forwards events to the inner sink and to a broadcast
/// channel used by remote/WebSocket subscribers.
pub struct BroadcastingEmitter {
    inner: Arc<dyn EventEmitter>,
    remote_events: broadcast::Sender<RemoteEventEnvelope>,
}

impl BroadcastingEmitter {
    pub fn new(
        inner: Arc<dyn EventEmitter>,
        remote_events: broadcast::Sender<RemoteEventEnvelope>,
    ) -> Self {
        Self {
            inner,
            remote_events,
        }
    }
}

impl EventEmitter for BroadcastingEmitter {
    fn emit(&self, event: &str, payload: Value) {
        self.inner.emit(event, payload.clone());
        let _ = self.remote_events.send(RemoteEventEnvelope {
            event: event.to_string(),
            payload,
        });
    }
}
