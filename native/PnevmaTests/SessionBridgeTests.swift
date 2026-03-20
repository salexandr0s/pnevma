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
    private var customBindingJSON: String?

    init(customBindingJSON: String? = nil) {
        self.customBindingJSON = customBindingJSON
    }

    func call<T: Decodable & Sendable>(method: String, params: (any Encodable & Sendable)?) async throws -> T {
        switch method {
        case "session.new":
            guard let params else {
                throw StubError.invalidParams
            }
            let encoder = JSONEncoder()
            encoder.keyEncodingStrategy = .convertToSnakeCase
            let data = try encoder.encode(AnyEncodable(params))
            lastCreateParams = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            let bindingJSON = customBindingJSON ?? #"""
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
            return try decode(bindingJSON)
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

    func lastCreateRemoteProfileID() -> String? {
        (lastCreateParams?["remote_target"] as? [String: Any])?["ssh_profile_id"] as? String
    }

    func lastCreateRemotePath() -> String? {
        (lastCreateParams?["remote_target"] as? [String: Any])?["remote_path"] as? String
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

    func testBindingLaunchConfigurationPrefersBackendProvidedLaunchCommand() async throws {
        let bus = SessionBridgeCommandBusStub(customBindingJSON:
            #"""
            {
              "session_id": "session-1",
              "binding": {
                "session_id": "session-1",
                "backend": "tmux_compat",
                "durability": "durable",
                "lifecycle_state": "attached",
                "mode": "live_attach",
                "cwd": "/tmp/project",
                "launch_command": "echo backend-launch",
                "env": [],
                "wait_after_command": false,
                "recovery_options": []
              }
            }
            """#
        )
        let bridge = SessionBridge(commandBus: bus) { "/tmp/project" }

        let binding = try await bridge.createSession(workingDirectory: nil)
        let launch = try XCTUnwrap(binding.makeLaunchConfiguration())

        XCTAssertEqual(launch.workingDirectory, "/tmp/project")
        XCTAssertEqual(launch.command, "/bin/sh -lc 'echo backend-launch'")
    }

    func testCreateSessionEncodesStructuredRemoteTargetAndSkipsLocalDefaultShell() async throws {
        let bus = SessionBridgeCommandBusStub()
        let bridge = SessionBridge(commandBus: bus) { "/tmp/project" }
        bridge.defaultShell = "/bin/bash"
        let remoteTarget = WorkspaceRemoteTarget(
            sshProfileID: "ssh-profile-1",
            sshProfileName: "Builder",
            host: "example.internal",
            port: 22,
            user: "builder",
            identityFile: "/tmp/id_ed25519",
            proxyJump: "jump.internal",
            remotePath: "/srv/project"
        )

        _ = try await bridge.createSession(
            workingDirectory: remoteTarget.remotePath,
            command: nil,
            remoteTarget: remoteTarget
        )

        let recordedCommand = await bus.lastCreateCommand()
        let recordedProfileID = await bus.lastCreateRemoteProfileID()
        let recordedRemotePath = await bus.lastCreateRemotePath()

        XCTAssertEqual(recordedCommand, "")
        XCTAssertEqual(recordedProfileID, remoteTarget.sshProfileID)
        XCTAssertEqual(recordedRemotePath, remoteTarget.remotePath)
    }
}
