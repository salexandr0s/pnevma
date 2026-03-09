import SwiftUI
import Observation
import Cocoa

// MARK: - Timestamp Formatting

private let briefISOFormatter: ISO8601DateFormatter = {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return f
}()

private let briefISOFormatterNoFraction: ISO8601DateFormatter = {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime]
    return f
}()

private let briefRelativeFormatter = RelativeDateTimeFormatter()

private func formatRelativeTimestamp(_ raw: String) -> String {
    let date = briefISOFormatter.date(from: raw)
        ?? briefISOFormatterNoFraction.date(from: raw)
    if let date {
        return briefRelativeFormatter.localizedString(for: date, relativeTo: Date.now)
    }
    return raw
        .replacing("T", with: " ")
        .prefix(19)
        .description
}

// MARK: - Event Grouping

private struct GroupedEvent: Identifiable {
    let id: String
    let kind: String
    let level: BriefEvent.EventLevel
    let events: [BriefEvent]
    var count: Int { events.count }
    var latestTimestamp: String { events.first?.timestamp ?? "" }
}

private func groupConsecutiveEvents(_ events: [BriefEvent]) -> [GroupedEvent] {
    guard !events.isEmpty else { return [] }
    var groups: [GroupedEvent] = []
    var currentKind = events[0].kind
    var currentBatch = [events[0]]

    for event in events.dropFirst() {
        if event.kind == currentKind {
            currentBatch.append(event)
        } else {
            groups.append(GroupedEvent(
                id: "group-\(groups.count)",
                kind: currentKind,
                level: currentBatch[0].level,
                events: currentBatch
            ))
            currentKind = event.kind
            currentBatch = [event]
        }
    }
    groups.append(GroupedEvent(
        id: "group-\(groups.count)",
        kind: currentKind,
        level: currentBatch[0].level,
        events: currentBatch
    ))
    return groups
}

// MARK: - GroupedEventRow

private struct GroupedEventRow: View {
    let group: GroupedEvent
    @State private var isExpanded = false

    var body: some View {
        if group.count == 1, let event = group.events.first {
            HStack(spacing: 6) {
                Circle()
                    .fill(group.level.color)
                    .frame(width: 6, height: 6)
                Text(event.summary)
                    .font(.callout)
                    .lineLimit(1)
                Spacer()
                Text(formatRelativeTimestamp(event.timestamp))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.vertical, 4)
        } else {
            VStack(alignment: .leading, spacing: 0) {
                Button(action: { withAnimation(.easeInOut(duration: 0.15)) { isExpanded.toggle() } }) {
                    HStack(spacing: 6) {
                        Circle()
                            .fill(group.level.color)
                            .frame(width: 6, height: 6)
                        Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .frame(width: 10)
                        Text(group.kind)
                            .font(.callout)
                        Text("\u{00d7}\(group.count)")
                            .font(.caption.monospacedDigit())
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(Capsule().fill(group.level.color.opacity(0.15)))
                        Spacer()
                        Text(formatRelativeTimestamp(group.latestTimestamp))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .buttonStyle(.plain)
                .padding(.vertical, 4)

                if isExpanded {
                    ForEach(group.events) { event in
                        HStack(spacing: 6) {
                            Text(event.summary)
                                .font(.callout)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                            Spacer()
                            Text(formatRelativeTimestamp(event.timestamp))
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                        .padding(.leading, 22)
                        .padding(.vertical, 2)
                    }
                }
            }
        }
    }
}

// MARK: - DailyBriefView

struct DailyBriefView: View {
    @State private var viewModel = DailyBriefViewModel()

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
        .task { await viewModel.activate() }
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

                // Recommended actions (moved before events)
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

                // Recent events timeline (grouped)
                GroupBox("Recent Events") {
                    if brief.recentEvents.isEmpty {
                        Text("No events today")
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .center)
                            .padding()
                    } else {
                        ScrollView {
                            VStack(alignment: .leading, spacing: 0) {
                                ForEach(groupConsecutiveEvents(brief.recentEvents)) { group in
                                    GroupedEventRow(group: group)
                                }
                            }
                        }
                        .frame(maxHeight: 280)
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
        usd.formatted(.currency(code: "USD"))
    }
}

// MARK: - MetricCard

struct MetricCard: View {
    let label: String
    let value: String
    @Environment(GhosttyThemeProvider.self) var theme

    var body: some View {
        VStack(spacing: 4) {
            Text(value)
                .font(.title)
                .bold()
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color(nsColor: theme.foregroundColor).opacity(0.06))
        )
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
