import Cocoa
import XCTest
@testable import Pnevma

@MainActor
final class WorkspaceRestoreTests: XCTestCase {

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

    func testContentAreaViewFallsBackToReplayPaneWhenDescriptorMissing() {
        let (_, rootPane) = PaneFactory.makeTerminal()
        let contentArea = ContentAreaView(
            frame: NSRect(x: 0, y: 0, width: 1200, height: 800),
            rootPaneView: rootPane
        )

        let missingDescriptorPaneID = UUID()
        let engine = PaneLayoutEngine(rootPaneID: missingDescriptorPaneID)
        contentArea.setLayoutEngine(engine)

        XCTAssertEqual(contentArea.paneCount, 1)
        XCTAssertEqual(contentArea.activePaneView?.paneType, "replay")
        XCTAssertEqual(
            contentArea.activePaneView?.metadataJSON,
            "{\"fallback\":\"missing_descriptor\"}"
        )
    }
}
