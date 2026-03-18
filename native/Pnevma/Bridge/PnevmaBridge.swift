import Foundation
import os

struct BridgeEvent {
    let name: String
    let payloadJSON: String
}

struct SessionOutputEvent {
    let sessionID: String
    let chunk: String
}

enum ActiveWorkspaceActivationState: Equatable {
    case idle
    case opening(workspaceID: UUID, generation: UInt64)
    case open(workspaceID: UUID, projectID: String)
    case failed(workspaceID: UUID, generation: UInt64, message: String)
    case closed(workspaceID: UUID?)

    var isOpen: Bool {
        if case .open = self {
            return true
        }
        return false
    }
}

final class BridgeEventHub: @unchecked Sendable {
    static let shared = BridgeEventHub()

    typealias Observer = (BridgeEvent) -> Void

    private let lock = NSLock()
    private var observers: [UUID: Observer] = [:]

    @discardableResult
    func addObserver(_ observer: @escaping Observer) -> UUID {
        let id = UUID()
        lock.lock()
        observers[id] = observer
        lock.unlock()
        return id
    }

    func removeObserver(_ id: UUID) {
        lock.lock()
        observers.removeValue(forKey: id)
        lock.unlock()
    }

    func post(_ event: BridgeEvent) {
        lock.lock()
        let callbacks = Array(observers.values)
        lock.unlock()

        Task { @MainActor in
            callbacks.forEach { $0(event) }
        }
    }
}

final class ActiveWorkspaceActivationHub: @unchecked Sendable {
    static let shared = ActiveWorkspaceActivationHub()

    typealias Observer = (ActiveWorkspaceActivationState) -> Void

    private let lock = NSLock()
    private var state: ActiveWorkspaceActivationState = .idle
    private var observers: [UUID: Observer] = [:]

    var currentState: ActiveWorkspaceActivationState {
        lock.lock()
        let current = state
        lock.unlock()
        return current
    }

    @discardableResult
    func addObserver(_ observer: @escaping Observer) -> UUID {
        let id = UUID()
        lock.lock()
        observers[id] = observer
        lock.unlock()
        return id
    }

    func removeObserver(_ id: UUID) {
        lock.lock()
        observers.removeValue(forKey: id)
        lock.unlock()
    }

    func update(_ state: ActiveWorkspaceActivationState) {
        lock.lock()
        self.state = state
        let callbacks = Array(observers.values)
        lock.unlock()
        // Dispatch observer calls on MainActor to ensure UI safety.
        Task { @MainActor in
            callbacks.forEach { $0(state) }
        }
    }
}

final class SessionOutputHub: @unchecked Sendable {
    static let shared = SessionOutputHub()

    typealias Observer = (SessionOutputEvent) -> Void

    private let queue = DispatchQueue(label: "com.pnevma.session-output")
    private var observers: [String: [UUID: Observer]] = [:]
    private var observerSessions: [UUID: String] = [:]
    private var pendingChunks: [String: String] = [:]
    private var flushScheduled = false

    @discardableResult
    func addObserver(for sessionID: String, observer: @escaping Observer) -> UUID {
        let id = UUID()
        queue.sync {
            observers[sessionID, default: [:]][id] = observer
            observerSessions[id] = sessionID
        }
        return id
    }

    func removeObserver(_ id: UUID) {
        queue.sync {
            guard let sessionID = observerSessions.removeValue(forKey: id) else { return }
            observers[sessionID]?.removeValue(forKey: id)
            if observers[sessionID]?.isEmpty == true {
                observers.removeValue(forKey: sessionID)
                pendingChunks.removeValue(forKey: sessionID)
            }
        }
    }

    func publish(sessionID: String, chunk: String) {
        guard !chunk.isEmpty else { return }
        queue.async {
            guard let sessionObservers = self.observers[sessionID], !sessionObservers.isEmpty else {
                return
            }
            self.pendingChunks[sessionID, default: ""].append(chunk)
            self.scheduleFlushLocked()
        }
    }

    private func scheduleFlushLocked() {
        guard !flushScheduled else { return }
        flushScheduled = true
        queue.asyncAfter(deadline: .now() + 0.05) {
            let deliveries = self.pendingChunks.compactMap { sessionID, chunk -> (SessionOutputEvent, [Observer])? in
                guard let sessionObservers = self.observers[sessionID], !sessionObservers.isEmpty else {
                    return nil
                }
                return (
                    SessionOutputEvent(sessionID: sessionID, chunk: chunk),
                    Array(sessionObservers.values)
                )
            }
            self.pendingChunks.removeAll()
            self.flushScheduled = false

            guard !deliveries.isEmpty else { return }
            Task { @MainActor in
                for (event, callbacks) in deliveries {
                    callbacks.forEach { $0(event) }
                }
            }
        }
    }
}

struct BridgeCallResult {
    let ok: Bool
    let payload: String
}

/// Swift wrapper around the Rust pnevma-bridge C FFI.
/// Manages the PnevmaHandle lifecycle and provides type-safe call interface.
// SAFETY: @unchecked Sendable is safe because all mutable state (handle) is
// protected by handleLock (NSLock). FFI calls are thread-safe by design.
final class PnevmaBridge: @unchecked Sendable {
    private var handle: OpaquePointer?
    private let handleLock = NSLock()
    private var isDestroying = false
    private let inflightFFI = DispatchGroup()
    private static let defaultSessionOutputCallback: SessionOutputCallback = { sessionID, data, len, _ in
        guard let sessionID, let data else { return }
        let chunk = String(
            decoding: UnsafeBufferPointer(start: data, count: Int(len)),
            as: UTF8.self
        )
        SessionOutputHub.shared.publish(
            sessionID: String(cString: sessionID),
            chunk: chunk
        )
    }

    init() {
        // Event callback — receives events from Rust
        let callback: @convention(c) (UnsafePointer<CChar>?, UnsafePointer<CChar>?, UnsafeMutableRawPointer?) -> Void = { event, payload, ctx in
            guard let event = event else { return }
            let eventStr = String(cString: event)
            let payloadStr = payload.map { String(cString: $0) } ?? "{}"
            #if DEBUG
            let truncated = payloadStr.prefix(200)
            Log.bridge.debug("Event: \(eventStr) payload: \(truncated, privacy: .private)")
            #else
            Log.bridge.info("Event: \(eventStr)")
            #endif

            if eventStr != "session_output" {
                BridgeEventHub.shared.post(BridgeEvent(name: eventStr, payloadJSON: payloadStr))
            }
        }

        handle = pnevma_create(callback, nil)
        if handle == nil {
            Log.bridge.error("Failed to create PnevmaHandle — pnevma_create returned NULL")
        } else if let handle {
            pnevma_set_session_output_callback(handle, Self.defaultSessionOutputCallback, nil)
        }
    }

    private func withLiveHandle<T>(_ body: (OpaquePointer) -> T?) -> T? {
        handleLock.lock()
        guard !isDestroying, let h = handle else {
            handleLock.unlock()
            return nil
        }
        inflightFFI.enter()
        handleLock.unlock()
        defer { inflightFFI.leave() }
        return body(h)
    }

    /// Synchronous call to the Rust backend. Must NOT be called from the main thread.
    func call(method: String, params: String) -> BridgeCallResult? {
        withLiveHandle { h in
            method.withCString { methodPtr in
                params.withCString { paramsPtr in
                    let result = pnevma_call(h, methodPtr, paramsPtr, UInt(params.utf8.count))
                    guard let result else { return nil as BridgeCallResult? }
                    defer { pnevma_free_result(result) }
                    guard let dataPtr = result.pointee.data else { return nil as BridgeCallResult? }
                    return BridgeCallResult(
                        ok: result.pointee.ok != 0,
                        payload: String(cString: dataPtr)
                    )
                }
            }
        }
    }

    /// Async call to the Rust backend with callback.
    func callAsync(method: String, params: String, completion: @escaping @Sendable (BridgeCallResult?) -> Void) {
        let callback: @convention(c) (UnsafePointer<PnevmaResult>?, UnsafeMutableRawPointer?) -> Void = { result, ctx in
            guard let ctx = ctx else { return }
            let rawObj = Unmanaged<AnyObject>.fromOpaque(ctx).takeUnretainedValue()
            guard let box_ = rawObj as? CompletionBox else {
                assertionFailure("Unexpected context type in async FFI callback")
                return
            }

            guard let result = result, let dataPtr = result.pointee.data else {
                box_.completion(nil)
                return
            }
            box_.completion(
                BridgeCallResult(
                    ok: result.pointee.ok != 0,
                    payload: String(cString: dataPtr)
                )
            )
        }

        let releaseContext: @convention(c) (UnsafeMutableRawPointer?) -> Void = { ctx in
            guard let ctx = ctx else { return }
            Unmanaged<AnyObject>.fromOpaque(ctx).release()
        }

        let submitted = withLiveHandle { h -> Bool in
            let context = Unmanaged.passRetained(CompletionBox(completion) as AnyObject).toOpaque()
            method.withCString { methodPtr in
                params.withCString { paramsPtr in
                    pnevma_call_async(
                        h,
                        methodPtr,
                        paramsPtr,
                        UInt(params.utf8.count),
                        callback,
                        context,
                        releaseContext
                    )
                }
            }
            return true
        }
        if submitted == nil {
            completion(nil)
        }
    }

    func destroy() {
        handleLock.lock()
        guard !isDestroying else {
            handleLock.unlock()
            return
        }
        isDestroying = true
        let h = handle
        handle = nil
        handleLock.unlock()

        inflightFFI.wait()

        if let h {
            pnevma_destroy(h)
        }
    }

    deinit {
        destroy()
    }
}

private final class CompletionBox: @unchecked Sendable {
    let completion: @Sendable (BridgeCallResult?) -> Void
    init(_ completion: @escaping @Sendable (BridgeCallResult?) -> Void) {
        self.completion = completion
    }
}
