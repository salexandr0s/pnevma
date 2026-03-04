import Foundation

/// Swift wrapper around the Rust pnevma-bridge C FFI.
/// Manages the PnevmaHandle lifecycle and provides type-safe call interface.
class PnevmaBridge {
    private var handle: OpaquePointer?

    init() {
        // Event callback — receives events from Rust
        let callback: @convention(c) (UnsafePointer<CChar>?, UnsafePointer<CChar>?, UnsafeMutableRawPointer?) -> Void = { event, payload, ctx in
            guard let event = event, let payload = payload else { return }
            let eventStr = String(cString: event)
            let payloadStr = String(cString: payload)
            print("[PnevmaBridge] Event: \(eventStr) payload: \(payloadStr)")
        }

        handle = pnevma_create(callback, nil)
        if handle == nil {
            print("[PnevmaBridge] ERROR: Failed to create PnevmaHandle")
        }
    }

    /// Synchronous call to the Rust backend. Must NOT be called from main thread.
    func call(method: String, params: String) -> String? {
        guard let handle = handle else { return nil }

        return method.withCString { methodPtr in
            params.withCString { paramsPtr in
                let result = pnevma_call(handle, methodPtr, paramsPtr, UInt(params.utf8.count))
                guard let result = result else { return nil as String? }
                defer { pnevma_free_result(result) }

                guard let dataPtr = result.pointee.data else { return nil as String? }
                return String(cString: dataPtr)
            }
        }
    }

    /// Async call to the Rust backend with callback.
    func callAsync(method: String, params: String, completion: @escaping (String?) -> Void) {
        guard let handle = handle else {
            completion(nil)
            return
        }

        // Store completion handler
        let context = Unmanaged.passRetained(CompletionBox(completion) as AnyObject).toOpaque()

        let callback: @convention(c) (UnsafePointer<PnevmaResult>?, UnsafeMutableRawPointer?) -> Void = { result, ctx in
            guard let ctx = ctx else { return }
            let box_ = Unmanaged<AnyObject>.fromOpaque(ctx).takeRetainedValue() as! CompletionBox

            guard let result = result, let dataPtr = result.pointee.data else {
                box_.completion(nil)
                return
            }
            box_.completion(String(cString: dataPtr))
        }

        method.withCString { methodPtr in
            params.withCString { paramsPtr in
                pnevma_call_async(handle, methodPtr, paramsPtr, UInt(params.utf8.count), callback, context)
            }
        }
    }

    func destroy() {
        if let handle = handle {
            pnevma_destroy(handle)
            self.handle = nil
        }
    }

    deinit {
        destroy()
    }
}

private class CompletionBox {
    let completion: (String?) -> Void
    init(_ completion: @escaping (String?) -> Void) {
        self.completion = completion
    }
}
