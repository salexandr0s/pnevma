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
        // Local FFI path: no redaction needed (stays within process).
        self.inner.emit(event, payload.clone());
        // Remote path: redact secrets before broadcasting to WebSocket subscribers.
        let redacted_payload = pnevma_redaction::redact_json_value(payload, &[]);
        let _ = self.remote_events.send(RemoteEventEnvelope {
            event: event.to_string(),
            payload: redacted_payload,
        });
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::atomic::{AtomicU64, Ordering};

    struct CountingEmitter(AtomicU64);
    impl EventEmitter for CountingEmitter {
        fn emit(&self, _event: &str, _payload: Value) {
            self.0.fetch_add(1, Ordering::SeqCst);
        }
    }

    #[test]
    fn remote_payload_is_redacted() {
        let inner = Arc::new(CountingEmitter(AtomicU64::new(0)));
        let (tx, mut rx) = broadcast::channel(8);
        let emitter = BroadcastingEmitter::new(inner.clone(), tx);

        let secret_payload = serde_json::json!({
            "output": "export OPENAI_API_KEY=sk-proj-aBcDeFgHiJkLmNoPqRsT1234567890abcdef"
        });
        emitter.emit("session_output", secret_payload);

        let envelope = rx.try_recv().expect("should receive event");
        let output = envelope.payload["output"].as_str().unwrap();
        assert!(
            !output.contains("sk-proj-"),
            "secret should be redacted in remote payload"
        );
        assert_eq!(
            inner.0.load(Ordering::SeqCst),
            1,
            "local emitter should still be called"
        );
    }
}
