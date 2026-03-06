import Cocoa
import os

/// Manages workspace lifecycle — creation, switching, persistence, and teardown.
/// Only the selected workspace is bound to the backend at any time.
@MainActor
final class WorkspaceManager: ObservableObject {

    @Published private(set) var workspaces: [Workspace] = []
    @Published private(set) var activeWorkspaceID: UUID?

    var activeWorkspace: Workspace? {
        guard let id = activeWorkspaceID else { return nil }
        return workspaces.first { $0.id == id }
    }

    /// Called when the active workspace changes, providing the new workspace's layout engine.
    var onActiveWorkspaceChanged: ((PaneLayoutEngine) -> Void)?

    private let commandBus: any CommandCalling
    private var bridgeObserverID: UUID?

    private struct PendingActivationTarget {
        let workspaceID: UUID?
        let path: String?
        let generation: UInt64
    }

    private var nextRequestGeneration: UInt64 = 0
    private var workspaceGenerations: [UUID: UInt64] = [:]
    private var workspaceProjectIDs: [UUID: String] = [:]
    private var desiredActivationTarget: PendingActivationTarget?
    private var activationTask: Task<Void, Never>?

    init(bridge: PnevmaBridge, commandBus: any CommandCalling) {
        _ = bridge
        self.commandBus = commandBus
        bridgeObserverID = BridgeEventHub.shared.addObserver { [weak self] event in
            Task { @MainActor [weak self] in
                self?.handleBridgeEvent(event)
            }
        }
    }

    deinit {
        activationTask?.cancel()
        if let bridgeObserverID {
            BridgeEventHub.shared.removeObserver(bridgeObserverID)
        }
    }

    @discardableResult
    func createWorkspace(name: String, projectPath: String? = nil) -> Workspace {
        let workspace = Workspace(name: name, projectPath: projectPath)
        ensurePlaceholderPaneIfNeeded(for: workspace)
        workspaces.append(workspace)
        activateWorkspace(id: workspace.id)
        Log.workspace.info("Created workspace '\(name)' id=\(workspace.id)")
        return workspace
    }

    func switchToWorkspace(_ id: UUID) {
        guard workspaces.contains(where: { $0.id == id }) else { return }
        activateWorkspace(id: id)
        Log.workspace.info("Switched to workspace \(id)")
    }

    func closeWorkspace(_ id: UUID) {
        guard let index = workspaces.firstIndex(where: { $0.id == id }) else { return }
        let closingWasActive = activeWorkspaceID == id
        let workspace = workspaces.remove(at: index)
        invalidateRequestState(for: id)
        Log.workspace.info("Closed workspace '\(workspace.name)'")

        if workspaces.isEmpty {
            let fallback = Workspace(name: "Default")
            ensurePlaceholderPaneIfNeeded(for: fallback)
            workspaces = [fallback]
        }

        if closingWasActive {
            let replacementIndex = min(index, workspaces.count - 1)
            activateWorkspace(id: workspaces[replacementIndex].id)
        }
    }

    func restore(
        snapshots: [Workspace.Snapshot],
        activeWorkspaceID restoredActiveWorkspaceID: UUID?
    ) {
        workspaces = snapshots.map(Workspace.init(snapshot:))
        for workspace in workspaces {
            ensurePlaceholderPaneIfNeeded(for: workspace)
        }

        if workspaces.isEmpty {
            let fallback = Workspace(name: "Default")
            ensurePlaceholderPaneIfNeeded(for: fallback)
            workspaces = [fallback]
        }

        if let restoredActiveWorkspaceID,
           workspaces.contains(where: { $0.id == restoredActiveWorkspaceID }) {
            activateWorkspace(id: restoredActiveWorkspaceID)
        } else {
            activateWorkspace(id: workspaces.first?.id)
        }
    }

    /// Refresh workspace metadata from the Rust backend.
    func refreshMetadata(for workspace: Workspace) {
        guard workspace.projectPath != nil else {
            resetMetadata(for: workspace)
            workspaceProjectIDs.removeValue(forKey: workspace.id)
            return
        }
        guard let generation = workspaceGenerations[workspace.id],
              let expectedProjectID = workspaceProjectIDs[workspace.id] else {
            return
        }

        let workspaceID = workspace.id
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let summary: ProjectSummary = try await self.commandBus.call(
                    method: "project.summary",
                    params: EmptyParams()
                )
                self.applySummary(
                    summary,
                    toWorkspaceID: workspaceID,
                    expectedGeneration: generation,
                    expectedProjectID: expectedProjectID
                )
            } catch {
                Log.workspace.error(
                    "Failed to refresh metadata: \(error.localizedDescription, privacy: .public)"
                )
            }
        }
    }

    private func activateWorkspace(id: UUID?) {
        activeWorkspaceID = id

        if let workspace = workspace(withID: id) {
            ensurePlaceholderPaneIfNeeded(for: workspace)
            onActiveWorkspaceChanged?(workspace.layoutEngine)
            scheduleActivation(for: workspace)
        } else {
            scheduleBackendClose()
        }
    }

    private func scheduleActivation(for workspace: Workspace) {
        let generation = issueGeneration(for: workspace.id)
        desiredActivationTarget = PendingActivationTarget(
            workspaceID: workspace.id,
            path: workspace.projectPath,
            generation: generation
        )
        startActivationLoopIfNeeded()
    }

    private func scheduleBackendClose() {
        nextRequestGeneration += 1
        desiredActivationTarget = PendingActivationTarget(
            workspaceID: nil,
            path: nil,
            generation: nextRequestGeneration
        )
        startActivationLoopIfNeeded()
    }

    private func startActivationLoopIfNeeded() {
        guard activationTask == nil else { return }
        activationTask = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.runActivationLoop()
        }
    }

    private func runActivationLoop() async {
        defer { activationTask = nil }

        while let target = desiredActivationTarget {
            desiredActivationTarget = nil

            if let workspaceID = target.workspaceID,
               let workspace = workspace(withID: workspaceID) {
                if let path = target.path {
                    await openWorkspaceProject(path: path, for: workspace, generation: target.generation)
                } else {
                    await closeWorkspaceProject(for: workspace, generation: target.generation)
                }
            } else {
                await closeActiveBackendProject()
            }
        }
    }

    private func openWorkspaceProject(path: String, for workspace: Workspace, generation: UInt64) async {
        do {
            let response: ProjectOpenResponse = try await commandBus.call(
                method: "project.open",
                params: OpenProjectParams(path: path)
            )

            guard workspaceGenerations[workspace.id] == generation,
                  activeWorkspaceID == workspace.id,
                  let liveWorkspace = self.workspace(withID: workspace.id) else {
                return
            }

            liveWorkspace.projectPath = response.status.projectPath
            workspaceProjectIDs[workspace.id] = response.projectID

            if seedInitialTerminalIfNeeded(for: liveWorkspace) {
                onActiveWorkspaceChanged?(liveWorkspace.layoutEngine)
            }
            refreshMetadata(for: liveWorkspace)
        } catch {
            guard workspaceGenerations[workspace.id] == generation,
                  activeWorkspaceID == workspace.id,
                  let liveWorkspace = self.workspace(withID: workspace.id) else {
                return
            }

            workspaceProjectIDs.removeValue(forKey: workspace.id)
            resetMetadata(for: liveWorkspace)
            Log.workspace.error(
                "Failed to open project for workspace \(workspace.id, privacy: .public): \(error.localizedDescription, privacy: .public)"
            )
            postProjectOpenFailure(
                message: error.localizedDescription,
                workspaceID: workspace.id,
                generation: generation
            )
        }
    }

    private func closeWorkspaceProject(for workspace: Workspace, generation: UInt64) async {
        do {
            let _: OkResponse = try await commandBus.call(method: "project.close", params: EmptyParams())
        } catch {
            Log.workspace.error("Failed to close backend project: \(error.localizedDescription, privacy: .public)")
        }

        guard workspaceGenerations[workspace.id] == generation,
              activeWorkspaceID == workspace.id,
              let liveWorkspace = self.workspace(withID: workspace.id) else {
            return
        }

        workspaceProjectIDs.removeValue(forKey: workspace.id)
        resetMetadata(for: liveWorkspace)
        if ensurePlaceholderPaneIfNeeded(for: liveWorkspace) {
            onActiveWorkspaceChanged?(liveWorkspace.layoutEngine)
        }
    }

    private func closeActiveBackendProject() async {
        do {
            let _: OkResponse = try await commandBus.call(method: "project.close", params: EmptyParams())
        } catch {
            Log.workspace.error("Failed to close backend project: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func handleBridgeEvent(_ event: BridgeEvent) {
        guard let workspace = activeWorkspace else { return }
        switch event.name {
        case "project_opened", "task_updated", "cost_updated", "notification_created",
             "notification_cleared", "notification_updated":
            refreshMetadata(for: workspace)
        default:
            break
        }
    }

    private func applySummary(
        _ summary: ProjectSummary,
        toWorkspaceID workspaceID: UUID,
        expectedGeneration: UInt64,
        expectedProjectID: String
    ) {
        guard workspaceGenerations[workspaceID] == expectedGeneration,
              activeWorkspaceID == workspaceID,
              let workspace = workspace(withID: workspaceID) else {
            return
        }

        guard summary.projectID == expectedProjectID else {
            Log.workspace.debug(
                "Dropping stale summary for workspace \(workspaceID, privacy: .public); expected project \(expectedProjectID, privacy: .public), got \(summary.projectID, privacy: .public)"
            )
            scheduleActivation(for: workspace)
            return
        }

        workspace.gitBranch = summary.gitBranch
        workspace.activeTasks = summary.activeTasks
        workspace.activeAgents = summary.activeAgents
        workspace.costToday = summary.costToday
        workspace.unreadNotifications = summary.unreadNotifications
    }

    @discardableResult
    private func ensurePlaceholderPaneIfNeeded(for workspace: Workspace) -> Bool {
        guard let rootPaneID = ensureRootPaneID(for: workspace) else { return false }

        let paneIDs = workspace.layoutEngine.root?.allPaneIDs ?? []
        let descriptors = paneIDs.compactMap { workspace.layoutEngine.persistedPane(for: $0) }
        guard descriptors.isEmpty else { return false }

        workspace.layoutEngine.upsertPersistedPane(
            PersistedPane(
                paneID: rootPaneID,
                type: "welcome",
                workingDirectory: nil,
                sessionID: nil,
                taskID: nil,
                metadataJSON: nil
            )
        )
        return true
    }

    @discardableResult
    private func seedInitialTerminalIfNeeded(for workspace: Workspace) -> Bool {
        guard let projectPath = workspace.projectPath,
              let rootPaneID = ensureRootPaneID(for: workspace) else {
            return false
        }

        let paneIDs = workspace.layoutEngine.root?.allPaneIDs ?? []
        let descriptors = paneIDs.compactMap { workspace.layoutEngine.persistedPane(for: $0) }
        let hasRestorablePane = descriptors.contains { $0.type != "welcome" }
        guard !hasRestorablePane else { return false }

        workspace.layoutEngine.upsertPersistedPane(
            PersistedPane(
                paneID: rootPaneID,
                type: "terminal",
                workingDirectory: projectPath,
                sessionID: workspace.layoutEngine.persistedPane(for: rootPaneID)?.sessionID,
                taskID: nil,
                metadataJSON: nil
            )
        )
        return true
    }

    private func ensureRootPaneID(for workspace: Workspace) -> PaneID? {
        if let rootPaneID = workspace.layoutEngine.root?.allPaneIDs.first {
            return rootPaneID
        }

        let paneID = PaneID()
        workspace.layoutEngine.root = .leaf(paneID)
        workspace.layoutEngine.activePaneID = paneID
        return paneID
    }

    private func resetMetadata(for workspace: Workspace) {
        workspace.gitBranch = nil
        workspace.activeTasks = 0
        workspace.activeAgents = 0
        workspace.costToday = 0
        workspace.unreadNotifications = 0
    }

    private func postProjectOpenFailure(message: String, workspaceID: UUID, generation: UInt64) {
        let payload = ProjectOpenFailureEventPayload(
            workspaceID: workspaceID,
            generation: generation,
            message: message
        )
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        guard let data = try? encoder.encode(payload),
              let payloadJSON = String(data: data, encoding: .utf8) else {
            BridgeEventHub.shared.post(
                BridgeEvent(
                    name: "project_open_failed",
                    payloadJSON: #"{"message":"Project activation failed."}"#
                )
            )
            return
        }

        BridgeEventHub.shared.post(
            BridgeEvent(name: "project_open_failed", payloadJSON: payloadJSON)
        )
    }

    @discardableResult
    private func issueGeneration(for workspaceID: UUID) -> UInt64 {
        nextRequestGeneration += 1
        let generation = nextRequestGeneration
        workspaceGenerations[workspaceID] = generation
        workspaceProjectIDs.removeValue(forKey: workspaceID)
        return generation
    }

    private func invalidateRequestState(for workspaceID: UUID) {
        workspaceGenerations.removeValue(forKey: workspaceID)
        workspaceProjectIDs.removeValue(forKey: workspaceID)
        if desiredActivationTarget?.workspaceID == workspaceID {
            desiredActivationTarget = nil
        }
    }

    private func workspace(withID id: UUID?) -> Workspace? {
        guard let id else { return nil }
        return workspaces.first { $0.id == id }
    }
}

// MARK: - API Types

private struct EmptyParams: Encodable {}
private struct OpenProjectParams: Encodable { let path: String }
private struct ProjectOpenFailureEventPayload: Codable {
    let workspaceID: UUID
    let generation: UInt64
    let message: String
}

struct ProjectOpenResponse: Decodable {
    let projectID: String
    let status: ProjectStatusResponse
}

struct ProjectStatusResponse: Decodable {
    let projectID: String
    let projectName: String
    let projectPath: String
    let sessions: Int
    let tasks: Int
    let worktrees: Int
}

struct ProjectSummary: Decodable {
    let projectID: String
    let gitBranch: String?
    let activeTasks: Int
    let activeAgents: Int
    let costToday: Double
    let unreadNotifications: Int
}
