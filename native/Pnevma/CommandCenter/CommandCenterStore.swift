import Foundation
import Observation
import os

@Observable
@MainActor
final class CommandCenterStore {
    enum Filter: String, CaseIterable, Identifiable, Equatable {
        case all
        case attention
        case active
        case queued
        case review
        case failed
        case idle

        var id: String { rawValue }

        var title: String {
            switch self {
            case .all: return "All"
            case .attention: return "Attention"
            case .active: return "Active"
            case .queued: return "Queued"
            case .review: return "Review"
            case .failed: return "Failed"
            case .idle: return "Idle"
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
    var selectedWorkspaceID: UUID? {
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

    func performPrimaryAction(on run: CommandCenterFleetRun) {
        guard let action = run.primaryAction else { return }
        performAction(action, on: run)
    }

    func selectWorkspace(_ workspaceID: UUID?) {
        selectedWorkspaceID = workspaceID
    }

    func clearFilters() {
        searchQuery = ""
        filter = .all
        selectedWorkspaceID = nil
    }

    func clearSearchOrFilters() {
        let trimmedQuery = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedQuery.isEmpty {
            searchQuery = ""
            return
        }

        if hasActiveConstraints {
            clearFilters()
        }
    }

    func focusAttentionQueue() {
        filter = .attention
        selectedRunID = visibleRuns.first?.id
    }

    func selectNextRun() {
        moveSelection(by: 1)
    }

    func selectPreviousRun() {
        moveSelection(by: -1)
    }

    func selectFirstRun() {
        selectedRunID = visibleRuns.first?.id
    }

    func selectLastRun() {
        selectedRunID = visibleRuns.last?.id
    }

    func performSelectedAction(_ action: CommandCenterAction) {
        guard let run = selectedRun,
              run.availableActionEnums.contains(action) else {
            return
        }
        performAction(action, on: run)
    }

    func focusIncident(_ incident: CommandCenterIncident) {
        let incidentWorkspaceIDs = Set(incident.workspaceIDs)
        if incidentWorkspaceIDs.count == 1 {
            selectedWorkspaceID = incidentWorkspaceIDs.first
        } else if incidentWorkspaceIDs.count > 1 {
            selectedWorkspaceID = nil
        } else if let selectedWorkspaceID,
                  !incidentWorkspaceIDs.contains(selectedWorkspaceID) {
            self.selectedWorkspaceID = nil
        }

        switch incident.kind {
        case .failed:
            filter = .failed
        case .stuck, .attention, .retrying:
            filter = .attention
        case .review:
            filter = .review
        case .idle:
            filter = .idle
        case .workspaceError:
            filter = .all
        }

        if let firstRun = visibleRuns.first(where: { run in
            incident.workspaceIDs.isEmpty || incident.workspaceIDs.contains(run.workspaceID)
        }) {
            selectedRunID = firstRun.id
        }
    }

    var fleetSummary: CommandCenterFleetSummary {
        CommandCenterFleetSummary(
            workspaceCount: scopedWorkspaceSnapshots.count,
            activeCount: scopedWorkspaceSnapshots.reduce(0) { $0 + ($1.snapshot?.summary.activeCount ?? 0) },
            queuedCount: scopedWorkspaceSnapshots.reduce(0) { $0 + ($1.snapshot?.summary.queuedCount ?? 0) },
            idleCount: scopedWorkspaceSnapshots.reduce(0) { $0 + ($1.snapshot?.summary.idleCount ?? 0) },
            stuckCount: scopedWorkspaceSnapshots.reduce(0) { $0 + ($1.snapshot?.summary.stuckCount ?? 0) },
            reviewNeededCount: scopedWorkspaceSnapshots.reduce(0) { $0 + ($1.snapshot?.summary.reviewNeededCount ?? 0) },
            failedCount: scopedWorkspaceSnapshots.reduce(0) { $0 + ($1.snapshot?.summary.failedCount ?? 0) },
            retryingCount: scopedWorkspaceSnapshots.reduce(0) { $0 + ($1.snapshot?.summary.retryingCount ?? 0) },
            slotLimit: scopedWorkspaceSnapshots.reduce(0) { $0 + ($1.snapshot?.summary.slotLimit ?? 0) },
            slotInUse: scopedWorkspaceSnapshots.reduce(0) { $0 + ($1.snapshot?.summary.slotInUse ?? 0) },
            costTodayUsd: scopedWorkspaceSnapshots.reduce(0) { $0 + ($1.snapshot?.summary.costTodayUsd ?? 0) }
        )
    }

    var fleetHealth: CommandCenterFleetHealth {
        if scopedWorkspaceSnapshots.contains(where: { $0.errorMessage != nil }) || fleetSummary.failedCount > 0 || fleetSummary.stuckCount > 0 {
            return .interventionNeeded
        }
        if fleetSummary.reviewNeededCount > 0 || fleetSummary.retryingCount > 0 || attentionRunCount > 0 {
            return .degraded
        }
        return .healthy
    }

    var healthSummaryText: String {
        switch fleetHealth {
        case .healthy:
            if fleetSummary.activeCount > 0 || fleetSummary.queuedCount > 0 {
                return "\(fleetSummary.activeCount) active • \(fleetSummary.queuedCount) queued • no intervention needed"
            }
            return "No active incidents across \(max(fleetSummary.workspaceCount, 0)) workspace\(fleetSummary.workspaceCount == 1 ? "" : "s")"
        case .degraded:
            return "\(attentionRunCount) attention item\(attentionRunCount == 1 ? "" : "s") across \(fleetSummary.workspaceCount) workspace\(fleetSummary.workspaceCount == 1 ? "" : "s")"
        case .interventionNeeded:
            return "Immediate follow-up required for \(attentionRunCount) item\(attentionRunCount == 1 ? "" : "s")"
        }
    }

    var scopeTitle: String {
        guard let selectedWorkspaceID,
              let cluster = workspaceClusters.first(where: { $0.id == selectedWorkspaceID }) else {
            return "All workspaces"
        }
        return cluster.workspaceName
    }

    var hasActiveConstraints: Bool {
        filter != .all || selectedWorkspaceID != nil || !searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var isStale: Bool {
        guard let lastRefreshAt else { return false }
        return Date().timeIntervalSince(lastRefreshAt) > 6
    }

    var attentionRunCount: Int {
        scopedRuns.filter(\.needsAttention).count + scopedWorkspaceSnapshots.filter { $0.errorMessage != nil }.count
    }

    var boardSections: [CommandCenterBoardSection] {
        let grouped = Dictionary(grouping: visibleRuns, by: \.boardSectionKind)
        return CommandCenterBoardSectionKind.allCases.compactMap { kind in
            guard let runs = grouped[kind], !runs.isEmpty else { return nil }
            return CommandCenterBoardSection(kind: kind, runs: sortedRuns(runs, for: kind))
        }
    }

    var attentionItems: [CommandCenterIncident] {
        var items: [CommandCenterIncident] = []

        let erroredSnapshots = scopedWorkspaceSnapshots.filter { $0.errorMessage != nil }
        if !erroredSnapshots.isEmpty {
            items.append(
                CommandCenterIncident(
                    kind: .workspaceError,
                    title: erroredSnapshots.count == 1 ? "Workspace unavailable" : "Workspaces unavailable",
                    summary: erroredSnapshots.first?.errorMessage ?? "Workspace refresh failed.",
                    count: erroredSnapshots.count,
                    severity: .urgent,
                    oldestAt: lastRefreshAt,
                    workspaceIDs: erroredSnapshots.map(\.id)
                )
            )
        }

        let definitions: [(CommandCenterIncidentKind, String, CommandCenterSeverity, (CommandCenterFleetRun) -> Bool)] = [
            (.failed, "Failed runs", .urgent, { $0.normalizedState == "failed" }),
            (.stuck, "Stuck runs", .urgent, { $0.normalizedState == "stuck" }),
            (.review, "Review needed", .watch, { $0.normalizedState == "review_needed" }),
            (.retrying, "Retrying", .watch, { $0.normalizedState == "retrying" }),
            (.idle, "Idle runs", .watch, { $0.normalizedState == "idle" && $0.run.attentionReason != nil }),
        ]

        for definition in definitions {
            let matching = scopedRuns.filter(definition.3)
            guard !matching.isEmpty else { continue }
            let oldest = matching.min(by: { $0.run.lastActivityAt < $1.run.lastActivityAt })?.run.lastActivityAt
            let summary = matching.first?.attentionSummary ?? definition.1
            items.append(
                CommandCenterIncident(
                    kind: definition.0,
                    title: definition.1,
                    summary: summary,
                    count: matching.count,
                    severity: definition.2,
                    oldestAt: oldest,
                    workspaceIDs: Array(Set(matching.map(\.workspaceID)))
                )
            )
        }

        let genericAttention = scopedRuns.filter { $0.run.attentionReason != nil && !$0.needsAttention }
        if !genericAttention.isEmpty {
            items.append(
                CommandCenterIncident(
                    kind: .attention,
                    title: "Attention queue",
                    summary: genericAttention.first?.attentionSummary ?? "Attention requested",
                    count: genericAttention.count,
                    severity: .watch,
                    oldestAt: genericAttention.min(by: { $0.run.lastActivityAt < $1.run.lastActivityAt })?.run.lastActivityAt,
                    workspaceIDs: Array(Set(genericAttention.map(\.workspaceID)))
                )
            )
        }

        return items.sorted { lhs, rhs in
            if lhs.severity != rhs.severity {
                return lhs.severity > rhs.severity
            }
            if lhs.count != rhs.count {
                return lhs.count > rhs.count
            }
            return (lhs.oldestAt ?? .distantFuture) < (rhs.oldestAt ?? .distantFuture)
        }
    }

    var workspaceClusters: [CommandCenterWorkspaceCluster] {
        workspaceSnapshots.map { snapshot in
            let runs = snapshot.runs
            let attentionCount = runs.filter(\.needsAttention).count
            let activeCount = runs.filter { $0.normalizedState == "running" }.count
            let queuedCount = runs.filter { $0.normalizedState == "queued" }.count
            let idleCount = runs.filter { $0.normalizedState == "idle" }.count
            return CommandCenterWorkspaceCluster(
                id: snapshot.id,
                workspaceName: snapshot.workspaceName,
                workspacePath: snapshot.workspacePath,
                activeCount: activeCount,
                queuedCount: queuedCount,
                idleCount: idleCount,
                attentionCount: attentionCount,
                errorMessage: snapshot.errorMessage
            )
        }
        .sorted { lhs, rhs in
            if lhs.severity != rhs.severity {
                return lhs.severity > rhs.severity
            }
            return lhs.workspaceName.localizedCaseInsensitiveCompare(rhs.workspaceName) == .orderedAscending
        }
    }

    var visibleSections: [CommandCenterWorkspaceSection] {
        scopedWorkspaceSnapshots.compactMap { snapshot in
            let runs = snapshot.runs
                .filter(matchesSearch)
                .filter(matchesFilter)
                .sorted(by: compareRuns)
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
        searchScopedRuns.filter(matchesFilter).sorted(by: compareRuns)
    }

    func filterCount(for filter: Filter) -> Int {
        searchScopedRuns.filter { matchesFilter(filter, run: $0) }.count
    }

    private var scopedWorkspaceSnapshots: [CommandCenterWorkspaceSnapshot] {
        guard let selectedWorkspaceID else { return workspaceSnapshots }
        return workspaceSnapshots.filter { $0.id == selectedWorkspaceID }
    }

    private var scopedRuns: [CommandCenterFleetRun] {
        scopedWorkspaceSnapshots.flatMap(\.runs)
    }

    private var searchScopedRuns: [CommandCenterFleetRun] {
        scopedRuns.filter(matchesSearch)
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
        coerceWorkspaceScope()
        coerceSelection()
        isRefreshing = false
        refreshInFlight = false

        if refreshQueued {
            refreshQueued = false
            queueRefresh(force: true)
        }
    }

    #if DEBUG
    func replaceSnapshotsForTesting(_ snapshots: [CommandCenterWorkspaceSnapshot]) {
        workspaceSnapshots = snapshots
        coerceWorkspaceScope()
        coerceSelection()
    }
    #endif

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
        matchesFilter(filter, run: run)
    }

    private func matchesFilter(_ filter: Filter, run: CommandCenterFleetRun) -> Bool {
        switch filter {
        case .all:
            return true
        case .attention:
            return run.needsAttention
        case .active:
            return ["running", "stuck", "retrying"].contains(run.normalizedState)
        case .queued:
            return run.normalizedState == "queued"
        case .review:
            return run.normalizedState == "review_needed"
        case .failed:
            return run.normalizedState == "failed"
        case .idle:
            return run.normalizedState == "idle"
        }
    }

    private func matchesSearch(_ run: CommandCenterFleetRun) -> Bool {
        let query = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return true }
        let needle = query.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
        let haystacks: [String] = [
            run.workspaceName,
            run.workspacePath,
            run.run.taskID,
            run.run.taskTitle,
            run.run.taskStatus,
            run.run.sessionID,
            run.run.sessionName,
            run.run.sessionStatus,
            run.run.sessionHealth,
            run.run.provider,
            run.run.model,
            run.run.agentProfile,
            run.run.branch,
            run.run.worktreeID,
            run.run.primaryFilePath,
            run.run.worktreePath,
            run.run.attentionReason,
        ].compactMap { $0 } + run.run.scopePaths
        return haystacks.contains {
            $0.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
                .contains(needle)
        }
    }

    private func compareRuns(_ lhs: CommandCenterFleetRun, _ rhs: CommandCenterFleetRun) -> Bool {
        if lhs.severity != rhs.severity {
            return lhs.severity > rhs.severity
        }
        if lhs.needsAttention != rhs.needsAttention {
            return lhs.needsAttention && !rhs.needsAttention
        }
        if lhs.boardSectionKind != rhs.boardSectionKind {
            return lhs.boardSectionKind.rawValue < rhs.boardSectionKind.rawValue
        }
        if lhs.run.lastActivityAt != rhs.run.lastActivityAt {
            return lhs.run.lastActivityAt > rhs.run.lastActivityAt
        }
        return lhs.title.localizedCaseInsensitiveCompare(rhs.title) == .orderedAscending
    }

    private func sortedRuns(
        _ runs: [CommandCenterFleetRun],
        for section: CommandCenterBoardSectionKind
    ) -> [CommandCenterFleetRun] {
        switch section {
        case .attention:
            return runs.sorted { lhs, rhs in
                if lhs.severity != rhs.severity {
                    return lhs.severity > rhs.severity
                }
                if lhs.run.lastActivityAt != rhs.run.lastActivityAt {
                    return lhs.run.lastActivityAt < rhs.run.lastActivityAt
                }
                return lhs.title.localizedCaseInsensitiveCompare(rhs.title) == .orderedAscending
            }
        case .active:
            return runs.sorted { lhs, rhs in
                if lhs.run.lastActivityAt != rhs.run.lastActivityAt {
                    return lhs.run.lastActivityAt > rhs.run.lastActivityAt
                }
                return lhs.title.localizedCaseInsensitiveCompare(rhs.title) == .orderedAscending
            }
        case .queued:
            return runs.sorted { lhs, rhs in
                if lhs.run.startedAt != rhs.run.startedAt {
                    return lhs.run.startedAt < rhs.run.startedAt
                }
                return lhs.title.localizedCaseInsensitiveCompare(rhs.title) == .orderedAscending
            }
        case .recent:
            return runs.sorted { lhs, rhs in
                if lhs.run.lastActivityAt != rhs.run.lastActivityAt {
                    return lhs.run.lastActivityAt > rhs.run.lastActivityAt
                }
                return lhs.title.localizedCaseInsensitiveCompare(rhs.title) == .orderedAscending
            }
        }
    }

    private func coerceWorkspaceScope() {
        guard let selectedWorkspaceID else { return }
        if !workspaceSnapshots.contains(where: { $0.id == selectedWorkspaceID }) {
            self.selectedWorkspaceID = nil
        }
    }

    private func coerceSelection() {
        if let selectedRunID,
           visibleRuns.contains(where: { $0.id == selectedRunID }) {
            return
        }
        selectedRunID = visibleRuns.first?.id
    }

    private func moveSelection(by offset: Int) {
        guard !visibleRuns.isEmpty else {
            selectedRunID = nil
            return
        }

        guard let selectedRunID,
              let currentIndex = visibleRuns.firstIndex(where: { $0.id == selectedRunID }) else {
            selectedRunID = offset < 0 ? visibleRuns.last?.id : visibleRuns.first?.id
            return
        }

        let nextIndex = min(max(currentIndex + offset, 0), visibleRuns.count - 1)
        self.selectedRunID = visibleRuns[nextIndex].id
    }
}
