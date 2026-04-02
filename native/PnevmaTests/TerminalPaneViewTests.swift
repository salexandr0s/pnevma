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
    private var lastCreateParamsValue: [String: Any]?

    func call<T: Decodable & Sendable>(method: String, params: (any Encodable & Sendable)?) async throws -> T {
        switch method {
        case "session.new":
            createSessionCallCountValue += 1
            if let params {
                let encoder = JSONEncoder()
                encoder.keyEncodingStrategy = .convertToSnakeCase
                let data = try encoder.encode(TerminalPaneAnyEncodable(params))
                lastCreateParamsValue = try JSONSerialization.jsonObject(with: data) as? [String: Any]
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
            throw NSError(domain: "TerminalPaneCommandBus", code: 1)
        }
    }

    func createSessionCallCount() -> Int {
        createSessionCallCountValue
    }

    func lastCreateCwd() -> String? {
        lastCreateParamsValue?["cwd"] as? String
    }

    func lastCreateCommand() -> String? {
        lastCreateParamsValue?["command"] as? String
    }

    func lastCreateRemoteProfileID() -> String? {
        (lastCreateParamsValue?["remote_target"] as? [String: Any])?["ssh_profile_id"] as? String
    }

    func lastCreateRemotePath() -> String? {
        (lastCreateParamsValue?["remote_target"] as? [String: Any])?["remote_path"] as? String
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
                let encoder = JSONEncoder()
                encoder.keyEncodingStrategy = .convertToSnakeCase
                let data = try encoder.encode(TerminalPaneAnyEncodable(params))
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

private actor RecordingSessionBridge: SessionBridging {
    private var killSessionIDs: [String] = []

    func createSession(
        name _: String,
        workingDirectory requestedWorkingDirectory: String?,
        command _: String?,
        remoteTarget _: WorkspaceRemoteTarget?
    ) async throws -> SessionBindingDescriptor {
        SessionBindingDescriptor(
            sessionID: "session-created",
            backend: nil,
            durability: nil,
            lifecycleState: nil,
            mode: "live_attach",
            cwd: requestedWorkingDirectory ?? "/tmp/project",
            launchCommand: "/bin/zsh -i",
            env: [],
            waitAfterCommand: false,
            recoveryOptions: []
        )
    }

    func binding(for sessionID: String) async throws -> SessionBindingDescriptor {
        SessionBindingDescriptor(
            sessionID: sessionID,
            backend: nil,
            durability: nil,
            lifecycleState: nil,
            mode: "archived",
            cwd: "/tmp/project",
            launchCommand: nil,
            env: [],
            waitAfterCommand: false,
            recoveryOptions: []
        )
    }

    func scrollback(for sessionID: String, limit: Int) async throws -> SessionScrollbackSlice {
        SessionScrollbackSlice(
            sessionID: sessionID,
            startOffset: 0,
            endOffset: 0,
            totalBytes: 0,
            data: ""
        )
    }

    func recover(sessionID _: String, action _: String) async throws -> SessionRecoveryResult {
        SessionRecoveryResult(ok: true, action: "retry", newSessionID: nil)
    }

    func sendResize(sessionID _: String, columns _: UInt16, rows _: UInt16) async {}

    func killSession(sessionID: String) async {
        killSessionIDs.append(sessionID)
    }

    func killCount() -> Int {
        killSessionIDs.count
    }

    func killedSessionIDs() -> [String] {
        killSessionIDs
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

    func testRemoteManagedTerminalCreatesStructuredRemoteBackendSession() async throws {
        let bus = TerminalPaneCommandBus()
        let activationHub = ActiveWorkspaceActivationHub()
        let bridge = SessionBridge(commandBus: bus) { "/tmp/project" }
        let priorBridge = PaneFactory.sessionBridge
        PaneFactory.sessionBridge = bridge
        defer { PaneFactory.sessionBridge = priorBridge }

        activationHub.update(.open(workspaceID: UUID(), projectID: "project-1"))

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

        let pane = TerminalPaneView(
            workingDirectory: remoteTarget.remotePath,
            launchMetadata: TerminalLaunchMetadata(
                launchMode: .managedSession,
                startBehavior: .immediate,
                remoteTarget: remoteTarget
            ),
            activationHub: activationHub
        )
        defer { pane.dispose() }

        try await waitUntil {
            await bus.createSessionCallCount() == 1 && pane.sessionID == "session-1"
        }

        let lastCreateCwd = await bus.lastCreateCwd()
        let lastCreateCommand = await bus.lastCreateCommand()
        let lastCreateRemoteProfileID = await bus.lastCreateRemoteProfileID()
        let lastCreateRemotePath = await bus.lastCreateRemotePath()

        XCTAssertEqual(lastCreateCwd, remoteTarget.remotePath)
        XCTAssertEqual(lastCreateCommand, "")
        XCTAssertEqual(lastCreateRemoteProfileID, remoteTarget.sshProfileID)
        XCTAssertEqual(lastCreateRemotePath, remoteTarget.remotePath)
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
            await bus.bindingCallCount() == 1
                && pane.sessionID == "session-archived"
                && pane.currentStateSnapshot?.scrollback == "restored log"
        }

        XCTAssertEqual(
            TerminalLaunchMetadata.from(json: pane.metadataJSON)?.launchMode,
            .managedSession
        )
        XCTAssertEqual(pane.currentStateSnapshot?.title, "Session Ended")
        XCTAssertEqual(
            pane.currentStateSnapshot?.message,
            "This terminal session is no longer live."
        )
        XCTAssertEqual(
            pane.currentStateSnapshot?.detail,
            "A cleaned transcript snapshot is shown below. Use Restore Previous Session to start a replacement managed session, or start a new session."
        )
        XCTAssertEqual(pane.currentStateSnapshot?.actionIDs, ["restore-previous"])
    }

    func testTerminalPaneStopsAutoReattachLoopAfterRepeatedLiveAttachStartupFailures() async throws {
        let bus = ExistingSessionTerminalPaneCommandBus()
        let activationHub = ActiveWorkspaceActivationHub()
        let bridge = SessionBridge(commandBus: bus) { "/tmp/project" }
        let priorBridge = PaneFactory.sessionBridge
        PaneFactory.sessionBridge = bridge
        defer { PaneFactory.sessionBridge = priorBridge }

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

        pane.loadSession(sessionID: "session-flaky", workingDirectory: "/tmp/project")

        try await waitUntil {
            await bus.bindingCallCount() == 1
                && pane.subviews.contains(where: { $0 is TerminalHostView })
        }

        for expectedBindingCount in 2...3 {
            let hostView = try XCTUnwrap(
                pane.subviews.compactMap { $0 as? TerminalHostView }.first
            )
            hostView.onTerminalClose?(false)

            try await waitUntil(timeoutNanos: 2_000_000_000) {
                await bus.bindingCallCount() == expectedBindingCount
                    && pane.subviews.contains(where: { $0 is TerminalHostView })
            }
        }

        let unstableHostView = try XCTUnwrap(
            pane.subviews.compactMap { $0 as? TerminalHostView }.first
        )
        unstableHostView.onTerminalClose?(false)

        try await Task.sleep(for: .milliseconds(500))
        let finalBindingCallCount = await bus.bindingCallCount()

        XCTAssertEqual(finalBindingCallCount, 3)
        XCTAssertEqual(pane.sessionID, "session-flaky")
        XCTAssertEqual(pane.currentStateSnapshot?.title, "Terminal Attach Failed")
        XCTAssertEqual(
            pane.currentStateSnapshot?.actionIDs,
            ["retry-attach"]
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

    func testAgentLauncherOverlayHostCapturesPointerHitsWithinOverlayFrame() throws {
        let pane = TerminalPaneView(
            workingDirectory: "/tmp/project",
            autoStartIfNeeded: false,
            launchMetadata: TerminalLaunchMetadata(
                launchMode: .localShell,
                startBehavior: .deferUntilActivate,
                remoteTarget: nil
            ),
            activationHub: ActiveWorkspaceActivationHub()
        )
        defer { pane.dispose() }

        let container = NSView(frame: NSRect(x: 0, y: 0, width: 320, height: 240))
        pane.frame = container.bounds
        container.addSubview(pane)

        pane.installAgentLauncherForTesting()
        container.layoutSubtreeIfNeeded()
        pane.layoutSubtreeIfNeeded()

        let overlayHost = try XCTUnwrap(
            pane.subviews.first { String(describing: type(of: $0)).contains("AgentLauncherOverlayView") }
        )
        let insidePoint = NSPoint(x: overlayHost.bounds.midX, y: overlayHost.bounds.midY)
        let outsidePoint = NSPoint(x: -1, y: overlayHost.bounds.midY)

        XCTAssertEqual(overlayHost.hitTest(insidePoint), overlayHost)
        XCTAssertNil(overlayHost.hitTest(outsidePoint))

        let paneInsidePoint = pane.convert(insidePoint, from: overlayHost)
        let paneOutsidePoint = pane.convert(outsidePoint, from: overlayHost)
        XCTAssertEqual(pane.hitTest(paneInsidePoint), pane)
        XCTAssertNotEqual(pane.hitTest(paneOutsidePoint), pane)
    }

    func testDisposeKillsOwnedSessionWhenNotTransferred() async throws {
        let bridge = RecordingSessionBridge()
        let priorBridge = PaneFactory.sessionBridge
        PaneFactory.sessionBridge = bridge
        defer { PaneFactory.sessionBridge = priorBridge }

        let pane = TerminalPaneView(
            workingDirectory: "/tmp/project",
            sessionID: "session-transfer",
            autoStartIfNeeded: false,
            launchMetadata: TerminalLaunchMetadata(
                launchMode: .managedSession,
                startBehavior: .deferUntilActivate,
                remoteTarget: nil
            ),
            activationHub: ActiveWorkspaceActivationHub()
        )

        try await waitUntil {
            pane.sessionID == "session-transfer"
        }

        pane.dispose()

        try await waitUntil {
            await bridge.killCount() == 1
        }
        let killedSessionIDs = await bridge.killedSessionIDs()
        XCTAssertEqual(killedSessionIDs, ["session-transfer"])
    }

    func testPrepareForTransferSuppressesSessionKillOnDispose() async throws {
        let bridge = RecordingSessionBridge()
        let priorBridge = PaneFactory.sessionBridge
        PaneFactory.sessionBridge = bridge
        defer { PaneFactory.sessionBridge = priorBridge }

        let pane = TerminalPaneView(
            workingDirectory: "/tmp/project",
            sessionID: "session-transfer",
            autoStartIfNeeded: false,
            launchMetadata: TerminalLaunchMetadata(
                launchMode: .managedSession,
                startBehavior: .deferUntilActivate,
                remoteTarget: nil
            ),
            activationHub: ActiveWorkspaceActivationHub()
        )

        try await waitUntil {
            pane.sessionID == "session-transfer"
        }

        pane.prepareForTransfer()
        pane.dispose()

        try await Task.sleep(for: .milliseconds(100))
        let killCount = await bridge.killCount()
        XCTAssertEqual(killCount, 0)
    }
}
