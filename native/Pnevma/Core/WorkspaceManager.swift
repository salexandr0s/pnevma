import Cocoa
import CryptoKit
import Observation
import os

/// Manages workspace lifecycle — creation, switching, persistence, and teardown.
/// Project workspaces keep their own backend runtime while selection only controls UI focus.
@Observable
@MainActor
final class WorkspaceManager {

    typealias RuntimeFactory = @MainActor (UUID) -> WorkspaceRuntime
    typealias ProjectInitializationPrompt = @MainActor (_ workspaceName: String, _ path: String) async -> Bool

    private(set) var workspaces: [Workspace] = []
    private(set) var activeWorkspaceID: UUID?

    var activeWorkspace: Workspace? {
        guard let id = activeWorkspaceID else { return nil }
        return workspaces.first { $0.id == id }
    }

    var activeRuntime: WorkspaceRuntime? {
        guard let id = activeWorkspaceID else { return nil }
        return workspaceRuntimes[id]
    }

    var activeCommandBus: (any CommandCalling)? {
        activeRuntime?.commandBus
    }

    // MARK: - Sidebar Grouping

    @MainActor
    struct ProjectGroup: Identifiable {
        let name: String
        var workspaces: [Workspace]
        nonisolated var id: String { name }

        var attention: [Workspace] { workspaces.filter { $0.operationalState == .attention } }
        var active: [Workspace] { workspaces.filter { $0.operationalState == .active } }
        var review: [Workspace] { workspaces.filter { $0.operationalState == .review } }
        var idle: [Workspace] { workspaces.filter { $0.operationalState == .idle } }
        var count: Int { workspaces.count }
    }

    var terminalWorkspaces: [Workspace] {
        workspaces.filter(\.isPermanent)
    }

    var pinnedWorkspaces: [Workspace] {
        workspaces.filter { !$0.isPermanent && $0.isPinned }
    }

    var projectGroups: [ProjectGroup] {
        let unpinned = workspaces.filter { !$0.isPermanent && !$0.isPinned }
        var groups: [String: [Workspace]] = [:]
        for ws in unpinned {
            let key = ws.projectRoot ?? "Ungrouped"
            groups[key, default: []].append(ws)
        }
        return groups
            .map { ProjectGroup(name: $0.key, workspaces: $0.value) }
            .sorted { lhs, rhs in
                // Groups with attention items sort first
                let lhsHasAttention = lhs.attention.isEmpty ? 1 : 0
                let rhsHasAttention = rhs.attention.isEmpty ? 1 : 0
                if lhsHasAttention != rhsHasAttention { return lhsHasAttention < rhsHasAttention }
                return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
            }
    }

    @ObservationIgnored
    var onActiveWorkspaceChanged: ((PaneLayoutEngine) -> Void)?

    @ObservationIgnored
    var onNotificationCountChanged: ((Int) -> Void)?

    @ObservationIgnored
    private let activationHub: ActiveWorkspaceActivationHub
    @ObservationIgnored
    private let projectPathResolver: any WorkspaceProjectPathResolving
    @ObservationIgnored
    private let runtimeFactory: RuntimeFactory
    @ObservationIgnored
    private let projectInitializationPrompt: ProjectInitializationPrompt
    @ObservationIgnored
    private var bridgeObserverID: UUID?
    @ObservationIgnored
    private var nextRequestGeneration: UInt64 = 0
    @ObservationIgnored
    private var workspaceGenerations: [UUID: UInt64] = [:]
    @ObservationIgnored
    private var workspaceProjectIDs: [UUID: String] = [:]
    @ObservationIgnored
    private var workspaceRuntimes: [UUID: WorkspaceRuntime] = [:]
    @ObservationIgnored
    private var runtimeOpenTasks: [UUID: Task<Void, Never>] = [:]

    init(
        activationHub: ActiveWorkspaceActivationHub = .shared,
        projectPathResolver: any WorkspaceProjectPathResolving = DefaultWorkspaceProjectPathResolver(),
        runtimeFactory: @escaping RuntimeFactory = { WorkspaceRuntime(workspaceID: $0) },
        projectInitializationPrompt: @escaping ProjectInitializationPrompt = WorkspaceManager.defaultProjectInitializationPrompt
    ) {
        self.activationHub = activationHub
        self.projectPathResolver = projectPathResolver
        self.runtimeFactory = runtimeFactory
        self.projectInitializationPrompt = projectInitializationPrompt
        bridgeObserverID = BridgeEventHub.shared.addObserver { [weak self] event in
            Task { @MainActor [weak self] in
                self?.handleBridgeEvent(event)
            }
        }
    }

    convenience init(
        bridge: PnevmaBridge,
        commandBus: any CommandCalling,
        activationHub: ActiveWorkspaceActivationHub = .shared,
        projectPathResolver: any WorkspaceProjectPathResolving = DefaultWorkspaceProjectPathResolver(),
        projectInitializationPrompt: @escaping ProjectInitializationPrompt = WorkspaceManager.defaultProjectInitializationPrompt
    ) {
        // Shared-bus convenience path for tests or intentionally single-runtime
        // scenarios only. Production app wiring should prefer the primary
        // initializer so each workspace runtime gets its own bridge/command bus.
        _ = bridge
        self.init(
            activationHub: activationHub,
            projectPathResolver: projectPathResolver,
            runtimeFactory: { workspaceID in
                WorkspaceRuntime(workspaceID: workspaceID, commandBus: commandBus)
            },
            projectInitializationPrompt: projectInitializationPrompt
        )
    }

    deinit {
        runtimeOpenTasks.values.forEach { $0.cancel() }
        if let bridgeObserverID {
            BridgeEventHub.shared.removeObserver(bridgeObserverID)
        }
        let runtimes = Array(workspaceRuntimes.values)
        Task { @MainActor in
            runtimes.forEach { $0.destroy() }
        }
    }

    func shutdown() {
        runtimeOpenTasks.values.forEach { $0.cancel() }
        runtimeOpenTasks.removeAll()
        let runtimes = Array(workspaceRuntimes.values)
        workspaceRuntimes.removeAll()
        runtimes.forEach { $0.destroy() }
        projectPathResolver.cleanupAll(workspaces: workspaces)
    }

    func prepareForShutdown() async {
        runtimeOpenTasks.values.forEach { $0.cancel() }
        runtimeOpenTasks.removeAll()
        let runtimes = Array(workspaceRuntimes.values)
        for runtime in runtimes {
            await runtime.closeProject(mode: .appShutdown)
        }
    }

    @discardableResult
    func createWorkspace(
        name: String,
        kind: WorkspaceKind,
        location: WorkspaceLocation = .local,
        projectPath: String? = nil,
        checkoutPath: String? = nil,
        terminalMode: WorkspaceTerminalMode,
        localBindingRole: WorkspaceLocalBindingRole? = nil,
        remoteTarget: WorkspaceRemoteTarget? = nil
    ) -> Workspace {
        let workspace = Workspace(
            name: name,
            projectPath: projectPath,
            checkoutPath: checkoutPath,
            kind: kind,
            location: location,
            terminalMode: terminalMode,
            localBindingRole: localBindingRole,
            remoteTarget: remoteTarget
        )
        ensurePlaceholderPaneIfNeeded(for: workspace)
        insertWorkspace(workspace)
        if workspace.supportsBackendProject {
            _ = ensureRuntime(for: workspace)
        }
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
            checkoutPath: projectPath,
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
        checkoutPath: String? = nil,
        terminalMode: WorkspaceTerminalMode,
        launchSource: WorkspaceLaunchSource? = nil,
        initialWorkingDirectory: String? = nil,
        initialTaskID: String? = nil
    ) -> Workspace {
        let standardizedProjectPath = Self.standardizeLocalProjectPath(projectPath) ?? projectPath
        let standardizedCheckoutPath =
            Self.standardizeLocalProjectPath(checkoutPath) ?? standardizedProjectPath
        let bindingRole: WorkspaceLocalBindingRole =
            standardizedCheckoutPath == standardizedProjectPath ? .base : .worktree

        if let existing = existingLocalWorkspace(
            projectPath: standardizedProjectPath,
            checkoutPath: standardizedCheckoutPath
        ) {
            existing.launchSource = launchSource ?? existing.launchSource
            existing.localBindingRole = bindingRole
            activateWorkspace(id: existing.id)
            return existing
        }

        let workspace = createWorkspace(
            name: name,
            kind: .project,
            location: .local,
            projectPath: standardizedProjectPath,
            checkoutPath: standardizedCheckoutPath,
            terminalMode: terminalMode,
            localBindingRole: bindingRole
        )
        resetMetadata(for: workspace)
        workspace.launchSource = launchSource
        _ = workspace.ensureActiveTabHasDisplayableRootPane(
            seed: TerminalPaneSeed(
                workingDirectory: initialWorkingDirectory ?? workspace.defaultWorkingDirectory,
                sessionID: nil,
                taskID: initialTaskID,
                metadataJSON: workspace.defaultTerminalMetadata().encodedJSON()
            )
        )
        Log.workspace.info(
            "Created local project workspace \(workspace.id, privacy: .public) for \(standardizedProjectPath, privacy: .public) @ \(standardizedCheckoutPath, privacy: .public)"
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
        teardownRuntime(for: id)
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
            if workspace.supportsBackendProject {
                _ = ensureRuntime(for: workspace)
                bootstrapRuntime(for: workspace)
            }
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

    func runtime(for workspaceID: UUID) -> WorkspaceRuntime? {
        workspaceRuntimes[workspaceID]
    }

    func commandCenterSnapshot(
        for workspaceID: UUID,
        timeoutNanoseconds: UInt64 = 250_000_000
    ) async throws -> CommandCenterSnapshot {
        let readiness = try await ensureRuntimeReady(
            workspaceID,
            timeoutNanoseconds: timeoutNanoseconds,
            activateIfNeeded: false
        )
        guard let runtime = readiness.runtime else {
            throw WorkspaceActionError.runtimeNotReady
        }
        return try await runtime.fetchCommandCenterSnapshot()
    }

    func ensureWorkspaceReady(
        _ workspaceID: UUID,
        timeoutNanoseconds: UInt64 = 5_000_000_000
    ) async throws -> (workspace: Workspace, runtime: WorkspaceRuntime?) {
        try await ensureRuntimeReady(
            workspaceID,
            timeoutNanoseconds: timeoutNanoseconds,
            activateIfNeeded: true
        )
    }

    private func ensureRuntimeReady(
        _ workspaceID: UUID,
        timeoutNanoseconds: UInt64,
        activateIfNeeded: Bool
    ) async throws -> (workspace: Workspace, runtime: WorkspaceRuntime?) {
        guard let workspace = workspace(withID: workspaceID) else {
            throw WorkspaceRuntimeReadinessError.workspaceMissing
        }

        if activateIfNeeded, activeWorkspaceID != workspaceID {
            activateWorkspace(id: workspaceID)
        }

        guard workspace.supportsBackendProject else {
            return (workspace, nil)
        }

        bootstrapRuntime(for: workspace)
        guard let runtime = workspaceRuntimes[workspaceID] else {
            throw WorkspaceRuntimeReadinessError.runtimeUnavailable(workspace.name)
        }

        let deadline = DispatchTime.now().uptimeNanoseconds + timeoutNanoseconds
        while DispatchTime.now().uptimeNanoseconds < deadline {
            switch runtime.state {
            case .open:
                if activateIfNeeded {
                    publishActivationState(for: workspace)
                }
                return (workspace, runtime)
            case .failed(_, let message):
                throw WorkspaceRuntimeReadinessError.activationFailed(workspace.name, message)
            case .closed:
                bootstrapRuntime(for: workspace)
            case .opening:
                break
            }
            try? await Task.sleep(nanoseconds: 75_000_000)
        }

        throw WorkspaceRuntimeReadinessError.timedOut(workspace.name)
    }

    func refreshMetadata(for workspace: Workspace) {
        guard workspace.supportsBackendProject else {
            resetMetadata(for: workspace)
            workspaceProjectIDs.removeValue(forKey: workspace.id)
            return
        }
        guard let generation = workspaceGenerations[workspace.id],
              let expectedProjectID = workspaceProjectIDs[workspace.id],
              let runtime = workspaceRuntimes[workspace.id] else {
            return
        }

        let workspaceID = workspace.id
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let summary: ProjectSummary = try await runtime.commandBus.call(
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
                    "Failed to refresh metadata for workspace \(workspace.name, privacy: .public): \(error.localizedDescription, privacy: .public)"
                )
            }
        }
    }

    private func activateWorkspace(id: UUID?) {
        activeWorkspaceID = id

        if let workspace = workspace(withID: id) {
            ensurePlaceholderPaneIfNeeded(for: workspace)
            if workspace.supportsProjectTools {
                _ = ensureRuntime(for: workspace)
                bootstrapRuntime(for: workspace)
            }
            publishActivationState(for: workspace)
            onActiveWorkspaceChanged?(workspace.layoutEngine)
            onNotificationCountChanged?(workspace.unreadNotifications + workspace.terminalNotificationCount)
        } else {
            activationHub.update(.closed(workspaceID: nil))
            onNotificationCountChanged?(0)
        }
    }

    private func bootstrapRuntime(for workspace: Workspace, forceReopen: Bool = false) {
        guard workspace.supportsBackendProject else { return }
        let runtime = ensureRuntime(for: workspace)

        if !forceReopen {
            switch runtime.state {
            case .open, .opening:
                return
            case .closed, .failed:
                break
            }
        }

        runtimeOpenTasks[workspace.id]?.cancel()
        let generation = issueGeneration(for: workspace.id)
        runtime.markOpening(
            generation: generation,
            projectPath: workspace.projectPath,
            checkoutPath: workspace.checkoutPath ?? workspace.projectPath
        )
        if activeWorkspaceID == workspace.id {
            activationHub.update(.opening(workspaceID: workspace.id, generation: generation))
        }

        runtimeOpenTasks[workspace.id] = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.runtimeOpenTasks[workspace.id] = nil }
            await self.openWorkspaceRuntime(workspaceID: workspace.id, generation: generation)
        }
    }

    private func ensureRuntime(for workspace: Workspace) -> WorkspaceRuntime {
        if let runtime = workspaceRuntimes[workspace.id] {
            return runtime
        }
        let runtime = runtimeFactory(workspace.id)
        workspaceRuntimes[workspace.id] = runtime
        return runtime
    }

    private func teardownRuntime(for workspaceID: UUID) {
        runtimeOpenTasks[workspaceID]?.cancel()
        runtimeOpenTasks.removeValue(forKey: workspaceID)
        guard let runtime = workspaceRuntimes.removeValue(forKey: workspaceID) else { return }
        Task { @MainActor in
            await runtime.closeProject(mode: .workspaceClose)
            runtime.destroy()
        }
    }

    private func openWorkspaceRuntime(workspaceID: UUID, generation: UInt64) async {
        guard let workspace = workspace(withID: workspaceID),
              workspace.supportsBackendProject,
              let runtime = workspaceRuntimes[workspaceID] else {
            return
        }

        do {
            guard let path = try await projectPathResolver.resolveProjectPath(for: workspace) else {
                throw WorkspaceProjectTransportError.projectPathUnavailable
            }
            let checkoutPath = workspace.location == .local
                ? (Self.standardizeLocalProjectPath(workspace.checkoutPath) ?? path)
                : path
            guard workspaceGenerations[workspace.id] == generation else { return }
            workspace.projectPath = path
            workspace.checkoutPath = checkoutPath
            runtime.markOpening(
                generation: generation,
                projectPath: path,
                checkoutPath: checkoutPath
            )

            let response = try await openOrTrust(
                path: path,
                checkoutPath: checkoutPath,
                workspaceName: workspace.name,
                activationToken: Self.clientActivationToken(
                    workspaceID: workspace.id,
                    generation: generation
                ),
                commandBus: runtime.commandBus
            )

            guard workspaceGenerations[workspace.id] == generation,
                  let liveWorkspace = self.workspace(withID: workspace.id) else {
                return
            }

            liveWorkspace.projectPath = response.status.projectPath
            liveWorkspace.checkoutPath = response.status.checkoutPath
            if liveWorkspace.location == .local && liveWorkspace.kind == .project {
                liveWorkspace.localBindingRole =
                    response.status.checkoutPath == response.status.projectPath ? .base : .worktree
            }
            liveWorkspace.activationFailureMessage = nil
            workspaceProjectIDs[workspace.id] = response.projectID
            runtime.markOpen(
                projectID: response.projectID,
                projectPath: response.status.projectPath,
                checkoutPath: response.status.checkoutPath
            )

            if activeWorkspaceID == workspace.id {
                activationHub.update(
                    .open(workspaceID: workspace.id, projectID: response.projectID)
                )
            }

            if seedInitialTerminalIfNeeded(for: liveWorkspace), activeWorkspaceID == workspace.id {
                onActiveWorkspaceChanged?(liveWorkspace.layoutEngine)
            }
            refreshMetadata(for: liveWorkspace)
        } catch {
            await handleWorkspaceProjectOpenFailure(
                for: workspace,
                generation: generation,
                error: error
            )
        }
    }

    private func handleWorkspaceProjectOpenFailure(
        for workspace: Workspace,
        generation: UInt64,
        error: Error
    ) async {
        guard workspaceGenerations[workspace.id] == generation,
              let liveWorkspace = self.workspace(withID: workspace.id) else {
            return
        }

        workspaceProjectIDs.removeValue(forKey: workspace.id)
        workspaceRuntimes[workspace.id]?.markFailed(
            generation: generation,
            message: error.localizedDescription
        )
        resetMetadata(for: liveWorkspace)
        liveWorkspace.activationFailureMessage = error.localizedDescription
        if activeWorkspaceID == workspace.id {
            activationHub.update(
                .failed(
                    workspaceID: workspace.id,
                    generation: generation,
                    message: error.localizedDescription
                )
            )
        }
        Log.workspace.error(
            "Failed to open project for workspace \(workspace.id, privacy: .public): \(error.localizedDescription, privacy: .public)"
        )
        postProjectOpenFailure(
            message: error.localizedDescription,
            workspaceID: workspace.id,
            generation: generation
        )
    }

    private func openOrTrust(
        path: String,
        checkoutPath: String,
        workspaceName: String,
        activationToken: String,
        commandBus: any CommandCalling,
        allowInitialize: Bool = true,
        allowTrust: Bool = true
    ) async throws -> ProjectOpenResponse {
        do {
            return try await commandBus.call(
                method: "project.open",
                params: OpenProjectParams(
                    path: path,
                    checkoutPath: checkoutPath == path ? nil : checkoutPath,
                    clientActivationToken: activationToken
                )
            )
        } catch let error as PnevmaError {
            guard case .backendError(_, let message) = error else {
                throw error
            }

            if allowInitialize, message == "workspace_not_initialized" {
                try await initializeProjectScaffold(
                    path: path,
                    workspaceName: workspaceName,
                    commandBus: commandBus
                )
                return try await openOrTrust(
                    path: path,
                    checkoutPath: checkoutPath,
                    workspaceName: workspaceName,
                    activationToken: activationToken,
                    commandBus: commandBus,
                    allowInitialize: false,
                    allowTrust: allowTrust
                )
            }

            guard allowTrust,
                  message == "workspace_not_trusted" || message == "workspace_config_changed" else {
                throw error
            }
            Log.workspace.info("Auto-trusting workspace at \(path, privacy: .public)")
            let _: OkResponse = try await commandBus.call(
                method: "project.trust",
                params: OpenProjectParams(
                    path: path,
                    checkoutPath: nil,
                    clientActivationToken: nil
                )
            )
            return try await openOrTrust(
                path: path,
                checkoutPath: checkoutPath,
                workspaceName: workspaceName,
                activationToken: activationToken,
                commandBus: commandBus,
                allowInitialize: allowInitialize,
                allowTrust: false
            )
        }
    }

    private func initializeProjectScaffold(
        path: String,
        workspaceName: String,
        commandBus: any CommandCalling
    ) async throws {
        let shouldInitialize = await projectInitializationPrompt(workspaceName, path)
        guard shouldInitialize else {
            throw WorkspaceProjectInitializationError.canceled(workspaceName)
        }

        let projectName = workspaceName.trimmingCharacters(in: .whitespacesAndNewlines)
        let _: InitializeProjectScaffoldResult = try await commandBus.call(
            method: "project.initialize_scaffold",
            params: InitializeProjectScaffoldParams(
                path: path,
                projectName: projectName.isEmpty ? nil : projectName,
                projectBrief: nil,
                defaultProvider: nil
            )
        )
    }

    private static func defaultProjectInitializationPrompt(
        workspaceName: String,
        path: String
    ) async -> Bool {
        let displayName = workspaceName.trimmingCharacters(in: .whitespacesAndNewlines)
        let subject = displayName.isEmpty ? URL(fileURLWithPath: path).lastPathComponent : displayName
        let alert = NSAlert()
        alert.messageText = "Initialize Project Scaffold?"
        alert.informativeText = "\(subject) is missing pnevma.toml and the .pnevma support directory. Initialize them now to open this workspace?"
        alert.addButton(withTitle: "Initialize")
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }

    private func handleBridgeEvent(_ event: BridgeEvent) {
        switch event.name {
        case "project_opened":
            handleProjectOpened(event)
        case "task_updated", "cost_updated", "notification_created",
             "notification_cleared", "notification_updated":
            for workspace in workspaces where workspace.supportsBackendProject {
                refreshMetadata(for: workspace)
            }
        default:
            break
        }
    }

    private func handleProjectOpened(_ event: BridgeEvent) {
        guard let payload = decodeProjectOpenedPayload(from: event.payloadJSON),
              let (workspaceID, generation) = Self.parseClientActivationToken(payload.clientActivationToken),
              workspaceGenerations[workspaceID] == generation,
              let workspace = workspace(withID: workspaceID),
              let runtime = workspaceRuntimes[workspaceID] else {
            return
        }

        let expectedProjectPath = workspace.projectPath?.trimmingCharacters(in: .whitespacesAndNewlines)
        let expectedCheckoutPath =
            (workspace.checkoutPath ?? workspace.projectPath)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
        if let expectedProjectPath,
           !expectedProjectPath.isEmpty,
           payload.projectPath != expectedProjectPath {
            Log.workspace.debug(
                "Ignoring mismatched project_opened for workspace \(workspace.id, privacy: .public); expected root \(expectedProjectPath, privacy: .public), got \(payload.projectPath, privacy: .public)"
            )
            return
        }
        if let expectedCheckoutPath,
           !expectedCheckoutPath.isEmpty,
           payload.checkoutPath != expectedCheckoutPath {
            Log.workspace.debug(
                "Ignoring mismatched project_opened for workspace \(workspace.id, privacy: .public); expected checkout \(expectedCheckoutPath, privacy: .public), got \(payload.checkoutPath, privacy: .public)"
            )
            return
        }

        workspace.projectPath = payload.projectPath
        workspace.checkoutPath = payload.checkoutPath
        if workspace.location == .local && workspace.kind == .project {
            workspace.localBindingRole =
                payload.checkoutPath == payload.projectPath ? .base : .worktree
        }
        workspaceProjectIDs[workspace.id] = payload.projectID
        runtime.markOpen(
            projectID: payload.projectID,
            projectPath: payload.projectPath,
            checkoutPath: payload.checkoutPath
        )

        if activeWorkspaceID == workspace.id {
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

    private func publishActivationState(for workspace: Workspace) {
        guard activeWorkspaceID == workspace.id else { return }
        guard workspace.supportsProjectTools else {
            activationHub.update(.closed(workspaceID: workspace.id))
            return
        }
        guard let runtime = workspaceRuntimes[workspace.id] else {
            activationHub.update(.closed(workspaceID: workspace.id))
            return
        }

        switch runtime.state {
        case .closed:
            activationHub.update(.closed(workspaceID: workspace.id))
        case .opening(let generation):
            activationHub.update(.opening(workspaceID: workspace.id, generation: generation))
        case .open(let projectID):
            activationHub.update(.open(workspaceID: workspace.id, projectID: projectID))
        case .failed(let generation, let message):
            activationHub.update(
                .failed(workspaceID: workspace.id, generation: generation, message: message)
            )
        }
    }

    static func clientActivationToken(workspaceID: UUID, generation: UInt64) -> String {
        "\(workspaceID.uuidString):\(generation)"
    }

    private static func parseClientActivationToken(_ token: String?) -> (UUID, UInt64)? {
        guard let token else { return nil }
        let parts = token.split(separator: ":", maxSplits: 1).map(String.init)
        guard parts.count == 2,
              let workspaceID = UUID(uuidString: parts[0]),
              let generation = UInt64(parts[1]) else {
            return nil
        }
        return (workspaceID, generation)
    }

    private func applySummary(
        _ summary: ProjectSummary,
        toWorkspaceID workspaceID: UUID,
        expectedGeneration: UInt64,
        expectedProjectID: String
    ) {
        guard workspaceGenerations[workspaceID] == expectedGeneration,
              let workspace = workspace(withID: workspaceID) else {
            return
        }

        guard summary.projectID == expectedProjectID else {
            Log.workspace.debug(
                "Dropping stale summary for workspace \(workspaceID, privacy: .public); expected project \(expectedProjectID, privacy: .public), got \(summary.projectID, privacy: .public)"
            )
            bootstrapRuntime(for: workspace, forceReopen: true)
            return
        }

        workspace.gitBranch = summary.gitBranch
        workspace.activeTasks = summary.activeTasks
        workspace.activeAgents = summary.activeAgents
        workspace.costToday = summary.costToday
        workspace.unreadNotifications = summary.unreadNotifications
        workspace.gitDirty = summary.gitDirty ?? false
        workspace.diffInsertions = summary.diffInsertions
        workspace.diffDeletions = summary.diffDeletions
        workspace.linkedPRNumber = summary.linkedPrNumber
        workspace.linkedPRURL = summary.linkedPrUrl
        workspace.ciStatus = summary.ciStatus
        workspace.attentionReason = summary.attentionReason
        if activeWorkspaceID == workspaceID {
            onNotificationCountChanged?(workspace.unreadNotifications + workspace.terminalNotificationCount)
        }
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

    private func existingLocalWorkspace(projectPath: String, checkoutPath: String) -> Workspace? {
        workspaces.first { workspace in
            guard workspace.kind == .project, workspace.location == .local else { return false }
            let existingProjectPath = Self.standardizeLocalProjectPath(workspace.projectPath)
            let existingCheckoutPath =
                Self.standardizeLocalProjectPath(workspace.checkoutPath) ?? existingProjectPath
            return existingProjectPath == projectPath && existingCheckoutPath == checkoutPath
        }
    }

    fileprivate static func standardizeLocalProjectPath(_ path: String?) -> String? {
        guard let path, !path.isEmpty else { return nil }
        let expanded = NSString(string: path).expandingTildeInPath
        return NSString(string: expanded).standardizingPath
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
    }

    private func workspace(withID id: UUID?) -> Workspace? {
        guard let id else { return nil }
        return workspaces.first { $0.id == id }
    }
}

enum WorkspaceRuntimeReadinessError: LocalizedError {
    case workspaceMissing
    case runtimeUnavailable(String)
    case activationFailed(String, String)
    case timedOut(String)

    var errorDescription: String? {
        switch self {
        case .workspaceMissing:
            return "The selected workspace is no longer available."
        case .runtimeUnavailable(let workspaceName):
            return "The backend runtime for \(workspaceName) is unavailable."
        case .activationFailed(_, let message):
            return message
        case .timedOut(let workspaceName):
            return "Timed out waiting for \(workspaceName) to become ready."
        }
    }
}

// MARK: - Project Path Resolution

enum WorkspaceActionError: LocalizedError {
    case workspaceUnavailable
    case runtimeFailed(String)
    case runtimeNotReady

    var errorDescription: String? {
        switch self {
        case .workspaceUnavailable:
            return "The target workspace is unavailable."
        case .runtimeFailed(let message):
            return message
        case .runtimeNotReady:
            return "The target workspace is still opening. Please try again."
        }
    }
}

private enum WorkspaceProjectInitializationError: LocalizedError {
    case canceled(String)

    var errorDescription: String? {
        switch self {
        case .canceled(let workspaceName):
            if workspaceName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return "Project initialization was canceled."
            }
            return "Project initialization for \(workspaceName) was canceled."
        }
    }
}

@MainActor
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

@MainActor
private final class DefaultWorkspaceProjectPathResolver: WorkspaceProjectPathResolving {
    private let remoteMountManager = RemoteWorkspaceMountManager()

    func resolveProjectPath(for workspace: Workspace) async throws -> String? {
        guard workspace.kind == .project else { return nil }

        switch workspace.location {
        case .local:
            return Self.standardizeLocalProjectPath(workspace.projectPath)
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

    private static func standardizeLocalProjectPath(_ path: String?) -> String? {
        guard let path, !path.isEmpty else { return nil }
        let expanded = NSString(string: path).expandingTildeInPath
        return NSString(string: expanded).standardizingPath
    }

    func cleanupAll(workspaces: [Workspace]) {
        let mountPaths = workspaces
            .filter { $0.location == .remote }
            .compactMap(\.projectPath)
        remoteMountManager.unmountAll(mountPaths: mountPaths)
    }
}

@MainActor
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
        let result = await runCommand(
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
        let result = await runCommand(
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

    private nonisolated func runCommand(
        executable: String,
        arguments: [String]
    ) async -> ShellCommandResult {
        Self.runCommandSync(executable: executable, arguments: arguments)
    }

    private nonisolated static func runCommandSync(
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
    let checkoutPath: String?
    let clientActivationToken: String?
}

private struct InitializeProjectScaffoldParams: Encodable {
    let path: String
    let projectName: String?
    let projectBrief: String?
    let defaultProvider: String?
}
private struct ProjectOpenedEventPayload: Decodable {
    let projectID: String
    let projectPath: String
    let checkoutPath: String
    let clientActivationToken: String?
}

private struct ProjectOpenFailureEventPayload: Codable {
    let workspaceID: UUID
    let generation: UInt64
    let message: String
}

struct InitializeProjectScaffoldResult: Decodable {
    let rootPath: String
    let createdPaths: [String]
    let alreadyInitialized: Bool
}

struct ProjectOpenResponse: Decodable {
    let projectID: String
    let status: ProjectStatusResponse
}

struct ProjectStatusResponse: Decodable {
    let projectID: String
    let projectName: String
    let projectPath: String
    let checkoutPath: String
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
    let diffInsertions: Int?
    let diffDeletions: Int?
    let linkedPrNumber: UInt64?
    let linkedPrUrl: String?
    let ciStatus: String?
    let attentionReason: String?
}
