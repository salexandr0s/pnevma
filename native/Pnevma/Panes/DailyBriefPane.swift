import SwiftUI
import Cocoa

// MARK: - Data Models

struct DailyBrief: Codable {
    let totalCost: Double
    let tasksCompleted: Int
    let tasksInProgress: Int
    let agentRuns: Int
    let recentEvents: [BriefEvent]
    let recommendations: [String]
}

struct BriefEvent: Identifiable, Codable {
    let id: String
    let timestamp: String
    let level: String
    let description: String
}

// MARK: - DailyBriefView

struct DailyBriefView: View {
    @StateObject private var viewModel = DailyBriefViewModel()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                // Big metrics
                HStack(spacing: 24) {
                    MetricCard(label: "Cost Today", value: viewModel.costDisplay)
                    MetricCard(label: "Completed", value: "\(viewModel.brief?.tasksCompleted ?? 0)")
                    MetricCard(label: "In Progress", value: "\(viewModel.brief?.tasksInProgress ?? 0)")
                    MetricCard(label: "Agent Runs", value: "\(viewModel.brief?.agentRuns ?? 0)")
                }

                // Recent events timeline
                GroupBox("Recent Events") {
                    if let events = viewModel.brief?.recentEvents, !events.isEmpty {
                        ForEach(events) { event in
                            HStack(alignment: .top, spacing: 8) {
                                Circle()
                                    .fill(eventColor(event.level))
                                    .frame(width: 8, height: 8)
                                    .padding(.top, 4)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(event.description)
                                        .font(.body)
                                    Text(event.timestamp)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            .padding(.vertical, 2)
                        }
                    } else {
                        Text("No events today")
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .center)
                            .padding()
                    }
                }

                // Recommendations
                GroupBox("Recommended Actions") {
                    if let recs = viewModel.brief?.recommendations, !recs.isEmpty {
                        ForEach(recs, id: \.self) { rec in
                            HStack(alignment: .top, spacing: 8) {
                                Image(systemName: "lightbulb")
                                    .foregroundStyle(.yellow)
                                Text(rec)
                                    .font(.body)
                            }
                            .padding(.vertical, 2)
                        }
                    } else {
                        Text("No recommendations")
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .padding(16)
        }
        .onAppear { viewModel.load() }
    }

    private func eventColor(_ level: String) -> Color {
        switch level {
        case "error": return .red
        case "warning": return .orange
        case "success": return .green
        default: return .blue
        }
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

final class DailyBriefViewModel: ObservableObject {
    @Published var brief: DailyBrief?

    var costDisplay: String {
        guard let cost = brief?.totalCost else { return "$0.00" }
        return String(format: "$%.2f", cost)
    }

    func load() {
        // Will call pnevma_call("project.daily_brief", "{}")
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
