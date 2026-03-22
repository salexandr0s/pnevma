import XCTest
@testable import Pnevma

private struct AnyEncodableCommandCenter: Encodable {
    private let encodeImpl: (Encoder) throws -> Void

    init(_ wrapped: Encodable) {
        encodeImpl = wrapped.encode
    }

    func encode(to encoder: Encoder) throws {
        try encodeImpl(encoder)
    }
}

private actor CommandCenterMockBus: CommandCalling {
    struct ProjectSpec {
        let projectID: String
        let projectPath: String
        let checkoutPath: String
        let openDelayNanos: UInt64

        init(projectID: String, projectPath: String, checkoutPath: String? = nil, openDelayNanos: UInt64) {
            self.projectID = projectID
            self.projectPath = projectPath
            self.checkoutPath = checkoutPath ?? projectPath
            self.openDelayNanos = openDelayNanos
        }
    }

    private let specsByBinding: [String: ProjectSpec]
    private let specsByID: [String: ProjectSpec]
    private var currentProjectIDValue: String?
    private var openPathHistory: [String] = []

    init(specs: [ProjectSpec]) {
        var byBinding: [String: ProjectSpec] = [:]
        var byID: [String: ProjectSpec] = [:]
        for spec in specs {
            byBinding[Self.bindingKey(projectPath: spec.projectPath, checkoutPath: spec.checkoutPath)] = spec
            byID[spec.projectID] = spec
        }
        specsByBinding = byBinding
        specsByID = byID
    }

    func call<T: Decodable & Sendable>(method: String, params: (any Encodable & Sendable)?) async throws -> T {
        switch method {
        case "project.open":
            let json = try encodeParams(params)
            guard let path = json["path"] as? String else {
                throw NSError(domain: "CommandCenterMockBus", code: 1)
            }
            let checkoutPath = (json["checkout_path"] as? String) ?? path
            guard let spec = specsByBinding[Self.bindingKey(projectPath: path, checkoutPath: checkoutPath)] else {
                throw NSError(domain: "CommandCenterMockBus", code: 1)
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
                    checkoutPath: spec.checkoutPath,
                    sessions: 0,
                    tasks: 0,
                    worktrees: 0
                )
            ) as! T
        case "project.summary":
            guard let currentProjectIDValue,
                  let spec = specsByID[currentProjectIDValue] else {
                throw NSError(domain: "CommandCenterMockBus", code: 2)
            }
            return ProjectSummary(
                projectID: spec.projectID,
                gitBranch: "main",
                activeTasks: 0,
                activeAgents: 0,
                costToday: 0,
                unreadNotifications: 0,
                gitDirty: nil,
                diffInsertions: nil,
                diffDeletions: nil,
                linkedPrNumber: nil,
                linkedPrUrl: nil,
                ciStatus: nil,
                attentionReason: nil
            ) as! T
        case "project.command_center_snapshot":
            guard let currentProjectIDValue,
                  let spec = specsByID[currentProjectIDValue] else {
                throw NSError(domain: "CommandCenterMockBus", code: 3)
            }
            return CommandCenterSnapshot(
                projectID: spec.projectID,
                projectName: spec.projectPath,
                projectPath: spec.projectPath,
                generatedAt: Date(),
                summary: CommandCenterSummary(
                    activeCount: 0,
                    queuedCount: 0,
                    idleCount: 0,
                    stuckCount: 0,
                    reviewNeededCount: 0,
                    failedCount: 0,
                    retryingCount: 0,
                    slotLimit: 4,
                    slotInUse: 0,
                    costTodayUsd: 0
                ),
                runs: []
            ) as! T
        case "project.close":
            currentProjectIDValue = nil
            return OkResponse(ok: true) as! T
        default:
            throw NSError(domain: "CommandCenterMockBus", code: 4)
        }
    }

    func openCount(for path: String) -> Int {
        openPathHistory.filter { $0 == path }.count
    }

    private static func bindingKey(projectPath: String, checkoutPath: String) -> String {
        "\(projectPath)|\(checkoutPath)"
    }

    private func encodeParams(_ params: Encodable?) throws -> [String: Any] {
        guard let params else { return [:] }
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        let data = try encoder.encode(AnyEncodableCommandCenter(params))
        return (try JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
    }
}

private final class CommandCenterWorkspaceProjectPathResolver: WorkspaceProjectPathResolving {
    enum Resolution {
        case passthrough
        case immediate(String?)
        case delayed(String?, UInt64)
    }

    var resolutions: [UUID: Resolution] = [:]

    func resolveProjectPath(for workspace: Workspace) async throws -> String? {
        let resolution = resolutions[workspace.id] ?? .passthrough
        switch resolution {
        case .passthrough:
            return workspace.projectPath
        case .immediate(let path):
            return path
        case .delayed(let path, let delayNanos):
            try await Task.sleep(nanoseconds: delayNanos)
            return path
        }
    }

    func cleanup(workspace: Workspace) {}

    func cleanupAll(workspaces: [Workspace]) {}
}

@MainActor
private final class CommandCenterRuntimeFactory {
    private let specs: [CommandCenterMockBus.ProjectSpec]
    private(set) var buses: [UUID: CommandCenterMockBus] = [:]

    init(specs: [CommandCenterMockBus.ProjectSpec]) {
        self.specs = specs
    }

    func makeRuntime(workspaceID: UUID) -> WorkspaceRuntime {
        let bus = CommandCenterMockBus(specs: specs)
        buses[workspaceID] = bus
        return WorkspaceRuntime(workspaceID: workspaceID, commandBus: bus)
    }
}

private actor CommandCenterRoutingMockBus: CommandCalling {
    private func decode<T: Decodable>(_ json: String) throws -> T {
        let data = Data(json.utf8)
        return try PnevmaJSON.decoder().decode(T.self, from: data)
    }

    func call<T: Decodable & Sendable>(method: String, params: (any Encodable & Sendable)?) async throws -> T {
        let json = try encodeParams(params)
        switch method {
        case "task.list":
            if json["status"] as? String == "Review" {
                return try decode(
                    #"""
                    [
                      {"id":"review-1","title":"Review One","status":"Review","priority":"high","cost_usd":1.0},
                      {"id":"review-2","title":"Review Two","status":"Review","priority":"medium","cost_usd":2.0}
                    ]
                    """#
                )
            }
            return try decode(
                #"""
                [
                  {"id":"diff-1","title":"Diff One","status":"InProgress","priority":"high"},
                  {"id":"diff-2","title":"Diff Two","status":"Review","priority":"medium"}
                ]
                """#
            )
        case "review.diff":
            let taskID = (json["task_id"] as? String) ?? ""
            return try decode(
                """
                {
                  "task_id":"\(taskID)",
                  "diff_path":"/tmp/\(taskID).diff",
                  "files":[
                    {
                      "path":"Sources/\(taskID).swift",
                      "hunks":[{"header":"@@ -1,1 +1,1 @@","lines":["+updated line"]}]
                    }
                  ]
                }
                """
            )
        case "review.get_pack":
            let taskID = (json["task_id"] as? String) ?? ""
            return try decode(
                """
                {
                  "task_id":"\(taskID)",
                  "status":"Pending",
                  "review_pack_path":"/tmp/\(taskID).json",
                  "reviewer_notes":null,
                  "approved_at":null,
                  "pack":{"acceptance_criteria":["criterion for \(taskID)"]}
                }
                """
            )
        default:
            throw NSError(domain: "CommandCenterRoutingMockBus", code: 1)
        }
    }

    private func encodeParams(_ params: Encodable?) throws -> [String: Any] {
        guard let params else { return [:] }
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        let data = try encoder.encode(AnyEncodableCommandCenter(params))
        return (try JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
    }
}

@MainActor
final class CommandCenterStoreTests: XCTestCase {
    override func setUp() {
        super.setUp()
        MainActor.assumeIsolated {
            CommandCenterDeepLinkStore.shared.clearPendingTaskIDs()
        }
    }

    override func tearDown() {
        MainActor.assumeIsolated {
            CommandCenterDeepLinkStore.shared.clearPendingTaskIDs()
        }
        super.tearDown()
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
        XCTFail("Timed out waiting for async Command Center condition", file: file, line: line)
    }

    func testOpeningWorkspaceAppearsBeforeResolvedProjectPathExists() async throws {
        let mountPath = "/tmp/remote-mounted-project"
        let resolver = CommandCenterWorkspaceProjectPathResolver()
        let runtimeFactory = CommandCenterRuntimeFactory(
            specs: [
                .init(projectID: "project-remote", projectPath: mountPath, openDelayNanos: 10_000_000)
            ]
        )
        let manager = WorkspaceManager(
            projectPathResolver: resolver,
            runtimeFactory: runtimeFactory.makeRuntime
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
                proxyJump: nil,
                remotePath: "/srv/project"
            ),
            terminalMode: .persistent
        )
        resolver.resolutions[workspace.id] = .delayed(mountPath, 500_000_000)

        let store = CommandCenterStore(workspaceManager: manager)
        store.refreshNow()

        try await waitUntil {
            store.visibleSections.count == 1
                && store.visibleSections.first?.errorMessage == "Workspace runtime is still opening."
        }

        let section = try XCTUnwrap(store.visibleSections.first)
        XCTAssertEqual(section.workspaceName, "Remote")
        XCTAssertEqual(section.workspacePath, "/srv/project")
        XCTAssertEqual(section.errorMessage, "Workspace runtime is still opening.")
        XCTAssertTrue(section.runs.isEmpty)
    }

    func testFailedPathResolutionAppearsForLocalWorkspace() async throws {
        let unresolvedMessage = "The workspace project path could not be resolved."
        let resolver = CommandCenterWorkspaceProjectPathResolver()
        let runtimeFactory = CommandCenterRuntimeFactory(
            specs: [
                .init(projectID: "project-a", projectPath: "/tmp/a", openDelayNanos: 10_000_000)
            ]
        )
        let manager = WorkspaceManager(
            projectPathResolver: resolver,
            runtimeFactory: runtimeFactory.makeRuntime
        )
        let workspace = manager.createWorkspace(name: "A", projectPath: "/tmp/a")
        resolver.resolutions[workspace.id] = .immediate(nil)

        let store = CommandCenterStore(workspaceManager: manager)
        store.refreshNow()

        try await waitUntil {
            store.visibleSections.count == 1
                && store.visibleSections.first?.errorMessage == unresolvedMessage
        }

        let section = try XCTUnwrap(store.visibleSections.first)
        XCTAssertEqual(section.workspaceName, "A")
        XCTAssertEqual(section.workspacePath, "/tmp/a")
        XCTAssertEqual(section.errorMessage, unresolvedMessage)
    }

    func testRemoteUnresolvedWorkspaceAppearsWithRemotePathFallback() async throws {
        let unresolvedMessage = "The workspace project path could not be resolved."
        let runtimeFactory = CommandCenterRuntimeFactory(
            specs: [
                .init(projectID: "project-remote", projectPath: "/tmp/remote-mounted-project", openDelayNanos: 10_000_000)
            ]
        )
        let manager = WorkspaceManager(
            projectPathResolver: CommandCenterWorkspaceProjectPathResolver(),
            runtimeFactory: runtimeFactory.makeRuntime
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
                proxyJump: nil,
                remotePath: "/srv/project"
            ),
            terminalMode: .persistent
        )

        let store = CommandCenterStore(workspaceManager: manager)
        store.refreshNow()

        try await waitUntil {
            store.visibleSections.count == 1
                && store.visibleSections.first?.errorMessage == unresolvedMessage
        }

        let section = try XCTUnwrap(store.visibleSections.first)
        XCTAssertEqual(section.workspaceName, "Remote")
        XCTAssertEqual(section.workspacePath, "/srv/project")
        XCTAssertEqual(section.errorMessage, unresolvedMessage)
        let runtimeBus = try XCTUnwrap(runtimeFactory.buses[workspace.id])
        let openCount = await runtimeBus.openCount(for: "/tmp/remote-mounted-project")
        XCTAssertEqual(openCount, 0)
    }

    func testConcurrentSnapshotsStayBoundToOwningWorkspace() async throws {
        let runtimeFactory = CommandCenterRuntimeFactory(
            specs: [
                .init(projectID: "project-a", projectPath: "/tmp/a", openDelayNanos: 120_000_000),
                .init(projectID: "project-b", projectPath: "/tmp/b", openDelayNanos: 40_000_000),
            ]
        )
        let manager = WorkspaceManager(runtimeFactory: runtimeFactory.makeRuntime)
        let workspaceA = manager.createWorkspace(name: "A", projectPath: "/tmp/a")
        let workspaceB = manager.createWorkspace(name: "B", projectPath: "/tmp/b")

        manager.switchToWorkspace(workspaceA.id)

        async let snapshotA = manager.commandCenterSnapshot(
            for: workspaceA.id,
            timeoutNanoseconds: 1_000_000_000
        )
        async let snapshotB = manager.commandCenterSnapshot(
            for: workspaceB.id,
            timeoutNanoseconds: 1_000_000_000
        )

        let (loadedA, loadedB) = try await (snapshotA, snapshotB)

        XCTAssertEqual(loadedA.projectID, "project-a")
        XCTAssertEqual(loadedA.projectPath, "/tmp/a")
        XCTAssertEqual(loadedB.projectID, "project-b")
        XCTAssertEqual(loadedB.projectPath, "/tmp/b")
        XCTAssertEqual(manager.activeWorkspaceID, workspaceA.id)
    }

    func testRefreshingCommandCenterDoesNotStealActiveWorkspace() async throws {
        let runtimeFactory = CommandCenterRuntimeFactory(
            specs: [
                .init(projectID: "project-a", projectPath: "/tmp/a", openDelayNanos: 80_000_000),
                .init(projectID: "project-b", projectPath: "/tmp/b", openDelayNanos: 80_000_000),
            ]
        )
        let manager = WorkspaceManager(runtimeFactory: runtimeFactory.makeRuntime)
        let workspaceA = manager.createWorkspace(name: "A", projectPath: "/tmp/a")
        _ = manager.createWorkspace(name: "B", projectPath: "/tmp/b")
        manager.switchToWorkspace(workspaceA.id)

        let store = CommandCenterStore(workspaceManager: manager)
        store.refreshNow()

        try await waitUntil(timeoutNanos: 5_000_000_000) {
            store.workspaceSnapshots.count == 2
                && store.workspaceSnapshots.allSatisfy { $0.snapshot != nil }
        }

        XCTAssertEqual(manager.activeWorkspaceID, workspaceA.id)
        XCTAssertEqual(
            store.workspaceSnapshots.compactMap(\.snapshot?.projectID).sorted(),
            ["project-a", "project-b"]
        )
    }

    func testDiffViewModelConsumesCommandCenterDeepLink() async throws {
        let activationHub = ActiveWorkspaceActivationHub()
        let viewModel = DiffViewModel(
            commandBus: CommandCenterRoutingMockBus(),
            activationHub: activationHub
        )

        activationHub.update(.open(workspaceID: UUID(), projectID: "project-diff"))
        try await waitUntil {
            viewModel.tasks.map(\.id).sorted() == ["diff-1", "diff-2"]
        }

        CommandCenterDeepLinkStore.shared.setPendingTaskID("diff-2", for: .diff)

        try await waitUntil {
            viewModel.selectedTaskId == "diff-2"
                && viewModel.files.first?.path == "Sources/diff-2.swift"
        }
    }

    func testReviewViewModelConsumesCommandCenterDeepLink() async throws {
        let activationHub = ActiveWorkspaceActivationHub()
        let viewModel = ReviewViewModel(
            commandBus: CommandCenterRoutingMockBus(),
            bridgeEventHub: BridgeEventHub(),
            activationHub: activationHub
        )

        activationHub.update(.open(workspaceID: UUID(), projectID: "project-review"))
        try await waitUntil {
            viewModel.reviewTasks.map(\.id).sorted() == ["review-1", "review-2"]
        }

        CommandCenterDeepLinkStore.shared.setPendingTaskID("review-2", for: .review)

        try await waitUntil {
            viewModel.selectedTaskID == "review-2"
                && viewModel.reviewPack?.taskID == "review-2"
                && viewModel.diffFiles.first?.path == "Sources/review-2.swift"
        }
    }

    func testTerminalWorkingDirectoryPrefersWorktreePath() {
        let run = CommandCenterFleetRun(
            id: "workspace:run",
            workspaceID: UUID(),
            workspaceName: "Workspace",
            workspacePath: "/tmp/workspace",
            generatedAt: Date(),
            run: CommandCenterRun(
                id: "run",
                taskID: "task-1",
                taskTitle: "Task",
                taskStatus: "InProgress",
                sessionID: nil,
                sessionName: nil,
                sessionStatus: nil,
                sessionHealth: nil,
                provider: nil,
                model: nil,
                agentProfile: nil,
                branch: nil,
                worktreeID: "worktree-1",
                primaryFilePath: nil,
                scopePaths: [],
                worktreePath: "/tmp/worktree/task-1",
                state: "running",
                attentionReason: nil,
                startedAt: Date(),
                lastActivityAt: Date(),
                retryCount: 0,
                retryAfter: nil,
                costUsd: 0,
                tokensIn: 0,
                tokensOut: 0,
                availableActions: []
            )
        )

        XCTAssertEqual(
            run.preferredTerminalWorkingDirectory(fallback: "/tmp/workspace"),
            "/tmp/worktree/task-1"
        )
    }

    func testRelatedFilesPathPrefersPrimaryFileThenScopeThenWorktree() {
        func makeRun(
            primaryFilePath: String?,
            scopePaths: [String],
            worktreePath: String?
        ) -> CommandCenterRun {
            CommandCenterRun(
                id: "run",
                taskID: "task-1",
                taskTitle: "Task",
                taskStatus: "InProgress",
                sessionID: "session-1",
                sessionName: "Agent",
                sessionStatus: "running",
                sessionHealth: "healthy",
                provider: nil,
                model: nil,
                agentProfile: nil,
                branch: nil,
                worktreeID: "worktree-1",
                primaryFilePath: primaryFilePath,
                scopePaths: scopePaths,
                worktreePath: worktreePath,
                state: "running",
                attentionReason: nil,
                startedAt: Date(),
                lastActivityAt: Date(),
                retryCount: 0,
                retryAfter: nil,
                costUsd: 0,
                tokensIn: 0,
                tokensOut: 0,
                availableActions: []
            )
        }

        XCTAssertEqual(
            makeRun(
                primaryFilePath: "/tmp/worktree/Primary.swift",
                scopePaths: ["/tmp/worktree/Scoped.swift"],
                worktreePath: "/tmp/worktree"
            ).relatedFilesPath,
            "/tmp/worktree/Primary.swift"
        )
        XCTAssertEqual(
            makeRun(
                primaryFilePath: nil,
                scopePaths: ["/tmp/worktree/Scoped.swift"],
                worktreePath: "/tmp/worktree"
            ).relatedFilesPath,
            "/tmp/worktree/Scoped.swift"
        )
        XCTAssertEqual(
            makeRun(
                primaryFilePath: nil,
                scopePaths: [],
                worktreePath: "/tmp/worktree"
            ).relatedFilesPath,
            "/tmp/worktree"
        )
    }

    func testWorkspaceScopeFiltersVisibleRunsAndSummary() {
        let manager = WorkspaceManager()
        let workspaceA = manager.createWorkspace(name: "Alpha", projectPath: "/tmp/alpha")
        let workspaceB = manager.createWorkspace(name: "Beta", projectPath: "/tmp/beta")
        let store = CommandCenterStore(workspaceManager: manager)

        store.replaceSnapshotsForTesting([
            CommandCenterWorkspaceSnapshot(
                id: workspaceA.id,
                workspaceName: workspaceA.name,
                workspacePath: "/tmp/alpha",
                snapshot: CommandCenterSnapshot(
                    projectID: "alpha",
                    projectName: "Alpha",
                    projectPath: "/tmp/alpha",
                    generatedAt: Date(),
                    summary: CommandCenterSummary(
                        activeCount: 1,
                        queuedCount: 0,
                        idleCount: 0,
                        stuckCount: 0,
                        reviewNeededCount: 0,
                        failedCount: 0,
                        retryingCount: 0,
                        slotLimit: 4,
                        slotInUse: 1,
                        costTodayUsd: 1.25
                    ),
                    runs: [
                        makeCommandCenterRun(
                            id: "run-a",
                            taskTitle: "Alpha work",
                            state: "running"
                        )
                    ]
                ),
                errorMessage: nil
            ),
            CommandCenterWorkspaceSnapshot(
                id: workspaceB.id,
                workspaceName: workspaceB.name,
                workspacePath: "/tmp/beta",
                snapshot: CommandCenterSnapshot(
                    projectID: "beta",
                    projectName: "Beta",
                    projectPath: "/tmp/beta",
                    generatedAt: Date(),
                    summary: CommandCenterSummary(
                        activeCount: 0,
                        queuedCount: 1,
                        idleCount: 0,
                        stuckCount: 0,
                        reviewNeededCount: 0,
                        failedCount: 1,
                        retryingCount: 0,
                        slotLimit: 4,
                        slotInUse: 1,
                        costTodayUsd: 2.50
                    ),
                    runs: [
                        makeCommandCenterRun(
                            id: "run-b",
                            taskTitle: "Beta failure",
                            state: "failed",
                            attentionReason: "build_failed"
                        )
                    ]
                ),
                errorMessage: nil
            ),
        ])

        XCTAssertEqual(store.visibleRuns.count, 2)
        XCTAssertEqual(store.fleetSummary.workspaceCount, 2)

        store.selectWorkspace(workspaceA.id)

        XCTAssertEqual(store.scopeTitle, "Alpha")
        XCTAssertEqual(store.visibleRuns.count, 1)
        XCTAssertEqual(store.visibleRuns.first?.workspaceID, workspaceA.id)
        XCTAssertEqual(store.fleetSummary.workspaceCount, 1)
        XCTAssertEqual(store.fleetSummary.activeCount, 1)
    }

    func testFocusIncidentClearsStaleWorkspaceScopeForMultiWorkspaceIncident() {
        let manager = WorkspaceManager()
        let workspaceA = manager.createWorkspace(name: "Alpha", projectPath: "/tmp/alpha")
        let workspaceB = manager.createWorkspace(name: "Beta", projectPath: "/tmp/beta")
        let workspaceC = manager.createWorkspace(name: "Gamma", projectPath: "/tmp/gamma")
        let store = CommandCenterStore(workspaceManager: manager)

        store.replaceSnapshotsForTesting([
            CommandCenterWorkspaceSnapshot(
                id: workspaceA.id,
                workspaceName: workspaceA.name,
                workspacePath: "/tmp/alpha",
                snapshot: CommandCenterSnapshot(
                    projectID: "alpha",
                    projectName: "Alpha",
                    projectPath: "/tmp/alpha",
                    generatedAt: Date(),
                    summary: CommandCenterSummary(
                        activeCount: 1,
                        queuedCount: 0,
                        idleCount: 0,
                        stuckCount: 0,
                        reviewNeededCount: 0,
                        failedCount: 0,
                        retryingCount: 0,
                        slotLimit: 4,
                        slotInUse: 1,
                        costTodayUsd: 0.25
                    ),
                    runs: [
                        makeCommandCenterRun(
                            id: "run-a",
                            taskTitle: "Alpha work",
                            state: "running"
                        )
                    ]
                ),
                errorMessage: nil
            ),
            CommandCenterWorkspaceSnapshot(
                id: workspaceB.id,
                workspaceName: workspaceB.name,
                workspacePath: "/tmp/beta",
                snapshot: CommandCenterSnapshot(
                    projectID: "beta",
                    projectName: "Beta",
                    projectPath: "/tmp/beta",
                    generatedAt: Date(),
                    summary: CommandCenterSummary(
                        activeCount: 0,
                        queuedCount: 0,
                        idleCount: 0,
                        stuckCount: 0,
                        reviewNeededCount: 0,
                        failedCount: 1,
                        retryingCount: 0,
                        slotLimit: 4,
                        slotInUse: 1,
                        costTodayUsd: 0.5
                    ),
                    runs: [
                        makeCommandCenterRun(
                            id: "run-b",
                            taskTitle: "Beta failure",
                            state: "failed",
                            attentionReason: "tests_failed"
                        )
                    ]
                ),
                errorMessage: nil
            ),
            CommandCenterWorkspaceSnapshot(
                id: workspaceC.id,
                workspaceName: workspaceC.name,
                workspacePath: "/tmp/gamma",
                snapshot: CommandCenterSnapshot(
                    projectID: "gamma",
                    projectName: "Gamma",
                    projectPath: "/tmp/gamma",
                    generatedAt: Date(),
                    summary: CommandCenterSummary(
                        activeCount: 0,
                        queuedCount: 0,
                        idleCount: 0,
                        stuckCount: 0,
                        reviewNeededCount: 0,
                        failedCount: 1,
                        retryingCount: 0,
                        slotLimit: 4,
                        slotInUse: 1,
                        costTodayUsd: 0.5
                    ),
                    runs: [
                        makeCommandCenterRun(
                            id: "run-c",
                            taskTitle: "Gamma failure",
                            state: "failed",
                            attentionReason: "tests_failed"
                        )
                    ]
                ),
                errorMessage: nil
            ),
        ])

        store.selectWorkspace(workspaceA.id)
        XCTAssertEqual(store.selectedWorkspaceID, workspaceA.id)
        XCTAssertEqual(store.selectedRun?.run.id, "run-a")

        store.focusIncident(
            CommandCenterIncident(
                kind: .failed,
                title: "Failed runs",
                summary: "Run failed",
                count: 2,
                severity: .urgent,
                oldestAt: nil,
                workspaceIDs: [workspaceB.id, workspaceC.id]
            )
        )

        XCTAssertNil(store.selectedWorkspaceID)
        XCTAssertEqual(store.filter, .failed)
        XCTAssertEqual(Set(store.visibleRuns.map(\.run.id)), Set(["run-b", "run-c"]))
        XCTAssertTrue([workspaceB.id, workspaceC.id].contains(store.selectedRun?.workspaceID))
    }

    func testFocusIncidentScopesToSingleWorkspaceAndSelectsMatchingRun() {
        let manager = WorkspaceManager()
        let workspaceA = manager.createWorkspace(name: "Alpha", projectPath: "/tmp/alpha")
        let workspaceB = manager.createWorkspace(name: "Beta", projectPath: "/tmp/beta")
        let store = CommandCenterStore(workspaceManager: manager)

        store.replaceSnapshotsForTesting([
            CommandCenterWorkspaceSnapshot(
                id: workspaceA.id,
                workspaceName: workspaceA.name,
                workspacePath: "/tmp/alpha",
                snapshot: CommandCenterSnapshot(
                    projectID: "alpha",
                    projectName: "Alpha",
                    projectPath: "/tmp/alpha",
                    generatedAt: Date(),
                    summary: CommandCenterSummary(
                        activeCount: 1,
                        queuedCount: 0,
                        idleCount: 0,
                        stuckCount: 0,
                        reviewNeededCount: 0,
                        failedCount: 0,
                        retryingCount: 0,
                        slotLimit: 4,
                        slotInUse: 1,
                        costTodayUsd: 0.25
                    ),
                    runs: [
                        makeCommandCenterRun(
                            id: "run-a",
                            taskTitle: "Alpha work",
                            state: "running"
                        )
                    ]
                ),
                errorMessage: nil
            ),
            CommandCenterWorkspaceSnapshot(
                id: workspaceB.id,
                workspaceName: workspaceB.name,
                workspacePath: "/tmp/beta",
                snapshot: CommandCenterSnapshot(
                    projectID: "beta",
                    projectName: "Beta",
                    projectPath: "/tmp/beta",
                    generatedAt: Date(),
                    summary: CommandCenterSummary(
                        activeCount: 0,
                        queuedCount: 0,
                        idleCount: 0,
                        stuckCount: 0,
                        reviewNeededCount: 1,
                        failedCount: 0,
                        retryingCount: 0,
                        slotLimit: 4,
                        slotInUse: 1,
                        costTodayUsd: 0.5
                    ),
                    runs: [
                        makeCommandCenterRun(
                            id: "run-b",
                            taskTitle: "Needs review",
                            state: "review_needed"
                        )
                    ]
                ),
                errorMessage: nil
            ),
        ])

        store.selectWorkspace(workspaceA.id)
        XCTAssertEqual(store.selectedWorkspaceID, workspaceA.id)
        XCTAssertEqual(store.selectedRun?.run.id, "run-a")

        store.focusIncident(
            CommandCenterIncident(
                kind: .review,
                title: "Review needed",
                summary: "Waiting on manual review",
                count: 1,
                severity: .watch,
                oldestAt: nil,
                workspaceIDs: [workspaceB.id]
            )
        )

        XCTAssertEqual(store.selectedWorkspaceID, workspaceB.id)
        XCTAssertEqual(store.filter, .review)
        XCTAssertEqual(store.visibleRuns.map(\.run.id), ["run-b"])
        XCTAssertEqual(store.selectedRun?.workspaceID, workspaceB.id)
        XCTAssertEqual(store.selectedRun?.run.id, "run-b")
    }

    func testAttentionItemsGroupRunIncidentsAndWorkspaceErrors() {
        let manager = WorkspaceManager()
        let workspace = manager.createWorkspace(name: "Ops", projectPath: "/tmp/ops")
        let store = CommandCenterStore(workspaceManager: manager)

        store.replaceSnapshotsForTesting([
            CommandCenterWorkspaceSnapshot(
                id: workspace.id,
                workspaceName: workspace.name,
                workspacePath: "/tmp/ops",
                snapshot: CommandCenterSnapshot(
                    projectID: "ops",
                    projectName: "Ops",
                    projectPath: "/tmp/ops",
                    generatedAt: Date(),
                    summary: CommandCenterSummary(
                        activeCount: 0,
                        queuedCount: 0,
                        idleCount: 0,
                        stuckCount: 1,
                        reviewNeededCount: 1,
                        failedCount: 1,
                        retryingCount: 0,
                        slotLimit: 4,
                        slotInUse: 1,
                        costTodayUsd: 0.5
                    ),
                    runs: [
                        makeCommandCenterRun(
                            id: "failed",
                            taskTitle: "Broken run",
                            state: "failed",
                            attentionReason: "tests_failed"
                        ),
                        makeCommandCenterRun(
                            id: "review",
                            taskTitle: "Needs review",
                            state: "review_needed"
                        ),
                        makeCommandCenterRun(
                            id: "stuck",
                            taskTitle: "Hung run",
                            state: "stuck"
                        ),
                    ]
                ),
                errorMessage: "Workspace runtime is still opening."
            ),
        ])

        let kinds = Set(store.attentionItems.map(\.kind))
        XCTAssertTrue(kinds.contains(.workspaceError))
        XCTAssertTrue(kinds.contains(.failed))
        XCTAssertTrue(kinds.contains(.review))
        XCTAssertTrue(kinds.contains(.stuck))
        XCTAssertEqual(store.attentionRunCount, 4)
    }

    func testSearchOnlyFiltersBoardWhileHealthAndAttentionQueueStayScoped() {
        let manager = WorkspaceManager()
        let workspace = manager.createWorkspace(name: "Ops", projectPath: "/tmp/ops")
        let store = CommandCenterStore(workspaceManager: manager)

        store.replaceSnapshotsForTesting([
            CommandCenterWorkspaceSnapshot(
                id: workspace.id,
                workspaceName: workspace.name,
                workspacePath: "/tmp/ops",
                snapshot: CommandCenterSnapshot(
                    projectID: "ops",
                    projectName: "Ops",
                    projectPath: "/tmp/ops",
                    generatedAt: Date(),
                    summary: CommandCenterSummary(
                        activeCount: 0,
                        queuedCount: 0,
                        idleCount: 0,
                        stuckCount: 0,
                        reviewNeededCount: 0,
                        failedCount: 1,
                        retryingCount: 0,
                        slotLimit: 4,
                        slotInUse: 1,
                        costTodayUsd: 0.5
                    ),
                    runs: [
                        makeCommandCenterRun(
                            id: "failed",
                            taskTitle: "Broken run",
                            state: "failed",
                            attentionReason: "tests_failed"
                        )
                    ]
                ),
                errorMessage: nil
            ),
        ])

        XCTAssertEqual(store.fleetHealth, .interventionNeeded)
        XCTAssertEqual(store.attentionRunCount, 1)
        XCTAssertEqual(store.healthSummaryText, "Immediate follow-up required for 1 item")
        XCTAssertEqual(store.attentionItems.map(\.kind), [.failed])
        XCTAssertEqual(store.attentionItems.first?.count, 1)
        XCTAssertEqual(store.workspaceClusters.first?.attentionCount, 1)

        store.searchQuery = "no visible runs"

        XCTAssertTrue(store.visibleRuns.isEmpty)
        XCTAssertEqual(store.filterCount(for: .failed), 0)
        XCTAssertEqual(store.fleetHealth, .interventionNeeded)
        XCTAssertEqual(store.attentionRunCount, 1)
        XCTAssertEqual(store.healthSummaryText, "Immediate follow-up required for 1 item")
        XCTAssertEqual(store.attentionItems.map(\.kind), [.failed])
        XCTAssertEqual(store.attentionItems.first?.count, 1)
        XCTAssertEqual(store.workspaceClusters.first?.attentionCount, 1)
    }

    func testKeyboardSelectionNavigationTracksVisibleRunOrder() {
        let manager = WorkspaceManager()
        let workspace = manager.createWorkspace(name: "Ops", projectPath: "/tmp/ops")
        let store = CommandCenterStore(workspaceManager: manager)

        store.replaceSnapshotsForTesting([
            CommandCenterWorkspaceSnapshot(
                id: workspace.id,
                workspaceName: workspace.name,
                workspacePath: "/tmp/ops",
                snapshot: CommandCenterSnapshot(
                    projectID: "ops",
                    projectName: "Ops",
                    projectPath: "/tmp/ops",
                    generatedAt: Date(),
                    summary: CommandCenterSummary(
                        activeCount: 1,
                        queuedCount: 1,
                        idleCount: 0,
                        stuckCount: 0,
                        reviewNeededCount: 0,
                        failedCount: 1,
                        retryingCount: 0,
                        slotLimit: 4,
                        slotInUse: 2,
                        costTodayUsd: 0.75
                    ),
                    runs: [
                        makeCommandCenterRun(
                            id: "active",
                            taskTitle: "Active run",
                            state: "running"
                        ),
                        makeCommandCenterRun(
                            id: "failed",
                            taskTitle: "Failed run",
                            state: "failed",
                            attentionReason: "tests_failed"
                        ),
                        makeCommandCenterRun(
                            id: "queued",
                            taskTitle: "Queued run",
                            state: "queued"
                        ),
                    ]
                ),
                errorMessage: nil
            )
        ])

        XCTAssertEqual(store.selectedRun?.run.id, "failed")

        store.selectNextRun()
        XCTAssertEqual(store.selectedRun?.run.id, "active")

        store.selectNextRun()
        XCTAssertEqual(store.selectedRun?.run.id, "queued")

        store.selectPreviousRun()
        XCTAssertEqual(store.selectedRun?.run.id, "active")

        store.selectLastRun()
        XCTAssertEqual(store.selectedRun?.run.id, "queued")

        store.selectFirstRun()
        XCTAssertEqual(store.selectedRun?.run.id, "failed")
    }

    func testPerformSelectedActionUsesSelectedRunWhenShortcutMatchesAvailableAction() {
        let manager = WorkspaceManager()
        let workspace = manager.createWorkspace(name: "Ops", projectPath: "/tmp/ops")
        let store = CommandCenterStore(workspaceManager: manager)
        var capturedAction: CommandCenterAction?
        var capturedRunID: String?

        store.onPerformAction = { action, run in
            capturedAction = action
            capturedRunID = run.run.id
        }

        store.replaceSnapshotsForTesting([
            CommandCenterWorkspaceSnapshot(
                id: workspace.id,
                workspaceName: workspace.name,
                workspacePath: "/tmp/ops",
                snapshot: CommandCenterSnapshot(
                    projectID: "ops",
                    projectName: "Ops",
                    projectPath: "/tmp/ops",
                    generatedAt: Date(),
                    summary: CommandCenterSummary(
                        activeCount: 1,
                        queuedCount: 0,
                        idleCount: 0,
                        stuckCount: 0,
                        reviewNeededCount: 0,
                        failedCount: 0,
                        retryingCount: 0,
                        slotLimit: 4,
                        slotInUse: 1,
                        costTodayUsd: 0.25
                    ),
                    runs: [
                        makeCommandCenterRun(
                            id: "selected",
                            taskTitle: "Selected run",
                            state: "running"
                        )
                    ]
                ),
                errorMessage: nil
            )
        ])

        store.performSelectedAction(.openTerminal)

        XCTAssertEqual(capturedAction, .openTerminal)
        XCTAssertEqual(capturedRunID, "selected")

        capturedAction = nil
        capturedRunID = nil

        store.performSelectedAction(.killSession)

        XCTAssertNil(capturedAction)
        XCTAssertNil(capturedRunID)
    }

    private func makeCommandCenterRun(
        id: String,
        taskTitle: String,
        state: String,
        attentionReason: String? = nil
    ) -> CommandCenterRun {
        CommandCenterRun(
            id: id,
            taskID: "task-\(id)",
            taskTitle: taskTitle,
            taskStatus: "InProgress",
            sessionID: "session-\(id)",
            sessionName: "Session \(id)",
            sessionStatus: "running",
            sessionHealth: "healthy",
            provider: "claude",
            model: "sonnet",
            agentProfile: "research",
            branch: "feature/\(id)",
            worktreeID: "wt-\(id)",
            primaryFilePath: "/tmp/\(id).swift",
            scopePaths: ["/tmp/\(id)-scope.swift"],
            worktreePath: "/tmp/worktree-\(id)",
            state: state,
            attentionReason: attentionReason,
            startedAt: Date(timeIntervalSinceNow: -600),
            lastActivityAt: Date(timeIntervalSinceNow: -120),
            retryCount: 0,
            retryAfter: nil,
            costUsd: 0.25,
            tokensIn: 128,
            tokensOut: 256,
            availableActions: ["open_terminal", "open_replay", "open_files"]
        )
    }
}
