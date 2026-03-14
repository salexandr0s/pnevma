import Foundation
import Observation
import os

@Observable
@MainActor
final class CommandCenterStore {
    enum Filter: String, CaseIterable, Identifiable {
        case all
        case attention
        case active
        case idle
        case stuck
        case queued
        case review
        case failed

        var id: String { rawValue }

        var title: String {
            switch self {
            case .all: return "All"
            case .attention: return "Attention"
            case .active: return "Active"
            case .idle: return "Idle"
            case .stuck: return "Stuck"
            case .queued: return "Queued"
            case .review: return "Review"
            case .failed: return "Failed"
            }
        }
    }

    private(set) var workspaceSnapshots: [CommandCenterWorkspaceSnapshot] = []
    private(set) var isRefreshing = false
    private(set) var lastRefreshAt: Date?
    private(set) var lastErrorMessage: String?
    var filter: Filter = .all {
        didSet { coerceSelection() }
    }
    var searchQuery = "" {
        didSet { coerceSelection() }
    }
    var selectedRunID: String? {
        didSet {
            if selectedRunID == oldValue { return }
        }
    }

    @ObservationIgnored
    private let workspaceManager: WorkspaceManager
    @ObservationIgnored
    private let bridgeEventHub: BridgeEventHub
    @ObservationIgnored
    private var pollTask: Task<Void, Never>?
    @ObservationIgnored
    private var bridgeObserverID: UUID?
    @ObservationIgnored
    private var refreshInFlight = false
    @ObservationIgnored
    private var refreshQueued = false
    @ObservationIgnored
    private var isActive = false
    @ObservationIgnored
    var onPerformAction: ((CommandCenterAction, CommandCenterRunRecord) -> Void)?

    init(
        workspaceManager: WorkspaceManager,
        bridgeEventHub: BridgeEventHub = .shared
    ) {
        self.workspaceManager = workspaceManager
        self.bridgeEventHub = bridgeEventHub
        bridgeObserverID = bridgeEventHub.addObserver { [weak self] event in
            Task { @MainActor [weak self] in
                self?.handleBridgeEvent(event)
            }
        }
    }

    deinit {
        if let bridgeObserverID {
            bridgeEventHub.removeObserver(bridgeObserverID)
        }
        pollTask?.cancel()
    }

    func activate() {
        guard !isActive else { return }
        isActive = true
        queueRefresh()
        startPolling()
    }

    func deactivate() {
        isActive = false
        pollTask?.cancel()
        pollTask = nil
    }

    func refreshNow() {
        queueRefresh(force: true)
    }

    func performAction(_ action: CommandCenterAction, on run: CommandCenterFleetRun) {
        onPerformAction?(action, run)
    }

    var fleetSummary: CommandCenterFleetSummary {
        CommandCenterFleetSummary(
            workspaceCount: workspaceSnapshots.count,
            activeCount: workspaceSnapshots.reduce(0) { $0 + ($1.snapshot?.summary.activeCount ?? 0) },
            queuedCount: workspaceSnapshots.reduce(0) { $0 + ($1.snapshot?.summary.queuedCount ?? 0) },
            idleCount: workspaceSnapshots.reduce(0) { $0 + ($1.snapshot?.summary.idleCount ?? 0) },
            stuckCount: workspaceSnapshots.reduce(0) { $0 + ($1.snapshot?.summary.stuckCount ?? 0) },
            reviewNeededCount: workspaceSnapshots.reduce(0) { $0 + ($1.snapshot?.summary.reviewNeededCount ?? 0) },
            failedCount: workspaceSnapshots.reduce(0) { $0 + ($1.snapshot?.summary.failedCount ?? 0) },
            retryingCount: workspaceSnapshots.reduce(0) { $0 + ($1.snapshot?.summary.retryingCount ?? 0) },
            slotLimit: workspaceSnapshots.reduce(0) { $0 + ($1.snapshot?.summary.slotLimit ?? 0) },
            slotInUse: workspaceSnapshots.reduce(0) { $0 + ($1.snapshot?.summary.slotInUse ?? 0) },
            costTodayUsd: workspaceSnapshots.reduce(0) { $0 + ($1.snapshot?.summary.costTodayUsd ?? 0) }
        )
    }

    var visibleSections: [CommandCenterWorkspaceSection] {
        workspaceSnapshots.compactMap { snapshot in
            let runs = snapshot.runs.filter(matchesSearch).filter(matchesFilter)
            guard !runs.isEmpty || snapshot.errorMessage != nil else {
                return nil
            }
            return CommandCenterWorkspaceSection(
                id: snapshot.id,
                workspaceName: snapshot.workspaceName,
                workspacePath: snapshot.workspacePath,
                runs: runs,
                errorMessage: snapshot.errorMessage
            )
        }
    }

    var selectedRun: CommandCenterFleetRun? {
        visibleRuns.first { $0.id == selectedRunID }
    }

    var visibleRuns: [CommandCenterFleetRun] {
        visibleSections.flatMap { $0.runs }
    }

    private func startPolling() {
        pollTask?.cancel()
        pollTask = Task { [weak self] in
            while let self, !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                guard !Task.isCancelled else { return }
                self.queueRefresh()
            }
        }
    }

    private func handleBridgeEvent(_ event: BridgeEvent) {
        guard isActive else { return }
        switch event.name {
        case "task_updated", "session_spawned", "session_heartbeat", "session_exited",
             "notification_created", "notification_updated", "notification_cleared", "cost_updated",
             "project_opened", "project_open_failed":
            queueRefresh()
        default:
            break
        }
    }

    private func queueRefresh(force: Bool = false) {
        guard isActive || force else { return }
        if refreshInFlight {
            refreshQueued = true
            return
        }
        refreshInFlight = true
        Task { [weak self] in
            await self?.refreshSnapshots()
        }
    }

    private func refreshSnapshots() async {
        isRefreshing = true

        let workspaces = eligibleWorkspaces()
        var refreshed: [CommandCenterWorkspaceSnapshot] = []
        var errors: [String] = []

        for workspace in workspaces {
            let displayPath = workspaceDisplayPath(for: workspace)
            do {
                let snapshot = try await workspaceManager.commandCenterSnapshot(for: workspace.id)
                refreshed.append(
                    CommandCenterWorkspaceSnapshot(
                        id: workspace.id,
                        workspaceName: workspace.name,
                        workspacePath: snapshot.projectPath,
                        snapshot: snapshot,
                        errorMessage: nil
                    )
                )
            } catch let error as WorkspaceRuntimeReadinessError {
                switch error {
                case .timedOut:
                    refreshed.append(
                        CommandCenterWorkspaceSnapshot(
                            id: workspace.id,
                            workspaceName: workspace.name,
                            workspacePath: displayPath,
                            snapshot: nil,
                            errorMessage: "Workspace runtime is still opening."
                        )
                    )
                default:
                    let message = error.localizedDescription
                    refreshed.append(
                        CommandCenterWorkspaceSnapshot(
                            id: workspace.id,
                            workspaceName: workspace.name,
                            workspacePath: displayPath,
                            snapshot: nil,
                            errorMessage: message
                        )
                    )
                    errors.append("\(workspace.name): \(message)")
                }
            } catch {
                let message = error.localizedDescription
                refreshed.append(
                    CommandCenterWorkspaceSnapshot(
                        id: workspace.id,
                        workspaceName: workspace.name,
                        workspacePath: displayPath,
                        snapshot: nil,
                        errorMessage: message
                    )
                )
                errors.append("\(workspace.name): \(message)")
                Log.workspace.error(
                    "Command center refresh failed for \(workspace.name, privacy: .public): \(message, privacy: .public)"
                )
            }
        }

        workspaceSnapshots = refreshed.sorted {
            $0.workspaceName.localizedCaseInsensitiveCompare($1.workspaceName) == .orderedAscending
        }
        lastRefreshAt = Date()
        lastErrorMessage = errors.first
        coerceSelection()
        isRefreshing = false
        refreshInFlight = false

        if refreshQueued {
            refreshQueued = false
            queueRefresh(force: true)
        }
    }

    private func eligibleWorkspaces() -> [Workspace] {
        workspaceManager.workspaces.filter {
            $0.supportsBackendProject
        }
    }

    private func workspaceDisplayPath(for workspace: Workspace) -> String {
        if let projectPath = workspace.projectPath, !projectPath.isEmpty {
            return projectPath
        }
        if let displayPath = workspace.displayPath, !displayPath.isEmpty {
            return displayPath
        }
        return workspace.name
    }

    private func matchesFilter(_ run: CommandCenterFleetRun) -> Bool {
        switch filter {
        case .all:
            return true
        case .attention:
            return run.run.attentionReason != nil
        case .active:
            return ["running", "idle", "stuck"].contains(run.run.state)
        case .idle:
            return run.run.state == "idle"
        case .stuck:
            return run.run.state == "stuck"
        case .queued:
            return run.run.state == "queued"
        case .review:
            return run.run.state == "review_needed"
        case .failed:
            return run.run.state == "failed"
        }
    }

    private func matchesSearch(_ run: CommandCenterFleetRun) -> Bool {
        let query = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return true }
        let needle = query.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
        let haystacks: [String] = [
            run.workspaceName,
            run.workspacePath,
            run.run.taskTitle,
            run.run.taskStatus,
            run.run.sessionName,
            run.run.provider,
            run.run.model,
            run.run.branch,
        ].compactMap { $0 }
        return haystacks.contains {
            $0.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
                .contains(needle)
        }
    }

    private func coerceSelection() {
        if let selectedRunID,
           visibleRuns.contains(where: { $0.id == selectedRunID }) {
            return
        }
        selectedRunID = visibleRuns.first?.id
    }
}
