import XCTest
@testable import Pnevma

private struct AnyEncodable: Encodable {
    private let encodeImpl: (Encoder) throws -> Void

    init(_ wrapped: Encodable) {
        encodeImpl = wrapped.encode
    }

    func encode(to encoder: Encoder) throws {
        try encodeImpl(encoder)
    }
}

private actor MockCommandBus: CommandCalling {
    struct ProjectSpec {
        let projectID: String
        let projectPath: String
        let gitBranch: String
        let activeTasks: Int
        let activeAgents: Int
        let costToday: Double
        let unreadNotifications: Int
        let openDelayNanos: UInt64
    }

    private let specsByPath: [String: ProjectSpec]
    private let specsByID: [String: ProjectSpec]
    private var currentProjectIDValue: String?
    private var openPathHistory: [String] = []
    private var closeCountValue = 0

    init(specs: [ProjectSpec]) {
        var byPath: [String: ProjectSpec] = [:]
        var byID: [String: ProjectSpec] = [:]
        for spec in specs {
            byPath[spec.projectPath] = spec
            byID[spec.projectID] = spec
        }
        specsByPath = byPath
        specsByID = byID
    }

    func call<T: Decodable>(method: String, params: Encodable?) async throws -> T {
        switch method {
        case "project.open":
            let json = try encodeParams(params)
            guard let path = json["path"] as? String,
                  let spec = specsByPath[path] else {
                throw NSError(domain: "MockCommandBus", code: 1)
            }
            openPathHistory.append(path)
            try await Task.sleep(nanoseconds: spec.openDelayNanos)
            currentProjectIDValue = spec.projectID
            return ProjectOpenResponse(
                projectID: spec.projectID,
                status: ProjectStatusResponse(
                    projectID: spec.projectID,
                    projectName: path,
                    projectPath: spec.projectPath,
                    sessions: 0,
                    tasks: spec.activeTasks,
                    worktrees: 0
                )
            ) as! T
        case "project.summary":
            guard let currentProjectIDValue,
                  let spec = specsByID[currentProjectIDValue] else {
                throw NSError(domain: "MockCommandBus", code: 2)
            }
            return ProjectSummary(
                projectID: spec.projectID,
                gitBranch: spec.gitBranch,
                activeTasks: spec.activeTasks,
                activeAgents: spec.activeAgents,
                costToday: spec.costToday,
                unreadNotifications: spec.unreadNotifications
            ) as! T
        case "project.close":
            closeCountValue += 1
            currentProjectIDValue = nil
            return OkResponse(ok: true) as! T
        default:
            throw NSError(domain: "MockCommandBus", code: 3)
        }
    }

    func setCurrentProjectID(_ projectID: String?) {
        currentProjectIDValue = projectID
    }

    func currentProjectID() -> String? {
        currentProjectIDValue
    }

    func openCount(for path: String) -> Int {
        openPathHistory.filter { $0 == path }.count
    }

    func closeCount() -> Int {
        closeCountValue
    }

    private func encodeParams(_ params: Encodable?) throws -> [String: Any] {
        guard let params else { return [:] }
        let data = try JSONEncoder().encode(AnyEncodable(params))
        return (try JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
    }
}

private actor FailingProjectOpenCommandBus: CommandCalling {
    let message: String

    init(message: String) {
        self.message = message
    }

    func call<T: Decodable>(method: String, params: Encodable?) async throws -> T {
        switch method {
        case "project.open":
            throw PnevmaError.backendError(method: method, message: message)
        case "project.close":
            return OkResponse(ok: true) as! T
        default:
            throw NSError(domain: "FailingProjectOpenCommandBus", code: 1)
        }
    }
}

private struct ProjectOpenFailurePayload: Decodable {
    let workspaceId: UUID?
    let generation: UInt64?
    let message: String
}

@MainActor
final class WorkspaceManagerTests: XCTestCase {
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
        XCTFail("Timed out waiting for async workspace condition", file: file, line: line)
    }

    func testLatestWorkspaceOpenWinsAfterRapidSwitch() async throws {
        let bus = MockCommandBus(specs: [
            .init(
                projectID: "project-a",
                projectPath: "/tmp/a",
                gitBranch: "branch-a",
                activeTasks: 1,
                activeAgents: 1,
                costToday: 1.0,
                unreadNotifications: 1,
                openDelayNanos: 200_000_000
            ),
            .init(
                projectID: "project-b",
                projectPath: "/tmp/b",
                gitBranch: "branch-b",
                activeTasks: 3,
                activeAgents: 2,
                costToday: 4.5,
                unreadNotifications: 0,
                openDelayNanos: 20_000_000
            )
        ])
        let bridge = PnevmaBridge()
        let manager = WorkspaceManager(bridge: bridge, commandBus: bus)

        _ = manager.createWorkspace(name: "A", projectPath: "/tmp/a")
        let workspaceB = manager.createWorkspace(name: "B", projectPath: "/tmp/b")

        try await waitUntil {
            await bus.currentProjectID() == "project-b" && workspaceB.gitBranch == "branch-b"
        }
        manager.refreshMetadata(for: workspaceB)
        let currentProjectID = await bus.currentProjectID()

        XCTAssertEqual(manager.activeWorkspaceID, workspaceB.id)
        XCTAssertEqual(workspaceB.gitBranch, "branch-b")
        XCTAssertEqual(workspaceB.activeTasks, 3)
        XCTAssertEqual(currentProjectID, "project-b")
    }

    func testSummaryMismatchTriggersReopenOfActiveWorkspace() async throws {
        let bus = MockCommandBus(specs: [
            .init(
                projectID: "project-a",
                projectPath: "/tmp/a",
                gitBranch: "branch-a",
                activeTasks: 1,
                activeAgents: 1,
                costToday: 1.0,
                unreadNotifications: 1,
                openDelayNanos: 10_000_000
            ),
            .init(
                projectID: "project-b",
                projectPath: "/tmp/b",
                gitBranch: "branch-b",
                activeTasks: 3,
                activeAgents: 2,
                costToday: 4.5,
                unreadNotifications: 0,
                openDelayNanos: 10_000_000
            )
        ])
        let bridge = PnevmaBridge()
        let manager = WorkspaceManager(bridge: bridge, commandBus: bus)

        let workspaceB = manager.createWorkspace(name: "B", projectPath: "/tmp/b")
        try await waitUntil {
            workspaceB.gitBranch == "branch-b"
        }
        XCTAssertEqual(workspaceB.gitBranch, "branch-b")

        await bus.setCurrentProjectID("project-a")
        manager.refreshMetadata(for: workspaceB)
        try await waitUntil {
            let currentProjectID = await bus.currentProjectID()
            let reopenCount = await bus.openCount(for: "/tmp/b")
            return currentProjectID == "project-b"
                && reopenCount == 2
                && workspaceB.gitBranch == "branch-b"
        }
        let currentProjectID = await bus.currentProjectID()
        let reopenCount = await bus.openCount(for: "/tmp/b")

        XCTAssertEqual(workspaceB.gitBranch, "branch-b")
        XCTAssertEqual(currentProjectID, "project-b")
        XCTAssertEqual(reopenCount, 2)
    }

    func testClosingActiveWorkspaceRebindsBackendToNextWorkspace() async throws {
        let bus = MockCommandBus(specs: [
            .init(
                projectID: "project-a",
                projectPath: "/tmp/a",
                gitBranch: "branch-a",
                activeTasks: 1,
                activeAgents: 1,
                costToday: 1.0,
                unreadNotifications: 0,
                openDelayNanos: 10_000_000
            ),
            .init(
                projectID: "project-b",
                projectPath: "/tmp/b",
                gitBranch: "branch-b",
                activeTasks: 2,
                activeAgents: 1,
                costToday: 2.0,
                unreadNotifications: 1,
                openDelayNanos: 10_000_000
            )
        ])
        let bridge = PnevmaBridge()
        let manager = WorkspaceManager(bridge: bridge, commandBus: bus)

        let workspaceA = manager.createWorkspace(name: "A", projectPath: "/tmp/a")
        let workspaceB = manager.createWorkspace(name: "B", projectPath: "/tmp/b")
        try await waitUntil {
            await bus.currentProjectID() == "project-b"
        }

        manager.switchToWorkspace(workspaceA.id)
        try await waitUntil {
            await bus.currentProjectID() == "project-a"
        }
        manager.closeWorkspace(workspaceA.id)
        try await waitUntil {
            let currentProjectID = await bus.currentProjectID()
            return manager.activeWorkspaceID == workspaceB.id && currentProjectID == "project-b"
        }
        let currentProjectID = await bus.currentProjectID()

        XCTAssertEqual(manager.activeWorkspaceID, workspaceB.id)
        XCTAssertEqual(currentProjectID, "project-b")
    }

    func testWorkspaceWithoutProjectClosesBackendAndShowsWelcomePane() async throws {
        let bus = MockCommandBus(specs: [
            .init(
                projectID: "project-a",
                projectPath: "/tmp/a",
                gitBranch: "branch-a",
                activeTasks: 1,
                activeAgents: 1,
                costToday: 1.0,
                unreadNotifications: 0,
                openDelayNanos: 10_000_000
            )
        ])
        let bridge = PnevmaBridge()
        let manager = WorkspaceManager(bridge: bridge, commandBus: bus)

        _ = manager.createWorkspace(name: "A", projectPath: "/tmp/a")
        try await waitUntil {
            await bus.currentProjectID() == "project-a"
        }

        let scratch = manager.createWorkspace(name: "Scratch")
        try await waitUntil {
            let rootPaneID = scratch.layoutEngine.root?.allPaneIDs.first
            let rootPane = rootPaneID.flatMap { scratch.layoutEngine.persistedPane(for: $0) }
            let closeCount = await bus.closeCount()
            return manager.activeWorkspaceID == scratch.id
                && closeCount == 1
                && rootPane?.type == "welcome"
        }

        let closeCount = await bus.closeCount()
        let rootPaneID = scratch.layoutEngine.root?.allPaneIDs.first
        let rootPane = rootPaneID.flatMap { scratch.layoutEngine.persistedPane(for: $0) }

        XCTAssertEqual(manager.activeWorkspaceID, scratch.id)
        XCTAssertEqual(closeCount, 1)
        XCTAssertEqual(rootPane?.type, "welcome")
    }

    func testProjectWorkspaceSeedsTerminalPaneAfterOpen() async throws {
        let bus = MockCommandBus(specs: [
            .init(
                projectID: "project-a",
                projectPath: "/tmp/a",
                gitBranch: "branch-a",
                activeTasks: 1,
                activeAgents: 1,
                costToday: 1.0,
                unreadNotifications: 0,
                openDelayNanos: 10_000_000
            )
        ])
        let bridge = PnevmaBridge()
        let manager = WorkspaceManager(bridge: bridge, commandBus: bus)

        let workspace = manager.createWorkspace(name: "A", projectPath: "/tmp/a")
        try await waitUntil {
            let rootPaneID = workspace.layoutEngine.root?.allPaneIDs.first
            let rootPane = rootPaneID.flatMap { workspace.layoutEngine.persistedPane(for: $0) }
            return rootPane?.type == "terminal" && rootPane?.workingDirectory == "/tmp/a"
        }

        let rootPaneID = workspace.layoutEngine.root?.allPaneIDs.first
        let rootPane = rootPaneID.flatMap { workspace.layoutEngine.persistedPane(for: $0) }

        XCTAssertEqual(rootPane?.type, "terminal")
        XCTAssertEqual(rootPane?.workingDirectory, "/tmp/a")
    }

    func testActivationHubTracksWorkspaceOpenAndScratchClose() async throws {
        let bus = MockCommandBus(specs: [
            .init(
                projectID: "project-a",
                projectPath: "/tmp/a",
                gitBranch: "branch-a",
                activeTasks: 1,
                activeAgents: 1,
                costToday: 1.0,
                unreadNotifications: 0,
                openDelayNanos: 10_000_000
            )
        ])
        let activationHub = ActiveWorkspaceActivationHub()
        let bridge = PnevmaBridge()
        let manager = WorkspaceManager(
            bridge: bridge,
            commandBus: bus,
            activationHub: activationHub
        )

        let workspace = manager.createWorkspace(name: "A", projectPath: "/tmp/a")
        if case .opening(let workspaceID, _) = activationHub.currentState {
            XCTAssertEqual(workspaceID, workspace.id)
        } else {
            XCTFail("Expected activation hub to enter opening state")
        }

        try await waitUntil {
            activationHub.currentState == .open(workspaceID: workspace.id, projectID: "project-a")
        }

        let scratch = manager.createWorkspace(name: "Scratch")
        XCTAssertEqual(activationHub.currentState, .closed(workspaceID: scratch.id))
    }

    func testProjectOpenFailurePostsActionableEvent() async throws {
        let bus = FailingProjectOpenCommandBus(message: "workspace_not_trusted")
        let activationHub = ActiveWorkspaceActivationHub()
        let bridge = PnevmaBridge()
        let manager = WorkspaceManager(
            bridge: bridge,
            commandBus: bus,
            activationHub: activationHub
        )

        let eventExpectation = expectation(description: "project_open_failed")
        var receivedPayloadJSON: String?
        let observerID = BridgeEventHub.shared.addObserver { event in
            guard event.name == "project_open_failed" else {
                return
            }
            receivedPayloadJSON = event.payloadJSON
            eventExpectation.fulfill()
        }
        defer { BridgeEventHub.shared.removeObserver(observerID) }

        let workspace = manager.createWorkspace(name: "Untrusted", projectPath: "/tmp/untrusted")

        await fulfillment(of: [eventExpectation], timeout: 3.0)
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let payloadJSON = try XCTUnwrap(receivedPayloadJSON)
        let payloadData = try XCTUnwrap(payloadJSON.data(using: .utf8))
        let decoded = try decoder.decode(ProjectOpenFailurePayload.self, from: payloadData)

        XCTAssertEqual(
            decoded.message,
            "Workspace trust is required before this project can open."
        )
        XCTAssertEqual(decoded.workspaceId, workspace.id)
        XCTAssertEqual(manager.activeWorkspaceID, workspace.id)
        XCTAssertNil(workspace.gitBranch)
        XCTAssertEqual(workspace.activeTasks, 0)
        XCTAssertEqual(
            activationHub.currentState,
            .failed(
                workspaceID: workspace.id,
                generation: decoded.generation ?? 0,
                message: "Workspace trust is required before this project can open."
            )
        )
    }
}
