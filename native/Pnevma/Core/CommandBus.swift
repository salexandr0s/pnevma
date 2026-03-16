import Foundation

/// Thread-safe wrapper that ensures a CheckedContinuation is resumed exactly once.
/// Used to prevent double-resume when a callback fires after a timeout.
private final class ContinuationGuard<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private let method: String
    private var continuation: CheckedContinuation<T, Error>?

    init(method: String) {
        self.method = method
    }

    func setContinuation(_ cont: CheckedContinuation<T, Error>) {
        lock.lock()
        defer { lock.unlock() }
        self.continuation = cont
    }

    func takeContinuation() -> CheckedContinuation<T, Error>? {
        lock.lock()
        defer { lock.unlock() }
        let cont = continuation
        continuation = nil
        return cont
    }

    deinit {
        // Safety net: if neither the callback nor the timeout consumed the
        // continuation, resume with an error to prevent an indefinite hang.
        if let cont = continuation {
            cont.resume(throwing: PnevmaError.bridgeCallFailed(method: method))
        }
    }
}

/// Convenience wrapper for making typed calls to the Rust backend.
/// All calls are dispatched to a background queue to avoid blocking the main thread.
protocol CommandCalling: Sendable {
    func call<T: Decodable & Sendable>(method: String, params: (any Encodable & Sendable)?) async throws -> T
}

extension CommandCalling {
    func call<T: Decodable & Sendable>(method: String) async throws -> T {
        try await call(method: method, params: nil)
    }
}

actor CommandBus: CommandCalling {
    @MainActor static var shared: (any CommandCalling)?

    private let bridge: PnevmaBridge

    init(bridge: PnevmaBridge) {
        self.bridge = bridge
    }

    /// Call a Rust command with pre-serialized JSON params and decode the result.
    /// Races the FFI callback against a 30-second timeout to prevent indefinite hangs.
    func callRaw<T: Decodable & Sendable>(method: String, paramsJSON: String) async throws -> T {
        return try await withThrowingTaskGroup(of: T.self) { group in
            let continuationGuard = ContinuationGuard<T>(method: method)

            group.addTask {
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<T, Error>) in
                    continuationGuard.setContinuation(continuation)

                    self.bridge.callAsync(method: method, params: paramsJSON) { resultJSON in
                        guard let cont: CheckedContinuation<T, Error> = continuationGuard.takeContinuation() else { return }

                        guard let result = resultJSON else {
                            cont.resume(throwing: PnevmaError.bridgeCallFailed(method: method))
                            return
                        }

                        guard result.ok else {
                            cont.resume(
                                throwing: PnevmaError.backendError(method: method, message: result.payload)
                            )
                            return
                        }

                        guard let data = result.payload.data(using: .utf8) else {
                            cont.resume(throwing: PnevmaError.invalidResponse)
                            return
                        }

                        do {
                            let decoder = PnevmaJSON.decoder()
                            let decoded = try decoder.decode(T.self, from: data)
                            cont.resume(returning: decoded)
                        } catch {
                            cont.resume(
                                throwing: PnevmaError.decodingFailed(method: method, error: error)
                            )
                        }
                    }
                }
            }

            group.addTask {
                try await Task.sleep(nanoseconds: 30_000_000_000)
                if let cont = continuationGuard.takeContinuation() {
                    cont.resume(throwing: PnevmaError.bridgeCallFailed(method: method))
                }
                throw PnevmaError.bridgeCallFailed(method: method)
            }

            guard let result = try await group.next() else {
                throw PnevmaError.bridgeCallFailed(method: method)
            }
            group.cancelAll()
            return result
        }
    }

    /// Call a Rust command and decode the JSON result.
    /// Races the FFI callback against a 30-second timeout to prevent indefinite hangs.
    func call<T: Decodable & Sendable>(method: String, params: (any Encodable & Sendable)? = nil) async throws -> T {
        let paramsJSON: String
        if let params = params {
            let encoder = JSONEncoder()
            encoder.keyEncodingStrategy = .convertToSnakeCase
            let data = try encoder.encode(params)
            paramsJSON = String(data: data, encoding: .utf8) ?? "{}"
        } else {
            paramsJSON = "{}"
        }

        return try await withThrowingTaskGroup(of: T.self) { group in
            // Continuation guard prevents double-resume when callback fires after timeout.
            let continuationGuard = ContinuationGuard<T>(method: method)

            group.addTask {
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<T, Error>) in
                    continuationGuard.setContinuation(continuation)

                    self.bridge.callAsync(method: method, params: paramsJSON) { resultJSON in
                        guard let cont: CheckedContinuation<T, Error> = continuationGuard.takeContinuation() else { return }

                        guard let result = resultJSON else {
                            cont.resume(throwing: PnevmaError.bridgeCallFailed(method: method))
                            return
                        }

                        guard result.ok else {
                            cont.resume(
                                throwing: PnevmaError.backendError(method: method, message: result.payload)
                            )
                            return
                        }

                        guard let data = result.payload.data(using: .utf8) else {
                            cont.resume(throwing: PnevmaError.invalidResponse)
                            return
                        }

                        do {
                            let decoder = PnevmaJSON.decoder()
                            let decoded = try decoder.decode(T.self, from: data)
                            cont.resume(returning: decoded)
                        } catch {
                            cont.resume(
                                throwing: PnevmaError.decodingFailed(method: method, error: error)
                            )
                        }
                    }
                }
            }

            group.addTask {
                try await Task.sleep(nanoseconds: 30_000_000_000) // 30 seconds
                if let cont = continuationGuard.takeContinuation() {
                    cont.resume(throwing: PnevmaError.bridgeCallFailed(method: method))
                }
                throw PnevmaError.bridgeCallFailed(method: method)
            }

            guard let result = try await group.next() else {
                throw PnevmaError.bridgeCallFailed(method: method)
            }
            group.cancelAll()
            return result
        }
    }
}

// SAFETY: @unchecked Sendable is safe here because this class is @MainActor-isolated,
// ensuring all property access happens on the main thread. The Sendable conformance
// is needed only to pass references across isolation boundaries (e.g., into Tasks).
@MainActor
final class ActiveWorkspaceCommandBus: CommandCalling, @unchecked Sendable {
    private let fallback: any CommandCalling
    private let activeCommandBusProvider: @MainActor () -> (any CommandCalling)?

    init(
        fallback: any CommandCalling,
        activeCommandBusProvider: @escaping @MainActor () -> (any CommandCalling)?
    ) {
        self.fallback = fallback
        self.activeCommandBusProvider = activeCommandBusProvider
    }

    func call<T: Decodable & Sendable>(method: String, params: (any Encodable & Sendable)?) async throws -> T {
        let bus = activeCommandBusProvider() ?? fallback
        return try await bus.call(method: method, params: params)
    }
}

enum PnevmaError: Error, LocalizedError {
    case bridgeCallFailed(method: String)
    case backendError(method: String, message: String)
    case invalidResponse
    case decodingFailed(method: String, error: Error)

    var errorDescription: String? {
        switch self {
        case .bridgeCallFailed(let method):
            return "The backend did not respond to \(method)."
        case .backendError(_, let message):
            return Self.describeBackendMessage(message)
        case .invalidResponse:
            return "The backend returned an invalid response."
        case .decodingFailed(let method, let error):
            return "Failed to decode backend response for \(method): \(Self.describeDecodingError(error))"
        }
    }

    /// Returns true when the error indicates the project is not open yet — view models
    /// should show a "waiting" state rather than a hard failure for this.
    ///
    /// Prefers a typed check against `PnevmaError.backendError` with the raw Rust message
    /// `"no open project"` (see `route_method` in `pnevma-commands`). Falls back to
    /// localized-description string matching for wrapped or non-`PnevmaError` errors.
    static func isProjectNotReady(_ error: Error) -> Bool {
        if case .backendError(_, let message) = error as? PnevmaError {
            return message == "no open project"
        }
        // Fallback for errors that may wrap a PnevmaError (e.g. NSError bridging).
        let desc = error.localizedDescription
        return desc.contains("No active project") || desc.contains("no open project")
    }

    private static func describeBackendMessage(_ message: String) -> String {
        switch message {
        case "workspace_not_trusted":
            return "Workspace trust is required before this project can open."
        case "workspace_config_changed":
            return "The workspace configuration changed and must be trusted again before opening."
        case "workspace_not_initialized":
            return "This workspace is missing pnevma.toml and the .pnevma support files. Initialize the project scaffold to open it."
        case "no open project":
            return "No active project is available."
        case "no projects available":
            return "No trusted or open projects are available."
        default:
            if message.hasPrefix("unknown method: analytics.usage_") {
                return "This build is using an older backend binary. Rebuild the app so the Rust bridge matches the native UI."
            }
            return message
        }
    }

    private static func describeDecodingError(_ error: Error) -> String {
        guard let decodingError = error as? DecodingError else {
            return error.localizedDescription
        }

        switch decodingError {
        case .keyNotFound(let key, let context):
            let path = codingPathDescription(context.codingPath)
            return path.isEmpty
                ? "missing key '\(key.stringValue)'"
                : "missing key '\(key.stringValue)' at \(path)"
        case .typeMismatch(_, let context),
             .valueNotFound(_, let context),
             .dataCorrupted(let context):
            let path = codingPathDescription(context.codingPath)
            return path.isEmpty ? context.debugDescription : "\(context.debugDescription) at \(path)"
        @unknown default:
            return error.localizedDescription
        }
    }

    private static func codingPathDescription(_ codingPath: [CodingKey]) -> String {
        codingPath
            .map(\.stringValue)
            .filter { !$0.isEmpty }
            .joined(separator: ".")
    }
}

struct OkResponse: Decodable {
    let ok: Bool
}

struct TaskDispatchResponse: Decodable {
    let status: String
}
