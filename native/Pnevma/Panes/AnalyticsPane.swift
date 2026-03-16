import SwiftUI
import Observation
import Cocoa
import Charts
import UniformTypeIdentifiers

// MARK: - Shared Formatters

nonisolated(unsafe) private let usageDayParser: ISO8601DateFormatter = {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withFullDate]
    return formatter
}()

nonisolated(unsafe) private let usageTimestampParser: ISO8601DateFormatter = {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return formatter
}()

nonisolated(unsafe) private let usageTimestampParserNoFraction: ISO8601DateFormatter = {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime]
    return formatter
}()

nonisolated(unsafe) private let usageRelativeFormatter = RelativeDateTimeFormatter()

nonisolated(unsafe) private let usageRequestDayFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.calendar = .autoupdatingCurrent
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = .autoupdatingCurrent
    formatter.dateFormat = "yyyy-MM-dd"
    return formatter
}()

nonisolated(unsafe) private let usageRequestTimestampFormatter: ISO8601DateFormatter = {
    let formatter = ISO8601DateFormatter()
    formatter.timeZone = .autoupdatingCurrent
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return formatter
}()

enum UsageRequestBoundary {
    case start
    case end
}

func usageRequestTimestamp(
    for date: Date,
    boundary: UsageRequestBoundary,
    calendar: Calendar = .autoupdatingCurrent,
    timeZone: TimeZone = .autoupdatingCurrent
) -> String {
    var calendar = calendar
    calendar.timeZone = timeZone

    let interval = calendar.dateInterval(of: .day, for: date)
        ?? DateInterval(start: calendar.startOfDay(for: date), duration: 86_400)
    let value = switch boundary {
    case .start:
        interval.start
    case .end:
        interval.end.addingTimeInterval(-0.001)
    }

    let formatter = usageRequestTimestampFormatter.copy() as? ISO8601DateFormatter ?? ISO8601DateFormatter()
    formatter.timeZone = timeZone
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return formatter.string(from: value)
}

private func formatTokens(_ value: Int) -> String {
    value.formatted(.number.grouping(.automatic))
}

private func formatCompactTokens(_ value: Int) -> String {
    if abs(value) >= 10_000 {
        return value.formatted(.number.notation(.compactName))
    }
    return formatTokens(value)
}

private func formatCost(_ value: Double) -> String {
    value.formatted(.currency(code: "USD"))
}

private func formatDateLabel(_ raw: String) -> String {
    guard let date = usageDayParser.date(from: raw) else { return raw }
    return date.formatted(.dateTime.month(.abbreviated).day())
}

private func formatSelectedDate(_ date: Date) -> String {
    date.formatted(.dateTime.month(.abbreviated).day().year())
}

private func formatRelativeTimestamp(_ raw: String?) -> String {
    guard let raw else { return "—" }
    let date = usageTimestampParser.date(from: raw)
        ?? usageTimestampParserNoFraction.date(from: raw)
    guard let date else { return raw }
    return usageRelativeFormatter.localizedString(for: date, relativeTo: .now)
}

private func sanitizeFilename(_ name: String) -> String {
    let invalid = CharacterSet(charactersIn: "/\\:*?\"<>|")
    return name
        .components(separatedBy: invalid)
        .joined(separator: "-")
        .trimmingCharacters(in: .whitespacesAndNewlines)
        .prefix(100)
        .description
}

// MARK: - Data Models

enum UsageScope: String, CaseIterable, Identifiable {
    case project
    case global

    var id: String { rawValue }

    var label: String {
        switch self {
        case .project: return "Project"
        case .global: return "Global"
        }
    }
}

enum UsageSegment: String, CaseIterable, Identifiable {
    case overview
    case providers
    case explorer
    case diagnostics

    var id: String { rawValue }

    var label: String {
        switch self {
        case .overview: return "Overview"
        case .providers: return "Providers"
        case .explorer: return "Explorer"
        case .diagnostics: return "Diagnostics"
        }
    }
}

enum UsageExplorerMode: String, CaseIterable, Identifiable {
    case sessions
    case tasks

    var id: String { rawValue }

    var label: String {
        switch self {
        case .sessions: return "Sessions"
        case .tasks: return "Tasks"
        }
    }
}

enum UsageExplorerSort: String, CaseIterable, Identifiable {
    case costDesc
    case tokensDesc
    case recentDesc

    var id: String { rawValue }

    var label: String {
        switch self {
        case .costDesc: return "Cost"
        case .tokensDesc: return "Tokens"
        case .recentDesc: return "Recent"
        }
    }
}

enum UsageTrendMetric: String, CaseIterable, Identifiable {
    case cost
    case tokens

    var id: String { rawValue }

    var label: String {
        switch self {
        case .cost: return "Cost"
        case .tokens: return "Tokens"
        }
    }
}

struct UsageAnalyticsSummary: Decodable {
    let scope: String
    let from: String
    let to: String
    let totals: UsageTotals
    let dailyTrend: [UsageTrendPoint]
    let topProviders: [UsageBreakdownItem]
    let topModels: [UsageBreakdownItem]
    let topTasks: [UsageTaskAnalyticsRow]
    let activity: UsageActivity
    let errorHotspots: [UsageErrorHotspot]
}

struct UsageTotals: Decodable {
    let totalInputTokens: Int
    let totalOutputTokens: Int
    let totalTokens: Int
    let totalCostUsd: Double
    let avgDailyCostUsd: Double
    let avgDailyTokens: Int
    let activeSessions: Int
    let tasksWithSpend: Int
    let errorHotspotCount: Int
}

struct UsageTrendPoint: Decodable, Identifiable {
    var id: String { date }
    let date: String
    let tokensIn: Int
    let tokensOut: Int
    let estimatedUsd: Double

    var parsedDate: Date {
        usageDayParser.date(from: date) ?? .distantPast
    }
}

struct UsageBreakdownItem: Decodable, Identifiable {
    var id: String { "\(secondaryLabel ?? "root")::\(key)" }
    let key: String
    let label: String
    let secondaryLabel: String?
    let totalTokens: Int
    let estimatedUsd: Double
    let recordCount: Int
}

struct UsageActivity: Decodable {
    let weekdays: [UsageActivityBucket]
    let hours: [UsageActivityBucket]
}

struct UsageActivityBucket: Decodable, Identifiable {
    var id: String { "\(index)-\(label)" }
    let index: Int
    let label: String
    let totalTokens: Int
    let estimatedUsd: Double
}

struct UsageErrorHotspot: Decodable, Identifiable {
    let id: String
    let signatureHash: String
    let canonicalMessage: String
    let category: String
    let firstSeen: String
    let lastSeen: String
    let totalCount: Int
    let sampleOutput: String?
    let remediationHint: String?
}

struct UsageSessionAnalyticsRow: Codable, Identifiable {
    var id: String { "\(projectName)::\(sessionID)" }
    let projectName: String
    let sessionID: String
    let sessionName: String
    let sessionStatus: String
    let branch: String?
    let taskID: String?
    let taskTitle: String?
    let taskStatus: String?
    let providers: [String]
    let models: [String]
    let totalInputTokens: Int
    let totalOutputTokens: Int
    let totalTokens: Int
    let totalCostUsd: Double
    let startedAt: String
    let lastHeartbeat: String
}

struct UsageTaskAnalyticsRow: Codable, Identifiable {
    var id: String { "\(projectName)::\(taskID)" }
    let projectName: String
    let taskID: String
    let title: String
    let status: String
    let providers: [String]
    let models: [String]
    let sessionCount: Int
    let totalInputTokens: Int
    let totalOutputTokens: Int
    let totalTokens: Int
    let totalCostUsd: Double
    let lastActivityAt: String?
}

struct UsageDiagnostics: Decodable {
    let scope: String
    let from: String
    let to: String
    let projectNames: [String]
    let trackedCostRows: Int
    let untrackedCostRows: Int
    let lastTrackedCostAt: String?
    let localProviderSnapshots: [ProviderUsageSnapshot]
}

struct ProviderUsageSnapshot: Decodable, Identifiable {
    var id: String { provider }
    let provider: String
    let status: String
    let errorMessage: String?
    let days: [ProviderUsageDay]
    let totals: ProviderUsageSummary
    let topModels: [ProviderUsageModelShare]

    var displayName: String {
        switch provider {
        case "claude": return "Claude"
        case "codex": return "Codex"
        default: return provider.capitalized
        }
    }

    var hasData: Bool { totals.totalRequests > 0 }
}

struct ProviderUsageDay: Decodable, Identifiable {
    var id: String { date }
    let date: String
    let inputTokens: Int
    let outputTokens: Int
    let cacheReadTokens: Int
    let cacheWriteTokens: Int
    let requests: Int
}

struct ProviderUsageSummary: Decodable {
    let totalInputTokens: Int
    let totalOutputTokens: Int
    let totalCacheReadTokens: Int
    let totalCacheWriteTokens: Int
    let totalRequests: Int
    let avgDailyTokens: Int
    let peakDay: String?
    let peakDayTokens: Int
}

struct ProviderUsageModelShare: Decodable, Identifiable {
    var id: String { model }
    let model: String
    let tokens: Int
    let sharePercent: Double
}

// MARK: - View Model

@Observable @MainActor
final class UsageViewModel {
    private enum ViewState: Equatable {
        case waiting(String)
        case loading(String)
        case ready
        case failed(String)
    }

    var segment: UsageSegment = .providers
    var scope: UsageScope = .project
    var trendMetric: UsageTrendMetric = .cost
    var explorerMode: UsageExplorerMode = .sessions
    var explorerSort: UsageExplorerSort = .costDesc
    var providerFilter = "All"
    var modelFilter = "All"
    var statusFilter = "All"
    var searchQuery = ""
    var pageSize = 25
    var currentPage = 1
    var selectedQuickRangeDays: Int? = 30

    var rangeStart: Date
    var rangeEnd: Date

    var summary: UsageAnalyticsSummary?
    var sessions: [UsageSessionAnalyticsRow] = []
    var tasks: [UsageTaskAnalyticsRow] = []
    var diagnostics: UsageDiagnostics?

    private var coreState: ViewState = .waiting("Waiting for project activation...")
    private var diagnosticsState: ViewState = .waiting("Open Diagnostics to load provider parity and tracking health.")

    @ObservationIgnored
    private let commandBus: (any CommandCalling)?
    @ObservationIgnored
    private let activationHub: ActiveWorkspaceActivationHub
    @ObservationIgnored
    private var activationObserverID: UUID?
    @ObservationIgnored
    nonisolated(unsafe) private var navigationObserver: NSObjectProtocol?
    @ObservationIgnored
    private var coreTask: Task<Void, Never>?
    @ObservationIgnored
    private var diagnosticsTask: Task<Void, Never>?

    init(
        commandBus: (any CommandCalling)? = CommandBus.shared,
        activationHub: ActiveWorkspaceActivationHub = .shared
    ) {
        self.commandBus = commandBus
        self.activationHub = activationHub

        let calendar = Calendar.autoupdatingCurrent
        let end = calendar.startOfDay(for: Date.now)
        self.rangeEnd = end
        self.rangeStart = calendar.date(byAdding: .day, value: -29, to: end) ?? end

        activationObserverID = activationHub.addObserver { [weak self] state in
            Task { @MainActor [weak self] in
                self?.handleActivationState(state)
            }
        }
        navigationObserver = NotificationCenter.default.addObserver(
            forName: .analyticsSegmentRequested,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.applyRequestedSegmentIfNeeded()
            }
        }
        applyRequestedSegmentIfNeeded()
    }

    deinit {
        if let activationObserverID {
            activationHub.removeObserver(activationObserverID)
        }
        if let navigationObserver {
            NotificationCenter.default.removeObserver(navigationObserver)
        }
    }

    var statusMessage: String? {
        switch coreState {
        case .waiting(let message), .loading(let message), .failed(let message):
            return message
        case .ready:
            return nil
        }
    }

    var isLoading: Bool {
        if case .loading = coreState { return true }
        return false
    }

    var rangeLabel: String {
        let start = formatSelectedDate(rangeStart)
        let end = formatSelectedDate(rangeEnd)
        return start == end ? start : "\(start) - \(end)"
    }

    var emptyStateDetail: String {
        switch coreState {
        case .failed(let message) where message.contains("older backend binary"):
            return "Rebuild the app so the Rust bridge and native UI are on the same revision."
        case .failed(let message) where message == "No trusted or open projects are available.":
            return "Trust a workspace or open a project to inspect tracked usage across projects."
        case .waiting, .loading, .failed:
            return scope == .global
                ? "Trust a workspace or open a project to inspect tracked usage across projects."
                : "Open a project or switch to global scope to inspect tracked usage."
        case .ready:
            return ""
        }
    }

    var diagnosticsMessage: String? {
        switch diagnosticsState {
        case .waiting(let message), .loading(let message), .failed(let message):
            return message
        case .ready:
            return nil
        }
    }

    var isDiagnosticsLoading: Bool {
        if case .loading = diagnosticsState { return true }
        return false
    }

    var availableProviders: [String] {
        let values = Set((sessions.flatMap(\.providers)) + (tasks.flatMap(\.providers)))
        return ["All"] + values.sorted()
    }

    var availableModels: [String] {
        let values = Set((sessions.flatMap(\.models)) + (tasks.flatMap(\.models)))
        return ["All"] + values.sorted()
    }

    var availableStatuses: [String] {
        let sessionStatuses = sessions.compactMap(\.taskStatus)
        let taskStatuses = tasks.map(\.status)
        return ["All"] + Set(sessionStatuses + taskStatuses).sorted()
    }

    var filteredSessions: [UsageSessionAnalyticsRow] {
        let providerFilter = providerFilter
        let modelFilter = modelFilter
        let statusFilter = statusFilter
        let query = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()

        let rows = sessions.filter { row in
            if providerFilter != "All", !row.providers.contains(providerFilter) { return false }
            if modelFilter != "All", !row.models.contains(modelFilter) { return false }
            if statusFilter != "All", row.taskStatus != statusFilter { return false }
            if !query.isEmpty {
                let haystack = [
                    row.projectName,
                    row.sessionName,
                    row.sessionID,
                    row.taskTitle ?? "",
                    row.taskStatus ?? "",
                    row.providers.joined(separator: " "),
                    row.models.joined(separator: " "),
                    row.branch ?? "",
                ]
                    .joined(separator: " ")
                    .lowercased()
                return haystack.contains(query)
            }
            return true
        }

        return sortSessions(rows)
    }

    var filteredTasks: [UsageTaskAnalyticsRow] {
        let providerFilter = providerFilter
        let modelFilter = modelFilter
        let statusFilter = statusFilter
        let query = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()

        let rows = tasks.filter { row in
            if providerFilter != "All", !row.providers.contains(providerFilter) { return false }
            if modelFilter != "All", !row.models.contains(modelFilter) { return false }
            if statusFilter != "All", row.status != statusFilter { return false }
            if !query.isEmpty {
                let haystack = [
                    row.projectName,
                    row.title,
                    row.taskID,
                    row.status,
                    row.providers.joined(separator: " "),
                    row.models.joined(separator: " "),
                ]
                    .joined(separator: " ")
                    .lowercased()
                return haystack.contains(query)
            }
            return true
        }

        return sortTasks(rows)
    }

    var visibleSessions: [UsageSessionAnalyticsRow] {
        paginate(filteredSessions)
    }

    var visibleTasks: [UsageTaskAnalyticsRow] {
        paginate(filteredTasks)
    }

    var totalPages: Int {
        let count = explorerMode == .sessions ? filteredSessions.count : filteredTasks.count
        return max(1, Int(ceil(Double(count) / Double(pageSize))))
    }

    var pageDescription: String {
        let count = explorerMode == .sessions ? filteredSessions.count : filteredTasks.count
        return "\(count) row\(count == 1 ? "" : "s") • page \(currentPage)/\(totalPages)"
    }

    var hasTrackedUsageInWindow: Bool {
        guard let summary else { return false }
        return summary.totals.totalTokens > 0 || summary.totals.totalCostUsd > 0
    }

    func activate() async {
        handleActivationState(activationHub.currentState)
    }

    func refresh() {
        reloadUsageData(showLoadingState: true)
    }

    func setSegment(_ segment: UsageSegment) {
        self.segment = segment
        guard segment != .providers else { return }
        if segment == .diagnostics, diagnostics == nil {
            loadDiagnostics(showLoadingState: true)
        }
    }

    func applyRequestedSegmentIfNeeded() {
        guard let rawValue = AnalyticsNavigationHub.shared.takeRequestedSegmentRawValue(),
              let segment = UsageSegment(rawValue: rawValue) else {
            return
        }
        self.segment = segment
    }

    func setScope(_ scope: UsageScope) {
        self.scope = scope
        currentPage = 1
        providerFilter = "All"
        modelFilter = "All"
        statusFilter = "All"
        reloadUsageData(showLoadingState: true)
    }

    func applyQuickRange(days: Int) {
        let calendar = Calendar.autoupdatingCurrent
        let end = calendar.startOfDay(for: Date.now)
        rangeEnd = end
        rangeStart = calendar.date(byAdding: .day, value: -(days - 1), to: end) ?? end
        selectedQuickRangeDays = days
        reloadUsageData(showLoadingState: true)
    }

    func updateDates(start: Date? = nil, end: Date? = nil) {
        if let start {
            rangeStart = normalizeDay(start)
        }
        if let end {
            rangeEnd = normalizeDay(end)
        }
        if rangeStart > rangeEnd {
            swap(&rangeStart, &rangeEnd)
        }
        selectedQuickRangeDays = nil
        reloadUsageData(showLoadingState: true)
    }

    func setDateRange(start: Date, end: Date) {
        rangeStart = normalizeDay(start)
        rangeEnd = normalizeDay(end)
        if rangeStart > rangeEnd {
            swap(&rangeStart, &rangeEnd)
        }
        selectedQuickRangeDays = nil
        reloadUsageData(showLoadingState: true)
    }

    func setExplorerMode(_ mode: UsageExplorerMode) {
        explorerMode = mode
        currentPage = 1
    }

    func setProviderFilter(_ value: String) {
        providerFilter = value
        currentPage = 1
    }

    func setModelFilter(_ value: String) {
        modelFilter = value
        currentPage = 1
    }

    func setStatusFilter(_ value: String) {
        statusFilter = value
        currentPage = 1
    }

    func setSearchQuery(_ value: String) {
        searchQuery = value
        currentPage = 1
    }

    func setSort(_ value: UsageExplorerSort) {
        explorerSort = value
    }

    func setPageSize(_ value: Int) {
        pageSize = value
        currentPage = 1
    }

    func goToPreviousPage() {
        currentPage = max(1, currentPage - 1)
    }

    func goToNextPage() {
        currentPage = min(totalPages, currentPage + 1)
    }

    func exportExplorer(asJSON: Bool) {
        let savePanel = NSSavePanel()
        savePanel.canCreateDirectories = true
        savePanel.nameFieldStringValue = suggestedExportFilename(asJSON: asJSON)
        savePanel.allowedContentTypes = [asJSON ? .json : .commaSeparatedText]

        guard savePanel.runModal() == .OK, let url = savePanel.url else { return }

        do {
            let content = try exportPayload(asJSON: asJSON)
            try content.write(to: url, atomically: true, encoding: .utf8)
        } catch {
            coreState = .failed(error.localizedDescription)
        }
    }

    private func normalizeDay(_ date: Date) -> Date {
        Calendar.autoupdatingCurrent.startOfDay(for: date)
    }

    private func resetDiagnosticsState() {
        diagnostics = nil
        diagnosticsState = .waiting("Open Diagnostics to load provider parity and tracking health.")
    }

    private func reloadUsageData(showLoadingState: Bool) {
        loadCore(showLoadingState: showLoadingState)
        if segment == .diagnostics {
            loadDiagnostics(showLoadingState: diagnostics == nil)
        } else {
            resetDiagnosticsState()
        }
    }

    private func sortSessions(_ rows: [UsageSessionAnalyticsRow]) -> [UsageSessionAnalyticsRow] {
        rows.sorted { left, right in
            switch explorerSort {
            case .costDesc:
                return compare(left.totalCostUsd, right.totalCostUsd, fallback: left.sessionName < right.sessionName)
            case .tokensDesc:
                return compare(left.totalTokens, right.totalTokens, fallback: left.sessionName < right.sessionName)
            case .recentDesc:
                return (left.lastHeartbeat > right.lastHeartbeat) || (left.lastHeartbeat == right.lastHeartbeat && left.sessionName < right.sessionName)
            }
        }
    }

    private func sortTasks(_ rows: [UsageTaskAnalyticsRow]) -> [UsageTaskAnalyticsRow] {
        rows.sorted { left, right in
            switch explorerSort {
            case .costDesc:
                return compare(left.totalCostUsd, right.totalCostUsd, fallback: left.title < right.title)
            case .tokensDesc:
                return compare(left.totalTokens, right.totalTokens, fallback: left.title < right.title)
            case .recentDesc:
                return (left.lastActivityAt ?? "") > (right.lastActivityAt ?? "")
            }
        }
    }

    private func compare<T: Comparable>(_ left: T, _ right: T, fallback: Bool) -> Bool {
        if left == right { return fallback }
        return left > right
    }

    private func paginate<T>(_ rows: [T]) -> [T] {
        let startIndex = max(0, (currentPage - 1) * pageSize)
        guard startIndex < rows.count else { return [] }
        let endIndex = min(rows.count, startIndex + pageSize)
        return Array(rows[startIndex..<endIndex])
    }

    private func suggestedExportFilename(asJSON: Bool) -> String {
        let base = explorerMode == .sessions ? "usage-sessions" : "usage-tasks"
        let scopeLabel = scope == .project ? "project" : "global"
        let dateLabel = "\(formatDate(rangeStart))_to_\(formatDate(rangeEnd))"
        return sanitizeFilename("\(base)-\(scopeLabel)-\(dateLabel)").appending(asJSON ? ".json" : ".csv")
    }

    private func exportPayload(asJSON: Bool) throws -> String {
        if asJSON {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601

            if explorerMode == .sessions {
                let data = try encoder.encode(filteredSessions)
                return String(decoding: data, as: UTF8.self)
            } else {
                let data = try encoder.encode(filteredTasks)
                return String(decoding: data, as: UTF8.self)
            }
        }

        if explorerMode == .sessions {
            return sessionCSV(filteredSessions)
        } else {
            return taskCSV(filteredTasks)
        }
    }

    private func sessionCSV(_ rows: [UsageSessionAnalyticsRow]) -> String {
        let header = [
            "project_name", "session_id", "session_name", "session_status", "branch",
            "task_id", "task_title", "task_status", "providers", "models",
            "total_input_tokens", "total_output_tokens", "total_tokens", "total_cost_usd",
            "started_at", "last_heartbeat",
        ]
        let body = rows.map { row in
            csv([
                row.projectName, row.sessionID, row.sessionName, row.sessionStatus, row.branch ?? "",
                row.taskID ?? "", row.taskTitle ?? "", row.taskStatus ?? "",
                row.providers.joined(separator: " | "), row.models.joined(separator: " | "),
                "\(row.totalInputTokens)", "\(row.totalOutputTokens)", "\(row.totalTokens)",
                String(format: "%.4f", row.totalCostUsd),
                row.startedAt, row.lastHeartbeat,
            ])
        }
        return ([csv(header)] + body).joined(separator: "\n")
    }

    private func taskCSV(_ rows: [UsageTaskAnalyticsRow]) -> String {
        let header = [
            "project_name", "task_id", "title", "status", "providers", "models",
            "session_count", "total_input_tokens", "total_output_tokens", "total_tokens",
            "total_cost_usd", "last_activity_at",
        ]
        let body = rows.map { row in
            csv([
                row.projectName, row.taskID, row.title, row.status,
                row.providers.joined(separator: " | "), row.models.joined(separator: " | "),
                "\(row.sessionCount)", "\(row.totalInputTokens)", "\(row.totalOutputTokens)",
                "\(row.totalTokens)", String(format: "%.4f", row.totalCostUsd),
                row.lastActivityAt ?? "",
            ])
        }
        return ([csv(header)] + body).joined(separator: "\n")
    }

    private func csv(_ values: [String]) -> String {
        values
            .map { "\"\($0.replacing("\"", with: "\"\""))\"" }
            .joined(separator: ",")
    }

    private func formatDate(_ date: Date) -> String {
        usageRequestDayFormatter.string(from: date)
    }

    private func requestParams() -> UsageRequestParams {
        UsageRequestParams(
            scope: scope.rawValue,
            from: usageRequestTimestamp(for: rangeStart, boundary: .start),
            to: usageRequestTimestamp(for: rangeEnd, boundary: .end)
        )
    }

    private func loadCore(showLoadingState: Bool) {
        guard let bus = commandBus else {
            coreState = .failed("Usage is unavailable because the command bus is not configured.")
            return
        }

        if showLoadingState {
            coreState = .loading("Loading usage intelligence...")
        }

        let params = requestParams()
        coreTask?.cancel()
        coreTask = Task { [weak self] in
            guard let self else { return }
            do {
                async let summary: UsageAnalyticsSummary = bus.call(
                    method: "analytics.usage_summary",
                    params: params
                )
                async let sessions: [UsageSessionAnalyticsRow] = bus.call(
                    method: "analytics.usage_sessions",
                    params: params
                )
                async let tasks: [UsageTaskAnalyticsRow] = bus.call(
                    method: "analytics.usage_tasks",
                    params: params
                )

                let resultSummary = try await summary
                let resultSessions = try await sessions
                let resultTasks = try await tasks

                guard !Task.isCancelled else { return }
                self.summary = resultSummary
                self.sessions = resultSessions
                self.tasks = resultTasks
                self.currentPage = min(self.currentPage, self.totalPages)
                self.coreState = .ready
                self.prefetchDiagnosticsIfNeeded(for: resultSummary)
            } catch {
                guard !Task.isCancelled else { return }
                self.handleCoreFailure(error)
            }
        }
    }

    private func loadDiagnostics(showLoadingState: Bool) {
        guard let bus = commandBus else {
            diagnosticsState = .failed("Diagnostics are unavailable because the command bus is not configured.")
            return
        }

        if showLoadingState {
            diagnosticsState = .loading("Loading usage diagnostics...")
        }

        let params = requestParams()
        diagnosticsTask?.cancel()
        diagnosticsTask = Task { [weak self] in
            guard let self else { return }
            do {
                let result: UsageDiagnostics = try await bus.call(
                    method: "analytics.usage_diagnostics",
                    params: params
                )
                guard !Task.isCancelled else { return }
                self.diagnostics = result
                self.diagnosticsState = .ready
            } catch {
                guard !Task.isCancelled else { return }
                self.diagnosticsState = .failed(error.localizedDescription)
            }
        }
    }

    private func handleActivationState(_ state: ActiveWorkspaceActivationState) {
        if scope == .global {
            if case .closed = state {
                coreTask?.cancel()
                diagnosticsTask?.cancel()
            }
            reloadUsageData(showLoadingState: summary == nil)
            return
        }

        switch state {
        case .idle, .opening:
            coreState = .waiting("Waiting for project activation...")
        case .open:
            reloadUsageData(showLoadingState: summary == nil)
        case .failed(_, _, let message):
            coreState = .failed(message)
        case .closed:
            coreTask?.cancel()
            diagnosticsTask?.cancel()
            summary = nil
            sessions = []
            tasks = []
            diagnostics = nil
            coreState = .waiting("Open a project to load usage intelligence.")
            diagnosticsState = .waiting("Open Diagnostics to load provider parity and tracking health.")
        }
    }

    private func handleCoreFailure(_ error: Error) {
        if PnevmaError.isProjectNotReady(error) {
            coreState = .waiting("Waiting for project activation...")
            return
        }
        coreState = .failed(error.localizedDescription)
    }

    private func prefetchDiagnosticsIfNeeded(for summary: UsageAnalyticsSummary) {
        guard summary.totals.totalTokens == 0, summary.totals.totalCostUsd == 0 else { return }
        if segment == .diagnostics || diagnostics != nil || isDiagnosticsLoading {
            return
        }
        loadDiagnostics(showLoadingState: false)
    }
}

private struct UsageRequestParams: Encodable {
    let scope: String
    let from: String
    let to: String
}

// MARK: - Root View

struct UsageView: View {
    @State private var viewModel = UsageViewModel()
    @State private var isShowingDateRangePicker = false
    @State private var draftRangeStart = Date()
    @State private var draftRangeEnd = Date()

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()

            if viewModel.segment == .providers {
                segmentContent
            } else if let statusMessage = viewModel.statusMessage {
                VStack(spacing: 8) {
                    if viewModel.isLoading {
                        ProgressView()
                            .controlSize(.small)
                    }
                    EmptyStateView(
                        icon: "chart.bar.doc.horizontal",
                        title: statusMessage,
                        message: viewModel.emptyStateDetail
                    )
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                segmentContent
            }
        }
        .task { await viewModel.activate() }
        .accessibilityIdentifier("pane.analytics")
    }

    private var toolbar: some View {
        if viewModel.segment == .providers {
            return AnyView(providersToolbar)
        }
        return AnyView(standardToolbar)
    }

    private var standardToolbar: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Usage Intelligence")
                        .font(.headline)
                    Text("Track spend, token flow, activity timing, and provider parity")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Refresh", systemImage: "arrow.clockwise") {
                    viewModel.refresh()
                }
                .labelStyle(.iconOnly)
                .buttonStyle(.plain)
                .keyboardShortcut("r", modifiers: .command)
                .accessibilityLabel("Refresh usage intelligence")
            }

            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: 14) {
                    scopeSection
                    viewSection
                    rangeSection
                    Spacer(minLength: 0)
                }

                VStack(alignment: .leading, spacing: 12) {
                    HStack(alignment: .top, spacing: 14) {
                        scopeSection
                        viewSection
                    }
                    rangeSection
                }
            }
        }
        .padding(12)
    }

    private var providersToolbar: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Provider Usage")
                        .font(.headline)
                    Text("Codex and Claude quota windows, credits, and local usage context")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Refresh", systemImage: "arrow.clockwise") {
                    Task { await ProviderUsageStore.shared.refresh(force: true) }
                }
                .labelStyle(.iconOnly)
                .buttonStyle(.plain)
                .keyboardShortcut("r", modifiers: .command)
                .accessibilityLabel("Refresh provider usage")
            }

            UsageToolbarSection(title: "View") {
                UsageChoiceBar(
                    options: Array(UsageSegment.allCases),
                    selection: viewModel.segment,
                    title: \.label,
                    action: { viewModel.setSegment($0) }
                )
                .frame(minWidth: 320)
            }
        }
        .padding(12)
    }

    private var scopeSection: some View {
        UsageToolbarSection(title: "Scope") {
            UsageChoiceBar(
                options: Array(UsageScope.allCases),
                selection: viewModel.scope,
                title: \.label,
                action: { viewModel.setScope($0) }
            )
            .frame(minWidth: 170)
        }
    }

    private var viewSection: some View {
        UsageToolbarSection(title: "View") {
            UsageChoiceBar(
                options: Array(UsageSegment.allCases),
                selection: viewModel.segment,
                title: \.label,
                action: { viewModel.setSegment($0) }
            )
            .frame(minWidth: 280)
        }
    }

    private var rangeSection: some View {
        UsageToolbarSection(title: "Range") {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) {
                    quickRangeButtons
                    dateRangeButton
                }

                VStack(alignment: .leading, spacing: 8) {
                    quickRangeButtons
                    dateRangeButton
                }
            }
        }
    }

    private var quickRangeButtons: some View {
        HStack(spacing: 8) {
            QuickRangeButton(
                title: "1D",
                isSelected: viewModel.selectedQuickRangeDays == 1
            ) {
                viewModel.applyQuickRange(days: 1)
            }
            QuickRangeButton(
                title: "7D",
                isSelected: viewModel.selectedQuickRangeDays == 7
            ) {
                viewModel.applyQuickRange(days: 7)
            }
            QuickRangeButton(
                title: "30D",
                isSelected: viewModel.selectedQuickRangeDays == 30
            ) {
                viewModel.applyQuickRange(days: 30)
            }
            QuickRangeButton(
                title: "90D",
                isSelected: viewModel.selectedQuickRangeDays == 90
            ) {
                viewModel.applyQuickRange(days: 90)
            }
        }
    }

    private var dateRangeButton: some View {
        Button {
            draftRangeStart = viewModel.rangeStart
            draftRangeEnd = viewModel.rangeEnd
            isShowingDateRangePicker = true
        } label: {
            Label(viewModel.rangeLabel, systemImage: "calendar")
                .lineLimit(1)
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .accessibilityHint("Choose a start date and end date")
        .popover(isPresented: $isShowingDateRangePicker, arrowEdge: .top) {
            UsageDateRangePopover(
                start: $draftRangeStart,
                end: $draftRangeEnd,
                onCancel: {
                    isShowingDateRangePicker = false
                },
                onApply: { start, end in
                    viewModel.setDateRange(start: start, end: end)
                    isShowingDateRangePicker = false
                }
            )
        }
    }

    @ViewBuilder
    private var segmentContent: some View {
        switch viewModel.segment {
        case .overview:
            OverviewSegment(viewModel: viewModel)
        case .providers:
            ProviderUsageDashboardView()
        case .explorer:
            ExplorerSegment(viewModel: viewModel)
        case .diagnostics:
            DiagnosticsSegment(viewModel: viewModel)
        }
    }
}

private struct UsageToolbarSection<Content: View>: View {
    let title: String
    let content: Content

    init(title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            content
        }
    }
}

private struct UsageChoiceBar<Option: Identifiable & Hashable>: View {
    let options: [Option]
    let selection: Option
    let title: KeyPath<Option, String>
    let action: (Option) -> Void

    var body: some View {
        HStack(spacing: 4) {
            ForEach(options) { option in
                let isSelected = option == selection
                Button(option[keyPath: title]) {
                    action(option)
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 12)
                .frame(minHeight: 28)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(isSelected ? Color.accentColor : Color.clear)
                )
                .foregroundStyle(isSelected ? Color.white : Color.primary)
                .contentShape(RoundedRectangle(cornerRadius: 8))
            }
        }
        .padding(4)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color.secondary.opacity(0.10))
        )
    }
}

private struct UsageDateRangePopover: View {
    @Binding var start: Date
    @Binding var end: Date

    let onCancel: () -> Void
    let onApply: (Date, Date) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Choose Date Range")
                    .font(.headline)
                Text("\(formatSelectedDate(start)) - \(formatSelectedDate(end))")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: 16) {
                    startCalendarColumn
                    endCalendarColumn
                }

                VStack(alignment: .leading, spacing: 16) {
                    startCalendarColumn
                    endCalendarColumn
                }
            }

            HStack {
                Button("Cancel", role: .cancel, action: onCancel)
                Spacer()
                Button("Apply") {
                    onApply(start, end)
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
        .frame(minWidth: 360)
        .onChange(of: start) {
            if start > end {
                end = start
            }
        }
        .onChange(of: end) {
            if end < start {
                start = end
            }
        }
    }

    private var startCalendarColumn: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Start")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            DatePicker(
                "Start",
                selection: $start,
                in: ...end,
                displayedComponents: .date
            )
            .datePickerStyle(.graphical)
            .labelsHidden()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var endCalendarColumn: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("End")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            DatePicker(
                "End",
                selection: $end,
                in: start...,
                displayedComponents: .date
            )
            .datePickerStyle(.graphical)
            .labelsHidden()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Overview

private struct OverviewSegment: View {
    let viewModel: UsageViewModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                if let summary = viewModel.summary {
                    if !viewModel.hasTrackedUsageInWindow {
                        UsageCoverageBanner(
                            diagnostics: viewModel.diagnostics,
                            windowLabel: "\(summary.from) to \(summary.to)",
                            onOpenDiagnostics: { viewModel.setSegment(.diagnostics) }
                        )
                    }

                    metricsGrid(summary: summary)
                    trendCard(summary: summary)

                    ViewThatFits(in: .horizontal) {
                        HStack(alignment: .top, spacing: 14) {
                            BreakdownCard(
                                title: "Top Providers",
                                caption: "Spend by provider in the selected window",
                                items: summary.topProviders
                            )
                            BreakdownCard(
                                title: "Top Models",
                                caption: "Spend grouped by model and provider",
                                items: summary.topModels
                            )
                        }

                        VStack(alignment: .leading, spacing: 14) {
                            BreakdownCard(
                                title: "Top Providers",
                                caption: "Spend by provider in the selected window",
                                items: summary.topProviders
                            )
                            BreakdownCard(
                                title: "Top Models",
                                caption: "Spend grouped by model and provider",
                                items: summary.topModels
                            )
                        }
                    }

                    ViewThatFits(in: .horizontal) {
                        HStack(alignment: .top, spacing: 14) {
                            ActivityCard(activity: summary.activity)
                            TopTasksCard(tasks: summary.topTasks)
                        }

                        VStack(alignment: .leading, spacing: 14) {
                            ActivityCard(activity: summary.activity)
                            TopTasksCard(tasks: summary.topTasks)
                        }
                    }

                    ErrorHotspotsCard(hotspots: summary.errorHotspots)
                }
            }
            .padding(16)
        }
    }

    private func metricsGrid(summary: UsageAnalyticsSummary) -> some View {
        LazyVGrid(
            columns: [GridItem(.adaptive(minimum: 150, maximum: 220), spacing: 10)],
            spacing: 10
        ) {
            MetricCard(label: "Total Cost", value: formatCost(summary.totals.totalCostUsd))
            MetricCard(label: "Total Tokens", value: formatCompactTokens(summary.totals.totalTokens))
            MetricCard(label: "Avg Daily Cost", value: formatCost(summary.totals.avgDailyCostUsd))
            MetricCard(label: "Avg Daily Tokens", value: formatCompactTokens(summary.totals.avgDailyTokens))
            MetricCard(label: "Active Sessions", value: "\(summary.totals.activeSessions)")
            MetricCard(label: "Tasks With Spend", value: "\(summary.totals.tasksWithSpend)")
            MetricCard(label: "Input Tokens", value: formatCompactTokens(summary.totals.totalInputTokens))
            MetricCard(label: "Output Tokens", value: formatCompactTokens(summary.totals.totalOutputTokens))
            MetricCard(label: "Error Hotspots", value: "\(summary.totals.errorHotspotCount)")
        }
    }

    private func trendCard(summary: UsageAnalyticsSummary) -> some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Daily Trend")
                            .font(.headline)
                        Text("\(summary.from) to \(summary.to)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    UsageChoiceBar(
                        options: Array(UsageTrendMetric.allCases),
                        selection: viewModel.trendMetric,
                        title: \.label,
                        action: { viewModel.trendMetric = $0 }
                    )
                    .frame(width: 180)
                }

                if summary.dailyTrend.isEmpty {
                    EmptyStateView(
                        icon: "waveform.path.ecg",
                        title: "No usage in this range",
                        message: "Adjust the range or switch scope to inspect a broader window."
                    )
                    .frame(height: 220)
                } else {
                    Chart {
                        ForEach(summary.dailyTrend) { point in
                            if viewModel.trendMetric == .cost {
                                LineMark(
                                    x: .value("Date", point.parsedDate),
                                    y: .value("Cost", point.estimatedUsd)
                                )
                                .interpolationMethod(.catmullRom)
                                .foregroundStyle(Color.accentColor)

                                AreaMark(
                                    x: .value("Date", point.parsedDate),
                                    y: .value("Cost", point.estimatedUsd)
                                )
                                .foregroundStyle(Color.accentColor.opacity(0.18))
                            } else {
                                BarMark(
                                    x: .value("Date", point.parsedDate),
                                    y: .value("Input", point.tokensIn)
                                )
                                .foregroundStyle(.blue.opacity(0.7))

                                BarMark(
                                    x: .value("Date", point.parsedDate),
                                    y: .value("Output", point.tokensOut)
                                )
                                .foregroundStyle(.green.opacity(0.7))
                            }
                        }
                    }
                    .chartXAxis {
                        AxisMarks(values: .stride(by: .day, count: max(1, summary.dailyTrend.count / 6))) { _ in
                            AxisGridLine()
                            AxisTick()
                            AxisValueLabel(format: .dateTime.month(.abbreviated).day())
                        }
                    }
                    .frame(height: 220)
                }
            }
        }
    }
}

// MARK: - Explorer

private struct ExplorerSegment: View {
    let viewModel: UsageViewModel

    var body: some View {
        VStack(spacing: 0) {
            filterBar
            Divider()

            ViewThatFits(in: .horizontal) {
                HStack {
                    explorerModeControl
                    Spacer()
                    explorerActions
                }

                VStack(alignment: .leading, spacing: 10) {
                    explorerModeControl
                    explorerActions
                }
            }
            .padding(12)

            Divider()

            ScrollView {
                VStack(spacing: 0) {
                    if viewModel.explorerMode == .sessions {
                        SessionExplorerTable(
                            rows: viewModel.visibleSessions,
                            hasTrackedUsageInWindow: viewModel.hasTrackedUsageInWindow
                        )
                    } else {
                        TaskExplorerTable(
                            rows: viewModel.visibleTasks,
                            hasTrackedUsageInWindow: viewModel.hasTrackedUsageInWindow
                        )
                    }
                }
                .padding(16)
            }

            Divider()

            HStack {
                Text(viewModel.pageDescription)
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Spacer()

                Button("Prev") {
                    viewModel.goToPreviousPage()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(viewModel.currentPage <= 1)

                Button("Next") {
                    viewModel.goToNextPage()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(viewModel.currentPage >= viewModel.totalPages)
            }
            .padding(12)
        }
    }

    private var filterBar: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 10) {
                MenuPicker(
                    title: "Provider",
                    selection: viewModel.providerFilter,
                    options: viewModel.availableProviders,
                    action: viewModel.setProviderFilter(_:))

                MenuPicker(
                    title: "Model",
                    selection: viewModel.modelFilter,
                    options: viewModel.availableModels,
                    action: viewModel.setModelFilter(_:))

                MenuPicker(
                    title: "Status",
                    selection: viewModel.statusFilter,
                    options: viewModel.availableStatuses,
                    action: viewModel.setStatusFilter(_:))

                TextField(
                    "Search session, task, branch, provider, model...",
                    text: Binding(
                        get: { viewModel.searchQuery },
                        set: { viewModel.setSearchQuery($0) }
                    )
                )
                .textFieldStyle(.roundedBorder)
            }

            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 10) {
                    MenuPicker(
                        title: "Provider",
                        selection: viewModel.providerFilter,
                        options: viewModel.availableProviders,
                        action: viewModel.setProviderFilter(_:))

                    MenuPicker(
                        title: "Model",
                        selection: viewModel.modelFilter,
                        options: viewModel.availableModels,
                        action: viewModel.setModelFilter(_:))

                    MenuPicker(
                        title: "Status",
                        selection: viewModel.statusFilter,
                        options: viewModel.availableStatuses,
                        action: viewModel.setStatusFilter(_:))
                }

                TextField(
                    "Search session, task, branch, provider, model...",
                    text: Binding(
                        get: { viewModel.searchQuery },
                        set: { viewModel.setSearchQuery($0) }
                    )
                )
                .textFieldStyle(.roundedBorder)
            }
        }
        .padding(12)
    }

    private var explorerModeControl: some View {
        UsageChoiceBar(
            options: Array(UsageExplorerMode.allCases),
            selection: viewModel.explorerMode,
            title: \.label,
            action: { viewModel.setExplorerMode($0) }
        )
        .frame(width: 220)
    }

    private var explorerActions: some View {
        HStack(spacing: 8) {
            Picker("Sort", selection: Binding(
                get: { viewModel.explorerSort },
                set: { viewModel.setSort($0) }
            )) {
                ForEach(UsageExplorerSort.allCases) { sort in
                    Text(sort.label).tag(sort)
                }
            }
            .pickerStyle(.menu)
            .frame(width: 110)

            Picker("Page Size", selection: Binding(
                get: { viewModel.pageSize },
                set: { viewModel.setPageSize($0) }
            )) {
                Text("25").tag(25)
                Text("50").tag(50)
                Text("100").tag(100)
            }
            .pickerStyle(.menu)
            .frame(width: 90)

            Button("Export CSV") {
                viewModel.exportExplorer(asJSON: false)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)

            Button("Export JSON") {
                viewModel.exportExplorer(asJSON: true)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
    }
}

// MARK: - Diagnostics

private struct DiagnosticsSegment: View {
    let viewModel: UsageViewModel

    var body: some View {
        Group {
            if let message = viewModel.diagnosticsMessage, viewModel.diagnostics == nil {
                VStack(spacing: 8) {
                    if viewModel.isDiagnosticsLoading {
                        ProgressView()
                            .controlSize(.small)
                    }
                    EmptyStateView(
                        icon: "stethoscope",
                        title: message,
                        message: "Diagnostics exposes tracked/untracked usage rows plus local provider snapshot health."
                    )
                }
            } else if let diagnostics = viewModel.diagnostics {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        if let message = viewModel.diagnosticsMessage {
                            UsageInlineNotice(
                                title: "Diagnostics refresh issue",
                                message: message
                            )
                        }

                        LazyVGrid(
                            columns: [GridItem(.adaptive(minimum: 160, maximum: 220), spacing: 10)],
                            spacing: 10
                        ) {
                            MetricCard(label: "Tracked Cost Rows", value: formatTokens(diagnostics.trackedCostRows))
                            MetricCard(label: "Untracked Cost Rows", value: formatTokens(diagnostics.untrackedCostRows))
                            MetricCard(label: "Projects", value: "\(diagnostics.projectNames.count)")
                        }

                        GroupBox {
                            VStack(alignment: .leading, spacing: 8) {
                                Text("Tracking Health")
                                    .font(.headline)
                                Text("Overview and Explorer use tracked Pnevma cost analytics. Local provider snapshots below are diagnostic-only.")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)

                                DetailRow(label: "Scope", value: diagnostics.scope.capitalized)
                                DetailRow(label: "Window", value: "\(diagnostics.from) to \(diagnostics.to)")
                                DetailRow(label: "Projects", value: diagnostics.projectNames.joined(separator: ", "))
                                DetailRow(label: "Last Tracked Cost", value: formatRelativeTimestamp(diagnostics.lastTrackedCostAt))
                            }
                        }

                        VStack(alignment: .leading, spacing: 10) {
                            Text("Local Provider Parity")
                                .font(.headline)
                            Text("These values come from local Claude/Codex session files and are shown for operator diagnostics, not primary cost rollups.")
                                .font(.caption)
                                .foregroundStyle(.secondary)

                            ForEach(diagnostics.localProviderSnapshots) { snapshot in
                                ProviderDiagnosticsCard(snapshot: snapshot)
                            }
                        }
                    }
                    .padding(16)
                }
            }
        }
    }
}

private struct UsageInlineNotice: View {
    let title: String
    let message: String

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle")
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.subheadline)
                    .bold()
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color.orange.opacity(0.10))
        )
    }
}

private struct UsageCoverageBanner: View {
    let diagnostics: UsageDiagnostics?
    let windowLabel: String
    let onOpenDiagnostics: () -> Void

    private var providerSummary: String? {
        guard let diagnostics else { return nil }
        let providers = diagnostics.localProviderSnapshots
            .filter(\.hasData)
            .map(\.displayName)
        guard !providers.isEmpty else { return nil }
        return ListFormatter.localizedString(byJoining: providers)
    }

    private var detail: String {
        guard let diagnostics else {
            return "Pnevma has not recorded tracked cost rows for \(windowLabel). This usually means cost ingestion has not populated this workspace yet."
        }

        if let providerSummary {
            return "\(providerSummary) local session files show activity on this machine in the selected window, but this workspace still has zero tracked cost rows."
        }

        if diagnostics.untrackedCostRows > 0 {
            return "This window has untracked cost rows but no tracked usage yet. Open Diagnostics to inspect source coverage before sharing this pane with testers."
        }

        return "Pnevma has not recorded tracked cost rows for \(windowLabel). Open Diagnostics to confirm whether this is a true zero-usage window or a tracking gap."
    }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "waveform.path.badge.minus")
                .font(.title3)
                .foregroundStyle(.orange)

            VStack(alignment: .leading, spacing: 8) {
                Text("No tracked usage in this window")
                    .font(.headline)
                Text(detail)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                HStack(spacing: 8) {
                    UsageTag(text: windowLabel)
                    if let diagnostics {
                        UsageTag(text: "\(diagnostics.trackedCostRows) tracked rows")
                    }
                    Button("Open Diagnostics", action: onOpenDiagnostics)
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                }
            }
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color.orange.opacity(0.10))
        )
    }
}

private struct UsageTag: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.caption)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(
                Capsule()
                    .fill(Color.secondary.opacity(0.12))
            )
    }
}

// MARK: - Cards

private struct BreakdownCard: View {
    let title: String
    let caption: String
    let items: [UsageBreakdownItem]

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                Text(caption)
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if items.isEmpty {
                    Text("No breakdown data in this window.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(items) { item in
                        HStack(alignment: .firstTextBaseline) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(item.label)
                                    .font(.subheadline)
                                if let secondary = item.secondaryLabel {
                                    Text(secondary)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            Spacer()
                            VStack(alignment: .trailing, spacing: 2) {
                                Text(formatCost(item.estimatedUsd))
                                    .font(.subheadline.monospacedDigit())
                                Text("\(formatCompactTokens(item.totalTokens)) tok • \(item.recordCount) rec")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        Divider()
                    }
                }
            }
        } label: {
            Text(title)
                .font(.headline)
        }
    }
}

private struct ActivityCard: View {
    let activity: UsageActivity

    private var weekdayMax: Int {
        max(activity.weekdays.map(\.totalTokens).max() ?? 0, 1)
    }

    private var hourMax: Int {
        max(activity.hours.map(\.totalTokens).max() ?? 0, 1)
    }

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 12) {
                Text("When usage happens")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                VStack(alignment: .leading, spacing: 6) {
                    Text("Day of Week")
                        .font(.subheadline)
                    HStack(spacing: 6) {
                        ForEach(activity.weekdays) { bucket in
                            VStack(spacing: 4) {
                                RoundedRectangle(cornerRadius: 4)
                                    .fill(Color.accentColor.opacity(opacity(bucket.totalTokens, maxValue: weekdayMax)))
                                    .frame(width: 34, height: 26)
                                Text(bucket.label)
                                    .font(.caption)
                            }
                            .frame(maxWidth: .infinity)
                        }
                    }
                }

                VStack(alignment: .leading, spacing: 6) {
                    Text("Hour of Day")
                        .font(.subheadline)
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 4), count: 6), spacing: 4) {
                        ForEach(activity.hours) { bucket in
                            VStack(spacing: 3) {
                                RoundedRectangle(cornerRadius: 3)
                                    .fill(Color.blue.opacity(opacity(bucket.totalTokens, maxValue: hourMax)))
                                    .frame(height: 18)
                                Text("\(bucket.index)")
                                    .font(.caption)
                            }
                        }
                    }
                }
            }
        } label: {
            Text("Activity")
                .font(.headline)
        }
    }

    private func opacity(_ value: Int, maxValue: Int) -> Double {
        guard maxValue > 0, value > 0 else { return 0.08 }
        return min(0.9, max(0.12, Double(value) / Double(maxValue)))
    }
}

private struct TopTasksCard: View {
    let tasks: [UsageTaskAnalyticsRow]

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                Text("Most expensive tasks in the selected window")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if tasks.isEmpty {
                    Text("No task-level usage data in this range.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(tasks) { task in
                        HStack(alignment: .top) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(task.title)
                                    .font(.subheadline)
                                Text("\(task.projectName) • \(task.status)")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            VStack(alignment: .trailing, spacing: 2) {
                                Text(formatCost(task.totalCostUsd))
                                    .font(.subheadline.monospacedDigit())
                                Text("\(formatCompactTokens(task.totalTokens)) tok")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        Divider()
                    }
                }
            }
        } label: {
            Text("Top Tasks")
                .font(.headline)
        }
    }
}

private struct ErrorHotspotsCard: View {
    let hotspots: [UsageErrorHotspot]

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                if hotspots.isEmpty {
                    Text("No error hotspots recorded yet.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(hotspots) { hotspot in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text(hotspot.category.capitalized)
                                    .font(.caption)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(Capsule().fill(Color.orange.opacity(0.2)))
                                Spacer()
                                Text("\(hotspot.totalCount)x")
                                    .font(.caption.monospacedDigit())
                                    .foregroundStyle(.secondary)
                            }
                            Text(hotspot.canonicalMessage)
                                .font(.subheadline)
                            if let hint = hotspot.remediationHint {
                                Text(hint)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Text("Last seen \(formatRelativeTimestamp(hotspot.lastSeen))")
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                        Divider()
                    }
                }
            }
        } label: {
            Text("Error Hotspots")
                .font(.headline)
        }
    }
}

private struct ProviderDiagnosticsCard: View {
    let snapshot: ProviderUsageSnapshot

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text(snapshot.displayName)
                        .font(.headline)
                    Spacer()
                    StatusPill(status: snapshot.status)
                }

                if let errorMessage = snapshot.errorMessage {
                    Text(errorMessage)
                        .font(.caption)
                        .foregroundStyle(.red)
                } else if snapshot.hasData {
                    HStack(spacing: 14) {
                        DetailRow(label: "Requests", value: formatTokens(snapshot.totals.totalRequests))
                        DetailRow(label: "Input", value: formatCompactTokens(snapshot.totals.totalInputTokens))
                        DetailRow(label: "Output", value: formatCompactTokens(snapshot.totals.totalOutputTokens))
                    }

                    if let topModel = snapshot.topModels.first {
                        DetailRow(
                            label: "Top Model",
                            value: "\(topModel.model) • \(String(format: "%.1f", topModel.sharePercent))%"
                        )
                    }

                    if let peakDay = snapshot.totals.peakDay {
                        DetailRow(
                            label: "Peak Day",
                            value: "\(formatDateLabel(peakDay)) • \(formatCompactTokens(snapshot.totals.peakDayTokens)) tok"
                        )
                    }
                } else {
                    Text(snapshot.status == "no_data"
                         ? "No local session files detected for this provider in the selected window."
                         : "No usage data available for this provider.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
}

private struct StatusPill: View {
    let status: String

    private var color: Color {
        switch status {
        case "ok": return .green
        case "no_data": return .orange
        case "error": return .red
        default: return .secondary
        }
    }

    var body: some View {
        Text(status.replacing("_", with: " ").capitalized)
            .font(.caption)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(Capsule().fill(color.opacity(0.18)))
            .foregroundStyle(color)
    }
}

private struct DetailRow: View {
    let label: String
    let value: String

    var body: some View {
        HStack {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .font(.caption.monospacedDigit())
        }
    }
}

private struct QuickRangeButton: View {
    let title: String
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Group {
            if isSelected {
                Button(title, action: action)
                    .buttonStyle(.borderedProminent)
            } else {
                Button(title, action: action)
                    .buttonStyle(.bordered)
            }
        }
        .controlSize(.small)
    }
}

private struct MenuPicker: View {
    let title: String
    let selection: String
    let options: [String]
    let action: (String) -> Void

    var body: some View {
        Menu {
            ForEach(options, id: \.self) { option in
                Button(option) {
                    action(option)
                }
            }
        } label: {
            HStack(spacing: 4) {
                Text(title)
                    .foregroundStyle(.secondary)
                Text(selection)
                    .foregroundStyle(.primary)
                Image(systemName: "chevron.down")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .font(.caption)
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color.secondary.opacity(0.08))
            )
        }
        .menuStyle(.borderlessButton)
    }
}

// MARK: - Explorer Tables

private struct SessionExplorerTable: View {
    let rows: [UsageSessionAnalyticsRow]
    let hasTrackedUsageInWindow: Bool

    var body: some View {
        GroupBox {
            VStack(spacing: 0) {
                ExplorerHeader(columns: ["Project", "Session", "Task", "Providers", "Models", "Status", "Tokens", "Cost", "Last"])

                if rows.isEmpty {
                    EmptyStateView(
                        icon: "rectangle.stack.badge.person.crop",
                        title: hasTrackedUsageInWindow
                            ? "No sessions match the current filters"
                            : "No tracked usage sessions in this window",
                        message: hasTrackedUsageInWindow
                            ? "Adjust the filters or widen the date range."
                            : "Tracked cost analytics are empty for this range, so the explorer has no rows to inspect yet."
                    )
                    .frame(height: 220)
                } else {
                    ForEach(rows) { row in
                        VStack(spacing: 0) {
                            HStack(alignment: .top, spacing: 10) {
                                ExplorerCell(row.projectName, width: 120)
                                ExplorerCell("\(row.sessionName)\n\(row.sessionID)", width: 220)
                                ExplorerCell(row.taskTitle ?? "—", width: 180, secondary: row.taskStatus)
                                ExplorerCell(row.providers.joined(separator: ", "), width: 110)
                                ExplorerCell(row.models.joined(separator: ", "), width: 170)
                                ExplorerCell(row.sessionStatus, width: 90, secondary: row.branch)
                                ExplorerCell(formatCompactTokens(row.totalTokens), width: 90, alignment: .trailing)
                                ExplorerCell(formatCost(row.totalCostUsd), width: 90, alignment: .trailing)
                                ExplorerCell(formatRelativeTimestamp(row.lastHeartbeat), width: 90, alignment: .trailing)
                            }
                            .padding(.vertical, 8)
                            Divider()
                        }
                    }
                }
            }
        }
    }
}

private struct TaskExplorerTable: View {
    let rows: [UsageTaskAnalyticsRow]
    let hasTrackedUsageInWindow: Bool

    var body: some View {
        GroupBox {
            VStack(spacing: 0) {
                ExplorerHeader(columns: ["Project", "Task", "Status", "Providers", "Models", "Sessions", "Tokens", "Cost", "Last"])

                if rows.isEmpty {
                    EmptyStateView(
                        icon: "list.bullet.rectangle",
                        title: hasTrackedUsageInWindow
                            ? "No tasks match the current filters"
                            : "No tracked usage tasks in this window",
                        message: hasTrackedUsageInWindow
                            ? "Adjust the filters or widen the date range."
                            : "Tracked cost analytics are empty for this range, so the explorer has no rows to inspect yet."
                    )
                    .frame(height: 220)
                } else {
                    ForEach(rows) { row in
                        VStack(spacing: 0) {
                            HStack(alignment: .top, spacing: 10) {
                                ExplorerCell(row.projectName, width: 120)
                                ExplorerCell("\(row.title)\n\(row.taskID)", width: 240)
                                ExplorerCell(row.status, width: 90)
                                ExplorerCell(row.providers.joined(separator: ", "), width: 110)
                                ExplorerCell(row.models.joined(separator: ", "), width: 170)
                                ExplorerCell("\(row.sessionCount)", width: 70, alignment: .trailing)
                                ExplorerCell(formatCompactTokens(row.totalTokens), width: 90, alignment: .trailing)
                                ExplorerCell(formatCost(row.totalCostUsd), width: 90, alignment: .trailing)
                                ExplorerCell(formatRelativeTimestamp(row.lastActivityAt), width: 90, alignment: .trailing)
                            }
                            .padding(.vertical, 8)
                            Divider()
                        }
                    }
                }
            }
        }
    }
}

private struct ExplorerHeader: View {
    let columns: [String]

    var body: some View {
        HStack(spacing: 10) {
            ForEach(columns, id: \.self) { title in
                Text(title)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(.bottom, 8)
    }
}

private struct ExplorerCell: View {
    let text: String
    let width: CGFloat
    var secondary: String? = nil
    var alignment: Alignment = .leading

    init(_ text: String, width: CGFloat, secondary: String? = nil, alignment: Alignment = .leading) {
        self.text = text
        self.width = width
        self.secondary = secondary
        self.alignment = alignment
    }

    var body: some View {
        VStack(alignment: alignment == .trailing ? .trailing : .leading, spacing: 2) {
            Text(text)
                .font(.caption)
                .lineLimit(2)
            if let secondary, !secondary.isEmpty {
                Text(secondary)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .frame(width: width, alignment: alignment)
    }
}

// MARK: - NSView Wrapper

final class UsagePaneView: NSView, PaneContent {
    let paneID = PaneID()
    let paneType = "analytics"
    let shouldPersist = true
    var title: String { "Usage" }

    override init(frame: NSRect) {
        super.init(frame: frame)
        _ = addSwiftUISubview(UsageView())
    }

    required init?(coder: NSCoder) { fatalError() }
}
