import AppKit
import XCTest
@testable import Pnevma

private struct TerminalPaneAnyEncodable: Encodable {
    private let encodeValue: (Encoder) throws -> Void

    init(_ value: any Encodable) {
        self.encodeValue = value.encode(to:)
    }

    func encode(to encoder: Encoder) throws {
        try encodeValue(encoder)
    }
}

private actor TerminalPaneCommandBus: CommandCalling {
    private var createSessionCallCountValue = 0

    func call<T: Decodable & Sendable>(method: String, params: (any Encodable & Sendable)?) async throws -> T {
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

private actor RetryingTerminalPaneCommandBus: CommandCalling {
    private var createSessionCallCountValue = 0

    func call<T: Decodable & Sendable>(method: String, params: (any Encodable & Sendable)?) async throws -> T {
        switch method {
        case "session.new":
            createSessionCallCountValue += 1
            if createSessionCallCountValue == 1 {
                throw PnevmaError.backendError(method: method, message: "no open project")
            }
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
            throw NSError(domain: "RetryingTerminalPaneCommandBus", code: 1)
        }
    }

    func createSessionCallCount() -> Int {
        createSessionCallCountValue
    }

    private func decode<T: Decodable>(_ json: String) throws -> T {
        try PnevmaJSON.decoder().decode(T.self, from: Data(json.utf8))
    }
}

private actor ExistingSessionTerminalPaneCommandBus: CommandCalling {
    private var createSessionCallCountValue = 0
    private var bindingCallCountValue = 0
    private var lastBoundSessionIDValue: String?

    func call<T: Decodable & Sendable>(method: String, params: (any Encodable & Sendable)?) async throws -> T {
        switch method {
        case "session.new":
            createSessionCallCountValue += 1
            throw NSError(domain: "ExistingSessionTerminalPaneCommandBus", code: 1)
        case "session.binding":
            bindingCallCountValue += 1
            if let params {
                let data = try JSONEncoder().encode(TerminalPaneAnyEncodable(params))
                let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
                lastBoundSessionIDValue = json?["session_id"] as? String ?? json?["sessionID"] as? String
            }
            let sessionID = lastBoundSessionIDValue ?? "session-existing"
            return try decode(
                #"""
                {
                  "session_id": "\#(sessionID)",
                  "mode": "live_attach",
                  "cwd": "/tmp/project",
                  "env": [],
                  "wait_after_command": false,
                  "recovery_options": []
                }
                """#
            )
        default:
            throw NSError(domain: "ExistingSessionTerminalPaneCommandBus", code: 2)
        }
    }

    func createSessionCallCount() -> Int {
        createSessionCallCountValue
    }

    func bindingCallCount() -> Int {
        bindingCallCountValue
    }

    func lastBoundSessionID() -> String? {
        lastBoundSessionIDValue
    }

    private func decode<T: Decodable>(_ json: String) throws -> T {
        try PnevmaJSON.decoder().decode(T.self, from: Data(json.utf8))
    }
}

private actor MissingSessionTerminalPaneCommandBus: CommandCalling {
    private var bindingCallCountValue = 0

    func call<T: Decodable & Sendable>(method: String, params: (any Encodable & Sendable)?) async throws -> T {
        switch method {
        case "session.binding":
            bindingCallCountValue += 1
            throw PnevmaError.backendError(method: method, message: "session not found: session-missing")
        default:
            throw NSError(domain: "MissingSessionTerminalPaneCommandBus", code: 1)
        }
    }

    func bindingCallCount() -> Int {
        bindingCallCountValue
    }
}

private actor ArchivedSessionTerminalPaneCommandBus: CommandCalling {
    private var bindingCallCountValue = 0

    func call<T: Decodable & Sendable>(method: String, params: (any Encodable & Sendable)?) async throws -> T {
        switch method {
        case "session.binding":
            bindingCallCountValue += 1
            return try decode(
                #"""
                {
                  "session_id": "session-archived",
                  "backend": "tmux_compat",
                  "durability": "durable",
                  "lifecycle_state": "exited",
                  "mode": "archived",
                  "cwd": "/tmp/project",
                  "launch_command": null,
                  "env": [],
                  "wait_after_command": false,
                  "recovery_options": [
                    {
                      "id": "restart",
                      "label": "Restart Session",
                      "description": "Restart backend process and rebind panes.",
                      "enabled": true
                    }
                  ]
                }
                """#
            )
        case "session.scrollback":
            return try decode(
                #"""
                {
                  "session_id": "session-archived",
                  "start_offset": 0,
                  "end_offset": 12,
                  "total_bytes": 12,
                  "data": "restored log"
                }
                """#
            )
        default:
            throw NSError(domain: "ArchivedSessionTerminalPaneCommandBus", code: 1)
        }
    }

    func bindingCallCount() -> Int {
        bindingCallCountValue
    }

    private func decode<T: Decodable>(_ json: String) throws -> T {
        try PnevmaJSON.decoder().decode(T.self, from: Data(json.utf8))
    }
}

@MainActor
final class TerminalPaneViewTests: XCTestCase {
    override func setUp() {
        super.setUp()
        MainActor.assumeIsolated {
            _ = NSApplication.shared
        }
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

    func testTerminalPaneRetriesWhenProjectIsStillNotReadyAfterActivationOpens() async throws {
        let bus = RetryingTerminalPaneCommandBus()
        let activationHub = ActiveWorkspaceActivationHub()
        let bridge = SessionBridge(commandBus: bus) { "/tmp/project" }
        let priorBridge = PaneFactory.sessionBridge
        PaneFactory.sessionBridge = bridge
        defer { PaneFactory.sessionBridge = priorBridge }

        activationHub.update(.open(workspaceID: UUID(), projectID: "project-1"))

        let pane = TerminalPaneView(
            workingDirectory: "/tmp/project",
            activationHub: activationHub
        )
        defer { pane.dispose() }

        try await waitUntil(timeoutNanos: 2_000_000_000) {
            await bus.createSessionCallCount() == 2 && pane.sessionID == "session-1"
        }
    }

    func testTerminalPaneLoadsExistingSessionIntoDeferredPane() async throws {
        let bus = ExistingSessionTerminalPaneCommandBus()
        let activationHub = ActiveWorkspaceActivationHub()
        let bridge = SessionBridge(commandBus: bus) { "/tmp/project" }
        let priorBridge = PaneFactory.sessionBridge
        let priorWorkspaceProvider = PaneFactory.activeWorkspaceProvider
        PaneFactory.sessionBridge = bridge
        PaneFactory.activeWorkspaceProvider = {
            Workspace(name: "Project", projectPath: "/tmp/project")
        }
        defer {
            PaneFactory.sessionBridge = priorBridge
            PaneFactory.activeWorkspaceProvider = priorWorkspaceProvider
        }

        activationHub.update(.open(workspaceID: UUID(), projectID: "project-1"))

        let pane = TerminalPaneView(
            workingDirectory: "/tmp/project",
            autoStartIfNeeded: false,
            launchMetadata: TerminalLaunchMetadata(
                launchMode: .localShell,
                startBehavior: .deferUntilActivate,
                remoteTarget: nil
            ),
            activationHub: activationHub
        )
        defer { pane.dispose() }

        pane.loadSession(sessionID: "session-existing", workingDirectory: "/tmp/project")

        try await waitUntil {
            await bus.bindingCallCount() == 1 && pane.sessionID == "session-existing"
        }

        let createSessionCallCount = await bus.createSessionCallCount()
        let lastBoundSessionID = await bus.lastBoundSessionID()

        XCTAssertEqual(createSessionCallCount, 0)
        XCTAssertEqual(lastBoundSessionID, "session-existing")
        XCTAssertEqual(
            TerminalLaunchMetadata.from(json: pane.metadataJSON)?.launchMode,
            .managedSession
        )
    }

    func testTerminalPaneClearsMissingRestoredSessionIntoStaleState() async throws {
        let bus = MissingSessionTerminalPaneCommandBus()
        let activationHub = ActiveWorkspaceActivationHub()
        let bridge = SessionBridge(commandBus: bus) { "/tmp/project" }
        let priorBridge = PaneFactory.sessionBridge
        let priorWorkspaceProvider = PaneFactory.activeWorkspaceProvider
        PaneFactory.sessionBridge = bridge
        PaneFactory.activeWorkspaceProvider = {
            Workspace(name: "Project", projectPath: "/tmp/project")
        }
        defer {
            PaneFactory.sessionBridge = priorBridge
            PaneFactory.activeWorkspaceProvider = priorWorkspaceProvider
        }

        activationHub.update(.open(workspaceID: UUID(), projectID: "project-1"))

        let pane = TerminalPaneView(
            workingDirectory: "/tmp/project",
            autoStartIfNeeded: false,
            launchMetadata: TerminalLaunchMetadata(
                launchMode: .localShell,
                startBehavior: .deferUntilActivate,
                remoteTarget: nil
            ),
            activationHub: activationHub
        )
        defer { pane.dispose() }

        pane.loadSession(sessionID: "session-missing", workingDirectory: "/tmp/project")

        try await waitUntil {
            await bus.bindingCallCount() == 1 && pane.sessionID == nil
        }

        XCTAssertEqual(
            TerminalLaunchMetadata.from(json: pane.metadataJSON)?.launchMode,
            .managedSession
        )
    }

    func testTerminalPaneKeepsArchivedRestoredSessionAvailableForRecovery() async throws {
        let bus = ArchivedSessionTerminalPaneCommandBus()
        let activationHub = ActiveWorkspaceActivationHub()
        let bridge = SessionBridge(commandBus: bus) { "/tmp/project" }
        let priorBridge = PaneFactory.sessionBridge
        let priorWorkspaceProvider = PaneFactory.activeWorkspaceProvider
        PaneFactory.sessionBridge = bridge
        PaneFactory.activeWorkspaceProvider = {
            Workspace(name: "Project", projectPath: "/tmp/project")
        }
        defer {
            PaneFactory.sessionBridge = priorBridge
            PaneFactory.activeWorkspaceProvider = priorWorkspaceProvider
        }

        activationHub.update(.open(workspaceID: UUID(), projectID: "project-1"))

        let pane = TerminalPaneView(
            workingDirectory: "/tmp/project",
            autoStartIfNeeded: false,
            launchMetadata: TerminalLaunchMetadata(
                launchMode: .localShell,
                startBehavior: .deferUntilActivate,
                remoteTarget: nil
            ),
            activationHub: activationHub
        )
        defer { pane.dispose() }

        pane.loadSession(sessionID: "session-archived", workingDirectory: "/tmp/project")

        try await waitUntil {
            await bus.bindingCallCount() == 1 && pane.sessionID == "session-archived"
        }

        XCTAssertEqual(
            TerminalLaunchMetadata.from(json: pane.metadataJSON)?.launchMode,
            .managedSession
        )
    }

    func testActiveTerminalPaneFocusesHostViewAfterJoiningWindow() throws {
        let bus = TerminalPaneCommandBus()
        let bridge = SessionBridge(commandBus: bus) { "/tmp/project" }
        let priorBridge = PaneFactory.sessionBridge
        PaneFactory.sessionBridge = bridge
        defer { PaneFactory.sessionBridge = priorBridge }

        let pane = TerminalPaneView(
            workingDirectory: "/tmp/project",
            autoStartIfNeeded: true,
            launchMetadata: TerminalLaunchMetadata(
                launchMode: .localShell,
                startBehavior: .immediate,
                remoteTarget: nil
            ),
            activationHub: ActiveWorkspaceActivationHub()
        )
        defer { pane.dispose() }

        pane.activate()

        let hostView = try XCTUnwrap(pane.subviews.compactMap { $0 as? TerminalHostView }.first)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        let contentView = NSView(frame: window.contentLayoutRect)
        window.contentView = contentView

        pane.frame = contentView.bounds
        contentView.addSubview(pane)

        XCTAssertTrue(window.firstResponder === hostView)
    }

    func testPlainTypingDismissesAgentLauncher() throws {
        let event = try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: "a",
            charactersIgnoringModifiers: "a",
            isARepeat: false,
            keyCode: 0
        ))

        XCTAssertTrue(TerminalPaneView.shouldDismissAgentLauncher(for: event))
    }

    func testCommandDSplitShortcutDoesNotDismissAgentLauncher() throws {
        let event = try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [.command],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: "d",
            charactersIgnoringModifiers: "d",
            isARepeat: false,
            keyCode: 2
        ))

        XCTAssertFalse(TerminalPaneView.shouldDismissAgentLauncher(for: event))
    }

    func testShiftCommandDSplitShortcutDoesNotDismissAgentLauncher() throws {
        let event = try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [.command, .shift],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: "D",
            charactersIgnoringModifiers: "d",
            isARepeat: false,
            keyCode: 2
        ))

        XCTAssertFalse(TerminalPaneView.shouldDismissAgentLauncher(for: event))
    }

    func testSplitKeepsAgentLauncherVisibleInOriginalAndNewPane() {
        let firstPane = TerminalPaneView(
            workingDirectory: "/tmp/project-a",
            autoStartIfNeeded: false,
            launchMetadata: TerminalLaunchMetadata(
                launchMode: .localShell,
                startBehavior: .deferUntilActivate,
                remoteTarget: nil
            ),
            activationHub: ActiveWorkspaceActivationHub()
        )
        let secondPane = TerminalPaneView(
            workingDirectory: "/tmp/project-b",
            autoStartIfNeeded: false,
            launchMetadata: TerminalLaunchMetadata(
                launchMode: .localShell,
                startBehavior: .deferUntilActivate,
                remoteTarget: nil
            ),
            activationHub: ActiveWorkspaceActivationHub()
        )
        defer {
            firstPane.dispose()
            secondPane.dispose()
        }

        let contentArea = ContentAreaView(
            frame: NSRect(x: 0, y: 0, width: 800, height: 600),
            rootPaneView: firstPane
        )

        firstPane.installAgentLauncherForTesting()
        secondPane.installAgentLauncherForTesting()

        XCTAssertTrue(firstPane.hasAgentLauncherOverlay)
        XCTAssertTrue(secondPane.hasAgentLauncherOverlay)
        XCTAssertNotNil(contentArea.splitActivePane(direction: .horizontal, newPaneView: secondPane))
        XCTAssertTrue(firstPane.hasAgentLauncherOverlay)
        XCTAssertTrue(secondPane.hasAgentLauncherOverlay)
    }
}
