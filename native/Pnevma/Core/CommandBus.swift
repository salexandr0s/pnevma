import Foundation

/// Convenience wrapper for making typed calls to the Rust backend.
/// All calls are dispatched to a background queue to avoid blocking the main thread.
protocol CommandCalling {
    func call<T: Decodable>(method: String, params: Encodable?) async throws -> T
}

actor CommandBus: CommandCalling {
    static var shared: CommandBus!

    private let bridge: PnevmaBridge

    init(bridge: PnevmaBridge) {
        self.bridge = bridge
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
                    let decoder = JSONDecoder()
                    decoder.keyDecodingStrategy = .convertFromSnakeCase
                    decoder.dateDecodingStrategy = .iso8601
                    let decoded = try decoder.decode(T.self, from: data)
                    continuation.resume(returning: decoded)
                } catch {
                    continuation.resume(throwing: PnevmaError.decodingFailed(error))
                }
            }
        }
    }
}

enum PnevmaError: Error, LocalizedError {
    case bridgeCallFailed(method: String)
    case backendError(method: String, message: String)
    case invalidResponse
    case decodingFailed(Error)

    var errorDescription: String? {
        switch self {
        case .bridgeCallFailed(let method):
            return "The backend did not respond to \(method)."
        case .backendError(_, let message):
            return Self.describeBackendMessage(message)
        case .invalidResponse:
            return "The backend returned an invalid response."
        case .decodingFailed(let error):
            return "Failed to decode the backend response: \(error.localizedDescription)"
        }
    }

    private static func describeBackendMessage(_ message: String) -> String {
        switch message {
        case "workspace_not_trusted":
            return "Workspace trust is required before this project can open."
        case "workspace_config_changed":
            return "The workspace configuration changed and must be trusted again before opening."
        case "no open project":
            return "No active project is available."
        default:
            return message
        }
    }
}

struct OkResponse: Decodable {
    let ok: Bool
}

struct TaskDispatchResponse: Decodable {
    let status: String
}
