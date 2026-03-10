import AppKit
import XCTest
@testable import Pnevma

private actor TerminalPaneCommandBus: CommandCalling {
    private var createSessionCallCountValue = 0

    func call<T: Decodable>(method: String, params: Encodable?) async throws -> T {
        switch method {
        case "session.new":
            createSessionCallCountValue += 1
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
            throw NSError(domain: "TerminalPaneCommandBus", code: 1)
        }
    }

    func createSessionCallCount() -> Int {
        createSessionCallCountValue
    }

    private func decode<T: Decodable>(_ json: String) throws -> T {
        try PnevmaJSON.decoder().decode(T.self, from: Data(json.utf8))
    }
}

@MainActor
final class TerminalPaneViewTests: XCTestCase {
    override func setUp() {
        super.setUp()
        _ = NSApplication.shared
    }

    private func waitUntil(
        timeoutNanos: UInt64 = 1_000_000_000,
        pollIntervalNanos: UInt64 = 10_000_000,
        file: StaticString = #filePath,
        line: UInt = #line,
        _ condition: @escaping () async -> Bool
    ) async throws {
        let deadline = DispatchTime.now().uptimeNanoseconds + timeoutNanos
        while DispatchTime.now().uptimeNanoseconds < deadline {
            if await condition() {
                return
            }
            try await Task.sleep(nanoseconds: pollIntervalNanos)
        }
        XCTFail("Timed out waiting for terminal pane condition", file: file, line: line)
    }

    func testTerminalPaneWaitsForActivationBeforeCreatingSession() async throws {
        let bus = TerminalPaneCommandBus()
        let activationHub = ActiveWorkspaceActivationHub()
        let bridge = SessionBridge(commandBus: bus) { "/tmp/project" }
        let priorBridge = PaneFactory.sessionBridge
        PaneFactory.sessionBridge = bridge
        defer { PaneFactory.sessionBridge = priorBridge }

        activationHub.update(.opening(workspaceID: UUID(), generation: 1))

        let pane = TerminalPaneView(
            workingDirectory: "/tmp/project",
            activationHub: activationHub
        )
        defer { pane.dispose() }

        let initialCreateCount = await bus.createSessionCallCount()
        XCTAssertEqual(initialCreateCount, 0)
        XCTAssertNil(pane.sessionID)

        activationHub.update(.open(workspaceID: UUID(), projectID: "project-1"))
        BridgeEventHub.shared.post(
            BridgeEvent(
                name: "project_opened",
                payloadJSON: #"{"project_id":"project-1"}"#
            )
        )

        try await waitUntil {
            await bus.createSessionCallCount() == 1 && pane.sessionID == "session-1"
        }
    }
}
