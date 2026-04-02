import Cocoa
import XCTest
@testable import Pnevma

private actor ActivationPaneCommandBus: CommandCalling {
    private var taskListCallCountValue = 0
    private var notificationListCallCountValue = 0
    private var taskListJSON = #"""
    [
      {
        "id": "task-1",
        "title": "Ready work",
        "goal": "Ship the board integration",
        "status": "Ready",
        "priority": "P1",
        "scope": ["native/Pnevma/Panes/TaskBoardPane.swift"],
        "dependencies": [],
        "acceptance_criteria": [
          { "description": "board loads" }
        ],
        "branch": "feature/taskboard",
        "worktree_id": "wt-1",
        "queued_position": null,
        "cost_usd": 1.25,
        "execution_mode": "worktree",
        "updated_at": "2026-03-06T08:00:00Z"
      }
    ]
    """#

    func call<T: Decodable & Sendable>(method: String, params: (any Encodable & Sendable)?) async throws -> T {
        switch method {
        case "task.list":
            taskListCallCountValue += 1
            return try decode(taskListJSON)
        case "task.create":
            taskListJSON = #"""
            [
              {
                "id": "task-1",
                "title": "Ready work",
                "goal": "Ship the board integration",
                "status": "Ready",
                "priority": "P1",
                "scope": ["native/Pnevma/Panes/TaskBoardPane.swift"],
                "dependencies": [],
                "acceptance_criteria": [
                  { "description": "board loads" }
                ],
                "branch": "feature/taskboard",
                "worktree_id": "wt-1",
                "queued_position": null,
                "cost_usd": 1.25,
                "execution_mode": "worktree",
                "updated_at": "2026-03-06T08:00:00Z"
              },
              {
                "id": "task-created",
                "title": "Planned follow-up",
                "goal": "Capture the next task from the board",
                "status": "Planned",
                "priority": "P2",
                "scope": [],
                "dependencies": [],
                "acceptance_criteria": [],
                "branch": null,
                "worktree_id": null,
                "queued_position": null,
                "cost_usd": null,
                "execution_mode": "worktree",
                "updated_at": "2026-03-07T10:15:00Z"
              }
            ]
            """#
            return try decode(#"{"task_id":"task-created"}"#)
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

    func replaceTaskListJSON(_ json: String) {
        taskListJSON = json
    }

    private func decode<T: Decodable>(_ json: String) throws -> T {
        let decoder = PnevmaJSON.decoder()
        return try decoder.decode(T.self, from: Data(json.utf8))
    }
}

@MainActor
final class WorkspaceRestoreTests: XCTestCase {
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

        let terminal = Workspace(name: "Terminal")
        let second = Workspace(name: "Two", projectPath: "/tmp/two")

        manager.restore(
            snapshots: [terminal.snapshot(), second.snapshot()],
            activeWorkspaceID: second.id
        )

        XCTAssertEqual(manager.workspaces.count, 2)
        XCTAssertEqual(manager.activeWorkspaceID, second.id)
        XCTAssertEqual(manager.activeWorkspace?.name, "Two")
    }

    func testWorkspaceSnapshotRoundTripsLaunchSource() {
        let workspace = Workspace(name: "Issue #12 — Fix opener", projectPath: "/tmp/project")
        workspace.launchSource = WorkspaceLaunchSource(
            kind: "issue",
            number: 12,
            title: "Fix opener",
            url: "https://github.com/acme/widgets/issues/12"
        )

        let restored = Workspace(snapshot: workspace.snapshot())

        XCTAssertEqual(restored.launchSource?.kind, "issue")
        XCTAssertEqual(restored.launchSource?.number, 12)
        XCTAssertEqual(restored.launchSource?.title, "Fix opener")
        XCTAssertEqual(
            restored.launchSource?.url,
            "https://github.com/acme/widgets/issues/12"
        )
    }

    func testWorkspaceSnapshotRoundTripsAgentTeamTerminalMetadata() throws {
        let workspace = Workspace(name: "Team Restore", projectPath: "/tmp/project")
        let paneID = workspace.layoutEngine.root?.allPaneIDs.first ?? UUID()
        workspace.layoutEngine.upsertPersistedPane(
            PersistedPane(
                paneID: paneID,
                type: "terminal",
                workingDirectory: "/tmp/project",
                sessionID: "leader-session",
                taskID: nil,
                metadataJSON: TerminalLaunchMetadata(
                    launchMode: .managedSession,
                    startBehavior: .deferUntilActivate,
                    remoteTarget: nil,
                    backendPaneID: "leader-pane",
                    agentTeamID: "team-1",
                    agentTeamRole: "leader",
                    agentTeamMemberIndex: 0
                ).encodedJSON()
            )
        )

        let restored = Workspace(snapshot: workspace.snapshot())
        let restoredPaneID = try XCTUnwrap(restored.layoutEngine.root?.allPaneIDs.first)
        let metadata = try XCTUnwrap(
            TerminalLaunchMetadata.from(
                json: restored.layoutEngine.persistedPane(for: restoredPaneID)?.metadataJSON
            )
        )
        XCTAssertEqual(metadata.backendPaneID, "leader-pane")
        XCTAssertEqual(metadata.agentTeamID, "team-1")
        XCTAssertEqual(metadata.agentTeamRole, "leader")
        XCTAssertEqual(metadata.agentTeamMemberIndex, 0)
    }

    func testWorkspaceAgentTeamPaneLocationFindsLeaderAcrossTabs() throws {
        let workspace = Workspace(name: "Team Tabs", projectPath: "/tmp/project")
        let leaderPaneID = workspace.layoutEngine.root?.allPaneIDs.first ?? UUID()
        workspace.layoutEngine.upsertPersistedPane(
            PersistedPane(
                paneID: leaderPaneID,
                type: "terminal",
                workingDirectory: "/tmp/project",
                sessionID: "leader-session",
                taskID: nil,
                metadataJSON: TerminalLaunchMetadata(
                    launchMode: .managedSession,
                    startBehavior: .deferUntilActivate,
                    remoteTarget: nil,
                    backendPaneID: "leader-pane",
                    agentTeamID: "team-1",
                    agentTeamRole: "leader",
                    agentTeamMemberIndex: 0
                ).encodedJSON()
            )
        )

        _ = workspace.addTab(title: "Member")
        let memberPaneID = workspace.layoutEngine.root?.allPaneIDs.first ?? UUID()
        workspace.layoutEngine.upsertPersistedPane(
            PersistedPane(
                paneID: memberPaneID,
                type: "terminal",
                workingDirectory: "/tmp/project",
                sessionID: "member-session",
                taskID: nil,
                metadataJSON: TerminalLaunchMetadata(
                    launchMode: .managedSession,
                    startBehavior: .deferUntilActivate,
                    remoteTarget: nil,
                    backendPaneID: "member-pane",
                    agentTeamID: "team-1",
                    agentTeamRole: "member",
                    agentTeamMemberIndex: 1
                ).encodedJSON()
            )
        )

        let leaderLocation = try XCTUnwrap(workspace.agentTeamPaneLocation(teamID: "team-1", role: "leader"))
        XCTAssertEqual(leaderLocation.tabIndex, 0)
        XCTAssertEqual(leaderLocation.paneID, leaderPaneID)

        let backendLocation = try XCTUnwrap(workspace.paneLocation(backendPaneID: "member-pane"))
        XCTAssertEqual(backendLocation.tabIndex, 1)
        XCTAssertEqual(backendLocation.paneID, memberPaneID)
    }

    func testWorkspaceManagerRestorePreservesMultipleProjectWorkspaces() {
        let bridge = PnevmaBridge()
        let manager = WorkspaceManager(bridge: bridge, commandBus: CommandBus(bridge: bridge))

        let terminal = Workspace(name: "Terminal")
        let firstProject = Workspace(name: "One", projectPath: "/tmp/one")
        let secondProject = Workspace(name: "Two", projectPath: "/tmp/two")

        manager.restore(
            snapshots: [terminal.snapshot(), firstProject.snapshot(), secondProject.snapshot()],
            activeWorkspaceID: secondProject.id
        )

        let projectWorkspaces = manager.workspaces.filter { $0.projectPath != nil }
        XCTAssertEqual(projectWorkspaces.count, 2)
        XCTAssertTrue(projectWorkspaces.contains(where: { $0.id == firstProject.id }))
        XCTAssertTrue(projectWorkspaces.contains(where: { $0.id == secondProject.id }))
        XCTAssertEqual(manager.activeWorkspaceID, secondProject.id)
        XCTAssertTrue(manager.workspaces.contains(where: { $0.id == terminal.id }))
    }

    func testContentAreaViewShowsRestoreErrorPaneWithoutMutatingStateWhenDescriptorMissing() {
        let (_, rootPane) = PaneFactory.makeWelcome()
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

    func testRestoredWelcomePaneRemainsPersistable() {
        let persistedPane = PersistedPane(
            paneID: UUID(),
            type: "welcome",
            workingDirectory: nil,
            sessionID: nil,
            taskID: nil,
            metadataJSON: nil
        )

        let (paneID, pane) = PaneFactory.make(from: persistedPane)

        XCTAssertEqual(paneID, persistedPane.paneID)
        XCTAssertEqual(pane.persistedPane().paneID, persistedPane.paneID)
        XCTAssertEqual(pane.persistedPane().type, "welcome")
        XCTAssertTrue(pane.shouldPersist)
    }

    func testSwitchingToNewTabAfterSeedingDescriptorDoesNotShowRestoreError() {
        let workspace = Workspace(name: "Terminal")
        let initialRootPaneID = workspace.layoutEngine.root!.allPaneIDs.first!
        workspace.layoutEngine.upsertPersistedPane(
            PersistedPane(
                paneID: initialRootPaneID,
                type: "welcome",
                workingDirectory: nil,
                sessionID: nil,
                taskID: nil,
                metadataJSON: nil
            )
        )

        let (_, rootPane) = PaneFactory.makeWelcome()
        let contentArea = ContentAreaView(
            frame: NSRect(x: 0, y: 0, width: 1200, height: 800),
            rootPaneView: rootPane
        )
        contentArea.setLayoutEngine(workspace.layoutEngine)

        _ = workspace.addTab(title: "Terminal")
        workspace.ensureActiveTabHasDisplayableRootPane()
        contentArea.setLayoutEngine(workspace.layoutEngine)

        XCTAssertEqual(contentArea.activePaneView?.paneType, "terminal")

        workspace.switchToTab(0)
        contentArea.setLayoutEngine(workspace.layoutEngine)
        XCTAssertNotEqual(contentArea.activePaneView?.paneType, "restore_error")

        workspace.switchToTab(1)
        workspace.ensureActiveTabHasDisplayableRootPane()
        contentArea.setLayoutEngine(workspace.layoutEngine)
        XCTAssertEqual(contentArea.activePaneView?.paneType, "terminal")
    }

    func testSwitchingWorkspacesPreservesNativePaneDescriptor() {
        let firstWorkspace = Workspace(name: "One")
        let secondWorkspace = Workspace(name: "Two")
        XCTAssertTrue(firstWorkspace.ensureActiveTabHasDisplayableRootPane())
        XCTAssertTrue(secondWorkspace.ensureActiveTabHasDisplayableRootPane())

        let (_, rootPane) = PaneFactory.makeWelcome()
        let contentArea = ContentAreaView(
            frame: NSRect(x: 0, y: 0, width: 1200, height: 800),
            rootPaneView: rootPane
        )

        contentArea.setLayoutEngine(firstWorkspace.layoutEngine)

        let workflowPane = WorkflowPaneView(frame: .zero)
        let workflowPaneID = contentArea.replaceActivePane(with: workflowPane)

        XCTAssertNotNil(workflowPaneID)
        XCTAssertEqual(contentArea.activePaneView?.paneType, "workflow")
        XCTAssertEqual(
            workflowPaneID.flatMap { firstWorkspace.layoutEngine.persistedPane(for: $0)?.type },
            "workflow"
        )

        contentArea.setLayoutEngine(secondWorkspace.layoutEngine)
        contentArea.setLayoutEngine(firstWorkspace.layoutEngine)

        XCTAssertEqual(contentArea.activePaneView?.paneType, "workflow")
        XCTAssertNotEqual(contentArea.activePaneView?.paneType, "restore_error")
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

        await viewModel.activate()
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

    func testTaskBoardViewModelCreatesTaskAndRefreshesPlannedLane() async throws {
        let bus = ActivationPaneCommandBus()
        let activationHub = ActiveWorkspaceActivationHub()
        let bridgeHub = BridgeEventHub()
        let viewModel = TaskBoardViewModel(
            commandBus: bus,
            bridgeEventHub: bridgeHub,
            activationHub: activationHub
        )

        activationHub.update(.open(workspaceID: UUID(), projectID: "project-1"))

        try await waitUntil {
            await bus.taskListCallCount() == 1 && viewModel.tasks(for: .ready).count == 1
        }

        var draft = TaskCreationDraft()
        draft.title = "Planned follow-up"
        draft.goal = "Capture the next task from the board"
        draft.priority = .p2

        let created = await viewModel.createTask(from: draft)
        XCTAssertTrue(created)

        try await waitUntil {
            await bus.taskListCallCount() == 2
                && viewModel.tasks(for: .planned).count == 1
                && viewModel.tasks(for: .planned).first?.title == "Planned follow-up"
        }
    }

    func testTaskBoardViewModelRefreshesWhenTaskUpdatedEventArrives() async throws {
        let bus = ActivationPaneCommandBus()
        let activationHub = ActiveWorkspaceActivationHub()
        let bridgeHub = BridgeEventHub()
        let viewModel = TaskBoardViewModel(
            commandBus: bus,
            bridgeEventHub: bridgeHub,
            activationHub: activationHub
        )

        activationHub.update(.open(workspaceID: UUID(), projectID: "project-1"))

        try await waitUntil {
            await bus.taskListCallCount() == 1 && viewModel.tasks(for: .ready).count == 1
        }

        await bus.replaceTaskListJSON(
            #"""
            [
              {
                "id": "task-1",
                "title": "Ready work",
                "goal": "Ship the board integration",
                "status": "Review",
                "priority": "P1",
                "scope": ["native/Pnevma/Panes/TaskBoardPane.swift"],
                "dependencies": [],
                "acceptance_criteria": [
                  { "description": "board loads" }
                ],
                "branch": "feature/taskboard",
                "worktree_id": "wt-1",
                "queued_position": null,
                "cost_usd": 1.25,
                "execution_mode": "worktree",
                "updated_at": "2026-03-07T11:00:00Z"
              }
            ]
            """#
        )
        bridgeHub.post(BridgeEvent(name: "task_updated", payloadJSON: #"{"task_id":"task-1"}"#))

        try await waitUntil {
            await bus.taskListCallCount() == 2 && viewModel.tasks(for: .review).count == 1
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

        await viewModel.activate()
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
