import XCTest
@testable import Pnevma

@MainActor
final class WorkspaceTabTests: XCTestCase {

    // MARK: - Tab Lifecycle

    func testNewWorkspaceHasOneTab() {
        let workspace = Workspace(name: "Test")
        XCTAssertEqual(workspace.tabs.count, 1)
        XCTAssertEqual(workspace.activeTabIndex, 0)
    }

    func testAddTabIncreasesCountAndActivatesNewTab() {
        let workspace = Workspace(name: "Test")
        let tab = workspace.addTab(title: "Second")
        XCTAssertEqual(workspace.tabs.count, 2)
        XCTAssertEqual(workspace.activeTabIndex, 1)
        XCTAssertEqual(tab.title, "Second")
    }

    func testAddMultipleTabs() {
        let workspace = Workspace(name: "Test")
        workspace.addTab(title: "Tab 2")
        workspace.addTab(title: "Tab 3")
        XCTAssertEqual(workspace.tabs.count, 3)
        XCTAssertEqual(workspace.activeTabIndex, 2)
    }

    func testEnsureActiveTabHasDisplayableRootPaneSeedsTerminalForBlankTab() {
        let workspace = Workspace(name: "Test")
        _ = workspace.addTab(title: "Second")

        let changed = workspace.ensureActiveTabHasDisplayableRootPane()

        let rootPaneID = workspace.layoutEngine.root?.allPaneIDs.first
        let pane = rootPaneID.flatMap { workspace.layoutEngine.persistedPane(for: $0) }
        XCTAssertTrue(changed)
        XCTAssertEqual(pane?.type, "terminal")
        XCTAssertEqual(pane?.workingDirectory, NSHomeDirectory())
    }

    func testEnsureActiveTabHasDisplayableRootPaneUsesWorkspaceProjectPath() {
        let workspace = Workspace(name: "Test", projectPath: "/tmp/project")
        _ = workspace.addTab(title: "Second")

        _ = workspace.ensureActiveTabHasDisplayableRootPane()

        let rootPaneID = workspace.layoutEngine.root?.allPaneIDs.first
        let pane = rootPaneID.flatMap { workspace.layoutEngine.persistedPane(for: $0) }
        XCTAssertEqual(pane?.type, "terminal")
        XCTAssertEqual(pane?.workingDirectory, "/tmp/project")
    }

    func testEnsureActiveTabHasDisplayableRootPaneUpgradesWelcomePaneForTerminalWorkspace() {
        let workspace = Workspace(name: "Test")
        let rootPaneID = workspace.layoutEngine.root!.allPaneIDs.first!
        workspace.layoutEngine.upsertPersistedPane(PersistedPane(
            paneID: rootPaneID,
            type: "welcome",
            workingDirectory: nil,
            sessionID: nil,
            taskID: nil,
            metadataJSON: nil
        ))

        let changed = workspace.ensureActiveTabHasDisplayableRootPane()

        let pane = workspace.layoutEngine.persistedPane(for: rootPaneID)
        XCTAssertTrue(changed)
        XCTAssertEqual(pane?.type, "terminal")
        XCTAssertEqual(pane?.workingDirectory, NSHomeDirectory())
    }

    func testEnsureActiveTabHasDisplayableRootPaneUpgradesWelcomePaneForProjectWorkspace() {
        let workspace = Workspace(name: "Test", projectPath: "/tmp/project")
        let rootPaneID = workspace.layoutEngine.root!.allPaneIDs.first!
        workspace.layoutEngine.upsertPersistedPane(PersistedPane(
            paneID: rootPaneID,
            type: "welcome",
            workingDirectory: nil,
            sessionID: nil,
            taskID: nil,
            metadataJSON: nil
        ))

        let changed = workspace.ensureActiveTabHasDisplayableRootPane()
        let pane = workspace.layoutEngine.persistedPane(for: rootPaneID)

        XCTAssertTrue(changed)
        XCTAssertEqual(pane?.type, "terminal")
        XCTAssertEqual(pane?.workingDirectory, "/tmp/project")
    }

    func testCloseTabRemovesIt() {
        let workspace = Workspace(name: "Test")
        workspace.addTab(title: "Tab 2")
        XCTAssertEqual(workspace.tabs.count, 2)

        let closed = workspace.closeTab(at: 1)
        XCTAssertTrue(closed)
        XCTAssertEqual(workspace.tabs.count, 1)
    }

    func testCannotCloseLastTab() {
        let workspace = Workspace(name: "Test")
        let closed = workspace.closeTab(at: 0)
        XCTAssertFalse(closed)
        XCTAssertEqual(workspace.tabs.count, 1)
    }

    func testCloseActiveTabAdjustsIndex() {
        let workspace = Workspace(name: "Test")
        workspace.addTab(title: "Tab 2")
        workspace.addTab(title: "Tab 3")
        // Active is tab 3 (index 2)
        workspace.switchToTab(1)
        // Active is tab 2 (index 1)
        workspace.closeTab(at: 1)
        // Tab 2 removed; tab 3 slides to index 1. Active should be clamped.
        XCTAssertEqual(workspace.tabs.count, 2)
        XCTAssertTrue(workspace.activeTabIndex < workspace.tabs.count)
    }

    func testCloseTabBeforeActiveAdjustsIndex() {
        let workspace = Workspace(name: "Test")
        workspace.addTab(title: "Tab 2")
        workspace.addTab(title: "Tab 3")
        // Active is tab 3 (index 2)
        workspace.closeTab(at: 0)
        // Tab 1 removed; active should shift down by 1
        XCTAssertEqual(workspace.activeTabIndex, 1)
        XCTAssertEqual(workspace.tabs.count, 2)
    }

    func testCloseTabAfterActiveKeepsIndex() {
        let workspace = Workspace(name: "Test")
        workspace.addTab(title: "Tab 2")
        workspace.addTab(title: "Tab 3")
        workspace.switchToTab(0)
        // Active is tab 1 (index 0)
        workspace.closeTab(at: 2)
        XCTAssertEqual(workspace.activeTabIndex, 0)
        XCTAssertEqual(workspace.tabs.count, 2)
    }

    func testCloseTabByID() {
        let workspace = Workspace(name: "Test")
        let tab2 = workspace.addTab(title: "Tab 2")
        XCTAssertTrue(workspace.closeTab(id: tab2.id))
        XCTAssertEqual(workspace.tabs.count, 1)
    }

    func testCloseTabByIDReturnsFalseForUnknown() {
        let workspace = Workspace(name: "Test")
        XCTAssertFalse(workspace.closeTab(id: UUID()))
    }

    // MARK: - Tab Switching

    func testSwitchToTabChangesActive() {
        let workspace = Workspace(name: "Test")
        workspace.addTab(title: "Tab 2")
        workspace.switchToTab(0)
        XCTAssertEqual(workspace.activeTabIndex, 0)
    }

    func testSwitchToInvalidIndexIsIgnored() {
        let workspace = Workspace(name: "Test")
        workspace.switchToTab(5)
        XCTAssertEqual(workspace.activeTabIndex, 0)
        workspace.switchToTab(-1)
        XCTAssertEqual(workspace.activeTabIndex, 0)
    }

    // MARK: - Layout Engine Identity

    func testLayoutEngineReturnsActiveTabEngine() {
        let workspace = Workspace(name: "Test")
        let tab2 = workspace.addTab(title: "Tab 2")
        XCTAssertTrue(workspace.layoutEngine === tab2.layoutEngine)
        workspace.switchToTab(0)
        XCTAssertTrue(workspace.layoutEngine === workspace.tabs[0].layoutEngine)
    }

    func testEachTabHasDistinctLayoutEngine() {
        let workspace = Workspace(name: "Test")
        let engine1 = workspace.layoutEngine
        workspace.addTab(title: "Tab 2")
        let engine2 = workspace.layoutEngine
        XCTAssertFalse(engine1 === engine2)
    }

    func testActiveTabPaneIDOfTypeReturnsPaneInCurrentTabOnly() {
        let workspace = Workspace(name: "Test")
        let browserPaneID = workspace.layoutEngine.root!.allPaneIDs.first!
        workspace.layoutEngine.upsertPersistedPane(PersistedPane(
            paneID: browserPaneID,
            type: "browser",
            workingDirectory: nil,
            sessionID: nil,
            taskID: nil,
            metadataJSON: nil
        ))

        let analyticsTab = workspace.addTab(title: "Analytics")
        let analyticsPaneID = analyticsTab.layoutEngine.root!.allPaneIDs.first!
        analyticsTab.layoutEngine.upsertPersistedPane(PersistedPane(
            paneID: analyticsPaneID,
            type: "analytics",
            workingDirectory: nil,
            sessionID: nil,
            taskID: nil,
            metadataJSON: nil
        ))

        XCTAssertEqual(workspace.activeTabPaneID(ofType: "analytics"), analyticsPaneID)
        XCTAssertNil(workspace.activeTabPaneID(ofType: "browser"))

        workspace.switchToTab(0)

        XCTAssertEqual(workspace.activeTabPaneID(ofType: "browser"), browserPaneID)
        XCTAssertNil(workspace.activeTabPaneID(ofType: "analytics"))
    }

    func testFirstPaneLocationOfTypeSearchesAcrossTabs() {
        let workspace = Workspace(name: "Test")
        let browserPaneID = workspace.layoutEngine.root!.allPaneIDs.first!
        workspace.layoutEngine.upsertPersistedPane(PersistedPane(
            paneID: browserPaneID,
            type: "browser",
            workingDirectory: nil,
            sessionID: nil,
            taskID: nil,
            metadataJSON: nil
        ))

        let reviewTab = workspace.addTab(title: "Review")
        let reviewPaneID = reviewTab.layoutEngine.root!.allPaneIDs.first!
        reviewTab.layoutEngine.upsertPersistedPane(PersistedPane(
            paneID: reviewPaneID,
            type: "review",
            workingDirectory: nil,
            sessionID: nil,
            taskID: nil,
            metadataJSON: nil
        ))

        XCTAssertEqual(
            workspace.firstPaneLocation(ofType: "browser"),
            WorkspacePaneLocation(tabIndex: 0, paneID: browserPaneID)
        )
        XCTAssertEqual(
            workspace.firstPaneLocation(ofType: "review"),
            WorkspacePaneLocation(tabIndex: 1, paneID: reviewPaneID)
        )
        XCTAssertNil(workspace.firstPaneLocation(ofType: "search"))
    }

    func testPreferredPaneLocationPrefersActiveTabOverEarlierTab() {
        let workspace = Workspace(name: "Test")
        let firstBrowserPaneID = workspace.layoutEngine.root!.allPaneIDs.first!
        workspace.layoutEngine.upsertPersistedPane(PersistedPane(
            paneID: firstBrowserPaneID,
            type: "browser",
            workingDirectory: nil,
            sessionID: nil,
            taskID: nil,
            metadataJSON: nil
        ))

        let browserTab = workspace.addTab(title: "Browser")
        let secondBrowserPaneID = browserTab.layoutEngine.root!.allPaneIDs.first!
        browserTab.layoutEngine.upsertPersistedPane(PersistedPane(
            paneID: secondBrowserPaneID,
            type: "browser",
            workingDirectory: nil,
            sessionID: nil,
            taskID: nil,
            metadataJSON: nil
        ))

        XCTAssertEqual(
            workspace.preferredPaneLocation(ofType: "browser"),
            WorkspacePaneLocation(tabIndex: 1, paneID: secondBrowserPaneID)
        )
        XCTAssertEqual(
            workspace.firstPaneLocation(ofType: "browser"),
            WorkspacePaneLocation(tabIndex: 0, paneID: firstBrowserPaneID)
        )
    }

    // MARK: - Snapshot Round-Trip

    func testSnapshotRoundTripPreservesTabsAndActiveIndex() {
        let workspace = Workspace(name: "Multi-tab")
        workspace.addTab(title: "Tab 2")
        workspace.addTab(title: "Tab 3")
        workspace.switchToTab(1)

        let snapshot = workspace.snapshot()
        let restored = Workspace(snapshot: snapshot)

        XCTAssertEqual(restored.tabs.count, 3)
        XCTAssertEqual(restored.activeTabIndex, 1)
        XCTAssertEqual(restored.tabs[1].title, "Tab 2")
    }

    func testSnapshotRoundTripPreservesPersistedPanes() {
        let workspace = Workspace(name: "Panes")
        let rootPaneID = workspace.layoutEngine.root!.allPaneIDs.first!
        workspace.layoutEngine.upsertPersistedPane(PersistedPane(
            paneID: rootPaneID,
            type: "terminal",
            workingDirectory: "/tmp/test",
            sessionID: "sess-1",
            taskID: nil,
            metadataJSON: nil
        ))

        let snapshot = workspace.snapshot()
        let restored = Workspace(snapshot: snapshot)

        let restoredPaneID = restored.layoutEngine.root?.allPaneIDs.first
        let restoredPane = restoredPaneID.flatMap { restored.layoutEngine.persistedPane(for: $0) }
        XCTAssertEqual(restoredPane?.type, "terminal")
        XCTAssertEqual(restoredPane?.workingDirectory, "/tmp/test")
    }

    func testLegacySnapshotWithoutTabsRestoresAsSingleTab() {
        // Simulate a legacy snapshot (pre-tabs): layoutData present, no tabSnapshots
        let engine = PaneLayoutEngine(rootPaneID: UUID())
        let layoutData = engine.serialize()

        let legacySnapshot = Workspace.Snapshot(
            id: UUID(),
            name: "Legacy",
            projectPath: "/tmp/legacy",
            kind: nil,
            location: nil,
            terminalMode: nil,
            remoteTarget: nil,
            tabSnapshots: nil,
            activeTabIndex: nil,
            layoutData: layoutData,
            customColor: nil,
            isPinned: false
        )

        let restored = Workspace(snapshot: legacySnapshot)
        XCTAssertEqual(restored.tabs.count, 1)
        XCTAssertEqual(restored.activeTabIndex, 0)
        XCTAssertEqual(restored.name, "Legacy")
    }

    // MARK: - PaneLayoutEngine.reset

    func testResetPreservesObjectIdentity() {
        let engine = PaneLayoutEngine(rootPaneID: UUID())
        let originalRef = engine

        let newPaneID = UUID()
        engine.reset(rootPaneID: newPaneID)

        XCTAssertTrue(engine === originalRef)
        XCTAssertEqual(engine.root?.allPaneIDs, [newPaneID])
        XCTAssertEqual(engine.activePaneID, newPaneID)
    }

    func testResetClearsExistingState() {
        let rootID = UUID()
        let engine = PaneLayoutEngine(rootPaneID: rootID)
        engine.upsertPersistedPane(PersistedPane(
            paneID: rootID, type: "terminal", workingDirectory: nil,
            sessionID: nil, taskID: nil, metadataJSON: nil
        ))
        engine.layout(in: NSRect(x: 0, y: 0, width: 800, height: 600))
        XCTAssertFalse(engine.paneFrames.isEmpty)

        let newID = UUID()
        engine.reset(rootPaneID: newID)

        XCTAssertTrue(engine.paneFrames.isEmpty)
        XCTAssertNil(engine.persistedPane(for: rootID))
        XCTAssertEqual(engine.root?.allPaneIDs, [newID])
    }
}
