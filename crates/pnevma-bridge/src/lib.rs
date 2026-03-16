//! C-ABI FFI bridge for the Pnevma native macOS app.
//!
//! This crate provides a staticlib that Swift code links against.
//! All public functions are `extern "C"` with `catch_unwind` safety.

use futures::FutureExt;
use parking_lot::Mutex as ParkingMutex;
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

/// Monotonically increasing generation counter for handle identity.
///
/// Each `PnevmaHandle` receives a unique generation at creation time.
/// Async callbacks record this generation so that stale callbacks from a
/// destroyed handle cannot be invoked on a new handle allocated at the
/// same memory address.
static GLOBAL_HANDLE_GENERATION: AtomicU64 = AtomicU64::new(1);

/// Opaque handle holding all Pnevma runtime state.
pub struct PnevmaHandle {
    runtime: Runtime,
    state: Arc<AppState>,
    session_output_cb: Arc<std::sync::Mutex<Option<Arc<SessionOutputCallbackRegistration>>>>,
    session_output_task: std::sync::Mutex<Option<tokio::task::JoinHandle<()>>>,
    project_service_generation: Arc<AtomicU64>,
    pending_async_callbacks: Arc<ParkingMutex<HashMap<u64, AsyncCallbackWrapper>>>,
    next_async_callback_id: AtomicU64,
    handle_generation: u64,
    shutting_down: Arc<AtomicBool>,
    /// Guards against double-destroy: first caller wins, subsequent calls are no-ops.
    destroyed: AtomicBool,
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

#[derive(Clone, Copy)]
struct SessionOutputCallbackWrapper {
    cb: SessionOutputCallback,
    ctx: *mut (),
}
unsafe impl Send for SessionOutputCallbackWrapper {}
unsafe impl Sync for SessionOutputCallbackWrapper {}

struct SessionOutputCallbackRegistration {
    wrapper: SessionOutputCallbackWrapper,
}
unsafe impl Send for SessionOutputCallbackRegistration {}
unsafe impl Sync for SessionOutputCallbackRegistration {}

/// Wraps an async FFI callback with its context pointer.
///
/// # Safety invariants
///
/// 1. **Retained ownership**: The `ctx` pointer is exclusively owned by this
///    wrapper from creation until release. No other code may alias or free it.
/// 2. **Exactly-once release**: `release_cb(ctx)` is called exactly once — either
///    after the completion callback fires, or on cancellation/shutdown — never both.
/// 3. **Generation guard**: `handle_generation` must match the generation of the
///    `PnevmaHandle` that created this wrapper. If a callback survives handle
///    destruction and recreation at the same address, the generation mismatch
///    prevents invoking a stale callback on a new handle's context.
/// 4. **Shutdown guard**: When `shutting_down` is true, the completion callback
///    is never invoked — only `release_cb` is called.
struct AsyncCallbackWrapper {
    cb: AsyncCallback,
    ctx: *mut (),
    release_cb: AsyncContextRelease,
    handle_generation: u64,
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
    let _ = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
        (callback.cb)(result, callback.ctx);
    }));
    release_async_context(callback);
    unsafe { pnevma_free_result(result) };
}

fn finish_pending_async_callback(
    callbacks: &ParkingMutex<HashMap<u64, AsyncCallbackWrapper>>,
    shutting_down: &AtomicBool,
    callback_id: u64,
    expected_generation: u64,
    result: Option<*mut PnevmaResult>,
) {
    let callback = callbacks.lock().remove(&callback_id);
    match (callback, result) {
        (Some(callback), Some(result)) => {
            if callback.handle_generation != expected_generation {
                tracing::warn!(
                    callback_id,
                    expected = expected_generation,
                    actual = callback.handle_generation,
                    "stale async callback — generation mismatch; releasing without invoking"
                );
                release_async_context(callback);
                unsafe { pnevma_free_result(result) };
                return;
            }
            if shutting_down.load(Ordering::SeqCst) {
                release_async_context(callback);
                unsafe { pnevma_free_result(result) };
            } else {
                finish_async_callback(callback, result);
            }
        }
        (None, Some(result)) => unsafe { pnevma_free_result(result) },
        (Some(callback), None) => {
            if callback.handle_generation != expected_generation {
                tracing::warn!(
                    callback_id,
                    expected = expected_generation,
                    actual = callback.handle_generation,
                    "stale async callback — generation mismatch; releasing without invoking"
                );
                release_async_context(callback);
                return;
            }
            if shutting_down.load(Ordering::SeqCst) {
                release_async_context(callback);
            } else {
                finish_async_callback(
                    callback,
                    make_error_result("internal error: async call panicked"),
                );
            }
        }
        (None, None) => {}
    }
}

struct PendingAsyncCallbackGuard {
    callbacks: Arc<ParkingMutex<HashMap<u64, AsyncCallbackWrapper>>>,
    shutting_down: Arc<AtomicBool>,
    callback_id: u64,
    expected_generation: u64,
    active: bool,
}

impl PendingAsyncCallbackGuard {
    fn insert(
        callbacks: Arc<ParkingMutex<HashMap<u64, AsyncCallbackWrapper>>>,
        shutting_down: Arc<AtomicBool>,
        callback_id: u64,
        callback: AsyncCallbackWrapper,
        expected_generation: u64,
    ) -> Self {
        callbacks.lock().insert(callback_id, callback);
        Self {
            callbacks,
            shutting_down,
            callback_id,
            expected_generation,
            active: true,
        }
    }

    fn finish(mut self, result: *mut PnevmaResult) {
        self.active = false;
        finish_pending_async_callback(
            &self.callbacks,
            self.shutting_down.as_ref(),
            self.callback_id,
            self.expected_generation,
            Some(result),
        );
    }
}

impl Drop for PendingAsyncCallbackGuard {
    fn drop(&mut self) {
        if !self.active {
            return;
        }
        finish_pending_async_callback(
            &self.callbacks,
            self.shutting_down.as_ref(),
            self.callback_id,
            self.expected_generation,
            None,
        );
    }
}

/// RAII guard ensuring `release_cb(ctx)` is called exactly once on panic.
/// Defuse when ownership transfers to `finish_async_callback` or `PendingAsyncCallbackGuard`.
struct AsyncContextReleaseGuard {
    ctx: *mut (),
    release_cb: AsyncContextRelease,
    active: bool,
}

impl AsyncContextReleaseGuard {
    fn new(ctx: *mut (), release_cb: AsyncContextRelease) -> Self {
        Self {
            ctx,
            release_cb,
            active: true,
        }
    }
    fn defuse(&mut self) {
        self.active = false;
    }
}

impl Drop for AsyncContextReleaseGuard {
    fn drop(&mut self) {
        if self.active {
            (self.release_cb)(self.ctx);
        }
    }
}

// Need Send+Sync for catch_unwind
unsafe impl Send for AsyncContextReleaseGuard {}
unsafe impl Sync for AsyncContextReleaseGuard {}

fn snapshot_session_output_callback(
    cb: &Arc<std::sync::Mutex<Option<Arc<SessionOutputCallbackRegistration>>>>,
) -> Option<Arc<SessionOutputCallbackRegistration>> {
    let guard = cb.lock().ok()?;
    guard.clone()
}

fn wait_for_session_output_callback_quiescence(
    registration: Arc<SessionOutputCallbackRegistration>,
) {
    let deadline = std::time::Instant::now() + std::time::Duration::from_secs(5);
    while Arc::strong_count(&registration) > 1 {
        if std::time::Instant::now() > deadline {
            tracing::warn!("session output callback quiescence timed out after 5s");
            break;
        }
        std::thread::yield_now();
        std::thread::sleep(std::time::Duration::from_millis(1));
    }
}

fn replace_session_output_callback(
    cb: &Arc<std::sync::Mutex<Option<Arc<SessionOutputCallbackRegistration>>>>,
    next: Option<Arc<SessionOutputCallbackRegistration>>,
) -> Result<Option<Arc<SessionOutputCallbackRegistration>>, ()> {
    let mut guard = cb.lock().map_err(|_| ())?;
    Ok(std::mem::replace(&mut *guard, next))
}

fn clear_session_output_callback(
    cb: &Arc<std::sync::Mutex<Option<Arc<SessionOutputCallbackRegistration>>>>,
) {
    if let Ok(Some(registration)) = replace_session_output_callback(cb, None) {
        wait_for_session_output_callback_quiescence(registration);
    }
}

fn invoke_session_output_callback(
    registration: Arc<SessionOutputCallbackRegistration>,
    session_id: &str,
    bytes: &[u8],
) {
    let sid_cstr = match CString::new(session_id) {
        Ok(s) => s,
        Err(_) => return,
    };
    let result = std::panic::catch_unwind(AssertUnwindSafe(|| {
        let wrapper = registration.wrapper;
        (wrapper.cb)(sid_cstr.as_ptr(), bytes.as_ptr(), bytes.len(), wrapper.ctx);
    }));
    if result.is_err() {
        tracing::error!("panic in session output FFI callback");
    }
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
    debug_assert!(
        !params_json.is_null() || params_len == 0,
        "non-null params_json required when params_len > 0"
    );
    if params_json.is_null() {
        return Ok(Value::Object(serde_json::Map::new()));
    }
    if params_len > MAX_PARAMS_LEN {
        return Err(make_error_result(&format!(
            "params too large: {} bytes (max {})",
            params_len, MAX_PARAMS_LEN
        )));
    }
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
        let pending_async_callbacks = Arc::new(ParkingMutex::new(HashMap::new()));
        let shutting_down = Arc::new(AtomicBool::new(false));
        let project_service_generation = Arc::new(AtomicU64::new(0));

        // Start background services
        let state_clone = Arc::clone(&state);
        let cost_shutdown_rx = shutdown_tx.subscribe();
        runtime.spawn(async move {
            pnevma_commands::cost_aggregation::start_cost_aggregation(
                state_clone,
                cost_shutdown_rx,
            );
        });

        Arc::into_raw(Arc::new(PnevmaHandle {
            runtime,
            state,
            session_output_cb: Arc::new(std::sync::Mutex::new(None)),
            session_output_task: std::sync::Mutex::new(None),
            project_service_generation,
            pending_async_callbacks,
            next_async_callback_id: AtomicU64::new(1),
            handle_generation: GLOBAL_HANDLE_GENERATION.fetch_add(1, Ordering::SeqCst),
            shutting_down,
            destroyed: AtomicBool::new(false),
            shutdown: shutdown_tx,
        })) as *mut PnevmaHandle
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
    // SAFETY: handle is non-null (checked above). We read the `destroyed` flag
    // before taking ownership to prevent double Arc::from_raw on the same pointer.
    let handle_ref = unsafe { &*handle };
    if handle_ref
        .destroyed
        .compare_exchange(false, true, Ordering::SeqCst, Ordering::SeqCst)
        .is_err()
    {
        // Already destroyed by another caller — no-op.
        return;
    }
    let _ = panic::catch_unwind(AssertUnwindSafe(|| {
        // Mark as shutting down BEFORE reclaiming ownership — narrows the
        // concurrent-destroy / concurrent-call race window.
        handle_ref.shutting_down.store(true, Ordering::SeqCst);
        let handle = unsafe { Arc::from_raw(handle as *const PnevmaHandle) };
        let _ = handle.shutdown.send(true);
        if let Ok(mut task_guard) = handle.session_output_task.lock() {
            if let Some(task) = task_guard.take() {
                task.abort();
            }
        }
        clear_session_output_callback(&handle.session_output_cb);
        let pending_callbacks = handle
            .pending_async_callbacks
            .lock()
            .drain()
            .map(|(_, callback)| callback)
            .collect::<Vec<_>>();
        for callback in pending_callbacks {
            release_async_context(callback);
        }
        // Wait briefly for in-flight calls to release their Arc clones
        let deadline = std::time::Instant::now() + std::time::Duration::from_secs(5);
        while Arc::strong_count(&handle) > 1 && std::time::Instant::now() < deadline {
            std::thread::sleep(std::time::Duration::from_millis(10));
        }
        match Arc::try_unwrap(handle) {
            Ok(inner) => inner
                .runtime
                .shutdown_timeout(std::time::Duration::from_secs(5)),
            Err(_) => { /* in-flight calls still running; Runtime drops via background shutdown */ }
        }
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

    #[cfg(debug_assertions)]
    {
        // SAFETY: pthread_main_np is available on macOS and returns 1 if main thread.
        assert!(
            unsafe { libc::pthread_main_np() } == 0,
            "pnevma_call must not be called from the main thread"
        );
    }

    let result = panic::catch_unwind(AssertUnwindSafe(|| {
        // Increment Arc refcount so this call keeps the handle alive even if
        // pnevma_destroy runs concurrently.
        unsafe { Arc::increment_strong_count(handle as *const PnevmaHandle) };
        let handle = unsafe { Arc::from_raw(handle as *const PnevmaHandle) };

        if handle.shutting_down.load(Ordering::SeqCst) {
            return make_error_result("handle is shutting down");
        }

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
                        // Spawn on the runtime and wait via a oneshot channel to avoid
                        // nested block_on (the outer block_on at route_method above).
                        let (tx, rx) = tokio::sync::oneshot::channel();
                        handle.runtime.spawn(async move {
                            stop_project_services(state).await;
                            let _ = tx.send(());
                        });
                        let _ = rx.blocking_recv();
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
        // Increment Arc refcount so this call keeps the handle alive even if
        // pnevma_destroy runs concurrently.
        unsafe { Arc::increment_strong_count(handle as *const PnevmaHandle) };
        let handle = unsafe { Arc::from_raw(handle as *const PnevmaHandle) };

        // RAII guard: if we panic before ownership of cb_ctx transfers to
        // finish_async_callback or PendingAsyncCallbackGuard, release it.
        let mut ctx_guard = AsyncContextReleaseGuard::new(cb_ctx, release_cb);

        if handle.shutting_down.load(Ordering::SeqCst) {
            ctx_guard.defuse();
            finish_async_callback(
                AsyncCallbackWrapper {
                    cb,
                    ctx: cb_ctx,
                    release_cb,
                    handle_generation: 0,
                },
                make_error_result("handle is shutting down"),
            );
            return;
        }

        let method_str = match unsafe { CStr::from_ptr(method) }.to_str() {
            Ok(s) => s.to_owned(),
            Err(_) => {
                let r = make_error_result("invalid UTF-8 in method");
                ctx_guard.defuse();
                finish_async_callback(
                    AsyncCallbackWrapper {
                        cb,
                        ctx: cb_ctx,
                        release_cb,
                        handle_generation: 0,
                    },
                    r,
                );
                return;
            }
        };
        if let Err(r) = validate_method_name(&method_str) {
            ctx_guard.defuse();
            finish_async_callback(
                AsyncCallbackWrapper {
                    cb,
                    ctx: cb_ctx,
                    release_cb,
                    handle_generation: 0,
                },
                r,
            );
            return;
        }

        let params = match parse_params(params_json, params_len) {
            Ok(v) => v,
            Err(r) => {
                ctx_guard.defuse();
                finish_async_callback(
                    AsyncCallbackWrapper {
                        cb,
                        ctx: cb_ctx,
                        release_cb,
                        handle_generation: 0,
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
        ctx_guard.defuse();
        let pending_callback = PendingAsyncCallbackGuard::insert(
            Arc::clone(&handle.pending_async_callbacks),
            Arc::clone(&handle.shutting_down),
            callback_id,
            AsyncCallbackWrapper {
                cb,
                ctx: cb_ctx,
                release_cb,
                handle_generation: handle.handle_generation,
            },
            handle.handle_generation,
        );
        let project_service_generation = Arc::clone(&handle.project_service_generation);
        handle.runtime.spawn(async move {
            let result = AssertUnwindSafe(route_method(&state, &method_str, &params))
                .catch_unwind()
                .await;
            let result = match result {
                Ok(result) => result,
                Err(_) => return,
            };
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
            pending_callback.finish(r);
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
/// is destroyed). Unregistering or destroying the handle waits for any
/// in-flight callback snapshots to finish before returning. The caller must
/// NOT free or mutate the context while the callback may be invoked from a
/// background thread.
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
        // Increment Arc refcount so this call keeps the handle alive even if
        // pnevma_destroy runs concurrently.
        unsafe { Arc::increment_strong_count(handle as *const PnevmaHandle) };
        let handle = unsafe { Arc::from_raw(handle as *const PnevmaHandle) };

        if let Ok(mut task_guard) = handle.session_output_task.lock() {
            if let Some(task) = task_guard.take() {
                task.abort();
            }
        }
        let cb_arc = Arc::clone(&handle.session_output_cb);
        clear_session_output_callback(&cb_arc);
        if cb as usize == 0 {
            return;
        }
        let registration = Arc::new(SessionOutputCallbackRegistration {
            wrapper: SessionOutputCallbackWrapper { cb, ctx },
        });
        if replace_session_output_callback(&cb_arc, Some(registration)).is_err() {
            return;
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
        drop(handle);
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
    cb: Arc<std::sync::Mutex<Option<Arc<SessionOutputCallbackRegistration>>>>,
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
                            if let Some(wrapper) = snapshot_session_output_callback(&cb) {
                                let sid = session_id.to_string();
                                invoke_session_output_callback(wrapper, &sid, chunk.as_bytes());
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
    use std::sync::Mutex;

    #[derive(Default)]
    struct AsyncCallbackState {
        called: AtomicU64,
        released: AtomicU64,
        last_ok: Mutex<Option<i32>>,
        last_payload: Mutex<Option<String>>,
    }

    fn async_callback_ctx(state: &Arc<AsyncCallbackState>) -> *mut () {
        Arc::into_raw(Arc::clone(state)).cast_mut().cast()
    }

    extern "C" fn test_async_cb(result: *const PnevmaResult, ctx: *mut ()) {
        let state = unsafe { &*(ctx as *const AsyncCallbackState) };
        state.called.fetch_add(1, Ordering::SeqCst);
        if result.is_null() {
            return;
        }

        let result = unsafe { &*result };
        *state.last_ok.lock().unwrap() = Some(result.ok);
        let payload = if result.data.is_null() {
            String::new()
        } else {
            let bytes = unsafe { std::slice::from_raw_parts(result.data.cast::<u8>(), result.len) };
            String::from_utf8_lossy(bytes).to_string()
        };
        *state.last_payload.lock().unwrap() = Some(payload);
    }

    extern "C" fn test_async_release_cb(ctx: *mut ()) {
        let state = unsafe { Arc::from_raw(ctx as *const AsyncCallbackState) };
        state.released.fetch_add(1, Ordering::SeqCst);
    }

    struct SessionOutputProbe {
        callback_slot: Arc<std::sync::Mutex<Option<Arc<SessionOutputCallbackRegistration>>>>,
        reacquired_mutex: AtomicBool,
        call_count: AtomicU64,
    }

    extern "C" fn session_output_probe_cb(
        _sid: *const c_char,
        _data: *const u8,
        _len: usize,
        ctx: *mut (),
    ) {
        let probe = unsafe { &*(ctx as *const SessionOutputProbe) };
        probe.call_count.fetch_add(1, Ordering::SeqCst);
        probe
            .reacquired_mutex
            .store(probe.callback_slot.try_lock().is_ok(), Ordering::SeqCst);
    }

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
        extern "C" fn noop_cb(_: *const c_char, _: *const c_char, _: *mut ()) {}
        let handle = pnevma_create(noop_cb, ptr::null_mut());
        assert!(!handle.is_null());
        let state = Arc::new(AsyncCallbackState::default());

        let method = CString::new("task.list").unwrap();
        let params = CString::new("{}").unwrap();
        pnevma_call_async(
            handle,
            method.as_ptr(),
            params.as_ptr(),
            params.as_bytes().len(),
            test_async_cb,
            async_callback_ctx(&state),
            test_async_release_cb,
        );

        // Give the async task time to complete
        std::thread::sleep(std::time::Duration::from_millis(500));
        assert_eq!(
            state.called.load(Ordering::SeqCst),
            1,
            "async callback should fire exactly once"
        );
        assert_eq!(
            state.released.load(Ordering::SeqCst),
            1,
            "async callback context should be released once after completion"
        );

        pnevma_destroy(handle);
    }

    #[test]
    fn pnevma_destroy_cancels_pending_async_callbacks() {
        extern "C" fn noop_cb(_: *const c_char, _: *const c_char, _: *mut ()) {}
        let handle = pnevma_create(noop_cb, ptr::null_mut());
        assert!(!handle.is_null());
        let state = Arc::new(AsyncCallbackState::default());

        let method = CString::new("task.list").unwrap();
        let params = CString::new("{}").unwrap();
        pnevma_call_async(
            handle,
            method.as_ptr(),
            params.as_ptr(),
            params.as_bytes().len(),
            test_async_cb,
            async_callback_ctx(&state),
            test_async_release_cb,
        );
        let h = unsafe { &*handle };
        assert_eq!(
            h.pending_async_callbacks.lock().len(),
            1,
            "callback should be pending before destroy"
        );

        pnevma_destroy(handle);
        std::thread::sleep(std::time::Duration::from_millis(250));
        assert!(
            state.called.load(Ordering::SeqCst) == 0,
            "destroyed handles must not invoke pending async callbacks"
        );
        assert_eq!(
            state.released.load(Ordering::SeqCst),
            1,
            "destroy must release pending async callback context exactly once"
        );
    }

    #[test]
    fn pending_async_callback_guard_cleans_up_panic_once() {
        let callbacks = Arc::new(ParkingMutex::new(HashMap::new()));
        let shutting_down = Arc::new(AtomicBool::new(false));
        let state = Arc::new(AsyncCallbackState::default());

        let unwind = panic::catch_unwind(AssertUnwindSafe({
            let callbacks = Arc::clone(&callbacks);
            let shutting_down = Arc::clone(&shutting_down);
            let state = Arc::clone(&state);
            move || {
                let _pending = PendingAsyncCallbackGuard::insert(
                    callbacks,
                    shutting_down,
                    7,
                    AsyncCallbackWrapper {
                        cb: test_async_cb,
                        ctx: async_callback_ctx(&state),
                        release_cb: test_async_release_cb,
                        handle_generation: 1,
                    },
                    1,
                );
                panic!("simulate panic after pending callback registration");
            }
        }));

        assert!(
            unwind.is_err(),
            "the inner panic should be caught by the test"
        );
        assert!(
            callbacks.lock().is_empty(),
            "panic cleanup must remove the pending callback"
        );
        assert_eq!(
            state.called.load(Ordering::SeqCst),
            1,
            "panic cleanup must complete the callback exactly once"
        );
        assert_eq!(
            state.released.load(Ordering::SeqCst),
            1,
            "panic cleanup must release the callback context exactly once"
        );
        assert_eq!(
            *state.last_ok.lock().unwrap(),
            Some(0),
            "panic cleanup should surface an internal error result"
        );
        let payload = state
            .last_payload
            .lock()
            .unwrap()
            .clone()
            .unwrap_or_default();
        assert!(
            payload.contains("internal error"),
            "panic cleanup should report a synthetic internal error"
        );
    }

    #[test]
    fn invoke_session_output_callback_does_not_hold_mutex_during_callback() {
        let callback_slot = Arc::new(std::sync::Mutex::new(None));
        let probe = Box::new(SessionOutputProbe {
            callback_slot: Arc::clone(&callback_slot),
            reacquired_mutex: AtomicBool::new(false),
            call_count: AtomicU64::new(0),
        });
        let probe_ptr = Box::into_raw(probe);

        {
            let mut guard = callback_slot.lock().unwrap();
            *guard = Some(Arc::new(SessionOutputCallbackRegistration {
                wrapper: SessionOutputCallbackWrapper {
                    cb: session_output_probe_cb,
                    ctx: probe_ptr.cast(),
                },
            }));
        }

        let wrapper = snapshot_session_output_callback(&callback_slot)
            .expect("callback snapshot should be available");
        invoke_session_output_callback(wrapper, "session-123", b"hello");

        let probe = unsafe { Box::from_raw(probe_ptr) };
        assert_eq!(
            probe.call_count.load(Ordering::SeqCst),
            1,
            "callback should be invoked exactly once"
        );
        assert!(
            probe.reacquired_mutex.load(Ordering::SeqCst),
            "the callback mutex must not be held across FFI invocation"
        );
    }

    #[test]
    fn clear_session_output_callback_waits_for_in_flight_snapshot() {
        let callback_slot = Arc::new(std::sync::Mutex::new(Some(Arc::new(
            SessionOutputCallbackRegistration {
                wrapper: SessionOutputCallbackWrapper {
                    cb: session_output_probe_cb,
                    ctx: ptr::null_mut(),
                },
            },
        ))));
        let snapshot = snapshot_session_output_callback(&callback_slot)
            .expect("callback snapshot should be available");
        let (held_tx, held_rx) = std::sync::mpsc::channel();
        let (release_tx, release_rx) = std::sync::mpsc::channel();

        let holder = std::thread::spawn(move || {
            held_tx.send(()).expect("signal held snapshot");
            release_rx.recv().expect("wait for release signal");
            drop(snapshot);
        });

        held_rx.recv().expect("snapshot should be held");
        let slot = Arc::clone(&callback_slot);
        let clearer = std::thread::spawn(move || {
            clear_session_output_callback(&slot);
        });

        std::thread::sleep(std::time::Duration::from_millis(20));
        assert!(
            !clearer.is_finished(),
            "clearing must wait for any in-flight snapshot to finish"
        );

        release_tx.send(()).expect("release held snapshot");
        clearer.join().expect("clearer should exit cleanly");
        holder.join().expect("holder should exit cleanly");
        assert!(
            callback_slot.lock().unwrap().is_none(),
            "callback slot should be empty after clear"
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

    #[test]
    fn generation_mismatch_releases_without_invoking() {
        let callbacks = Arc::new(ParkingMutex::new(HashMap::new()));
        let shutting_down = Arc::new(AtomicBool::new(false));
        let state = Arc::new(AsyncCallbackState::default());

        // Insert a callback with generation 1
        callbacks.lock().insert(
            42,
            AsyncCallbackWrapper {
                cb: test_async_cb,
                ctx: async_callback_ctx(&state),
                release_cb: test_async_release_cb,
                handle_generation: 1,
            },
        );

        // Finish with expected_generation=2 (mismatch)
        let result = make_result(true, "ok");
        finish_pending_async_callback(&callbacks, &shutting_down, 42, 2, Some(result));

        assert_eq!(
            state.called.load(Ordering::SeqCst),
            0,
            "callback must not be invoked on generation mismatch"
        );
        assert_eq!(
            state.released.load(Ordering::SeqCst),
            1,
            "context must still be released on generation mismatch"
        );
        assert!(
            callbacks.lock().is_empty(),
            "callback must be removed from pending map"
        );
    }

    #[test]
    fn generation_match_invokes_callback() {
        let callbacks = Arc::new(ParkingMutex::new(HashMap::new()));
        let shutting_down = Arc::new(AtomicBool::new(false));
        let state = Arc::new(AsyncCallbackState::default());

        callbacks.lock().insert(
            43,
            AsyncCallbackWrapper {
                cb: test_async_cb,
                ctx: async_callback_ctx(&state),
                release_cb: test_async_release_cb,
                handle_generation: 5,
            },
        );

        let result = make_result(true, "hello");
        finish_pending_async_callback(&callbacks, &shutting_down, 43, 5, Some(result));

        assert_eq!(
            state.called.load(Ordering::SeqCst),
            1,
            "callback must be invoked when generations match"
        );
        assert_eq!(
            state.released.load(Ordering::SeqCst),
            1,
            "context must be released after invocation"
        );
    }

    #[test]
    fn global_handle_generation_is_monotonic() {
        let g1 = GLOBAL_HANDLE_GENERATION.fetch_add(1, Ordering::SeqCst);
        let g2 = GLOBAL_HANDLE_GENERATION.fetch_add(1, Ordering::SeqCst);
        let g3 = GLOBAL_HANDLE_GENERATION.fetch_add(1, Ordering::SeqCst);
        assert!(
            g1 < g2 && g2 < g3,
            "global generation must be strictly increasing"
        );
    }

    // ── FFI stress tests ────────────────────────────────────────────────────

    /// Spawn 50 async calls from 50 threads simultaneously via a barrier,
    /// exercising thread-safety of `pnevma_call_async`'s pointer handling,
    /// ParkingMutex contention, and pending-callback bookkeeping.
    #[test]
    fn stress_concurrent_async_calls() {
        extern "C" fn noop_cb(_: *const c_char, _: *const c_char, _: *mut ()) {}
        let handle = pnevma_create(noop_cb, ptr::null_mut());
        assert!(!handle.is_null());

        let count = 50usize;
        let states: Vec<Arc<AsyncCallbackState>> = (0..count)
            .map(|_| Arc::new(AsyncCallbackState::default()))
            .collect();

        // SAFETY: PnevmaHandle uses internal synchronization (ParkingMutex,
        // AtomicU64, Arc-based fields). The FFI contract allows concurrent
        // calls from any thread — this is what Swift/AppKit does in practice.
        let handle_addr = handle as usize;
        let barrier = Arc::new(std::sync::Barrier::new(count));

        let threads: Vec<_> = states
            .iter()
            .map(|state| {
                let state = Arc::clone(state);
                let barrier = Arc::clone(&barrier);
                std::thread::spawn(move || {
                    let method = CString::new("task.list").unwrap();
                    let params = CString::new("{}").unwrap();
                    // Barrier ensures all 50 threads fire simultaneously
                    barrier.wait();
                    pnevma_call_async(
                        handle_addr as *mut PnevmaHandle,
                        method.as_ptr(),
                        params.as_ptr(),
                        params.as_bytes().len(),
                        test_async_cb,
                        async_callback_ctx(&state),
                        test_async_release_cb,
                    );
                })
            })
            .collect();

        for t in threads {
            t.join().expect("caller thread must not panic");
        }

        // Wait for all async tasks to complete on the Tokio runtime
        std::thread::sleep(std::time::Duration::from_secs(5));

        let total_called: u64 = states.iter().map(|s| s.called.load(Ordering::SeqCst)).sum();
        assert_eq!(
            total_called, count as u64,
            "all {count} async callbacks must fire"
        );

        pnevma_destroy(handle);
        std::thread::sleep(std::time::Duration::from_millis(500));

        for (i, state) in states.iter().enumerate() {
            assert_eq!(
                state.released.load(Ordering::SeqCst),
                1,
                "callback {i} context must be released exactly once"
            );
        }
    }

    /// Rapidly create and destroy 100 PnevmaHandle instances, each exercising
    /// a full Tokio runtime + async call lifecycle, verifying no resource leak
    /// causes a crash, hang, or double-free across cycles.
    #[test]
    fn stress_create_destroy_cycles() {
        extern "C" fn noop_cb(_: *const c_char, _: *const c_char, _: *mut ()) {}
        for i in 0..100 {
            let handle = pnevma_create(noop_cb, ptr::null_mut());
            assert!(
                !handle.is_null(),
                "create must return non-null on cycle {i}"
            );

            // Fire an async call each cycle to exercise the full runtime lifecycle
            // (runtime spawn → task execute → callback → context release → runtime shutdown).
            let state = Arc::new(AsyncCallbackState::default());
            let method = CString::new("task.list").unwrap();
            let params = CString::new("{}").unwrap();
            pnevma_call_async(
                handle,
                method.as_ptr(),
                params.as_ptr(),
                params.as_bytes().len(),
                test_async_cb,
                async_callback_ctx(&state),
                test_async_release_cb,
            );

            // Destroy while the async call may still be in flight — exercises
            // both the "completed before destroy" and "pending at destroy" paths
            // across 100 iterations.
            pnevma_destroy(handle);

            // Verify the callback context was released (either via normal
            // completion or destroy cleanup) — a leak here would mean the
            // Arc-to-raw-pointer round-trip is broken.
            std::thread::sleep(std::time::Duration::from_millis(50));
            assert_eq!(
                state.released.load(Ordering::SeqCst),
                1,
                "cycle {i}: callback context must be released exactly once"
            );
        }
    }

    /// Submit async calls from multiple threads, then immediately destroy
    /// the handle before the Tokio runtime has completed them. This exercises
    /// the generation guard: async tasks that finish after destroy must not
    /// invoke their callback, and every context must be released exactly once.
    ///
    /// Note: the destroy happens AFTER all submissions complete (join), not
    /// concurrently — concurrent destroy + call is UB by FFI contract (Swift
    /// serializes these). The race being tested is between async task
    /// completion on the Tokio runtime and the destroy/shutdown path.
    #[test]
    fn stress_callback_after_destroy_race() {
        extern "C" fn noop_cb(_: *const c_char, _: *const c_char, _: *mut ()) {}

        // Run multiple rounds to increase the chance of hitting the race window
        for round in 0..10 {
            let handle = pnevma_create(noop_cb, ptr::null_mut());
            assert!(!handle.is_null());

            let count = 10usize;
            let states: Vec<Arc<AsyncCallbackState>> = (0..count)
                .map(|_| Arc::new(AsyncCallbackState::default()))
                .collect();

            // SAFETY: handle remains valid until pnevma_destroy below.
            // All threads join before destroy.
            let handle_addr = handle as usize;
            let barrier = Arc::new(std::sync::Barrier::new(count));

            // Spawn caller threads that submit async calls simultaneously
            let callers: Vec<_> = states
                .iter()
                .map(|state| {
                    let state = Arc::clone(state);
                    let barrier = Arc::clone(&barrier);
                    std::thread::spawn(move || {
                        let method = CString::new("task.list").unwrap();
                        let params = CString::new("{}").unwrap();
                        barrier.wait();
                        pnevma_call_async(
                            handle_addr as *mut PnevmaHandle,
                            method.as_ptr(),
                            params.as_ptr(),
                            params.as_bytes().len(),
                            test_async_cb,
                            async_callback_ctx(&state),
                            test_async_release_cb,
                        );
                    })
                })
                .collect();

            // Wait for all submissions to complete
            for t in callers {
                t.join().expect("caller thread must not panic");
            }

            // Destroy immediately — async tasks may still be running on the
            // Tokio runtime. The generation guard must prevent stale invocations.
            pnevma_destroy(handle);
            std::thread::sleep(std::time::Duration::from_millis(250));

            for (i, state) in states.iter().enumerate() {
                assert_eq!(
                    state.released.load(Ordering::SeqCst),
                    1,
                    "round {round} callback {i}: context must be released exactly once"
                );
                assert!(
                    state.called.load(Ordering::SeqCst) <= 1,
                    "round {round} callback {i}: must fire at most once"
                );
            }
        }
    }

    /// Submit 20 async calls from 20 threads under contention and verify
    /// that no callback is lost — every single one must fire exactly once
    /// and have its context released.
    #[test]
    fn stress_no_callback_lost_under_contention() {
        extern "C" fn noop_cb(_: *const c_char, _: *const c_char, _: *mut ()) {}
        let handle = pnevma_create(noop_cb, ptr::null_mut());
        assert!(!handle.is_null());

        let count = 20usize;
        let states: Vec<Arc<AsyncCallbackState>> = (0..count)
            .map(|_| Arc::new(AsyncCallbackState::default()))
            .collect();

        let handle_addr = handle as usize;
        let barrier = Arc::new(std::sync::Barrier::new(count));

        let threads: Vec<_> = states
            .iter()
            .map(|state| {
                let state = Arc::clone(state);
                let barrier = Arc::clone(&barrier);
                std::thread::spawn(move || {
                    let method = CString::new("task.list").unwrap();
                    let params = CString::new("{}").unwrap();
                    barrier.wait();
                    pnevma_call_async(
                        handle_addr as *mut PnevmaHandle,
                        method.as_ptr(),
                        params.as_ptr(),
                        params.as_bytes().len(),
                        test_async_cb,
                        async_callback_ctx(&state),
                        test_async_release_cb,
                    );
                })
            })
            .collect();

        for t in threads {
            t.join().expect("caller thread must not panic");
        }

        std::thread::sleep(std::time::Duration::from_secs(3));

        for (i, state) in states.iter().enumerate() {
            assert_eq!(
                state.called.load(Ordering::SeqCst),
                1,
                "callback {i} must not be lost under contention"
            );
        }

        pnevma_destroy(handle);
        std::thread::sleep(std::time::Duration::from_millis(500));

        for (i, state) in states.iter().enumerate() {
            assert_eq!(
                state.released.load(Ordering::SeqCst),
                1,
                "callback {i} context must be released"
            );
        }
    }
}
