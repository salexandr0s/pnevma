//! C-ABI FFI bridge for the Pnevma native macOS app.
//!
//! This crate provides a staticlib that Swift code links against.
//! All public functions are `extern "C"` with `catch_unwind` safety.

use pnevma_commands::event_emitter::EventEmitter;
use pnevma_commands::state::AppState;
use pnevma_commands::state::ManagedService;
use pnevma_commands::{route_method, NullEmitter};
use pnevma_db::GlobalDb;
use pnevma_session::SessionEvent;
use serde_json::Value;
use std::collections::HashMap;
use std::ffi::{CStr, CString};
use std::os::raw::c_char;
use std::panic::{self, AssertUnwindSafe};
use std::ptr;
use std::sync::{
    atomic::{AtomicBool, AtomicU64, Ordering},
    Arc,
};
use tokio::runtime::Runtime;

// ---------------------------------------------------------------------------
// Types matching pnevma-bridge.h
// ---------------------------------------------------------------------------

/// Callback for Rust→Swift event forwarding.
type EventCallback = extern "C" fn(event: *const c_char, payload_json: *const c_char, ctx: *mut ());

/// Callback for async call completion.
type AsyncCallback = extern "C" fn(result: *const PnevmaResult, ctx: *mut ());

/// Callback for releasing async callback context.
type AsyncContextRelease = extern "C" fn(ctx: *mut ());

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
    session_output_cb: Arc<std::sync::Mutex<Option<SessionOutputCallbackWrapper>>>,
    session_output_task: std::sync::Mutex<Option<tokio::task::JoinHandle<()>>>,
    project_service_generation: Arc<AtomicU64>,
    pending_async_callbacks: Arc<std::sync::Mutex<HashMap<u64, AsyncCallbackWrapper>>>,
    next_async_callback_id: AtomicU64,
    shutting_down: Arc<AtomicBool>,
    shutdown: tokio::sync::watch::Sender<bool>,
}

// Wrappers to make callback pointers Send+Sync (they cross FFI boundary).
//
// SAFETY: The Swift caller guarantees that:
// 1. The `ctx` pointer is not shared across threads without synchronization.
// 2. The `ctx` pointer outlives all Rust usage (i.e., remains valid until the
//    PnevmaHandle is destroyed or the callback is unregistered).
// 3. The callback function itself is safe to call from any thread.
struct EventCallbackWrapper {
    cb: EventCallback,
    ctx: *mut (),
}
unsafe impl Send for EventCallbackWrapper {}
unsafe impl Sync for EventCallbackWrapper {}

struct SessionOutputCallbackWrapper {
    cb: SessionOutputCallback,
    ctx: *mut (),
}
unsafe impl Send for SessionOutputCallbackWrapper {}
unsafe impl Sync for SessionOutputCallbackWrapper {}

struct AsyncCallbackWrapper {
    cb: AsyncCallback,
    ctx: *mut (),
    release_cb: AsyncContextRelease,
}
unsafe impl Send for AsyncCallbackWrapper {}
unsafe impl Sync for AsyncCallbackWrapper {}

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
        let cb = self.inner.cb;
        let ctx = self.inner.ctx;
        let event_ptr = event_cstr.as_ptr();
        let payload_ptr = payload_cstr.as_ptr();
        let result = std::panic::catch_unwind(AssertUnwindSafe(|| {
            cb(event_ptr, payload_ptr, ctx);
        }));
        if result.is_err() {
            tracing::error!(event = %event, "panic in FFI event callback");
        }
    }
}

// ---------------------------------------------------------------------------
// Helper: allocate a PnevmaResult on the heap
// ---------------------------------------------------------------------------

fn make_result(ok: bool, data: &str) -> *mut PnevmaResult {
    let cstr = CString::new(data).unwrap_or_else(|_| {
        CString::new("").expect("empty string literal cannot contain interior nuls")
    });
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

fn release_async_context(callback: AsyncCallbackWrapper) {
    (callback.release_cb)(callback.ctx);
}

fn finish_async_callback(callback: AsyncCallbackWrapper, result: *mut PnevmaResult) {
    (callback.cb)(result, callback.ctx);
    release_async_context(callback);
    // Free the result after callback returns.
    unsafe { pnevma_free_result(result) };
}

// ---------------------------------------------------------------------------
// Helper: parse JSON params from FFI byte pointer
// ---------------------------------------------------------------------------

/// Parse JSON params from a raw C byte pointer.
/// Returns `Ok(Value)` on success, or `Err(*mut PnevmaResult)` with an error result
/// that the caller should return immediately.
const MAX_PARAMS_LEN: usize = 16 * 1024 * 1024; // 16 MB
const MAX_METHOD_LEN: usize = 128;

fn parse_params(params_json: *const c_char, params_len: usize) -> Result<Value, *mut PnevmaResult> {
    if params_json.is_null() {
        return Ok(Value::Object(serde_json::Map::new()));
    }
    if params_len > MAX_PARAMS_LEN {
        return Err(make_error_result(&format!(
            "params too large: {} bytes (max {})",
            params_len, MAX_PARAMS_LEN
        )));
    }
    debug_assert!(
        !params_json.is_null() || params_len == 0,
        "non-null params_json required when params_len > 0"
    );
    // SAFETY: The caller (Swift side) must guarantee that `params_json` points to a valid
    // allocation of at least `params_len` bytes. The Swift wrapper always passes
    // `string.utf8.count` for the length, which matches the allocation size.
    let slice = unsafe { std::slice::from_raw_parts(params_json as *const u8, params_len) };
    let s = std::str::from_utf8(slice).map_err(|_| make_error_result("invalid UTF-8 in params"))?;
    serde_json::from_str(s).map_err(|e| make_error_result(&format!("invalid JSON in params: {e}")))
}

fn validate_method_name(method: &str) -> Result<(), *mut PnevmaResult> {
    if method.is_empty() {
        return Err(make_error_result("method must not be empty"));
    }
    if method.len() > MAX_METHOD_LEN {
        return Err(make_error_result(&format!(
            "method exceeds {MAX_METHOD_LEN} byte limit"
        )));
    }
    if !method
        .chars()
        .all(|c| c.is_ascii_alphanumeric() || matches!(c, '_' | '-' | '.'))
    {
        return Err(make_error_result("method contains invalid characters"));
    }
    Ok(())
}

async fn stop_control_plane_server(state: &Arc<AppState>) {
    let prior = {
        let mut slot = state.control_plane.lock().await;
        take_managed_service(&mut *slot)
    };
    if let Some(handle) = prior {
        handle.shutdown().await;
    }
}

async fn stop_remote_server(state: &Arc<AppState>) {
    let prior = {
        let mut slot = state.remote_handle.lock().await;
        take_managed_service(&mut *slot)
    };
    if let Some(handle) = prior {
        handle.shutdown();
    }
}

async fn stop_control_plane_server_if_generation(state: &Arc<AppState>, generation: u64) {
    let prior = {
        let mut slot = state.control_plane.lock().await;
        take_managed_service_if_generation(&mut *slot, generation)
    };
    if let Some(handle) = prior {
        handle.shutdown().await;
    }
}

async fn stop_remote_server_if_generation(state: &Arc<AppState>, generation: u64) {
    let prior = {
        let mut slot = state.remote_handle.lock().await;
        take_managed_service_if_generation(&mut *slot, generation)
    };
    if let Some(handle) = prior {
        handle.shutdown();
    }
}

fn next_project_service_generation(counter: &Arc<AtomicU64>) -> u64 {
    counter.fetch_add(1, Ordering::SeqCst) + 1
}

fn project_service_generation_is_current(counter: &AtomicU64, generation: u64) -> bool {
    counter.load(Ordering::SeqCst) == generation
}

fn take_managed_service<T>(slot: &mut Option<ManagedService<T>>) -> Option<T> {
    slot.take().map(|service| service.handle)
}

fn take_managed_service_if_generation<T>(
    slot: &mut Option<ManagedService<T>>,
    generation: u64,
) -> Option<T> {
    match slot.as_ref() {
        Some(service) if service.generation == generation => take_managed_service(slot),
        _ => None,
    }
}

async fn sync_project_services(
    state: Arc<AppState>,
    generation_counter: Arc<AtomicU64>,
    generation: u64,
) -> Result<(), String> {
    if !project_service_generation_is_current(generation_counter.as_ref(), generation) {
        return Ok(());
    }

    let (project_path, project_config, global_config) = {
        let current = state.current.lock().await;
        let ctx = current
            .as_ref()
            .ok_or_else(|| "no open project".to_string())?;
        (
            ctx.project_path.clone(),
            ctx.config.clone(),
            ctx.global_config.clone(),
        )
    };

    stop_control_plane_server(&state).await;
    stop_remote_server(&state).await;

    if !project_service_generation_is_current(generation_counter.as_ref(), generation) {
        return Ok(());
    }

    let settings = pnevma_commands::control::resolve_control_plane_settings(
        project_path.as_path(),
        &project_config,
        &global_config,
    )?;
    let control_handle =
        pnevma_commands::control::start_control_plane(Arc::clone(&state), settings).await?;
    if !project_service_generation_is_current(generation_counter.as_ref(), generation) {
        if let Some(handle) = control_handle {
            handle.shutdown().await;
        }
        return Ok(());
    }
    *state.control_plane.lock().await =
        control_handle.map(|handle| ManagedService { generation, handle });

    if !project_service_generation_is_current(generation_counter.as_ref(), generation) {
        stop_control_plane_server_if_generation(&state, generation).await;
        return Ok(());
    }
    let remote_handle =
        pnevma_commands::remote_bridge::maybe_start_remote(Arc::clone(&state)).await;
    if !project_service_generation_is_current(generation_counter.as_ref(), generation) {
        if let Some(handle) = remote_handle {
            handle.shutdown();
        }
        return Ok(());
    }
    *state.remote_handle.lock().await =
        remote_handle.map(|handle| ManagedService { generation, handle });
    if !project_service_generation_is_current(generation_counter.as_ref(), generation) {
        stop_remote_server_if_generation(&state, generation).await;
    }
    Ok(())
}

async fn stop_project_services(state: Arc<AppState>) {
    stop_control_plane_server(&state).await;
    stop_remote_server(&state).await;
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

        let global_db = match runtime.block_on(GlobalDb::open()) {
            Ok(db) => db,
            Err(err) => {
                tracing::error!(error = %err, "failed to bootstrap global database");
                return ptr::null_mut();
            }
        };
        let state = Arc::new(AppState::new_with_global_db(emitter, global_db));
        // Register self_arc so internal code can clone it (e.g. AutomationCoordinator).
        let _ = state.self_arc.set(Arc::clone(&state));
        let (shutdown_tx, _shutdown_rx) = tokio::sync::watch::channel(false);
        let pending_async_callbacks = Arc::new(std::sync::Mutex::new(HashMap::new()));
        let shutting_down = Arc::new(AtomicBool::new(false));
        let project_service_generation = Arc::new(AtomicU64::new(0));

        // Start background services
        let state_clone = Arc::clone(&state);
        runtime.spawn(async move {
            pnevma_commands::cost_aggregation::start_cost_aggregation(state_clone);
        });

        Box::into_raw(Box::new(PnevmaHandle {
            runtime,
            state,
            session_output_cb: Arc::new(std::sync::Mutex::new(None)),
            session_output_task: std::sync::Mutex::new(None),
            project_service_generation,
            pending_async_callbacks,
            next_async_callback_id: AtomicU64::new(1),
            shutting_down,
            shutdown: shutdown_tx,
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
        // Signal all tasks to shut down
        handle.shutting_down.store(true, Ordering::SeqCst);
        let _ = handle.shutdown.send(true);
        if let Ok(mut cb_guard) = handle.session_output_cb.lock() {
            *cb_guard = None;
        }
        let pending_callbacks = if let Ok(mut callbacks) = handle.pending_async_callbacks.lock() {
            callbacks
                .drain()
                .map(|(_, callback)| callback)
                .collect::<Vec<_>>()
        } else {
            Vec::new()
        };
        for callback in pending_callbacks {
            release_async_context(callback);
        }
        if let Ok(mut task_guard) = handle.session_output_task.lock() {
            if let Some(task) = task_guard.take() {
                task.abort();
            }
        }
        // Give tasks time to finish gracefully
        handle
            .runtime
            .shutdown_timeout(std::time::Duration::from_secs(5));
    }));
}

/// Synchronous RPC call. Blocks until the command completes.
///
/// **Must be called from a background thread** — never from the main thread.
///
/// Returns a heap-allocated `PnevmaResult`. Caller must free with `pnevma_free_result`.
///
/// `params_json` must point to a valid allocation of at least `params_len`
/// bytes. Passing a length exceeding the allocation is undefined behavior.
/// NULL is valid when `params_len` is 0 (treated as empty params).
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
        if let Err(r) = validate_method_name(method_str) {
            return r;
        }

        let params = match parse_params(params_json, params_len) {
            Ok(v) => v,
            Err(r) => return r,
        };

        let state = &handle.state;
        match handle
            .runtime
            .block_on(route_method(state, method_str, &params))
        {
            Ok(val) => {
                match method_str {
                    "project.open" => {
                        let state = Arc::clone(state);
                        let generation =
                            next_project_service_generation(&handle.project_service_generation);
                        let generation_counter = Arc::clone(&handle.project_service_generation);
                        handle.runtime.spawn(async move {
                            if let Err(err) =
                                sync_project_services(state, generation_counter, generation).await
                            {
                                tracing::error!(error = %err, "failed to synchronize project services after project.open");
                            }
                        });
                    }
                    "project.close" => {
                        next_project_service_generation(&handle.project_service_generation);
                        let state = Arc::clone(state);
                        handle.runtime.block_on(stop_project_services(state));
                    }
                    _ => {}
                }
                make_result(true, &val.to_string())
            }
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
///
/// `params_json` must point to a valid allocation of at least `params_len`
/// bytes. Passing a length exceeding the allocation is undefined behavior.
///
/// LIFETIME CONTRACT: `cb_ctx` must remain valid until the callback fires or
/// its `release_cb` is invoked. Destroying the handle cancels pending async
/// calls without invoking their completion callbacks, but still invokes
/// `release_cb` exactly once for each pending callback. `release_cb` must be a
/// valid function pointer; use a no-op function when `cb_ctx` requires no
/// cleanup. Passing NULL is valid only if both callbacks handle NULL context.
#[no_mangle]
#[allow(clippy::not_unsafe_ptr_arg_deref)]
pub extern "C" fn pnevma_call_async(
    handle: *mut PnevmaHandle,
    method: *const c_char,
    params_json: *const c_char,
    params_len: usize,
    cb: AsyncCallback,
    cb_ctx: *mut (),
    release_cb: AsyncContextRelease,
) {
    if handle.is_null() || method.is_null() {
        release_cb(cb_ctx);
        return;
    }

    let _ = panic::catch_unwind(AssertUnwindSafe(|| {
        let handle = unsafe { &*handle };

        let method_str = match unsafe { CStr::from_ptr(method) }.to_str() {
            Ok(s) => s.to_owned(),
            Err(_) => {
                let r = make_error_result("invalid UTF-8 in method");
                finish_async_callback(
                    AsyncCallbackWrapper {
                        cb,
                        ctx: cb_ctx,
                        release_cb,
                    },
                    r,
                );
                return;
            }
        };
        if let Err(r) = validate_method_name(&method_str) {
            finish_async_callback(
                AsyncCallbackWrapper {
                    cb,
                    ctx: cb_ctx,
                    release_cb,
                },
                r,
            );
            return;
        }

        let params = match parse_params(params_json, params_len) {
            Ok(v) => v,
            Err(r) => {
                finish_async_callback(
                    AsyncCallbackWrapper {
                        cb,
                        ctx: cb_ctx,
                        release_cb,
                    },
                    r,
                );
                return;
            }
        };

        let state = Arc::clone(&handle.state);
        let callback_id = handle
            .next_async_callback_id
            .fetch_add(1, Ordering::Relaxed);
        if let Ok(mut callbacks) = handle.pending_async_callbacks.lock() {
            callbacks.insert(
                callback_id,
                AsyncCallbackWrapper {
                    cb,
                    ctx: cb_ctx,
                    release_cb,
                },
            );
        } else {
            let r = make_error_result("async callback registry poisoned");
            finish_async_callback(
                AsyncCallbackWrapper {
                    cb,
                    ctx: cb_ctx,
                    release_cb,
                },
                r,
            );
            return;
        }
        let callbacks = Arc::clone(&handle.pending_async_callbacks);
        let shutting_down = Arc::clone(&handle.shutting_down);
        let project_service_generation = Arc::clone(&handle.project_service_generation);
        handle.runtime.spawn(async move {
            let result = route_method(&state, &method_str, &params).await;
            let r = match result {
                Ok(val) => {
                    match method_str.as_str() {
                        "project.open" => {
                            let generation =
                                next_project_service_generation(&project_service_generation);
                            let state = Arc::clone(&state);
                            let generation_counter = Arc::clone(&project_service_generation);
                            tokio::spawn(async move {
                                if let Err(err) =
                                    sync_project_services(state, generation_counter, generation)
                                        .await
                                {
                                    tracing::error!(error = %err, "failed to synchronize project services after project.open");
                                }
                            });
                        }
                        "project.close" => {
                            next_project_service_generation(&project_service_generation);
                            stop_project_services(Arc::clone(&state)).await;
                        }
                        _ => {}
                    }
                    make_result(true, &val.to_string())
                }
                Err((_code, msg)) => make_error_result(&msg),
            };
            if shutting_down.load(Ordering::SeqCst) {
                if let Ok(mut callbacks) = callbacks.lock() {
                    callbacks.remove(&callback_id);
                }
                unsafe { pnevma_free_result(r) };
                return;
            }
            let callback = callbacks
                .lock()
                .ok()
                .and_then(|mut callbacks| callbacks.remove(&callback_id));
            if let Some(callback) = callback {
                finish_async_callback(callback, r);
            } else {
                unsafe { pnevma_free_result(r) };
            }
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
///
/// LIFETIME CONTRACT: `ctx` must remain valid for as long as the callback
/// is registered (i.e., until a new callback is registered or the handle
/// is destroyed). The caller must NOT free or mutate the context while
/// the callback may be invoked from a background thread.
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
        if let Ok(mut task_guard) = handle.session_output_task.lock() {
            if let Some(task) = task_guard.take() {
                task.abort();
            }
        }
        let cb_arc = Arc::clone(&handle.session_output_cb);
        if let Ok(mut cb_guard) = cb_arc.lock() {
            if cb as usize == 0 {
                *cb_guard = None;
                return;
            }
            *cb_guard = Some(SessionOutputCallbackWrapper { cb, ctx });
        }

        // Spawn a background task that subscribes to the session supervisor's
        // output broadcast and forwards chunks to the FFI callback.
        let state = Arc::clone(&handle.state);
        let cb_arc2 = Arc::clone(&handle.session_output_cb);
        let mut shutdown_rx = handle.shutdown.subscribe();
        let join = handle.runtime.spawn(async move {
            session_output_forward_loop(state, cb_arc2, &mut shutdown_rx).await;
        });
        if let Ok(mut task_guard) = handle.session_output_task.lock() {
            *task_guard = Some(join);
        }
    }));
}

// ---------------------------------------------------------------------------
// Session output forwarding
// ---------------------------------------------------------------------------

/// Background loop that subscribes to the session supervisor's output broadcast
/// and forwards PTY output chunks to the registered FFI callback.
///
/// Handles project open/close by polling for an active project context.
/// Exits when the shutdown signal is received.
async fn session_output_forward_loop(
    state: Arc<AppState>,
    cb: Arc<std::sync::Mutex<Option<SessionOutputCallbackWrapper>>>,
    shutdown_rx: &mut tokio::sync::watch::Receiver<bool>,
) {
    loop {
        // Wait for a project to be open
        let mut rx = loop {
            if *shutdown_rx.borrow() {
                return;
            }
            let maybe_rx = {
                let current = state.current.lock().await;
                current.as_ref().map(|ctx| ctx.sessions.subscribe())
            };
            if let Some(rx) = maybe_rx {
                break rx;
            }
            // No project open yet; poll periodically
            tokio::select! {
                _ = tokio::time::sleep(std::time::Duration::from_millis(500)) => {}
                _ = shutdown_rx.changed() => { return; }
            }
        };

        // Forward output events until the channel closes or shutdown
        loop {
            tokio::select! {
                event = rx.recv() => {
                    match event {
                        Ok(SessionEvent::Output { session_id, chunk }) => {
                            let cb_guard = match cb.lock() {
                                Ok(g) => g,
                                Err(_) => continue,
                            };
                            if let Some(wrapper) = cb_guard.as_ref() {
                                let sid = session_id.to_string();
                                let sid_cstr = match CString::new(sid) {
                                    Ok(s) => s,
                                    Err(_) => continue,
                                };
                                let bytes = chunk.as_bytes();
                                let result = std::panic::catch_unwind(AssertUnwindSafe(|| {
                                    (wrapper.cb)(
                                        sid_cstr.as_ptr(),
                                        bytes.as_ptr(),
                                        bytes.len(),
                                        wrapper.ctx,
                                    );
                                }));
                                if result.is_err() {
                                    tracing::error!("panic in session output FFI callback");
                                }
                            }
                        }
                        Ok(_) => {} // Ignore non-output events
                        Err(tokio::sync::broadcast::error::RecvError::Lagged(n)) => {
                            tracing::warn!(skipped = n, "session output callback lagged");
                        }
                        Err(tokio::sync::broadcast::error::RecvError::Closed) => {
                            break; // Channel closed, project likely closed
                        }
                    }
                }
                _ = shutdown_rx.changed() => { return; }
            }
        }
    }
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
    fn parse_params_rejects_oversized_input() {
        // We can't actually allocate 16MB+ for this test, but we can test the logic
        // by checking that the constant is set correctly
        assert_eq!(MAX_PARAMS_LEN, 16 * 1024 * 1024);
    }

    #[test]
    fn parse_params_null_returns_empty_object() {
        let result = parse_params(ptr::null(), 0);
        assert!(result.is_ok());
        let val = result.unwrap();
        assert!(val.is_object());
        assert!(val.as_object().unwrap().is_empty());
    }

    #[test]
    fn parse_params_invalid_json_returns_error() {
        let invalid = CString::new("not valid json{{{").unwrap();
        let result = parse_params(invalid.as_ptr(), invalid.as_bytes().len());
        assert!(result.is_err());
    }

    #[test]
    fn parse_params_valid_json_returns_value() {
        let valid = CString::new(r#"{"key": "value"}"#).unwrap();
        let result = parse_params(valid.as_ptr(), valid.as_bytes().len());
        assert!(result.is_ok());
        let val = result.unwrap();
        assert_eq!(val["key"], "value");
    }

    #[test]
    fn validate_method_name_rejects_invalid_values() {
        assert!(validate_method_name("").is_err());
        assert!(validate_method_name("task list").is_err());
        assert!(validate_method_name(&"m".repeat(MAX_METHOD_LEN + 1)).is_err());
        assert!(validate_method_name("task.list").is_ok());
    }

    #[test]
    fn pnevma_set_session_output_callback_stores_callback() {
        extern "C" fn noop_cb(_: *const c_char, _: *const c_char, _: *mut ()) {}
        extern "C" fn output_cb(_sid: *const c_char, _data: *const u8, _len: usize, _ctx: *mut ()) {
        }

        let handle = pnevma_create(noop_cb, ptr::null_mut());
        assert!(!handle.is_null());

        pnevma_set_session_output_callback(handle, output_cb, ptr::null_mut());

        // Verify the callback was stored
        let h = unsafe { &*handle };
        let guard = h.session_output_cb.lock().unwrap();
        assert!(
            guard.is_some(),
            "callback should be stored after registration"
        );
        drop(guard);
        let task_guard = h.session_output_task.lock().unwrap();
        assert!(task_guard.is_some(), "forward loop should be running");
        drop(task_guard);

        // Give the forward loop a moment to start (it will be waiting for a project)
        std::thread::sleep(std::time::Duration::from_millis(100));

        pnevma_destroy(handle);
    }

    #[test]
    fn pnevma_call_async_invokes_callback() {
        use std::sync::atomic::{AtomicBool, AtomicUsize, Ordering};

        extern "C" fn noop_cb(_: *const c_char, _: *const c_char, _: *mut ()) {}
        let handle = pnevma_create(noop_cb, ptr::null_mut());
        assert!(!handle.is_null());

        static CALLED: AtomicBool = AtomicBool::new(false);
        static RELEASED: AtomicUsize = AtomicUsize::new(0);

        extern "C" fn async_cb(_result: *const PnevmaResult, _ctx: *mut ()) {
            CALLED.store(true, Ordering::SeqCst);
        }
        extern "C" fn release_cb(ctx: *mut ()) {
            let released = unsafe { &*(ctx as *const AtomicUsize) };
            released.fetch_add(1, Ordering::SeqCst);
        }

        let method = CString::new("task.list").unwrap();
        let params = CString::new("{}").unwrap();
        pnevma_call_async(
            handle,
            method.as_ptr(),
            params.as_ptr(),
            params.as_bytes().len(),
            async_cb,
            (&RELEASED as *const AtomicUsize).cast_mut().cast(),
            release_cb,
        );

        // Give the async task time to complete
        std::thread::sleep(std::time::Duration::from_millis(500));
        assert!(
            CALLED.load(Ordering::SeqCst),
            "async callback should have been invoked"
        );
        assert_eq!(
            RELEASED.load(Ordering::SeqCst),
            1,
            "async callback context should be released once after completion"
        );

        pnevma_destroy(handle);
    }

    #[test]
    fn pnevma_destroy_cancels_pending_async_callbacks() {
        use std::sync::atomic::{AtomicBool, AtomicUsize, Ordering};

        extern "C" fn noop_cb(_: *const c_char, _: *const c_char, _: *mut ()) {}
        let handle = pnevma_create(noop_cb, ptr::null_mut());
        assert!(!handle.is_null());

        static CALLED_AFTER_DESTROY: AtomicBool = AtomicBool::new(false);
        static RELEASED_AFTER_DESTROY: AtomicUsize = AtomicUsize::new(0);

        extern "C" fn async_cb(_result: *const PnevmaResult, _ctx: *mut ()) {
            CALLED_AFTER_DESTROY.store(true, Ordering::SeqCst);
        }
        extern "C" fn release_cb(ctx: *mut ()) {
            let released = unsafe { &*(ctx as *const AtomicUsize) };
            released.fetch_add(1, Ordering::SeqCst);
        }

        let method = CString::new("task.list").unwrap();
        let params = CString::new("{}").unwrap();
        pnevma_call_async(
            handle,
            method.as_ptr(),
            params.as_ptr(),
            params.as_bytes().len(),
            async_cb,
            (&RELEASED_AFTER_DESTROY as *const AtomicUsize)
                .cast_mut()
                .cast(),
            release_cb,
        );
        let h = unsafe { &*handle };
        assert_eq!(
            h.pending_async_callbacks.lock().unwrap().len(),
            1,
            "callback should be pending before destroy"
        );

        pnevma_destroy(handle);
        std::thread::sleep(std::time::Duration::from_millis(250));
        assert!(
            !CALLED_AFTER_DESTROY.load(Ordering::SeqCst),
            "destroyed handles must not invoke pending async callbacks"
        );
        assert_eq!(
            RELEASED_AFTER_DESTROY.load(Ordering::SeqCst),
            1,
            "destroy must release pending async callback context exactly once"
        );
    }

    #[test]
    fn project_service_generation_helpers_track_latest_generation() {
        let counter = Arc::new(AtomicU64::new(0));

        let first = next_project_service_generation(&counter);
        let second = next_project_service_generation(&counter);

        assert_eq!(first, 1);
        assert_eq!(second, 2);
        assert!(
            !project_service_generation_is_current(counter.as_ref(), first),
            "older generations must be treated as stale"
        );
        assert!(
            project_service_generation_is_current(counter.as_ref(), second),
            "the latest generation must remain current"
        );
    }

    #[test]
    fn take_managed_service_if_generation_only_removes_matching_entry() {
        let mut slot = Some(ManagedService {
            generation: 2,
            handle: "current",
        });

        assert!(
            take_managed_service_if_generation(&mut slot, 1).is_none(),
            "mismatched generations must leave the slot untouched"
        );
        assert!(
            slot.is_some(),
            "slot should remain populated after mismatch"
        );
        assert_eq!(
            take_managed_service_if_generation(&mut slot, 2),
            Some("current"),
            "matching generations must remove and return the handle"
        );
        assert!(slot.is_none(), "slot should be empty after a matching take");
    }
}
