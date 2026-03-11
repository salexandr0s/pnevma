import SwiftUI
import Observation
import Cocoa
import Charts

// MARK: - Data Models

struct ProviderUsageSnapshot: Decodable, Identifiable {
    var id: String { provider }
    let provider: String
    let status: String
    let errorMessage: String?
    let days: [DailyTokenUsage]
    let totals: UsageSummary
    let topModels: [ModelShare]

    var displayName: String {
        switch provider {
        case "claude": return "Claude"
        case "codex": return "Codex"
        default: return provider.capitalized
        }
    }

    var logoAsset: String {
        provider == "claude" ? "anthropic-logo" : "openai-logo"
    }

    var hasData: Bool { totals.totalRequests > 0 }
}

struct DailyTokenUsage: Decodable, Identifiable {
    var id: String { date }
    let date: String
    let inputTokens: Int
    let outputTokens: Int
    let cacheReadTokens: Int
    let cacheWriteTokens: Int
    let requests: Int

    private static let dateParser: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withFullDate]
        return f
    }()

    var parsedDate: Date {
        Self.dateParser.date(from: date) ?? .distantPast
    }
}

struct UsageSummary: Decodable {
    let totalInputTokens: Int
    let totalOutputTokens: Int
    let totalCacheReadTokens: Int
    let totalCacheWriteTokens: Int
    let totalRequests: Int
    let avgDailyTokens: Int
    let peakDay: String?
    let peakDayTokens: Int
}

struct ModelShare: Decodable, Identifiable {
    var id: String { model }
    let model: String
    let tokens: Int
    let sharePercent: Double
}

// MARK: - Helpers

private func formatTokens(_ value: Int) -> String {
    value.formatted(.number.grouping(.automatic))
}

// MARK: - UsageView

struct UsageView: View {
    @State private var viewModel = UsageViewModel()

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Analytics")
                    .font(.headline)
                Spacer()
                Button { viewModel.load() } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.caption)
                }
                .buttonStyle(.plain)
                .keyboardShortcut("r", modifiers: .command)
                .accessibilityLabel("Refresh analytics")
            }
            .padding(12)

            Divider()

            Group {
                if let statusMessage = viewModel.statusMessage {
                    VStack(spacing: 8) {
                        if viewModel.isLoading {
                            ProgressView()
                                .controlSize(.small)
                        }
                        EmptyStateView(
                            icon: "chart.bar.xaxis",
                            title: statusMessage
                        )
                    }
                } else {
                    usageContent
                }
            }
        }
        .task { await viewModel.activate() }
        .accessibilityIdentifier("pane.analytics")
    }

    @ViewBuilder
    private var usageContent: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                ForEach(viewModel.providers) { snapshot in
                    ProviderCard(snapshot: snapshot)
                }
            }
            .padding(16)
        }
    }
}

// MARK: - ProviderCard

private struct ProviderCard: View {
    let snapshot: ProviderUsageSnapshot

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 12) {
                cardBody
            }
        } label: {
            providerHeader
        }
    }

    @ViewBuilder
    private var providerHeader: some View {
        HStack(spacing: 6) {
            Image(snapshot.logoAsset)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 14, height: 14)
            Text(snapshot.displayName)
                .font(.headline)
            Spacer()
            statusBadge
        }
    }

    @ViewBuilder
    private var statusBadge: some View {
        let (color, label) = badgeInfo
        HStack(spacing: 4) {
            Circle()
                .fill(color)
                .frame(width: 7, height: 7)
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var badgeInfo: (Color, String) {
        switch snapshot.status {
        case "ok":      return (.green, "OK")
        case "no_data": return (.yellow, "No Data")
        case "error":   return (.red, "Error")
        default:        return (.secondary, snapshot.status)
        }
    }

    @ViewBuilder
    private var cardBody: some View {
        switch snapshot.status {
        case "ok" where snapshot.hasData:
            statsGrid
            if !snapshot.topModels.isEmpty {
                topModelsSection
            }
            if !snapshot.days.isEmpty {
                dailyChart
            }
        case "ok":
            Text("No usage data for this period")
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.vertical, 8)
        case "no_data":
            Text("No session files found — use \(snapshot.displayName) to generate usage data")
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.vertical, 8)
        case "error":
            Text(snapshot.errorMessage ?? "An unknown error occurred")
                .foregroundStyle(.red)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 4)
        default:
            EmptyView()
        }
    }

    // MARK: Stats Grid

    private var statsGrid: some View {
        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
            StatCell(label: "Input Tokens",       value: formatTokens(snapshot.totals.totalInputTokens))
            StatCell(label: "Output Tokens",      value: formatTokens(snapshot.totals.totalOutputTokens))
            StatCell(label: "Cache Read",         value: formatTokens(snapshot.totals.totalCacheReadTokens))
            StatCell(label: "Cache Write",        value: formatTokens(snapshot.totals.totalCacheWriteTokens))
            StatCell(label: "Total Requests",     value: formatTokens(snapshot.totals.totalRequests))
            StatCell(label: "Avg Daily Tokens",   value: formatTokens(snapshot.totals.avgDailyTokens))
        }
    }

    // MARK: Top Models

    private var topModelsSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Top Models")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            ForEach(snapshot.topModels) { model in
                VStack(alignment: .leading, spacing: 2) {
                    HStack {
                        Text(model.model)
                            .font(.caption.monospacedDigit())
                            .lineLimit(1)
                        Spacer()
                        Text(formatTokens(model.tokens))
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                        Text(String(format: "%.1f%%", model.sharePercent))
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                            .frame(width: 44, alignment: .trailing)
                    }
                    GeometryReader { geo in
                        Capsule()
                            .fill(Color.accentColor.opacity(DesignTokens.Opacity.strong))
                            .frame(width: geo.size.width * model.sharePercent / 100, height: 4)
                    }
                    .frame(height: 4)
                }
            }
        }
    }

    // MARK: Daily Chart

    @ViewBuilder
    private var dailyChart: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Daily Token Usage (last 30 days)")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            let inputColor: Color = snapshot.provider == "claude" ? .blue : .indigo
            let outputColor: Color = .green

            Chart {
                ForEach(snapshot.days) { day in
                    BarMark(
                        x: .value("Date", day.parsedDate),
                        y: .value("Tokens", day.inputTokens)
                    )
                    .foregroundStyle(by: .value("Type", "Input"))

                    BarMark(
                        x: .value("Date", day.parsedDate),
                        y: .value("Tokens", day.outputTokens)
                    )
                    .foregroundStyle(by: .value("Type", "Output"))
                }
            }
            .chartForegroundStyleScale(["Input": inputColor, "Output": outputColor])
            .chartXAxis {
                AxisMarks(values: .stride(by: .day, count: 7)) { _ in
                    AxisGridLine()
                    AxisTick()
                    AxisValueLabel(format: .dateTime.month().day(), centered: true)
                }
            }
            .chartYAxis {
                AxisMarks { value in
                    AxisGridLine()
                    AxisValueLabel {
                        if let intVal = value.as(Int.self) {
                            Text(formatTokens(intVal))
                                .font(.caption.monospacedDigit())
                        }
                    }
                }
            }
            .frame(height: 180)
        }
    }
}

// MARK: - StatCell

private struct StatCell: View {
    let label: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.caption.monospacedDigit())
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(8)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(Color.secondary.opacity(0.08))
        )
        .accessibilityElement(children: .combine)
    }
}

// MARK: - ViewModel

@Observable @MainActor
final class UsageViewModel {
    private enum ViewState: Equatable {
        case waiting(String)
        case loading(String)
        case ready
        case failed(String)
    }

    var providers: [ProviderUsageSnapshot] = []
    private var viewState: ViewState = .waiting("Loading usage data...")

    @ObservationIgnored
    private let commandBus: (any CommandCalling)?
    @ObservationIgnored
    private let activationHub: ActiveWorkspaceActivationHub
    @ObservationIgnored
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
        case .waiting(let message), .loading(let message), .failed(let message):
            return message
        case .ready:
            return nil
        }
    }

    var isLoading: Bool {
        if case .loading = viewState { return true }
        return false
    }

    func activate() async {
        handleActivationState(activationHub.currentState)
    }

    @ObservationIgnored
    private var loadTask: Task<Void, Never>?

    func load(showLoadingState: Bool = true) {
        guard let bus = commandBus else {
            viewState = .failed("Usage is unavailable because the command bus is not configured.")
            return
        }
        if showLoadingState, providers.isEmpty {
            viewState = .loading("Loading usage data...")
        }
        loadTask?.cancel()
        loadTask = Task { [weak self] in
            guard let self else { return }
            do {
                struct DaysParams: Encodable { let days: Int }
                let result: [ProviderUsageSnapshot] = try await bus.call(
                    method: "usage.local_snapshot",
                    params: DaysParams(days: 30)
                )
                guard !Task.isCancelled else { return }
                self.providers = result
                self.viewState = .ready
            } catch {
                guard !Task.isCancelled else { return }
                self.handleLoadFailure(error)
            }
        }
    }

    private func handleActivationState(_ state: ActiveWorkspaceActivationState) {
        switch state {
        case .idle:
            load(showLoadingState: providers.isEmpty)
        case .opening:
            viewState = .waiting("Waiting for project activation...")
        case .open:
            load(showLoadingState: providers.isEmpty)
        case .failed(_, _, let message):
            viewState = .failed(message)
        case .closed:
            loadTask?.cancel()
            providers = []
            load(showLoadingState: true)
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

final class UsagePaneView: NSView, PaneContent {
    let paneID = PaneID()
    let paneType = "analytics"  // Keep internal type for backwards compatibility
    let shouldPersist = true
    var title: String { "Usage" }

    override init(frame: NSRect) {
        super.init(frame: frame)
        _ = addSwiftUISubview(UsageView())
    }

    required init?(coder: NSCoder) { fatalError() }
}
