import Foundation

/// Convenience wrapper for making typed calls to the Rust backend.
/// All calls are dispatched to a background queue to avoid blocking the main thread.
protocol CommandCalling: Sendable {
    func call<T: Decodable>(method: String, params: Encodable?) async throws -> T
}

extension CommandCalling {
    func call<T: Decodable>(method: String) async throws -> T {
        try await call(method: method, params: nil)
    }
}

actor CommandBus: CommandCalling {
    static var shared: (any CommandCalling)?

    private let bridge: PnevmaBridge

    init(bridge: PnevmaBridge) {
        self.bridge = bridge
    }

    /// Call a Rust command with pre-serialized JSON params and decode the result.
    func callRaw<T: Decodable>(method: String, paramsJSON: String) async throws -> T {
        return try await withCheckedThrowingContinuation { continuation in
            bridge.callAsync(method: method, params: paramsJSON) { resultJSON in
                guard let result = resultJSON else {
                    continuation.resume(throwing: PnevmaError.bridgeCallFailed(method: method))
                    return
                }

                guard result.ok else {
                    continuation.resume(
                        throwing: PnevmaError.backendError(method: method, message: result.payload)
                    )
                    return
                }

                guard let data = result.payload.data(using: .utf8) else {
                    continuation.resume(throwing: PnevmaError.invalidResponse)
                    return
                }

                do {
                    let decoder = PnevmaJSON.decoder()
                    let decoded = try decoder.decode(T.self, from: data)
                    continuation.resume(returning: decoded)
                } catch {
                    continuation.resume(
                        throwing: PnevmaError.decodingFailed(method: method, error: error)
                    )
                }
            }
        }
    }

    /// Call a Rust command and decode the JSON result.
    func call<T: Decodable>(method: String, params: Encodable? = nil) async throws -> T {
        let paramsJSON: String
        if let params = params {
            let encoder = JSONEncoder()
            encoder.keyEncodingStrategy = .convertToSnakeCase
            let data = try encoder.encode(params)
            paramsJSON = String(data: data, encoding: .utf8) ?? "{}"
        } else {
            paramsJSON = "{}"
        }

        return try await withCheckedThrowingContinuation { continuation in
            bridge.callAsync(method: method, params: paramsJSON) { resultJSON in
                guard let result = resultJSON else {
                    continuation.resume(throwing: PnevmaError.bridgeCallFailed(method: method))
                    return
                }

                guard result.ok else {
                    continuation.resume(
                        throwing: PnevmaError.backendError(method: method, message: result.payload)
                    )
                    return
                }

                guard let data = result.payload.data(using: .utf8) else {
                    continuation.resume(throwing: PnevmaError.invalidResponse)
                    return
                }

                do {
                    let decoder = PnevmaJSON.decoder()
                    let decoded = try decoder.decode(T.self, from: data)
                    continuation.resume(returning: decoded)
                } catch {
                    continuation.resume(
                        throwing: PnevmaError.decodingFailed(method: method, error: error)
                    )
                }
            }
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

    func call<T: Decodable>(method: String, params: Encodable?) async throws -> T {
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
