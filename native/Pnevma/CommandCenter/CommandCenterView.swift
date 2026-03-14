import SwiftUI
import Observation

struct CommandCenterView: View {
    @Bindable var store: CommandCenterStore

    var body: some View {
        VStack(spacing: 0) {
            summaryBar
            Divider()
            controlsBar
            Divider()
            content
        }
        .frame(minWidth: 1080, minHeight: 720)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var summaryBar: some View {
        let summary = store.fleetSummary
        return ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                MetricChip(title: "Workspaces", value: "\(summary.workspaceCount)")
                MetricChip(title: "Active", value: "\(summary.activeCount)")
                MetricChip(title: "Queued", value: "\(summary.queuedCount)")
                MetricChip(title: "Idle", value: "\(summary.idleCount)")
                MetricChip(title: "Stuck", value: "\(summary.stuckCount)", tint: .orange)
                MetricChip(title: "Review", value: "\(summary.reviewNeededCount)", tint: .yellow)
                MetricChip(title: "Failed", value: "\(summary.failedCount)", tint: .red)
                MetricChip(title: "Retrying", value: "\(summary.retryingCount)", tint: .blue)
                MetricChip(title: "Slots", value: "\(summary.slotInUse)/\(summary.slotLimit)")
                MetricChip(title: "Cost Today", value: summary.costTodayUsd, currency: true)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
    }

    private var controlsBar: some View {
        HStack(spacing: 12) {
            TextField("Search tasks, workspaces, models, or branches", text: $store.searchQuery)
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 340)

            Picker("Filter", selection: $store.filter) {
                ForEach(CommandCenterStore.Filter.allCases) { filter in
                    Text(filter.title).tag(filter)
                }
            }
            .pickerStyle(.segmented)
            .frame(maxWidth: 520)

            Spacer()

            if let lastErrorMessage = store.lastErrorMessage, !lastErrorMessage.isEmpty {
                Label(lastErrorMessage, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .lineLimit(1)
                    .help(lastErrorMessage)
            }

            Button {
                store.refreshNow()
            } label: {
                Label(store.isRefreshing ? "Refreshing…" : "Refresh", systemImage: "arrow.clockwise")
            }
            .disabled(store.isRefreshing)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private var content: some View {
        HSplitView {
            runList
            detailPane
        }
    }

    private var runList: some View {
        Group {
            if store.visibleSections.isEmpty {
                ContentUnavailableView(
                    "No command-center runs",
                    systemImage: "square.grid.3x3.topleft.fill",
                    description: Text("Open a project workspace and dispatch work to populate the command center.")
                )
            } else {
                List(selection: $store.selectedRunID) {
                    ForEach(store.visibleSections) { section in
                        Section {
                            if let errorMessage = section.errorMessage {
                                HStack(spacing: 8) {
                                    Image(systemName: "exclamationmark.triangle.fill")
                                        .foregroundStyle(.orange)
                                    Text(errorMessage)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(2)
                                }
                                .padding(.vertical, 4)
                            }
                            ForEach(section.runs) { run in
                                CommandCenterRunRow(run: run)
                                    .tag(run.id)
                            }
                        } header: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(section.workspaceName)
                                Text(section.workspacePath)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                .listStyle(.inset)
            }
        }
        .frame(minWidth: 420, idealWidth: 520)
    }

    private var detailPane: some View {
        Group {
            if let run = store.selectedRun {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        HStack(alignment: .top) {
                            VStack(alignment: .leading, spacing: 6) {
                                Text(run.title)
                                    .font(.title2)
                                    .fontWeight(.semibold)
                                Text(run.workspaceName)
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                                if !run.subtitle.isEmpty {
                                    Text(run.subtitle)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            Spacer()
                            StateBadge(state: run.run.state)
                        }

                        actionButtons(for: run)

                        metadataGrid(for: run)

                        if let attention = run.run.attentionReason {
                            GroupBox("Attention") {
                                Text(attention.replacingOccurrences(of: "_", with: " ").capitalized)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                    }
                    .padding(20)
                }
            } else {
                ContentUnavailableView(
                    "Select a run",
                    systemImage: "cursorarrow.click",
                    description: Text("Choose a run from the list to inspect it and jump into the related tools.")
                )
            }
        }
        .frame(minWidth: 420)
    }

    @ViewBuilder
    private func actionButtons(for run: CommandCenterFleetRun) -> some View {
        if run.availableActionEnums.isEmpty {
            EmptyView()
        } else {
            GroupBox("Actions") {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 120), spacing: 10)], spacing: 10) {
                    ForEach(run.availableActionEnums) { action in
                        Button {
                            store.performAction(action, on: run)
                        } label: {
                            Label(action.title, systemImage: action.systemImage)
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)
                    }
                }
            }
        }
    }

    private func metadataGrid(for run: CommandCenterFleetRun) -> some View {
        GroupBox("Details") {
            VStack(alignment: .leading, spacing: 10) {
                DetailRow(label: "Task", value: run.run.taskID)
                DetailRow(label: "Task Status", value: run.run.taskStatus)
                DetailRow(label: "Session", value: run.run.sessionID)
                DetailRow(label: "Session Health", value: run.run.sessionHealth)
                DetailRow(label: "Provider", value: run.run.provider)
                DetailRow(label: "Model", value: run.run.model)
                DetailRow(label: "Profile", value: run.run.agentProfile)
                DetailRow(label: "Branch", value: run.run.branch)
                DetailRow(label: "Worktree", value: run.run.worktreeID)
                DetailRow(label: "Started", value: dateTime(run.run.startedAt))
                DetailRow(label: "Last Activity", value: dateTime(run.run.lastActivityAt))
                DetailRow(label: "Retry Count", value: "\(run.run.retryCount)")
                DetailRow(label: "Retry After", value: run.run.retryAfter.map(dateTime))
                DetailRow(label: "Cost", value: currency(run.run.costUsd))
                DetailRow(label: "Tokens", value: "\(run.run.tokensIn) in / \(run.run.tokensOut) out")
            }
        }
    }

    private func dateTime(_ date: Date) -> String {
        date.formatted(date: .abbreviated, time: .shortened)
    }

    private func currency(_ value: Double) -> String {
        value.formatted(.currency(code: "USD"))
    }
}

private struct CommandCenterRunRow: View {
    let run: CommandCenterFleetRun

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .center, spacing: 8) {
                Text(run.title)
                    .font(.body)
                    .lineLimit(1)
                Spacer()
                StateBadge(state: run.run.state)
            }

            if !run.subtitle.isEmpty {
                Text(run.subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            HStack(spacing: 10) {
                if let taskStatus = run.run.taskStatus {
                    Text(taskStatus)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Text(run.run.lastActivityAt, style: .relative)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                if run.run.costUsd > 0 {
                    Text(run.run.costUsd, format: .currency(code: "USD"))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, 4)
    }
}

private struct MetricChip: View {
    let title: String
    let valueText: String
    let tint: Color

    init(title: String, value: String, tint: Color = .secondary, currency: Bool = false) {
        self.title = title
        self.valueText = value
        self.tint = tint
    }

    init(title: String, value: Double, currency: Bool) {
        self.title = title
        self.valueText = value.formatted(.currency(code: "USD"))
        self.tint = .green
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(valueText)
                .font(.headline)
                .foregroundStyle(tint)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color.secondary.opacity(0.09))
        )
    }
}

private struct StateBadge: View {
    let state: String

    var body: some View {
        Text(state.replacingOccurrences(of: "_", with: " ").capitalized)
            .font(.caption)
            .fontWeight(.semibold)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(color.opacity(0.18), in: Capsule())
            .foregroundStyle(color)
    }

    private var color: Color {
        switch state {
        case "running": return .green
        case "idle": return .yellow
        case "stuck": return .orange
        case "review_needed": return .yellow
        case "retrying": return .blue
        case "failed": return .red
        case "queued": return .purple
        default: return .secondary
        }
    }
}

private struct DetailRow: View {
    let label: String
    let value: String?

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 110, alignment: .leading)
            Text(value ?? "—")
                .font(.body)
                .textSelection(.enabled)
            Spacer(minLength: 0)
        }
    }
}
