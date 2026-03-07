import SwiftUI
import Cocoa
import Charts

// MARK: - Data Models

struct CostDataPoint: Identifiable {
    let id = UUID()
    let date: Date
    let cost: Double
    let model: String
}

struct ErrorSignature: Identifiable {
    let id = UUID()
    let signature: String
    let count: Int
    let lastSeen: Date
}

// MARK: - AnalyticsView

struct AnalyticsView: View {
    @StateObject private var viewModel = AnalyticsViewModel()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                // Cost overview
                GroupBox("Cost Overview") {
                    Chart(viewModel.costData) { point in
                        BarMark(
                            x: .value("Date", point.date, unit: .day),
                            y: .value("Cost", point.cost)
                        )
                        .foregroundStyle(by: .value("Model", point.model))
                    }
                    .frame(height: 200)
                }

                // Model comparison
                GroupBox("Model Comparison") {
                    Chart(viewModel.modelBreakdown, id: \.model) { item in
                        SectorMark(
                            angle: .value("Cost", item.cost),
                            innerRadius: .ratio(0.5)
                        )
                        .foregroundStyle(by: .value("Model", item.model))
                    }
                    .frame(height: 180)
                }

                // Error hotspots
                GroupBox("Error Hotspots") {
                    if viewModel.errors.isEmpty {
                        Text("No errors recorded")
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .center)
                            .padding()
                    } else {
                        ForEach(viewModel.errors) { error in
                            HStack {
                                Text(error.signature)
                                    .font(.body)
                                    .lineLimit(1)
                                Spacer()
                                Text("\(error.count)")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(Capsule().fill(Color.red.opacity(0.15)))
                            }
                            .padding(.vertical, 2)
                        }
                    }
                }
            }
            .padding(16)
        }
        .onAppear { viewModel.load() }
    }
}

// MARK: - ViewModel

final class AnalyticsViewModel: ObservableObject {
    @Published var costData: [CostDataPoint] = []
    @Published var modelBreakdown: [(model: String, cost: Double)] = []
    @Published var errors: [ErrorSignature] = []

    func load() {
        // Will call pnevma_call("usage.breakdown", ...) etc.
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
