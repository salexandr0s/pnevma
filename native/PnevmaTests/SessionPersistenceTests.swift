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
            workspaces: [],
            activeWorkspaceID: nil,
            sidebarVisible: true
        )
        persistence.save(state: state)

        let restored = persistence.restore()
        XCTAssertNotNil(restored)
        XCTAssertEqual(restored?.windowFrame?.x, 100)
        XCTAssertEqual(restored?.windowFrame?.width, 1400)
        XCTAssertEqual(restored?.sidebarVisible, true)
    }

    func testMarkDirtyAndSaveIfDirtyTriggersSave() {
        var saveCalled = false
        let state = SessionPersistence.SessionState(
            windowFrame: nil,
            workspaces: [],
            activeWorkspaceID: nil,
            sidebarVisible: false
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
            sidebarVisible: true
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
            sidebarVisible: true
        )
        persistence.save(state: state)

        XCTAssertNil(persistence.restore(ifEnabled: false))
        XCTAssertNotNil(persistence.restore(ifEnabled: true))
    }

    func testSaveAndRestorePreservesWorkspaceSnapshots() {
        let workspace = Workspace(name: "Persisted")
        let state = SessionPersistence.SessionState(
            windowFrame: SessionPersistence.CodableRect(NSRect(x: 10, y: 20, width: 900, height: 700)),
            workspaces: [workspace.snapshot()],
            activeWorkspaceID: workspace.id,
            sidebarVisible: false
        )

        persistence.save(state: state)

        let restored = persistence.restore()
        XCTAssertEqual(restored?.workspaces.count, 1)
        XCTAssertEqual(restored?.workspaces.first?.name, "Persisted")
        XCTAssertEqual(restored?.activeWorkspaceID, workspace.id)
        XCTAssertEqual(restored?.sidebarVisible, false)
    }

    func testSaveWritesSessionFileWith0600Permissions() throws {
        let state = SessionPersistence.SessionState(
            windowFrame: nil,
            workspaces: [],
            activeWorkspaceID: nil,
            sidebarVisible: true
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

        for _ in 0..<iterations {
            group.enter()
            DispatchQueue.global().async {
                self.persistence.markDirty()
                group.leave()
            }
        }

        let result = group.wait(timeout: .now() + 5)
        XCTAssertEqual(result, .success, "All markDirty calls should complete without deadlock")
    }

    func testDirtyStateIsSavedAfterPersistenceIsReenabled() {
        let state = SessionPersistence.SessionState(
            windowFrame: nil,
            workspaces: [],
            activeWorkspaceID: nil,
            sidebarVisible: false
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
}
