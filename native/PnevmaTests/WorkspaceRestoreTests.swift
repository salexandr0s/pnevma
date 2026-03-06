import Cocoa
import XCTest
@testable import Pnevma

private actor ActivationPaneCommandBus: CommandCalling {
    private var taskListCallCountValue = 0
    private var notificationListCallCountValue = 0

    func call<T: Decodable>(method: String, params: Encodable?) async throws -> T {
        switch method {
        case "task.list":
            taskListCallCountValue += 1
            return try decode(
                #"[{"id":"task-1","title":"Ready work","status":"Ready","priority":"P1","cost_usd":1.25}]"#
            )
        case "notification.list":
            notificationListCallCountValue += 1
            return try decode(
                #"[{"id":"note-1","level":"info","title":"Heads up","body":"hello","unread":true,"created_at":"2026-03-06T08:00:00Z","task_id":null,"session_id":null}]"#
            )
        default:
            throw NSError(domain: "ActivationPaneCommandBus", code: 1)
        }
    }

    func taskListCallCount() -> Int {
        taskListCallCountValue
    }

    func notificationListCallCount() -> Int {
        notificationListCallCountValue
    }

    private func decode<T: Decodable>(_ json: String) throws -> T {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(T.self, from: Data(json.utf8))
    }
}

@MainActor
final class WorkspaceRestoreTests: XCTestCase {
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
        XCTFail("Timed out waiting for async condition", file: file, line: line)
    }


    func testWorkspaceSnapshotRoundTripsPersistedPaneTypesAndActivePane() {
        let rootPaneID = UUID()
        let replayPaneID = UUID()
        let engine = PaneLayoutEngine(rootPaneID: rootPaneID)

        engine.upsertPersistedPane(
            PersistedPane(
                paneID: rootPaneID,
                type: "taskboard",
                workingDirectory: nil,
                sessionID: nil,
                taskID: nil,
                metadataJSON: "{\"section\":\"board\"}"
            )
        )

        XCTAssertEqual(
            engine.splitPane(rootPaneID, direction: .horizontal, newPaneID: replayPaneID),
            replayPaneID
        )
        engine.upsertPersistedPane(
            PersistedPane(
                paneID: replayPaneID,
                type: "replay",
                workingDirectory: nil,
                sessionID: "session-123",
                taskID: "task-123",
                metadataJSON: "{\"source\":\"restore-test\"}"
            )
        )
        engine.setActivePane(replayPaneID)

        let workspace = Workspace(name: "Restore", layoutEngine: engine)
        let restored = Workspace(snapshot: workspace.snapshot())

        XCTAssertEqual(restored.layoutEngine.activePaneID, replayPaneID)
        XCTAssertEqual(restored.layoutEngine.root?.allPaneIDs.count, 2)
        XCTAssertEqual(restored.layoutEngine.persistedPane(for: rootPaneID)?.type, "taskboard")
        XCTAssertEqual(restored.layoutEngine.persistedPane(for: replayPaneID)?.type, "replay")
        XCTAssertEqual(
            restored.layoutEngine.persistedPane(for: replayPaneID)?.sessionID,
            "session-123"
        )
    }

    func testWorkspaceManagerRestoreUsesPersistedActiveWorkspace() {
        let bridge = PnevmaBridge()
        let manager = WorkspaceManager(bridge: bridge, commandBus: CommandBus(bridge: bridge))

        let first = Workspace(name: "One")
        let second = Workspace(name: "Two")

        manager.restore(
            snapshots: [first.snapshot(), second.snapshot()],
            activeWorkspaceID: second.id
        )

        XCTAssertEqual(manager.workspaces.count, 2)
        XCTAssertEqual(manager.activeWorkspaceID, second.id)
        XCTAssertEqual(manager.activeWorkspace?.name, "Two")
    }

    func testContentAreaViewShowsRestoreErrorPaneWithoutMutatingStateWhenDescriptorMissing() {
        let (_, rootPane) = PaneFactory.makeTerminal()
        let contentArea = ContentAreaView(
            frame: NSRect(x: 0, y: 0, width: 1200, height: 800),
            rootPaneView: rootPane
        )

        let missingDescriptorPaneID = UUID()
        let engine = PaneLayoutEngine(rootPaneID: missingDescriptorPaneID)
        contentArea.setLayoutEngine(engine)
        contentArea.syncPersistedPanes()

        XCTAssertEqual(contentArea.paneCount, 1)
        XCTAssertEqual(contentArea.activePaneView?.paneType, "restore_error")
        XCTAssertFalse(contentArea.activePaneView?.shouldPersist ?? true)
        XCTAssertNil(engine.persistedPane(for: missingDescriptorPaneID))
    }

    func testTaskBoardViewModelWaitsForActivationBeforeLoading() async throws {
        let bus = ActivationPaneCommandBus()
        let activationHub = ActiveWorkspaceActivationHub()
        let bridgeHub = BridgeEventHub()
        let viewModel = TaskBoardViewModel(
            commandBus: bus,
            bridgeEventHub: bridgeHub,
            activationHub: activationHub
        )

        viewModel.activate()
        XCTAssertEqual(viewModel.statusMessage, "Waiting for project activation...")
        let initialTaskCalls = await bus.taskListCallCount()
        XCTAssertEqual(initialTaskCalls, 0)

        activationHub.update(.open(workspaceID: UUID(), projectID: "project-1"))

        try await waitUntil {
            await bus.taskListCallCount() == 1
                && viewModel.statusMessage == nil
                && viewModel.tasks(for: .ready).count == 1
        }
    }

    func testNotificationsViewModelWaitsForActivationBeforeLoading() async throws {
        let bus = ActivationPaneCommandBus()
        let activationHub = ActiveWorkspaceActivationHub()
        let bridgeHub = BridgeEventHub()
        let viewModel = NotificationsViewModel(
            commandBus: bus,
            bridgeEventHub: bridgeHub,
            activationHub: activationHub
        )

        viewModel.activate()
        XCTAssertEqual(viewModel.statusMessage, "Waiting for project activation...")
        let initialNotificationCalls = await bus.notificationListCallCount()
        XCTAssertEqual(initialNotificationCalls, 0)

        activationHub.update(.open(workspaceID: UUID(), projectID: "project-1"))

        try await waitUntil {
            await bus.notificationListCallCount() == 1
                && viewModel.statusMessage == nil
                && viewModel.notifications.count == 1
        }
    }
}
