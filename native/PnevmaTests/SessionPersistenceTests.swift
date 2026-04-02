import XCTest
@testable import Pnevma

final class SessionPersistenceTests: XCTestCase {

    private var persistence: SessionPersistence!
    private var tempDir: URL!

    override func setUp() {
        super.setUp()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("pnevma-tests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let saveURL = tempDir.appendingPathComponent("session.json")
        persistence = SessionPersistence(saveURL: saveURL)
    }

    override func tearDown() {
        persistence.stopAutoSave()
        persistence = nil
        if let tempDir = tempDir {
            try? FileManager.default.removeItem(at: tempDir)
        }
        tempDir = nil
        super.tearDown()
    }

    func testSaveAndRestoreRoundTrip() {
        let state = SessionPersistence.SessionState(
            windowFrame: SessionPersistence.CodableRect(NSRect(x: 100, y: 200, width: 1400, height: 900)),
            commandCenterWindowFrame: SessionPersistence.CodableRect(NSRect(x: 400, y: 500, width: 1200, height: 800)),
            commandCenterVisible: true,
            workspaces: [],
            activeWorkspaceID: nil,
            sidebarVisible: true,
            rightInspectorVisible: true,
            rightInspectorWidth: 340
        )
        persistence.save(state: state)

        let restored = persistence.restore()
        XCTAssertNotNil(restored)
        XCTAssertEqual(restored?.windowFrame?.x, 100)
        XCTAssertEqual(restored?.windowFrame?.width, 1400)
        XCTAssertEqual(restored?.commandCenterWindowFrame?.x, 400)
        XCTAssertEqual(restored?.commandCenterWindowFrame?.width, 1200)
        XCTAssertEqual(restored?.commandCenterVisible, true)
        XCTAssertEqual(restored?.sidebarVisible, true)
        XCTAssertEqual(restored?.rightInspectorVisible, true)
        XCTAssertEqual(restored?.rightInspectorWidth, 340)
    }

    @MainActor
    func testMarkDirtyAndSaveIfDirtyTriggersSave() {
        var saveCalled = false
        let state = SessionPersistence.SessionState(
            windowFrame: nil,
            workspaces: [],
            activeWorkspaceID: nil,
            sidebarVisible: false,
            rightInspectorVisible: false,
            rightInspectorWidth: 300
        )

        persistence.stateProvider = {
            saveCalled = true
            return state
        }

        // Mark dirty and trigger save cycle
        persistence.markDirty()
        // Start auto-save with a very short interval
        persistence.startAutoSave(interval: 0.1)

        let expectation = expectation(description: "auto-save fires")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            expectation.fulfill()
        }
        waitForExpectations(timeout: 2)

        XCTAssertTrue(saveCalled, "stateProvider should have been called after markDirty")
    }

    func testRestoreReturnsNilForMissingFile() {
        // No file has been saved to the temp directory yet
        let result = persistence.restore()
        XCTAssertNil(result, "restore should return nil when no session file exists")
    }

    func testSaveDoesNothingWhenPersistenceIsDisabled() {
        persistence.isPersistenceEnabled = false

        let state = SessionPersistence.SessionState(
            windowFrame: nil,
            workspaces: [],
            activeWorkspaceID: nil,
            sidebarVisible: true,
            rightInspectorVisible: true,
            rightInspectorWidth: nil
        )
        persistence.save(state: state)

        let saveURL = tempDir.appendingPathComponent("session.json")
        XCTAssertFalse(FileManager.default.fileExists(atPath: saveURL.path))
    }

    func testRestoreReturnsNilWhenPersistenceIsDisabled() {
        let state = SessionPersistence.SessionState(
            windowFrame: nil,
            workspaces: [],
            activeWorkspaceID: nil,
            sidebarVisible: true,
            rightInspectorVisible: true,
            rightInspectorWidth: nil
        )
        persistence.save(state: state)

        XCTAssertNil(persistence.restore(ifEnabled: false))
        XCTAssertNotNil(persistence.restore(ifEnabled: true))
    }

    func testRestoreDefaultsRightInspectorFieldsForLegacySessions() throws {
        let legacyJSON = #"""
        {
          "windowFrame": null,
          "workspaces": [],
          "activeWorkspaceID": null,
          "sidebarVisible": false
        }
        """#

        let decoded = try JSONDecoder().decode(
            SessionPersistence.SessionState.self,
            from: Data(legacyJSON.utf8)
        )

        XCTAssertFalse(decoded.sidebarVisible)
        XCTAssertNil(decoded.commandCenterWindowFrame)
        XCTAssertFalse(decoded.commandCenterVisible)
        XCTAssertTrue(decoded.rightInspectorVisible)
        XCTAssertNil(decoded.rightInspectorWidth)
        XCTAssertTrue(decoded.agentTeamWindows.isEmpty)
    }

    func testSaveAndRestorePreservesDetachedAgentTeamWindows() {
        let state = SessionPersistence.SessionState(
            windowFrame: nil,
            agentTeamWindows: [
                SessionPersistence.AgentTeamWindowState(
                    teamID: "team-1",
                    projectID: "project-1",
                    leaderSessionID: "leader-1",
                    leaderPaneID: "leader-pane",
                    memberSessionID: "member-1",
                    memberPaneID: "member-pane",
                    provider: "claude-code",
                    memberIndex: 1,
                    title: "Claude teammate 1",
                    frame: SessionPersistence.CodableRect(NSRect(x: 300, y: 120, width: 420, height: 260))
                )
            ],
            workspaces: [],
            activeWorkspaceID: nil,
            sidebarVisible: true,
            rightInspectorVisible: false,
            rightInspectorWidth: 320
        )

        persistence.save(state: state)

        let restored = persistence.restore()
        XCTAssertEqual(restored?.agentTeamWindows.count, 1)
        XCTAssertEqual(restored?.agentTeamWindows.first?.teamID, "team-1")
        XCTAssertEqual(restored?.agentTeamWindows.first?.memberPaneID, "member-pane")
        XCTAssertEqual(restored?.agentTeamWindows.first?.frame?.width, 420)
    }

    @MainActor
    func testSaveAndRestorePreservesWorkspaceSnapshots() {
        let workspace = Workspace(name: "Persisted")
        let state = SessionPersistence.SessionState(
            windowFrame: SessionPersistence.CodableRect(NSRect(x: 10, y: 20, width: 900, height: 700)),
            workspaces: [workspace.snapshot()],
            activeWorkspaceID: workspace.id,
            sidebarVisible: false,
            rightInspectorVisible: true,
            rightInspectorWidth: 360
        )

        persistence.save(state: state)

        let restored = persistence.restore()
        XCTAssertEqual(restored?.workspaces.count, 1)
        XCTAssertEqual(restored?.workspaces.first?.name, "Persisted")
        XCTAssertEqual(restored?.activeWorkspaceID, workspace.id)
        XCTAssertEqual(restored?.sidebarVisible, false)
        XCTAssertEqual(restored?.rightInspectorVisible, true)
        XCTAssertEqual(restored?.rightInspectorWidth, 360)
    }

    func testSaveWritesSessionFileWith0600Permissions() throws {
        let state = SessionPersistence.SessionState(
            windowFrame: nil,
            workspaces: [],
            activeWorkspaceID: nil,
            sidebarVisible: true,
            rightInspectorVisible: false,
            rightInspectorWidth: 320
        )

        persistence.save(state: state)

        let saveURL = tempDir.appendingPathComponent("session.json")
        let attributes = try FileManager.default.attributesOfItem(atPath: saveURL.path)
        let permissions = attributes[.posixPermissions] as? NSNumber
        XCTAssertEqual(permissions?.intValue, 0o600)
    }

    func testMarkDirtyFromMultipleThreads() {
        // Verify thread-safety of markDirty — should not crash or race.
        let group = DispatchGroup()
        let iterations = 1000
        let persistence = persistence!

        for _ in 0..<iterations {
            group.enter()
            DispatchQueue.global().async {
                persistence.markDirty()
                group.leave()
            }
        }

        let result = group.wait(timeout: .now() + 5)
        XCTAssertEqual(result, .success, "All markDirty calls should complete without deadlock")
    }

    @MainActor
    func testDirtyStateIsSavedAfterPersistenceIsReenabled() {
        let state = SessionPersistence.SessionState(
            windowFrame: nil,
            workspaces: [],
            activeWorkspaceID: nil,
            sidebarVisible: false,
            rightInspectorVisible: true,
            rightInspectorWidth: 340
        )
        var saveCount = 0
        persistence.stateProvider = {
            saveCount += 1
            return state
        }
        persistence.isPersistenceEnabled = false
        persistence.markDirty()
        persistence.startAutoSave(interval: 0.05)

        let disabledExpectation = expectation(description: "disabled auto-save interval elapses")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            disabledExpectation.fulfill()
        }
        waitForExpectations(timeout: 1)
        XCTAssertEqual(saveCount, 0)

        persistence.isPersistenceEnabled = true

        let enabledExpectation = expectation(description: "auto-save resumes after re-enable")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            enabledExpectation.fulfill()
        }
        waitForExpectations(timeout: 1)

        XCTAssertGreaterThanOrEqual(saveCount, 1)
        XCTAssertNotNil(persistence.restore())
    }

    // MARK: - Corruption Handling

    func testRestoreFromTruncatedJSON() {
        let saveURL = tempDir.appendingPathComponent("session.json")
        let truncated = #"{"windowFrame": null, "workspaces": [{"#
        try? truncated.data(using: .utf8)?.write(to: saveURL)

        let result = persistence.restore()
        XCTAssertNil(result, "restore from truncated JSON should return nil")
    }

    func testRestoreFromBinaryGarbage() {
        let saveURL = tempDir.appendingPathComponent("session.json")
        var bytes = Data(count: 256)
        for i in 0..<bytes.count { bytes[i] = UInt8(i % 256) }
        try? bytes.write(to: saveURL)

        let result = persistence.restore()
        XCTAssertNil(result, "restore from binary garbage should return nil")
    }

    func testRestoreFromEmptyFile() {
        let saveURL = tempDir.appendingPathComponent("session.json")
        try? Data().write(to: saveURL)

        let result = persistence.restore()
        XCTAssertNil(result, "restore from empty file should return nil")
    }

    func testRestoreFromWrongSchema() {
        let saveURL = tempDir.appendingPathComponent("session.json")
        let wrongSchema = "[]"
        try? wrongSchema.data(using: .utf8)?.write(to: saveURL)

        let result = persistence.restore()
        XCTAssertNil(result, "restore from wrong schema (JSON array) should return nil")
    }
}
