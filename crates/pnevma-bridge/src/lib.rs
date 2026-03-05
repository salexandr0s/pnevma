//! C-ABI FFI bridge for the Pnevma native macOS app.
//!
//! This crate provides a staticlib that Swift code links against.
//! All public functions are `extern "C"` with `catch_unwind` safety.

use pnevma_commands::event_emitter::EventEmitter;
use pnevma_commands::state::AppState;
use pnevma_commands::{route_method, NullEmitter};
use serde_json::Value;
use std::ffi::{CStr, CString};
use std::os::raw::c_char;
use std::panic::{self, AssertUnwindSafe};
use std::ptr;
use std::sync::Arc;
use tokio::runtime::Runtime;

// ---------------------------------------------------------------------------
// Types matching pnevma-bridge.h
// ---------------------------------------------------------------------------

/// Callback for Rust→Swift event forwarding.
type EventCallback = extern "C" fn(event: *const c_char, payload_json: *const c_char, ctx: *mut ());

/// Callback for async call completion.
type AsyncCallback = extern "C" fn(result: *const PnevmaResult, ctx: *mut ());

/// Callback for high-frequency session PTY output.
type SessionOutputCallback =
    extern "C" fn(session_id: *const c_char, data: *const u8, len: usize, ctx: *mut ());

/// Result struct returned by synchronous FFI calls.
#[repr(C)]
pub struct PnevmaResult {
    pub ok: i32,
    pub data: *const c_char,
    pub len: usize,
}

/// Opaque handle holding all Pnevma runtime state.
pub struct PnevmaHandle {
    runtime: Runtime,
    state: Arc<AppState>,
    _session_output_cb: std::sync::Mutex<Option<SessionOutputCallbackWrapper>>,
}

// Wrappers to make callback pointers Send+Sync (they cross FFI boundary)
struct EventCallbackWrapper {
    cb: EventCallback,
    ctx: *mut (),
}
unsafe impl Send for EventCallbackWrapper {}
unsafe impl Sync for EventCallbackWrapper {}

struct SessionOutputCallbackWrapper {
    _cb: SessionOutputCallback,
    _ctx: *mut (),
}
unsafe impl Send for SessionOutputCallbackWrapper {}
unsafe impl Sync for SessionOutputCallbackWrapper {}

// ---------------------------------------------------------------------------
// FFI EventEmitter implementation
// ---------------------------------------------------------------------------

/// EventEmitter that forwards events to Swift via the C callback.
struct FfiEventEmitter {
    inner: EventCallbackWrapper,
}

impl EventEmitter for FfiEventEmitter {
    fn emit(&self, event: &str, payload: Value) {
        let event_cstr = match CString::new(event) {
            Ok(s) => s,
            Err(_) => return,
        };
        let payload_str = payload.to_string();
        let payload_cstr = match CString::new(payload_str) {
            Ok(s) => s,
            Err(_) => return,
        };
        (self.inner.cb)(event_cstr.as_ptr(), payload_cstr.as_ptr(), self.inner.ctx);
    }
}

// ---------------------------------------------------------------------------
// Helper: allocate a PnevmaResult on the heap
// ---------------------------------------------------------------------------

fn make_result(ok: bool, data: &str) -> *mut PnevmaResult {
    let cstr = CString::new(data).unwrap_or_else(|_| CString::new("").unwrap());
    let len = cstr.as_bytes().len();
    let ptr = cstr.into_raw();
    Box::into_raw(Box::new(PnevmaResult {
        ok: if ok { 1 } else { 0 },
        data: ptr,
        len,
    }))
}

fn make_error_result(msg: &str) -> *mut PnevmaResult {
    make_result(false, msg)
}

// ---------------------------------------------------------------------------
// FFI exports
// ---------------------------------------------------------------------------

/// Create a new Pnevma runtime handle.
///
/// `cb` receives all Rust-emitted events (e.g. "task_updated", "session_output").
/// `ctx` is an opaque pointer forwarded to every callback invocation.
///
/// Returns NULL on failure. The caller must eventually call `pnevma_destroy`.
#[no_mangle]
#[allow(clippy::not_unsafe_ptr_arg_deref)]
pub extern "C" fn pnevma_create(cb: EventCallback, ctx: *mut ()) -> *mut PnevmaHandle {
    let result = panic::catch_unwind(|| {
        // Build tokio runtime
        let runtime = match Runtime::new() {
            Ok(rt) => rt,
            Err(_) => return ptr::null_mut(),
        };

        // Create emitter
        let emitter: Arc<dyn EventEmitter> = if cb as usize == 0 {
            Arc::new(NullEmitter)
        } else {
            Arc::new(FfiEventEmitter {
                inner: EventCallbackWrapper { cb, ctx },
            })
        };

        let state = Arc::new(AppState::new(emitter));

        // Start background services
        let state_clone = Arc::clone(&state);
        runtime.spawn(async move {
            pnevma_commands::auto_dispatch::start_auto_dispatch(state_clone);
        });
        let state_clone = Arc::clone(&state);
        runtime.spawn(async move {
            pnevma_commands::cost_aggregation::start_cost_aggregation(state_clone);
        });

        Box::into_raw(Box::new(PnevmaHandle {
            runtime,
            state,
            _session_output_cb: std::sync::Mutex::new(None),
        }))
    });

    result.unwrap_or(ptr::null_mut())
}

/// Destroy a Pnevma handle, shutting down all background tasks.
///
/// After this call, the handle pointer is invalid.
#[no_mangle]
#[allow(clippy::not_unsafe_ptr_arg_deref)]
pub extern "C" fn pnevma_destroy(handle: *mut PnevmaHandle) {
    if handle.is_null() {
        return;
    }
    let _ = panic::catch_unwind(AssertUnwindSafe(|| {
        let handle = unsafe { Box::from_raw(handle) };
        // Runtime drops here, cancelling all spawned tasks
        drop(handle);
    }));
}

/// Synchronous RPC call. Blocks until the command completes.
///
/// **Must be called from a background thread** — never from the main thread.
///
/// Returns a heap-allocated `PnevmaResult`. Caller must free with `pnevma_free_result`.
#[no_mangle]
#[allow(clippy::not_unsafe_ptr_arg_deref)]
pub extern "C" fn pnevma_call(
    handle: *mut PnevmaHandle,
    method: *const c_char,
    params_json: *const c_char,
    params_len: usize,
) -> *mut PnevmaResult {
    if handle.is_null() || method.is_null() {
        return make_error_result("null handle or method");
    }

    let result = panic::catch_unwind(AssertUnwindSafe(|| {
        let handle = unsafe { &*handle };

        let method_str = match unsafe { CStr::from_ptr(method) }.to_str() {
            Ok(s) => s,
            Err(_) => return make_error_result("invalid UTF-8 in method"),
        };

        let params: Value = if params_json.is_null() {
            Value::Object(serde_json::Map::new())
        } else {
            let slice = unsafe { std::slice::from_raw_parts(params_json as *const u8, params_len) };
            match std::str::from_utf8(slice) {
                Ok(s) => serde_json::from_str(s).unwrap_or(Value::Object(serde_json::Map::new())),
                Err(_) => return make_error_result("invalid UTF-8 in params"),
            }
        };

        let state = &handle.state;
        match handle
            .runtime
            .block_on(route_method(state, method_str, &params))
        {
            Ok(val) => make_result(true, &val.to_string()),
            Err((_code, msg)) => make_error_result(&msg),
        }
    }));

    result.unwrap_or_else(|_| make_error_result("panic in pnevma_call"))
}

/// Asynchronous RPC call. Returns immediately; the callback is invoked on
/// completion from a background thread.
///
/// The `PnevmaResult*` passed to the callback is valid only for the duration
/// of the callback. Copy any data you need before returning. The result is
/// freed automatically by Rust after the callback returns — do NOT call
/// `pnevma_free_result` on it.
#[no_mangle]
#[allow(clippy::not_unsafe_ptr_arg_deref)]
pub extern "C" fn pnevma_call_async(
    handle: *mut PnevmaHandle,
    method: *const c_char,
    params_json: *const c_char,
    params_len: usize,
    cb: AsyncCallback,
    cb_ctx: *mut (),
) {
    if handle.is_null() || method.is_null() {
        return;
    }

    let _ = panic::catch_unwind(AssertUnwindSafe(|| {
        let handle = unsafe { &*handle };

        let method_str = match unsafe { CStr::from_ptr(method) }.to_str() {
            Ok(s) => s.to_owned(),
            Err(_) => {
                let r = make_error_result("invalid UTF-8 in method");
                cb(r, cb_ctx);
                unsafe { pnevma_free_result(r) };
                return;
            }
        };

        let params: Value = if params_json.is_null() {
            Value::Object(serde_json::Map::new())
        } else {
            let slice = unsafe { std::slice::from_raw_parts(params_json as *const u8, params_len) };
            match std::str::from_utf8(slice) {
                Ok(s) => serde_json::from_str(s).unwrap_or(Value::Object(serde_json::Map::new())),
                Err(_) => {
                    let r = make_error_result("invalid UTF-8 in params");
                    cb(r, cb_ctx);
                    unsafe { pnevma_free_result(r) };
                    return;
                }
            }
        };

        // Cast pointer to usize for Send safety across the spawn boundary.
        // This is safe because the caller guarantees the context pointer
        // remains valid until the callback is invoked.
        let cb_ctx_usize = cb_ctx as usize;

        let state = Arc::clone(&handle.state);
        handle.runtime.spawn(async move {
            let result = route_method(&state, &method_str, &params).await;
            let r = match result {
                Ok(val) => make_result(true, &val.to_string()),
                Err((_code, msg)) => make_error_result(&msg),
            };
            cb(r, cb_ctx_usize as *mut ());
            // Free the result after callback returns
            unsafe { pnevma_free_result(r) };
        });
    }));
}

/// Free a `PnevmaResult` returned by `pnevma_call`.
///
/// Safe to call with NULL.
///
/// # Safety
///
/// `result` must be a pointer returned by `pnevma_call`, or NULL.
#[no_mangle]
pub unsafe extern "C" fn pnevma_free_result(result: *mut PnevmaResult) {
    if result.is_null() {
        return;
    }
    let _ = panic::catch_unwind(|| {
        let result = unsafe { Box::from_raw(result) };
        if !result.data.is_null() {
            // Reconstruct CString to deallocate
            let _ = unsafe { CString::from_raw(result.data as *mut c_char) };
        }
    });
}

/// Register a callback for high-frequency session PTY output.
///
/// This bypasses the JSON event system for performance. The callback receives
/// raw bytes directly from the PTY.
#[no_mangle]
#[allow(clippy::not_unsafe_ptr_arg_deref)]
pub extern "C" fn pnevma_set_session_output_callback(
    handle: *mut PnevmaHandle,
    cb: SessionOutputCallback,
    ctx: *mut (),
) {
    if handle.is_null() {
        return;
    }
    let _ = panic::catch_unwind(AssertUnwindSafe(|| {
        let handle = unsafe { &*handle };
        if let Ok(mut cb_guard) = handle._session_output_cb.lock() {
            *cb_guard = Some(SessionOutputCallbackWrapper { _cb: cb, _ctx: ctx });
        }
        // TODO: Wire the callback into SessionSupervisor's output stream
        // once the session bridge is fully connected.
    }));
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn pnevma_create_returns_non_null() {
        extern "C" fn noop_cb(_: *const c_char, _: *const c_char, _: *mut ()) {}
        let handle = pnevma_create(noop_cb, ptr::null_mut());
        assert!(
            !handle.is_null(),
            "pnevma_create should return non-null handle"
        );
        pnevma_destroy(handle);
    }

    #[test]
    fn pnevma_call_with_null_handle_returns_error() {
        let method = CString::new("task.list").unwrap();
        let params = CString::new("{}").unwrap();
        let result = pnevma_call(
            ptr::null_mut(),
            method.as_ptr(),
            params.as_ptr(),
            params.as_bytes().len(),
        );
        assert!(!result.is_null());
        let r = unsafe { &*result };
        assert_eq!(r.ok, 0, "should return error for null handle");
        unsafe { pnevma_free_result(result) };
    }

    #[test]
    fn pnevma_call_returns_valid_result() {
        extern "C" fn noop_cb(_: *const c_char, _: *const c_char, _: *mut ()) {}
        let handle = pnevma_create(noop_cb, ptr::null_mut());
        assert!(!handle.is_null());

        let method = CString::new("task.list").unwrap();
        let params = CString::new("{}").unwrap();
        let result = pnevma_call(
            handle,
            method.as_ptr(),
            params.as_ptr(),
            params.as_bytes().len(),
        );
        assert!(
            !result.is_null(),
            "pnevma_call should return non-null result"
        );
        let r = unsafe { &*result };
        // Result may be ok or error depending on DB state — just verify it has data
        assert!(!r.data.is_null(), "result should have data pointer");
        assert!(r.len > 0, "result should have non-zero length");
        unsafe { pnevma_free_result(result) };
        pnevma_destroy(handle);
    }

    #[test]
    fn pnevma_free_result_null_is_safe() {
        // Should not crash
        unsafe { pnevma_free_result(ptr::null_mut()) };
    }

    #[test]
    fn pnevma_call_async_invokes_callback() {
        use std::sync::atomic::{AtomicBool, Ordering};

        extern "C" fn noop_cb(_: *const c_char, _: *const c_char, _: *mut ()) {}
        let handle = pnevma_create(noop_cb, ptr::null_mut());
        assert!(!handle.is_null());

        static CALLED: AtomicBool = AtomicBool::new(false);

        extern "C" fn async_cb(_result: *const PnevmaResult, _ctx: *mut ()) {
            CALLED.store(true, Ordering::SeqCst);
        }

        let method = CString::new("task.list").unwrap();
        let params = CString::new("{}").unwrap();
        pnevma_call_async(
            handle,
            method.as_ptr(),
            params.as_ptr(),
            params.as_bytes().len(),
            async_cb,
            ptr::null_mut(),
        );

        // Give the async task time to complete
        std::thread::sleep(std::time::Duration::from_millis(500));
        assert!(
            CALLED.load(Ordering::SeqCst),
            "async callback should have been invoked"
        );

        pnevma_destroy(handle);
    }
}
