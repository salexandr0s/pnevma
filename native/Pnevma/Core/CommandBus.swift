import Foundation

/// Convenience wrapper for making typed calls to the Rust backend.
/// All calls are dispatched to a background queue to avoid blocking the main thread.
actor CommandBus {
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
                guard let resultJSON = resultJSON else {
                    continuation.resume(throwing: PnevmaError.bridgeCallFailed(method: method))
                    return
                }

                guard let data = resultJSON.data(using: .utf8) else {
                    continuation.resume(throwing: PnevmaError.invalidResponse)
                    return
                }

                do {
                    let decoder = JSONDecoder()
                    decoder.keyDecodingStrategy = .convertFromSnakeCase
                    let decoded = try decoder.decode(T.self, from: data)
                    continuation.resume(returning: decoded)
                } catch {
                    continuation.resume(throwing: PnevmaError.decodingFailed(error))
                }
            }
        }
    }
}

enum PnevmaError: Error {
    case bridgeCallFailed(method: String)
    case invalidResponse
    case decodingFailed(Error)
}
