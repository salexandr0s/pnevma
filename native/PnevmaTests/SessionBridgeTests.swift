import XCTest
@testable import Pnevma

private struct AnyEncodable: Encodable {
    private let encodeValue: (Encoder) throws -> Void

    init(_ value: any Encodable) {
        self.encodeValue = value.encode(to:)
    }

    func encode(to encoder: Encoder) throws {
        try encodeValue(encoder)
    }
}

private actor SessionBridgeCommandBusStub: CommandCalling {
    enum StubError: Error {
        case invalidParams
        case unsupportedMethod
    }

    private var lastCreateParams: [String: Any]?

    func call<T: Decodable>(method: String, params: Encodable?) async throws -> T {
        switch method {
        case "session.new":
            guard let params else {
                throw StubError.invalidParams
            }
            let data = try JSONEncoder().encode(AnyEncodable(params))
            lastCreateParams = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            return try decode(
                #"""
                {
                  "session_id": "session-1",
                  "binding": {
                    "session_id": "session-1",
                    "mode": "live_attach",
                    "cwd": "/tmp/project",
                    "env": [],
                    "wait_after_command": false,
                    "recovery_options": []
                  }
                }
                """#
            )
        default:
            throw StubError.unsupportedMethod
        }
    }

    func lastCreateCommand() -> String? {
        lastCreateParams?["command"] as? String
    }

    func lastCreateCwd() -> String? {
        lastCreateParams?["cwd"] as? String
    }

    private func decode<T: Decodable>(_ json: String) throws -> T {
        try PnevmaJSON.decoder().decode(T.self, from: Data(json.utf8))
    }
}

@MainActor
final class SessionBridgeTests: XCTestCase {
    func testCreateSessionUsesConfiguredDefaultShell() async throws {
        let bus = SessionBridgeCommandBusStub()
        let bridge = SessionBridge(commandBus: bus) { "/tmp/project" }
        bridge.defaultShell = "/bin/bash"

        _ = try await bridge.createSession(workingDirectory: nil)

        let recordedCwd = await bus.lastCreateCwd()
        let recordedCommand = await bus.lastCreateCommand()

        XCTAssertEqual(recordedCwd, "/tmp/project")
        XCTAssertEqual(recordedCommand, "/bin/bash")
    }
}
