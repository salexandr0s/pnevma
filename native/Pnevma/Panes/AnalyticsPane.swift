import SwiftUI
import Cocoa
import Charts

// MARK: - Data Models

struct UsageBreakdown: Decodable, Identifiable {
    var id: String { provider }
    let provider: String
    let tokensIn: Int
    let tokensOut: Int
    let estimatedUsd: Double
    let recordCount: Int
}

struct UsageByModel: Decodable, Identifiable {
    var id: String { provider + ":" + model }
    let provider: String
    let model: String
    let tokensIn: Int
    let tokensOut: Int
    let estimatedUsd: Double
}

struct UsageDailyTrend: Decodable, Identifiable {
    var id: String { date }
    let date: String
    let tokensIn: Int
    let tokensOut: Int
    let estimatedUsd: Double
}

struct ErrorSignatureItem: Decodable, Identifiable {
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

// MARK: - AnalyticsView

struct AnalyticsView: View {
    @StateObject private var viewModel = AnalyticsViewModel()

    var body: some View {
        Group {
            if let statusMessage = viewModel.statusMessage {
                EmptyStateView(
                    icon: "chart.bar.xaxis",
                    title: statusMessage
                )
            } else {
                analyticsContent
            }
        }
        .onAppear { viewModel.activate() }
    }

    @ViewBuilder
    private var analyticsContent: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {

                // Cost Overview — daily trend bar chart
                GroupBox("Cost Overview") {
                    if viewModel.dailyTrend.isEmpty {
                        Text("No cost data available")
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .center)
                            .padding()
                    } else {
                        Chart(viewModel.dailyTrend) { point in
                            BarMark(
                                x: .value("Date", point.date),
                                y: .value("Cost (USD)", point.estimatedUsd)
                            )
                        }
                        .frame(height: 200)
                    }
                }

                // Model Comparison — pie/sector chart
                GroupBox("Model Comparison") {
                    if viewModel.byModel.isEmpty {
                        Text("No model data available")
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .center)
                            .padding()
                    } else {
                        Chart(viewModel.byModel) { item in
                            SectorMark(
                                angle: .value("Cost", item.estimatedUsd),
                                innerRadius: .ratio(0.5)
                            )
                            .foregroundStyle(by: .value("Model", item.model))
                        }
                        .frame(height: 180)
                    }
                }

                // Provider Breakdown
                GroupBox("Provider Breakdown") {
                    if viewModel.breakdown.isEmpty {
                        Text("No provider data available")
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .center)
                            .padding()
                    } else {
                        VStack(spacing: 0) {
                            ForEach(viewModel.breakdown) { item in
                                HStack {
                                    Text(item.provider)
                                        .font(.body)
                                    Spacer()
                                    VStack(alignment: .trailing, spacing: 2) {
                                        Text(String(format: "$%.4f", item.estimatedUsd))
                                            .font(.body.monospacedDigit())
                                        Text("\(item.tokensIn + item.tokensOut) tokens · \(item.recordCount) records")
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                                .padding(.vertical, 6)
                                Divider()
                            }
                        }
                    }
                }

                // Error Hotspots
                GroupBox("Error Hotspots") {
                    if viewModel.errors.isEmpty {
                        Text("No errors recorded")
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .center)
                            .padding()
                    } else {
                        VStack(spacing: 0) {
                            ForEach(viewModel.errors) { error in
                                VStack(alignment: .leading, spacing: 4) {
                                    HStack(alignment: .top) {
                                        Text(error.canonicalMessage)
                                            .font(.body)
                                            .lineLimit(2)
                                        Spacer()
                                        Text("\(error.totalCount)")
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                            .padding(.horizontal, 6)
                                            .padding(.vertical, 2)
                                            .background(Capsule().fill(Color.red.opacity(0.15)))
                                    }
                                    HStack(spacing: 6) {
                                        Text(error.category)
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                            .padding(.horizontal, 5)
                                            .padding(.vertical, 1)
                                            .background(
                                                RoundedRectangle(cornerRadius: 3)
                                                    .fill(Color.secondary.opacity(0.12))
                                            )
                                        if let hint = error.remediationHint {
                                            Text(hint)
                                                .font(.caption)
                                                .foregroundStyle(.secondary)
                                                .lineLimit(1)
                                        }
                                    }
                                }
                                .padding(.vertical, 6)
                                Divider()
                            }
                        }
                    }
                }
            }
            .padding(16)
        }
    }
}

// MARK: - ViewModel

@MainActor
final class AnalyticsViewModel: ObservableObject {
    private enum ViewState: Equatable {
        case waiting(String)
        case loading(String)
        case ready
        case failed(String)
    }

    @Published var breakdown: [UsageBreakdown] = []
    @Published var byModel: [UsageByModel] = []
    @Published var dailyTrend: [UsageDailyTrend] = []
    @Published var errors: [ErrorSignatureItem] = []

    @Published private var viewState: ViewState = .waiting("Open a project to load analytics.")

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
        case .waiting(let message), .loading(let message), .failed(let message):
            return message
        case .ready:
            return nil
        }
    }

    func activate() {
        handleActivationState(activationHub.currentState)
    }

    func load(showLoadingState: Bool = true) {
        guard let bus = commandBus else {
            viewState = .failed("Analytics is unavailable because the command bus is not configured.")
            return
        }
        if showLoadingState, breakdown.isEmpty {
            viewState = .loading("Loading analytics...")
        }
        Task { [weak self] in
            guard let self else { return }
            do {
                struct DaysParams: Encodable { let days: Int? }
                struct LimitParams: Encodable { let limit: Int? }

                async let fetchBreakdown: [UsageBreakdown] = bus.call(
                    method: "analytics.usage_breakdown",
                    params: DaysParams(days: nil)
                )
                async let fetchByModel: [UsageByModel] = bus.call(
                    method: "analytics.usage_by_model",
                    params: nil
                )
                async let fetchTrend: [UsageDailyTrend] = bus.call(
                    method: "analytics.usage_daily_trend",
                    params: DaysParams(days: nil)
                )
                async let fetchErrors: [ErrorSignatureItem] = bus.call(
                    method: "analytics.error_signatures",
                    params: LimitParams(limit: nil)
                )

                let (breakdown, byModel, trend, errors) = try await (
                    fetchBreakdown,
                    fetchByModel,
                    fetchTrend,
                    fetchErrors
                )
                self.breakdown = breakdown
                self.byModel = byModel
                self.dailyTrend = trend
                self.errors = errors
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
            load(showLoadingState: breakdown.isEmpty)
        case .failed(_, _, let message):
            viewState = .failed(message)
        case .closed:
            viewState = .waiting("Open a project to load analytics.")
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

final class AnalyticsPaneView: NSView, PaneContent {
    let paneID = PaneID()
    let paneType = "analytics"
    let shouldPersist = false
    var title: String { "Analytics" }

    override init(frame: NSRect) {
        super.init(frame: frame)
        _ = addSwiftUISubview(AnalyticsView())
    }

    required init?(coder: NSCoder) { fatalError() }
}
