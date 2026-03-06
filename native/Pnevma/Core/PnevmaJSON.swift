import Foundation

private struct PnevmaCodingKey: CodingKey {
    let stringValue: String
    let intValue: Int?

    init?(stringValue: String) {
        self.stringValue = stringValue
        self.intValue = nil
    }

    init?(intValue: Int) {
        self.stringValue = "\(intValue)"
        self.intValue = intValue
    }
}

enum PnevmaJSON {
    private static let acronymSegments: [String: String] = [
        "api": "API",
        "ffi": "FFI",
        "id": "ID",
        "ids": "IDs",
        "pty": "PTY",
        "ssh": "SSH",
        "tls": "TLS",
        "uri": "URI",
        "url": "URL",
        "urls": "URLs",
        "ws": "WS",
    ]

    static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .custom { codingPath in
            let rawKey = codingPath.last?.stringValue ?? ""
            return PnevmaCodingKey(stringValue: decodeKey(rawKey))!
        }
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    static func decodeKey(_ rawKey: String) -> String {
        guard rawKey.contains("_") else {
            return rawKey
        }

        let segments = rawKey
            .split(separator: "_", omittingEmptySubsequences: true)
            .map { $0.lowercased() }
        guard let first = segments.first else {
            return rawKey
        }

        var decoded = first
        for segment in segments.dropFirst() {
            if let acronym = acronymSegments[segment] {
                decoded += acronym
                continue
            }

            decoded += segment.prefix(1).uppercased() + segment.dropFirst()
        }
        return decoded
    }
}
