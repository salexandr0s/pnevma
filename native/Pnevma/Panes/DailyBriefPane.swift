import SwiftUI
import Cocoa

// MARK: - Data Models

struct DailyBrief: Decodable {
    let generatedAt: String
    let totalTasks: Int
    let readyTasks: Int
    let reviewTasks: Int
    let blockedTasks: Int
    let failedTasks: Int
    let totalCostUsd: Double
    let recentEvents: [BriefEvent]
    let recommendedActions: [String]
    let activeSessions: Int
    let costLast24hUsd: Double
    let tasksCompletedLast24h: Int
    let tasksFailedLast24h: Int
    let staleReadyCount: Int
    let longestRunningTask: String?
    let topCostTasks: [TopCostTask]
}

struct BriefEvent: Identifiable, Decodable {
    let timestamp: String
    let kind: String
    let summary: String
    let payload: JSONValue

    var id: String { "\(timestamp)-\(kind)-\(summary)" }

    var level: EventLevel {
        switch kind {
        case "TaskFailed":        return .error
        case "TaskBlocked":       return .warning
        case "TaskCompleted":     return .success
        case "TaskDispatched",
             "TaskStarted":       return .info
        default:                  return .info
        }
    }

    enum EventLevel {
        case error, warning, success, info

        var color: Color {
            switch self {
            case .error:   return .red
            case .warning: return .orange
            case .success: return .green
            case .info:    return .blue
            }
        }
    }
}

struct TopCostTask: Decodable, Identifiable {
    let taskId: String
    let title: String
    let costUsd: Double

    var id: String { taskId }
}

// MARK: - DailyBriefView

struct DailyBriefView: View {
    @StateObject private var viewModel = DailyBriefViewModel()

    var body: some View {
        Group {
            if let statusMessage = viewModel.statusMessage {
                EmptyStateView(
                    icon: "calendar.badge.clock",
                    title: statusMessage
                )
            } else if let brief = viewModel.brief {
                contentView(brief: brief)
            }
        }
        .onAppear { viewModel.activate() }
    }

    @ViewBuilder
    private func contentView(brief: DailyBrief) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {

                // Row 1 — task counts
                HStack(spacing: 12) {
                    MetricCard(label: "Total Tasks",  value: "\(brief.totalTasks)")
                    MetricCard(label: "Ready",        value: "\(brief.readyTasks)")
                    MetricCard(label: "Review",       value: "\(brief.reviewTasks)")
                    MetricCard(label: "Blocked",      value: "\(brief.blockedTasks)")
                    MetricCard(label: "Failed",       value: "\(brief.failedTasks)")
                }

                // Row 2 — cost / activity
                HStack(spacing: 12) {
                    MetricCard(label: "Total Cost",       value: formatCost(brief.totalCostUsd))
                    MetricCard(label: "Cost (24 h)",      value: formatCost(brief.costLast24hUsd))
                    MetricCard(label: "Completed (24 h)", value: "\(brief.tasksCompletedLast24h)")
                    MetricCard(label: "Failed (24 h)",    value: "\(brief.tasksFailedLast24h)")
                    MetricCard(label: "Active Sessions",  value: "\(brief.activeSessions)")
                }

                // Stale + longest running summary
                if brief.staleReadyCount > 0 || brief.longestRunningTask != nil {
                    HStack(spacing: 16) {
                        if brief.staleReadyCount > 0 {
                            Label(
                                "\(brief.staleReadyCount) stale ready task\(brief.staleReadyCount == 1 ? "" : "s")",
                                systemImage: "clock.badge.exclamationmark"
                            )
                            .font(.caption)
                            .foregroundStyle(.orange)
                        }
                        if let longest = brief.longestRunningTask {
                            Label("Longest running: \(longest)", systemImage: "timer")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, 2)
                }

                // Recent events timeline
                GroupBox("Recent Events") {
                    if brief.recentEvents.isEmpty {
                        Text("No events today")
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .center)
                            .padding()
                    } else {
                        VStack(alignment: .leading, spacing: 0) {
                            ForEach(brief.recentEvents) { event in
                                HStack(alignment: .top, spacing: 8) {
                                    Circle()
                                        .fill(event.level.color)
                                        .frame(width: 8, height: 8)
                                        .padding(.top, 5)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(event.summary)
                                            .font(.body)
                                        Text(formatTimestamp(event.timestamp))
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                                .padding(.vertical, 4)
                            }
                        }
                    }
                }

                // Recommended actions
                GroupBox("Recommended Actions") {
                    if brief.recommendedActions.isEmpty {
                        Text("No recommendations")
                            .foregroundStyle(.secondary)
                    } else {
                        VStack(alignment: .leading, spacing: 4) {
                            ForEach(brief.recommendedActions, id: \.self) { rec in
                                HStack(alignment: .top, spacing: 8) {
                                    Image(systemName: "lightbulb")
                                        .foregroundStyle(.yellow)
                                    Text(rec)
                                        .font(.body)
                                }
                                .padding(.vertical, 2)
                            }
                        }
                    }
                }

                // Top cost tasks
                if !brief.topCostTasks.isEmpty {
                    GroupBox("Top Cost Tasks") {
                        VStack(alignment: .leading, spacing: 4) {
                            ForEach(brief.topCostTasks) { task in
                                HStack {
                                    Text(task.title)
                                        .font(.body)
                                        .lineLimit(1)
                                    Spacer()
                                    Text(formatCost(task.costUsd))
                                        .font(.body.monospacedDigit())
                                        .foregroundStyle(.secondary)
                                }
                                .padding(.vertical, 2)
                            }
                        }
                    }
                }
            }
            .padding(16)
        }
    }

    private func formatCost(_ usd: Double) -> String {
        String(format: "$%.2f", usd)
    }

    private func formatTimestamp(_ raw: String) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: raw) {
            return RelativeDateTimeFormatter().localizedString(for: date, relativeTo: Date())
        }
        // Fallback: trim the T/Z noise for readability
        return raw
            .replacingOccurrences(of: "T", with: " ")
            .prefix(19)
            .description
    }
}

// MARK: - MetricCard

struct MetricCard: View {
    let label: String
    let value: String

    var body: some View {
        VStack(spacing: 4) {
            Text(value)
                .font(.title)
                .fontWeight(.bold)
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
    }
}

// MARK: - ViewModel

@MainActor
final class DailyBriefViewModel: ObservableObject {
    private enum ViewState: Equatable {
        case waiting(String)
        case loading
        case ready
        case failed(String)
    }

    @Published var brief: DailyBrief?
    @Published private var viewState: ViewState = .waiting("Open a project to load the daily brief.")

    private let commandBus: (any CommandCalling)?
    private let activationHub: ActiveWorkspaceActivationHub
    private var activationObserverID: UUID?

    init(
        commandBus: (any CommandCalling)? = CommandBus.shared,
        activationHub: ActiveWorkspaceActivationHub = .shared
    ) {
        self.commandBus = commandBus
        self.activationHub = activationHub

        activationObserverID = activationHub.addObserver { [weak self] state in
            Task { @MainActor [weak self] in
                self?.handleActivationState(state)
            }
        }
    }

    deinit {
        if let activationObserverID {
            activationHub.removeObserver(activationObserverID)
        }
    }

    var statusMessage: String? {
        switch viewState {
        case .waiting(let message), .failed(let message):
            return message
        case .loading:
            return "Loading daily brief..."
        case .ready:
            return nil
        }
    }

    func activate() {
        handleActivationState(activationHub.currentState)
    }

    func load() {
        guard let bus = commandBus else {
            viewState = .failed("Daily brief is unavailable because the command bus is not configured.")
            return
        }
        if brief == nil {
            viewState = .loading
        }
        Task { [weak self] in
            guard let self else { return }
            do {
                let result: DailyBrief = try await bus.call(method: "project.daily_brief", params: nil)
                self.brief = result
                self.viewState = .ready
            } catch {
                self.handleLoadFailure(error)
            }
        }
    }

    private func handleActivationState(_ state: ActiveWorkspaceActivationState) {
        switch state {
        case .idle:
            viewState = .waiting("Waiting for project activation...")
        case .opening:
            viewState = .waiting("Waiting for project activation...")
        case .open:
            load()
        case .failed(_, _, let message):
            viewState = .failed(message)
        case .closed:
            brief = nil
            viewState = .waiting("Open a project to load the daily brief.")
        }
    }

    private func handleLoadFailure(_ error: Error) {
        if PnevmaError.isProjectNotReady(error) {
            viewState = .waiting("Waiting for project activation...")
            return
        }
        viewState = .failed(error.localizedDescription)
    }
}

// MARK: - NSView Wrapper

final class DailyBriefPaneView: NSView, PaneContent {
    let paneID = PaneID()
    let paneType = "daily_brief"
    let shouldPersist = false
    var title: String { "Daily Brief" }

    override init(frame: NSRect) {
        super.init(frame: frame)
        _ = addSwiftUISubview(DailyBriefView())
    }

    required init?(coder: NSCoder) { fatalError() }
}
