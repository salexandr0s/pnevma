import Cocoa
import CryptoKit
import Observation
import os

/// Manages workspace lifecycle — creation, switching, persistence, and teardown.
/// Only the selected workspace is bound to the backend at any time.
@Observable
@MainActor
final class WorkspaceManager {

    private(set) var workspaces: [Workspace] = []
    private(set) var activeWorkspaceID: UUID?

    var activeWorkspace: Workspace? {
        guard let id = activeWorkspaceID else { return nil }
        return workspaces.first { $0.id == id }
    }

    /// Called when the active workspace changes, providing the new workspace's layout engine.
    @ObservationIgnored
    var onActiveWorkspaceChanged: ((PaneLayoutEngine) -> Void)?

    /// Called when unread or terminal notification counts change on the active workspace.
    @ObservationIgnored
    var onNotificationCountChanged: ((Int) -> Void)?

    @ObservationIgnored
    private let commandBus: any CommandCalling
    @ObservationIgnored
    private let activationHub: ActiveWorkspaceActivationHub
    @ObservationIgnored
    private let projectPathResolver: any WorkspaceProjectPathResolving
    @ObservationIgnored
    private var bridgeObserverID: UUID?

    private struct PendingActivationTarget {
        let workspaceID: UUID?
        let generation: UInt64
    }

    @ObservationIgnored
    private var nextRequestGeneration: UInt64 = 0
    @ObservationIgnored
    private var workspaceGenerations: [UUID: UInt64] = [:]
    @ObservationIgnored
    private var workspaceProjectIDs: [UUID: String] = [:]
    @ObservationIgnored
    private var desiredActivationTarget: PendingActivationTarget?
    @ObservationIgnored
    private var activationTask: Task<Void, Never>?

    init(
        bridge: PnevmaBridge,
        commandBus: any CommandCalling,
        activationHub: ActiveWorkspaceActivationHub = .shared,
        projectPathResolver: any WorkspaceProjectPathResolving = DefaultWorkspaceProjectPathResolver()
    ) {
        _ = bridge
        self.commandBus = commandBus
        self.activationHub = activationHub
        self.projectPathResolver = projectPathResolver
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

    func shutdown() {
        projectPathResolver.cleanupAll(workspaces: workspaces)
    }

    func prepareForShutdown() async {
        if activeWorkspace?.kind == .project {
            do {
                let _: OkResponse = try await commandBus.call(method: "project.close", params: EmptyParams())
            } catch {
                Log.workspace.error("Failed to close backend project during shutdown: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    @discardableResult
    func createWorkspace(
        name: String,
        kind: WorkspaceKind,
        location: WorkspaceLocation = .local,
        projectPath: String? = nil,
        terminalMode: WorkspaceTerminalMode,
        remoteTarget: WorkspaceRemoteTarget? = nil
    ) -> Workspace {
        let workspace = Workspace(
            name: name,
            projectPath: projectPath,
            kind: kind,
            location: location,
            terminalMode: terminalMode,
            remoteTarget: remoteTarget
        )
        ensurePlaceholderPaneIfNeeded(for: workspace)
        insertWorkspace(workspace)
        activateWorkspace(id: workspace.id)
        Log.workspace.info("Created workspace '\(name)' id=\(workspace.id)")
        return workspace
    }

    @discardableResult
    func createWorkspace(name: String, projectPath: String? = nil) -> Workspace {
        createWorkspace(
            name: name,
            kind: projectPath == nil ? .terminal : .project,
            location: .local,
            projectPath: projectPath,
            terminalMode: projectPath == nil ? .nonPersistent : .persistent
        )
    }

    @discardableResult
    func ensureTerminalWorkspace(name: String = "Terminal") -> Workspace {
        if let existing = workspaces.first(where: { $0.isPermanent }) {
            return existing
        }
        return createWorkspace(
            name: name,
            kind: .terminal,
            terminalMode: .nonPersistent
        )
    }

    @discardableResult
    func createLocalProjectWorkspace(
        name: String,
        projectPath: String,
        terminalMode: WorkspaceTerminalMode
    ) -> Workspace {
        let workspace = createWorkspace(
            name: name,
            kind: .project,
            location: .local,
            projectPath: projectPath,
            terminalMode: terminalMode
        )
        resetMetadata(for: workspace)
        _ = workspace.ensureActiveTabHasDisplayableRootPane()
        Log.workspace.info(
            "Created local project workspace \(workspace.id, privacy: .public) for \(projectPath, privacy: .public)"
        )
        return workspace
    }

    @discardableResult
    func createRemoteWorkspace(
        name: String,
        remoteTarget: WorkspaceRemoteTarget,
        terminalMode: WorkspaceTerminalMode
    ) -> Workspace {
        let workspace = createWorkspace(
            name: name,
            kind: .project,
            location: .remote,
            terminalMode: terminalMode,
            remoteTarget: remoteTarget
        )
        resetMetadata(for: workspace)
        _ = workspace.ensureActiveTabHasDisplayableRootPane()
        Log.workspace.info(
            "Created remote workspace \(workspace.id, privacy: .public) for \(remoteTarget.remotePath, privacy: .public)"
        )
        return workspace
    }

    func switchToWorkspace(_ id: UUID) {
        guard workspaces.contains(where: { $0.id == id }) else { return }
        guard activeWorkspaceID != id else { return }
        activateWorkspace(id: id)
        Log.workspace.info("Switched to workspace \(id)")
    }

    func renameWorkspace(_ id: UUID, to newName: String) {
        guard let workspace = workspace(withID: id) else { return }
        workspace.name = newName
        Log.workspace.info("Renamed workspace \(id) to '\(newName)'")
    }

    func togglePinWorkspace(_ id: UUID) {
        guard let workspace = workspace(withID: id) else { return }
        workspace.isPinned.toggle()
        Log.workspace.info("Toggled pin for workspace \(id), isPinned=\(workspace.isPinned)")
    }

    func setWorkspaceColor(_ id: UUID, hex: String?) {
        guard let workspace = workspace(withID: id) else { return }
        workspace.customColor = hex
        Log.workspace.info("Set color for workspace \(id) to \(hex ?? "none")")
    }

    func closeWorkspace(_ id: UUID) {
        guard let index = workspaces.firstIndex(where: { $0.id == id }) else { return }
        guard !workspaces[index].isPermanent else { return }
        let closingWasActive = activeWorkspaceID == id
        let workspace = workspaces.remove(at: index)
        invalidateRequestState(for: id)
        Log.workspace.info("Closed workspace '\(workspace.name)'")

        if workspaces.isEmpty {
            _ = ensureTerminalWorkspace()
        }

        if closingWasActive {
            let replacementIndex = min(index, workspaces.count - 1)
            activateWorkspace(id: workspaces[replacementIndex].id)
            Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: 250_000_000)
                self?.projectPathResolver.cleanup(workspace: workspace)
            }
        } else {
            projectPathResolver.cleanup(workspace: workspace)
        }
    }

    func restore(
        snapshots: [Workspace.Snapshot],
        activeWorkspaceID restoredActiveWorkspaceID: UUID?
    ) {
        workspaces = snapshots.map(Workspace.init(snapshot:))
        normalizeWorkspaceCollection()
        for workspace in workspaces {
            ensurePlaceholderPaneIfNeeded(for: workspace)
        }

        if workspaces.isEmpty {
            _ = ensureTerminalWorkspace()
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
        guard workspace.supportsBackendProject else {
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
            scheduleActivation(for: workspace)
            onActiveWorkspaceChanged?(workspace.layoutEngine)
        } else {
            scheduleBackendClose()
        }
    }

    private func scheduleActivation(for workspace: Workspace) {
        workspace.activationFailureMessage = nil
        let generation = issueGeneration(for: workspace.id)
        desiredActivationTarget = PendingActivationTarget(
            workspaceID: workspace.id,
            generation: generation
        )
        if workspace.supportsProjectTools {
            activationHub.update(
                .opening(workspaceID: workspace.id, generation: generation)
            )
        } else {
            activationHub.update(.closed(workspaceID: workspace.id))
        }
        startActivationLoopIfNeeded()
    }

    private func scheduleBackendClose() {
        nextRequestGeneration += 1
        desiredActivationTarget = PendingActivationTarget(
            workspaceID: nil,
            generation: nextRequestGeneration
        )
        activationHub.update(.closed(workspaceID: nil))
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
                if workspace.supportsProjectTools {
                    do {
                        guard let path = try await projectPathResolver.resolveProjectPath(for: workspace) else {
                            throw WorkspaceProjectTransportError.projectPathUnavailable
                        }
                        guard workspaceGenerations[workspace.id] == target.generation,
                              activeWorkspaceID == workspace.id else {
                            continue
                        }
                        workspace.projectPath = path
                        await openWorkspaceProject(path: path, for: workspace, generation: target.generation)
                    } catch {
                        await handleWorkspaceProjectOpenFailure(
                            for: workspace,
                            generation: target.generation,
                            error: error
                        )
                    }
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
            let response: ProjectOpenResponse = try await openOrTrust(
                path: path,
                activationToken: Self.clientActivationToken(
                    workspaceID: workspace.id,
                    generation: generation
                )
            )

            guard workspaceGenerations[workspace.id] == generation,
                  activeWorkspaceID == workspace.id,
                  let liveWorkspace = self.workspace(withID: workspace.id) else {
                return
            }

            liveWorkspace.projectPath = response.status.projectPath
            liveWorkspace.activationFailureMessage = nil
            workspaceProjectIDs[workspace.id] = response.projectID
            activationHub.update(
                .open(workspaceID: workspace.id, projectID: response.projectID)
            )

            if seedInitialTerminalIfNeeded(for: liveWorkspace) {
                onActiveWorkspaceChanged?(liveWorkspace.layoutEngine)
            }
            refreshMetadata(for: liveWorkspace)
        } catch {
            await handleWorkspaceProjectOpenFailure(for: workspace, generation: generation, error: error)
        }
    }

    private func handleWorkspaceProjectOpenFailure(
        for workspace: Workspace,
        generation: UInt64,
        error: Error
    ) async {
        guard workspaceGenerations[workspace.id] == generation,
              activeWorkspaceID == workspace.id,
              let liveWorkspace = self.workspace(withID: workspace.id) else {
            return
        }

        workspaceProjectIDs.removeValue(forKey: workspace.id)
        resetMetadata(for: liveWorkspace)
        liveWorkspace.activationFailureMessage = error.localizedDescription
        activationHub.update(
            .failed(
                workspaceID: workspace.id,
                generation: generation,
                message: error.localizedDescription
            )
        )
        Log.workspace.error(
            "Failed to open project for workspace \(workspace.id, privacy: .public): \(error.localizedDescription, privacy: .public)"
        )
        postProjectOpenFailure(
            message: error.localizedDescription,
            workspaceID: workspace.id,
            generation: generation
        )
    }

    /// Try to open a project; if trust is required, auto-trust and retry once.
    private func openOrTrust(path: String, activationToken: String) async throws -> ProjectOpenResponse {
        do {
            return try await commandBus.call(
                method: "project.open",
                params: OpenProjectParams(
                    path: path,
                    clientActivationToken: activationToken
                )
            )
        } catch let error as PnevmaError {
            guard case .backendError(_, let message) = error,
                  message == "workspace_not_trusted" || message == "workspace_config_changed" else {
                throw error
            }
            Log.workspace.info("Auto-trusting workspace at \(path, privacy: .public)")
            let _: OkResponse = try await commandBus.call(
                method: "project.trust",
                params: OpenProjectParams(
                    path: path,
                    clientActivationToken: nil
                )
            )
            return try await commandBus.call(
                method: "project.open",
                params: OpenProjectParams(
                    path: path,
                    clientActivationToken: activationToken
                )
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
        liveWorkspace.activationFailureMessage = nil
        activationHub.update(.closed(workspaceID: workspace.id))
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
        activationHub.update(.closed(workspaceID: activeWorkspaceID))
    }

    private func handleBridgeEvent(_ event: BridgeEvent) {
        guard let workspace = activeWorkspace else { return }
        switch event.name {
        case "project_opened":
            handleProjectOpened(event, for: workspace)
        case "task_updated", "cost_updated", "notification_created",
             "notification_cleared", "notification_updated":
            refreshMetadata(for: workspace)
        default:
            break
        }
    }

    private func handleProjectOpened(_ event: BridgeEvent, for workspace: Workspace) {
        guard let payload = decodeProjectOpenedPayload(from: event.payloadJSON),
              projectOpenedPayloadAppliesToActiveWorkspace(payload, workspace: workspace) else {
            return
        }

        workspace.projectPath = payload.projectPath
        workspaceProjectIDs[workspace.id] = payload.projectID

        if case .opening(let workspaceID, let generation) = activationHub.currentState,
           workspaceID == workspace.id,
           workspaceGenerations[workspace.id] == generation {
            activationHub.update(
                .open(workspaceID: workspace.id, projectID: payload.projectID)
            )
            if seedInitialTerminalIfNeeded(for: workspace) {
                onActiveWorkspaceChanged?(workspace.layoutEngine)
            }
        }

        refreshMetadata(for: workspace)
    }

    private func decodeProjectOpenedPayload(from payloadJSON: String) -> ProjectOpenedEventPayload? {
        guard let data = payloadJSON.data(using: .utf8) else { return nil }
        return try? PnevmaJSON.decoder().decode(ProjectOpenedEventPayload.self, from: data)
    }

    private func projectOpenedPayloadAppliesToActiveWorkspace(
        _ payload: ProjectOpenedEventPayload,
        workspace: Workspace
    ) -> Bool {
        guard case .opening(let workspaceID, let generation) = activationHub.currentState,
              workspaceID == workspace.id,
              workspaceGenerations[workspace.id] == generation,
              workspace.supportsBackendProject,
              let workspacePath = workspace.projectPath,
              payload.clientActivationToken == Self.clientActivationToken(
                  workspaceID: workspace.id,
                  generation: generation
              ) else {
            return false
        }
        return Self.normalizedProjectPath(workspacePath) == Self.normalizedProjectPath(payload.projectPath)
    }

    static func clientActivationToken(workspaceID: UUID, generation: UInt64) -> String {
        "\(workspaceID.uuidString):\(generation)"
    }

    private static func normalizedProjectPath(_ path: String) -> String {
        URL(fileURLWithPath: path)
            .resolvingSymlinksInPath()
            .standardizedFileURL
            .path
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
        workspace.gitDirty = summary.gitDirty ?? false
        onNotificationCountChanged?(workspace.unreadNotifications + workspace.terminalNotificationCount)
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
                type: "terminal",
                workingDirectory: workspace.defaultWorkingDirectory,
                sessionID: nil,
                taskID: nil,
                metadataJSON: workspace.defaultTerminalMetadata().encodedJSON()
            )
        )
        return true
    }

    @discardableResult
    private func seedInitialTerminalIfNeeded(for workspace: Workspace) -> Bool {
        guard let rootPaneID = ensureRootPaneID(for: workspace) else {
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
                workingDirectory: workspace.defaultWorkingDirectory,
                sessionID: workspace.layoutEngine.persistedPane(for: rootPaneID)?.sessionID,
                taskID: nil,
                metadataJSON: workspace.defaultTerminalMetadata().encodedJSON()
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
        workspace.gitDirty = false
    }

    private func insertWorkspace(_ workspace: Workspace) {
        if workspace.isPermanent {
            workspaces.removeAll { $0.isPermanent }
            workspaces.insert(workspace, at: 0)
            return
        }

        ensureTerminalWorkspace()
        workspaces.append(workspace)
    }

    private func normalizeWorkspaceCollection() {
        var sawTerminal = false
        var normalized: [Workspace] = []
        for workspace in workspaces {
            if workspace.isPermanent {
                guard !sawTerminal else { continue }
                sawTerminal = true
                normalized.insert(workspace, at: 0)
            } else {
                normalized.append(workspace)
            }
        }
        workspaces = normalized
        if !sawTerminal {
            let terminal = Workspace(
                name: "Terminal",
                kind: .terminal,
                location: .local,
                terminalMode: .nonPersistent
            )
            ensurePlaceholderPaneIfNeeded(for: terminal)
            workspaces.insert(terminal, at: 0)
        }
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

// MARK: - Project Path Resolution

protocol WorkspaceProjectPathResolving {
    func resolveProjectPath(for workspace: Workspace) async throws -> String?
    func cleanup(workspace: Workspace)
    func cleanupAll(workspaces: [Workspace])
}

private enum WorkspaceProjectTransportError: LocalizedError {
    case missingRemoteTarget
    case missingSSHFS
    case projectPathUnavailable
    case remotePathResolutionFailed(String)
    case mountFailed(String)

    var errorDescription: String? {
        switch self {
        case .missingRemoteTarget:
            return "The remote workspace is missing its SSH target configuration."
        case .missingSSHFS:
            return "Remote native tools require sshfs. Install sshfs/macFUSE locally to open this remote project."
        case .projectPathUnavailable:
            return "The workspace project path could not be resolved."
        case .remotePathResolutionFailed(let message):
            return "Failed to resolve the remote project path: \(message)"
        case .mountFailed(let message):
            return "Failed to mount the remote project: \(message)"
        }
    }
}

enum WorkspaceProjectTransportSupport {
    static func hasRemoteNativeToolingSupport(fileManager: FileManager = .default) -> Bool {
        findExecutable(named: "sshfs", fileManager: fileManager) != nil
    }

    static func findExecutable(
        named name: String,
        fileManager: FileManager = .default
    ) -> String? {
        let candidates = [
            "/opt/homebrew/bin/\(name)",
            "/usr/local/bin/\(name)",
            "/usr/bin/\(name)",
            "/bin/\(name)",
            "/usr/sbin/\(name)",
            "/sbin/\(name)",
        ]
        return candidates.first(where: { fileManager.isExecutableFile(atPath: $0) })
    }
}

private final class DefaultWorkspaceProjectPathResolver: WorkspaceProjectPathResolving {
    private let remoteMountManager = RemoteWorkspaceMountManager()

    func resolveProjectPath(for workspace: Workspace) async throws -> String? {
        guard workspace.kind == .project else { return nil }

        switch workspace.location {
        case .local:
            return workspace.projectPath
        case .remote:
            guard let remoteTarget = workspace.remoteTarget else {
                throw WorkspaceProjectTransportError.missingRemoteTarget
            }
            return try await remoteMountManager.ensureMounted(
                remoteTarget: remoteTarget,
                preferredMountPath: workspace.projectPath
            )
        }
    }

    func cleanup(workspace: Workspace) {
        guard workspace.location == .remote else { return }
        remoteMountManager.unmount(mountPath: workspace.projectPath)
    }

    func cleanupAll(workspaces: [Workspace]) {
        let mountPaths = workspaces
            .filter { $0.location == .remote }
            .compactMap(\.projectPath)
        remoteMountManager.unmountAll(mountPaths: mountPaths)
    }
}

private final class RemoteWorkspaceMountManager {
    private let fileManager = FileManager.default

    func ensureMounted(
        remoteTarget: WorkspaceRemoteTarget,
        preferredMountPath: String?
    ) async throws -> String {
        guard let sshfsPath = findExecutable(named: "sshfs") else {
            throw WorkspaceProjectTransportError.missingSSHFS
        }

        let mountPath = preferredMountPath ?? defaultMountPath(for: remoteTarget)
        if isMounted(at: mountPath) {
            return mountPath
        }

        let resolvedRemotePath = try await resolveRemotePath(for: remoteTarget)
        try prepareMountDirectory(at: mountPath)

        let source = "\(remoteTarget.user)@\(remoteTarget.host):\(resolvedRemotePath)"
        let result = try await runCommand(
            executable: sshfsPath,
            arguments: sshfsArguments(
                source: source,
                mountPath: mountPath,
                remoteTarget: remoteTarget
            )
        )
        guard result.status == 0, isMounted(at: mountPath) else {
            let message = result.stderr.isEmpty ? result.stdout : result.stderr
            throw WorkspaceProjectTransportError.mountFailed(message.trimmingCharacters(in: .whitespacesAndNewlines))
        }

        Log.workspace.info("Mounted remote workspace at \(mountPath, privacy: .public)")
        return mountPath
    }

    func unmount(mountPath: String?) {
        guard let mountPath, isMounted(at: mountPath) else { return }

        if let umountPath = findExecutable(named: "umount") {
            let result = Self.runCommandSync(executable: umountPath, arguments: [mountPath])
            if result.status == 0 || !isMounted(at: mountPath) {
                cleanupMountDirectory(at: mountPath)
                return
            }
        }

        if let diskutilPath = findExecutable(named: "diskutil") {
            _ = Self.runCommandSync(executable: diskutilPath, arguments: ["unmount", "force", mountPath])
        }
        cleanupMountDirectory(at: mountPath)
    }

    func unmountAll(mountPaths: [String]) {
        for mountPath in Set(mountPaths) {
            unmount(mountPath: mountPath)
        }
    }

    private func resolveRemotePath(for remoteTarget: WorkspaceRemoteTarget) async throws -> String {
        let destination = "\(remoteTarget.user)@\(remoteTarget.host)"
        let remoteCommand = "cd -- \(remoteTarget.shellDirectoryExpression) && pwd -P"
        let result = try await runCommand(
            executable: "/usr/bin/ssh",
            arguments: sshArguments(
                remoteTarget: remoteTarget,
                destination: destination,
                remoteCommand: remoteCommand
            )
        )

        let output = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        guard result.status == 0, !output.isEmpty else {
            let message = result.stderr.isEmpty ? result.stdout : result.stderr
            throw WorkspaceProjectTransportError.remotePathResolutionFailed(
                message.trimmingCharacters(in: .whitespacesAndNewlines)
            )
        }
        return output
    }

    private func defaultMountPath(for remoteTarget: WorkspaceRemoteTarget) -> String {
        let baseURL = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first?
            .appendingPathComponent("Pnevma", isDirectory: true)
            .appendingPathComponent("RemoteWorkspaces", isDirectory: true)
            ?? URL(fileURLWithPath: NSHomeDirectory())
                .appendingPathComponent("Library/Application Support/Pnevma/RemoteWorkspaces", isDirectory: true)

        let fingerprintInput = "\(remoteTarget.sshProfileID)|\(remoteTarget.remotePath)"
        let digest = SHA256.hash(data: Data(fingerprintInput.utf8))
        let digestString = digest.map { String(format: "%02x", $0) }.joined()
        return baseURL
            .appendingPathComponent(remoteTarget.sshProfileID, isDirectory: true)
            .appendingPathComponent(digestString, isDirectory: true)
            .path
    }

    private func prepareMountDirectory(at path: String) throws {
        let mountURL = URL(fileURLWithPath: path)
        if fileManager.fileExists(atPath: path), !isMounted(at: path) {
            try? fileManager.removeItem(at: mountURL)
        }
        try fileManager.createDirectory(
            at: mountURL,
            withIntermediateDirectories: true,
            attributes: nil
        )
    }

    private func cleanupMountDirectory(at path: String) {
        guard !isMounted(at: path) else { return }
        try? fileManager.removeItem(at: URL(fileURLWithPath: path))
    }

    private func isMounted(at path: String) -> Bool {
        guard let mountPath = findExecutable(named: "mount") else { return false }
        let result = Self.runCommandSync(executable: mountPath, arguments: [])
        guard result.status == 0 else { return false }
        return result.stdout
            .split(separator: "\n")
            .contains { $0.contains(" on \(path) ") }
    }

    private func sshfsArguments(
        source: String,
        mountPath: String,
        remoteTarget: WorkspaceRemoteTarget
    ) -> [String] {
        var args = [
            source,
            mountPath,
            "-p", String(remoteTarget.port),
            "-o", "BatchMode=yes",
            "-o", "ConnectTimeout=10",
            "-o", "reconnect",
            "-o", "ServerAliveInterval=15",
            "-o", "ServerAliveCountMax=3",
            "-o", "defer_permissions",
            "-o", "auto_cache",
        ]
        if let identityFile = remoteTarget.identityFile, !identityFile.isEmpty {
            args.append(contentsOf: ["-o", "IdentityFile=\(identityFile)"])
        }
        if let proxyJump = remoteTarget.proxyJump, !proxyJump.isEmpty {
            args.append(contentsOf: ["-o", "ProxyJump=\(proxyJump)"])
        }
        return args
    }

    private func sshArguments(
        remoteTarget: WorkspaceRemoteTarget,
        destination: String,
        remoteCommand: String
    ) -> [String] {
        var args = [
            "-p", String(remoteTarget.port),
            "-o", "BatchMode=yes",
            "-o", "ConnectTimeout=10",
        ]
        if let identityFile = remoteTarget.identityFile, !identityFile.isEmpty {
            args.append(contentsOf: ["-i", identityFile])
        }
        if let proxyJump = remoteTarget.proxyJump, !proxyJump.isEmpty {
            args.append(contentsOf: ["-J", proxyJump])
        }
        args.append(destination)
        args.append(remoteCommand)
        return args
    }

    private func findExecutable(named name: String) -> String? {
        WorkspaceProjectTransportSupport.findExecutable(
            named: name,
            fileManager: fileManager
        )
    }

    private func runCommand(
        executable: String,
        arguments: [String]
    ) async throws -> ShellCommandResult {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(returning: Self.runCommandSync(executable: executable, arguments: arguments))
            }
        }
    }

    private static func runCommandSync(
        executable: String,
        arguments: [String]
    ) -> ShellCommandResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return ShellCommandResult(status: -1, stdout: "", stderr: error.localizedDescription)
        }

        let stdout = String(data: stdoutPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let stderr = String(data: stderrPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        return ShellCommandResult(status: process.terminationStatus, stdout: stdout, stderr: stderr)
    }
}

private struct ShellCommandResult {
    let status: Int32
    let stdout: String
    let stderr: String
}

// MARK: - API Types

private struct EmptyParams: Encodable {}
private struct OpenProjectParams: Encodable {
    let path: String
    let clientActivationToken: String?
}
private struct ProjectOpenedEventPayload: Decodable {
    let projectID: String
    let projectPath: String
    let clientActivationToken: String?
}

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
    let gitDirty: Bool?
}
