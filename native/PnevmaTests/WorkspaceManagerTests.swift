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
    private var closeModesValue: [String] = []

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

    func call<T: Decodable & Sendable>(method: String, params: (any Encodable & Sendable)?) async throws -> T {
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
                unreadNotifications: spec.unreadNotifications,
                gitDirty: nil,
                diffInsertions: nil,
                diffDeletions: nil,
                linkedPrNumber: nil,
                linkedPrUrl: nil,
                ciStatus: nil,
                attentionReason: nil
            ) as! T
        case "project.close":
            let json = try encodeParams(params)
            closeCountValue += 1
            closeModesValue.append((json["mode"] as? String) ?? "workspace_close")
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

    func closeModes() -> [String] {
        closeModesValue
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

    func call<T: Decodable & Sendable>(method: String, params: (any Encodable & Sendable)?) async throws -> T {
        switch method {
        case "project.open":
            throw PnevmaError.backendError(method: method, message: message)
        case "project.trust":
            throw PnevmaError.backendError(method: method, message: message)
        case "project.close":
            return OkResponse(ok: true) as! T
        default:
            throw NSError(domain: "FailingProjectOpenCommandBus", code: 1)
        }
    }
}

private actor RecoveringProjectOpenCommandBus: CommandCalling {
    private let spec: MockCommandBus.ProjectSpec
    private var currentProjectIDValue: String?
    private var openCallCountValue = 0
    private var initializeCallCountValue = 0
    private var trustCallCountValue = 0

    init(spec: MockCommandBus.ProjectSpec) {
        self.spec = spec
    }

    func call<T: Decodable & Sendable>(method: String, params: (any Encodable & Sendable)?) async throws -> T {
        switch method {
        case "project.open":
            openCallCountValue += 1
            if initializeCallCountValue == 0 {
                throw PnevmaError.backendError(method: method, message: "workspace_not_initialized")
            }
            if trustCallCountValue == 0 {
                throw PnevmaError.backendError(method: method, message: "workspace_not_trusted")
            }
            currentProjectIDValue = spec.projectID
            return ProjectOpenResponse(
                projectID: spec.projectID,
                status: ProjectStatusResponse(
                    projectID: spec.projectID,
                    projectName: spec.projectPath,
                    projectPath: spec.projectPath,
                    sessions: 0,
                    tasks: spec.activeTasks,
                    worktrees: 0
                )
            ) as! T
        case "project.initialize_scaffold":
            initializeCallCountValue += 1
            return InitializeProjectScaffoldResult(
                rootPath: spec.projectPath,
                createdPaths: [
                    spec.projectPath + "/pnevma.toml",
                    spec.projectPath + "/.pnevma"
                ],
                alreadyInitialized: false
            ) as! T
        case "project.trust":
            trustCallCountValue += 1
            return OkResponse(ok: true) as! T
        case "project.summary":
            guard let currentProjectIDValue,
                  currentProjectIDValue == spec.projectID else {
                throw NSError(domain: "RecoveringProjectOpenCommandBus", code: 2)
            }
            return ProjectSummary(
                projectID: spec.projectID,
                gitBranch: spec.gitBranch,
                activeTasks: spec.activeTasks,
                activeAgents: spec.activeAgents,
                costToday: spec.costToday,
                unreadNotifications: spec.unreadNotifications,
                gitDirty: nil,
                diffInsertions: nil,
                diffDeletions: nil,
                linkedPrNumber: nil,
                linkedPrUrl: nil,
                ciStatus: nil,
                attentionReason: nil
            ) as! T
        case "project.close":
            currentProjectIDValue = nil
            return OkResponse(ok: true) as! T
        default:
            throw NSError(domain: "RecoveringProjectOpenCommandBus", code: 1)
        }
    }

    func openCallCount() -> Int {
        openCallCountValue
    }

    func initializeCallCount() -> Int {
        initializeCallCountValue
    }

    func trustCallCount() -> Int {
        trustCallCountValue
    }
}

private final class MockWorkspaceProjectPathResolver: WorkspaceProjectPathResolving {
    var resolvedPaths: [UUID: String] = [:]
    var defaultRemotePath: String?
    private(set) var cleanedWorkspaceIDs: [UUID] = []

    func resolveProjectPath(for workspace: Workspace) async throws -> String? {
        if workspace.location == .remote {
            return resolvedPaths[workspace.id] ?? defaultRemotePath
        }
        return workspace.projectPath
    }

    func cleanup(workspace: Workspace) {
        cleanedWorkspaceIDs.append(workspace.id)
    }

    func cleanupAll(workspaces: [Workspace]) {
        cleanedWorkspaceIDs.append(contentsOf: workspaces.map(\.id))
    }
}

private struct ProjectOpenFailurePayload: Decodable {
    let workspaceID: UUID?
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

    private func openingState(
        _ activationHub: ActiveWorkspaceActivationHub,
        file: StaticString = #filePath,
        line: UInt = #line
    ) -> (workspaceID: UUID, generation: UInt64) {
        guard case .opening(let workspaceID, let generation) = activationHub.currentState else {
            XCTFail("Expected activation hub to be opening", file: file, line: line)
            return (UUID(), 0)
        }
        return (workspaceID, generation)
    }

    func testPrimaryInitializerCreatesDistinctRuntimeAndCommandBusPerWorkspace() throws {
        let manager = WorkspaceManager()
        defer { manager.shutdown() }

        let workspaceA = manager.createWorkspace(name: "A", projectPath: "/tmp/runtime-a")
        let runtimeA = try XCTUnwrap(manager.activeRuntime)
        let busA = runtimeA.commandBus as AnyObject

        let workspaceB = manager.createWorkspace(name: "B", projectPath: "/tmp/runtime-b")
        let runtimeB = try XCTUnwrap(manager.activeRuntime)
        let busB = runtimeB.commandBus as AnyObject

        XCTAssertNotEqual(ObjectIdentifier(runtimeA), ObjectIdentifier(runtimeB))
        XCTAssertNotEqual(ObjectIdentifier(busA), ObjectIdentifier(busB))

        manager.switchToWorkspace(workspaceA.id)
        XCTAssertTrue(manager.activeRuntime === runtimeA)

        manager.switchToWorkspace(workspaceB.id)
        XCTAssertTrue(manager.activeRuntime === runtimeB)
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

    func testClosingActiveWorkspaceDestroysOnlyThatRuntimeAndLeavesReplacementOpen() async throws {
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
            manager.runtime(for: workspaceA.id)?.projectID == "project-a"
                && manager.runtime(for: workspaceB.id)?.projectID == "project-b"
        }

        manager.switchToWorkspace(workspaceA.id)
        manager.closeWorkspace(workspaceA.id)
        try await waitUntil {
            manager.activeWorkspaceID == workspaceB.id
                && manager.runtime(for: workspaceA.id) == nil
                && manager.runtime(for: workspaceB.id)?.projectID == "project-b"
        }
        try await waitUntil {
            let closeCount = await bus.closeCount()
            let closeModes = await bus.closeModes()
            return closeCount == 1 && closeModes == ["workspace_close"]
        }

        let closeCount = await bus.closeCount()
        let closeModes = await bus.closeModes()
        XCTAssertEqual(manager.activeWorkspaceID, workspaceB.id)
        XCTAssertNil(manager.runtime(for: workspaceA.id))
        XCTAssertEqual(manager.runtime(for: workspaceB.id)?.projectID, "project-b")
        XCTAssertEqual(closeCount, 1)
        XCTAssertEqual(closeModes, ["workspace_close"])
    }

    func testSwitchingToTerminalKeepsProjectRuntimeOpenAndShowsTerminalPane() async throws {
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

        let projectWorkspace = manager.createWorkspace(name: "A", projectPath: "/tmp/a")
        try await waitUntil {
            manager.runtime(for: projectWorkspace.id)?.projectID == "project-a"
        }

        let terminal = manager.ensureTerminalWorkspace()
        manager.switchToWorkspace(terminal.id)
        try await waitUntil {
            let rootPaneID = terminal.layoutEngine.root?.allPaneIDs.first
            let rootPane = rootPaneID.flatMap { terminal.layoutEngine.persistedPane(for: $0) }
            return manager.activeWorkspaceID == terminal.id
                && manager.runtime(for: projectWorkspace.id)?.projectID == "project-a"
                && rootPane?.type == "terminal"
        }

        let closeCount = await bus.closeCount()
        let rootPaneID = terminal.layoutEngine.root?.allPaneIDs.first
        let rootPane = rootPaneID.flatMap { terminal.layoutEngine.persistedPane(for: $0) }

        XCTAssertEqual(manager.activeWorkspaceID, terminal.id)
        XCTAssertEqual(closeCount, 0)
        XCTAssertEqual(manager.runtime(for: projectWorkspace.id)?.projectID, "project-a")
        XCTAssertEqual(rootPane?.type, "terminal")
    }

    func testSwitchingToAlreadyActiveTerminalWorkspaceIsNoOp() async throws {
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

        let projectWorkspace = manager.createWorkspace(name: "A", projectPath: "/tmp/a")
        try await waitUntil {
            manager.runtime(for: projectWorkspace.id)?.projectID == "project-a"
        }

        let terminal = manager.ensureTerminalWorkspace()
        manager.switchToWorkspace(terminal.id)
        try await waitUntil {
            manager.activeWorkspaceID == terminal.id
        }

        manager.switchToWorkspace(terminal.id)
        try await Task.sleep(nanoseconds: 50_000_000)

        let closeCount = await bus.closeCount()
        XCTAssertEqual(manager.activeWorkspaceID, terminal.id)
        XCTAssertEqual(closeCount, 0)
        XCTAssertEqual(manager.runtime(for: projectWorkspace.id)?.projectID, "project-a")
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

    func testCreatingProjectWorkspacePreservesExistingProjectWorkspaces() async throws {
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
                unreadNotifications: 0,
                openDelayNanos: 10_000_000
            )
        ])
        let bridge = PnevmaBridge()
        let manager = WorkspaceManager(bridge: bridge, commandBus: bus)

        let projectWorkspace = manager.createWorkspace(name: "A", projectPath: "/tmp/a")
        try await waitUntil {
            manager.runtime(for: projectWorkspace.id)?.projectID == "project-a"
        }

        let terminal = manager.ensureTerminalWorkspace()
        manager.switchToWorkspace(terminal.id)
        try await waitUntil { manager.activeWorkspaceID == terminal.id }

        let secondWorkspace = manager.createLocalProjectWorkspace(
            name: "B",
            projectPath: "/tmp/b",
            terminalMode: .persistent
        )

        try await waitUntil {
            let rootPaneID = secondWorkspace.layoutEngine.root?.allPaneIDs.first
            let rootPane = rootPaneID.flatMap { secondWorkspace.layoutEngine.persistedPane(for: $0) }
            let projectWorkspaceCount = manager.workspaces.filter { $0.projectPath != nil }.count
            return manager.activeWorkspaceID == secondWorkspace.id
                && projectWorkspaceCount == 2
                && manager.runtime(for: projectWorkspace.id)?.projectID == "project-a"
                && manager.runtime(for: secondWorkspace.id)?.projectID == "project-b"
                && rootPane?.type == "terminal"
                && rootPane?.workingDirectory == "/tmp/b"
        }

        XCTAssertNotEqual(secondWorkspace.id, terminal.id)
        XCTAssertEqual(secondWorkspace.name, "B")
        XCTAssertEqual(secondWorkspace.projectPath, "/tmp/b")
        XCTAssertTrue(manager.workspaces.contains(where: { $0.id == projectWorkspace.id }))
        XCTAssertTrue(manager.workspaces.contains(where: { $0.id == secondWorkspace.id }))
        let closeCount = await bus.closeCount()
        let secondWorkspaceOpenCount = await bus.openCount(for: "/tmp/b")
        XCTAssertEqual(closeCount, 0)
        XCTAssertEqual(secondWorkspaceOpenCount, 1)
    }

    func testPrepareForShutdownClosesOpenProjects() async throws {
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
        defer { manager.shutdown() }

        let projectWorkspace = manager.createWorkspace(name: "A", projectPath: "/tmp/a")
        try await waitUntil {
            manager.runtime(for: projectWorkspace.id)?.projectID == "project-a"
        }

        await manager.prepareForShutdown()

        let closeCount = await bus.closeCount()
        let closeModes = await bus.closeModes()
        XCTAssertEqual(closeCount, 1)
        XCTAssertEqual(closeModes, ["app_shutdown"])
        XCTAssertNil(manager.runtime(for: projectWorkspace.id)?.projectID)
    }

    func testCreateLocalProjectWorkspaceAppliesLaunchSourceAndInitialTerminalSeed() throws {
        let manager = WorkspaceManager()
        defer { manager.shutdown() }

        let workspace = manager.createLocalProjectWorkspace(
            name: "Issue #12 — Fix opener",
            projectPath: "/tmp/project",
            terminalMode: .persistent,
            launchSource: WorkspaceLaunchSource(
                kind: "issue",
                number: 12,
                title: "Fix opener",
                url: "https://github.com/acme/widgets/issues/12"
            ),
            initialWorkingDirectory: "/tmp/project/.pnevma/worktrees/task-12",
            initialTaskID: "task-12"
        )

        let rootPaneID = try XCTUnwrap(workspace.layoutEngine.root?.allPaneIDs.first)
        let rootPane = try XCTUnwrap(workspace.layoutEngine.persistedPane(for: rootPaneID))

        XCTAssertEqual(workspace.launchSource?.kind, "issue")
        XCTAssertEqual(workspace.launchSource?.number, 12)
        XCTAssertEqual(rootPane.type, "terminal")
        XCTAssertEqual(rootPane.workingDirectory, "/tmp/project/.pnevma/worktrees/task-12")
        XCTAssertEqual(rootPane.taskID, "task-12")
    }

    func testRemoteWorkspaceResolvesProjectPathAndOpensBackendProject() async throws {
        let mountPath = "/tmp/remote-mounted-project"
        let bus = MockCommandBus(specs: [
            .init(
                projectID: "project-remote",
                projectPath: mountPath,
                gitBranch: "main",
                activeTasks: 3,
                activeAgents: 2,
                costToday: 4.0,
                unreadNotifications: 1,
                openDelayNanos: 50_000_000
            )
        ])
        let activationHub = ActiveWorkspaceActivationHub()
        let resolver = MockWorkspaceProjectPathResolver()
        resolver.defaultRemotePath = mountPath
        let manager = WorkspaceManager(
            bridge: PnevmaBridge(),
            commandBus: bus,
            activationHub: activationHub,
            projectPathResolver: resolver
        )

        let workspace = manager.createRemoteWorkspace(
            name: "Remote",
            remoteTarget: WorkspaceRemoteTarget(
                sshProfileID: "profile-1",
                sshProfileName: "Remote",
                host: "example.internal",
                port: 22,
                user: "builder",
                identityFile: nil,
                proxyJump: "jump.internal",
                remotePath: "/srv/project"
            ),
            terminalMode: .persistent
        )

        try await waitUntil {
            return activationHub.currentState == .open(
                workspaceID: workspace.id,
                projectID: "project-remote"
            ) && manager.runtime(for: workspace.id)?.projectID == "project-remote"
        }

        XCTAssertEqual(workspace.projectPath, mountPath)
        XCTAssertTrue(workspace.supportsProjectTools)
    }

    func testRemoteWorkspaceShellCommandExpandsHomeRelativePaths() {
        let target = WorkspaceRemoteTarget(
            sshProfileID: "profile-1",
            sshProfileName: "Remote",
            host: "example.internal",
            port: 22,
            user: "builder",
            identityFile: nil,
            proxyJump: nil,
            remotePath: "~/repo with spaces"
        )

        XCTAssertEqual(target.shellDirectoryExpression, "${HOME}/'repo with spaces'")
        XCTAssertTrue(target.remoteShellCommand.contains("${HOME}/"))
        XCTAssertTrue(target.remoteShellCommand.contains("repo with spaces"))
        XCTAssertFalse(target.remoteShellCommand.contains("cd -- '~"))
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

        let terminal = manager.ensureTerminalWorkspace()
        manager.switchToWorkspace(terminal.id)
        XCTAssertEqual(activationHub.currentState, .closed(workspaceID: terminal.id))
    }

    func testProjectOpenedEventPromotesActivationBeforeOpenCallReturns() async throws {
        let bus = MockCommandBus(specs: [
            .init(
                projectID: "project-a",
                projectPath: "/tmp/a",
                gitBranch: "branch-a",
                activeTasks: 1,
                activeAgents: 1,
                costToday: 1.0,
                unreadNotifications: 0,
                openDelayNanos: 300_000_000
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
        let opening = openingState(activationHub)
        BridgeEventHub.shared.post(
            BridgeEvent(
                name: "project_opened",
                payloadJSON: """
                {"project_id":"project-a","project_name":"A","project_path":"/tmp/a","client_activation_token":"\(WorkspaceManager.clientActivationToken(workspaceID: workspace.id, generation: opening.generation))"}
                """
            )
        )

        try await waitUntil(timeoutNanos: 2_000_000_000) {
            activationHub.currentState == .open(workspaceID: workspace.id, projectID: "project-a")
        }

        let currentProjectID = await bus.currentProjectID()
        XCTAssertNil(currentProjectID)
    }

    func testStaleProjectOpenedEventIsIgnoredAfterWorkspaceSwitch() async throws {
        let bus = MockCommandBus(specs: [
            .init(
                projectID: "project-a",
                projectPath: "/tmp/a",
                gitBranch: "branch-a",
                activeTasks: 1,
                activeAgents: 1,
                costToday: 1.0,
                unreadNotifications: 0,
                openDelayNanos: 300_000_000
            ),
            .init(
                projectID: "project-b",
                projectPath: "/tmp/b",
                gitBranch: "branch-b",
                activeTasks: 2,
                activeAgents: 1,
                costToday: 2.0,
                unreadNotifications: 0,
                openDelayNanos: 300_000_000
            )
        ])
        let activationHub = ActiveWorkspaceActivationHub()
        let bridge = PnevmaBridge()
        let manager = WorkspaceManager(
            bridge: bridge,
            commandBus: bus,
            activationHub: activationHub
        )

        _ = manager.createWorkspace(name: "A", projectPath: "/tmp/a")
        let workspaceB = manager.createWorkspace(name: "B", projectPath: "/tmp/b")
        let opening = openingState(activationHub)

        BridgeEventHub.shared.post(
            BridgeEvent(
                name: "project_opened",
                payloadJSON: """
                {"project_id":"project-a","project_name":"A","project_path":"/tmp/a","client_activation_token":"\(WorkspaceManager.clientActivationToken(workspaceID: workspaceB.id, generation: opening.generation))"}
                """
            )
        )

        try await Task.sleep(nanoseconds: 75_000_000)
        if case .opening(let workspaceID, _) = activationHub.currentState {
            XCTAssertEqual(workspaceID, workspaceB.id)
        } else {
            XCTFail("Stale project_opened event should not promote the active workspace")
        }

        try await waitUntil {
            let currentProjectID = await bus.currentProjectID()
            return activationHub.currentState == .open(
                workspaceID: workspaceB.id,
                projectID: "project-b"
            ) && currentProjectID == "project-b"
        }
    }

    func testSwitchingBackToAlreadyOpenWorkspaceReusesExistingRuntime() async throws {
        let bus = MockCommandBus(specs: [
            .init(
                projectID: "project-a",
                projectPath: "/tmp/a",
                gitBranch: "branch-a",
                activeTasks: 1,
                activeAgents: 1,
                costToday: 1.0,
                unreadNotifications: 0,
                openDelayNanos: 300_000_000
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
        let initialOpening = openingState(activationHub)
        try await waitUntil {
            activationHub.currentState == .open(workspaceID: workspace.id, projectID: "project-a")
        }
        let initialOpenCount = await bus.openCount(for: "/tmp/a")
        let terminal = manager.ensureTerminalWorkspace()
        manager.switchToWorkspace(terminal.id)
        XCTAssertEqual(activationHub.currentState, .closed(workspaceID: terminal.id))

        manager.switchToWorkspace(workspace.id)
        try await waitUntil {
            activationHub.currentState == .open(workspaceID: workspace.id, projectID: "project-a")
        }

        let openCount = await bus.openCount(for: "/tmp/a")
        XCTAssertEqual(initialOpening.workspaceID, workspace.id)
        XCTAssertEqual(manager.runtime(for: workspace.id)?.projectID, "project-a")
        XCTAssertEqual(openCount, initialOpenCount)
    }

    func testMissingScaffoldInitializationPromptsThenRecoversWorkspaceOpen() async throws {
        let spec = MockCommandBus.ProjectSpec(
            projectID: "project-a",
            projectPath: "/tmp/a",
            gitBranch: "branch-a",
            activeTasks: 1,
            activeAgents: 1,
            costToday: 1.0,
            unreadNotifications: 0,
            openDelayNanos: 0
        )
        let bus = RecoveringProjectOpenCommandBus(spec: spec)
        let activationHub = ActiveWorkspaceActivationHub()
        let bridge = PnevmaBridge()
        let manager = WorkspaceManager(
            bridge: bridge,
            commandBus: bus,
            activationHub: activationHub,
            projectInitializationPrompt: { _, _ in true }
        )

        let workspace = manager.createWorkspace(name: "A", projectPath: "/tmp/a")

        try await waitUntil(timeoutNanos: 2_000_000_000) {
            activationHub.currentState == .open(workspaceID: workspace.id, projectID: "project-a")
                && workspace.activationFailureMessage == nil
                && workspace.gitBranch == "branch-a"
        }

        let initializeCallCount = await bus.initializeCallCount()
        let trustCallCount = await bus.trustCallCount()
        let openCallCount = await bus.openCallCount()
        XCTAssertEqual(initializeCallCount, 1)
        XCTAssertEqual(trustCallCount, 1)
        XCTAssertEqual(openCallCount, 3)
        XCTAssertEqual(manager.runtime(for: workspace.id)?.projectID, "project-a")
    }

    func testMissingScaffoldCancellationFailsWorkspaceActivation() async throws {
        let bus = FailingProjectOpenCommandBus(message: "workspace_not_initialized")
        let activationHub = ActiveWorkspaceActivationHub()
        let bridge = PnevmaBridge()
        let manager = WorkspaceManager(
            bridge: bridge,
            commandBus: bus,
            activationHub: activationHub,
            projectInitializationPrompt: { _, _ in false }
        )

        let workspace = manager.createWorkspace(name: "Canceled", projectPath: "/tmp/canceled")

        try await waitUntil(timeoutNanos: 2_000_000_000) {
            if case .failed(let workspaceID, _, let message) = activationHub.currentState {
                return workspaceID == workspace.id
                    && message == "Project initialization for Canceled was canceled."
            }
            return false
        }

        XCTAssertEqual(
            workspace.activationFailureMessage,
            "Project initialization for Canceled was canceled."
        )
    }

    func testDefaultResolverExpandsHomeRelativeLocalProjectPaths() async throws {
        let absolutePath = URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/Caches/pnevma-home-relative-test")
            .path
        let bus = MockCommandBus(specs: [
            .init(
                projectID: "project-home",
                projectPath: absolutePath,
                gitBranch: "main",
                activeTasks: 0,
                activeAgents: 0,
                costToday: 0,
                unreadNotifications: 0,
                openDelayNanos: 0
            )
        ])
        let bridge = PnevmaBridge()
        let manager = WorkspaceManager(bridge: bridge, commandBus: bus)

        let workspace = manager.createWorkspace(name: "Home", projectPath: "~/Library/Caches/pnevma-home-relative-test")

        try await waitUntil(timeoutNanos: 2_000_000_000) {
            manager.runtime(for: workspace.id)?.projectID == "project-home"
        }

        let openCount = await bus.openCount(for: absolutePath)
        XCTAssertEqual(openCount, 1)
        XCTAssertEqual(workspace.projectPath, absolutePath)
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
        let decoder = PnevmaJSON.decoder()
        let payloadJSON = try XCTUnwrap(receivedPayloadJSON)
        let payloadData = try XCTUnwrap(payloadJSON.data(using: .utf8))
        let decoded = try decoder.decode(ProjectOpenFailurePayload.self, from: payloadData)

        XCTAssertEqual(
            decoded.message,
            "Workspace trust is required before this project can open."
        )
        XCTAssertEqual(decoded.workspaceID, workspace.id)
        XCTAssertEqual(manager.activeWorkspaceID, workspace.id)
        XCTAssertNil(workspace.gitBranch)
        XCTAssertEqual(workspace.activeTasks, 0)
        XCTAssertEqual(
            workspace.activationFailureMessage,
            "Workspace trust is required before this project can open."
        )
        XCTAssertEqual(
            PaneFactory.availablePaneTypes(for: workspace),
            Set(["terminal", "ssh", "workflow", "notifications", "browser", "analytics", "resource_monitor", "harness_config"])
        )
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
