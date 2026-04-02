import SwiftUI

struct CommandCenterInspectorView: View {
    let run: CommandCenterFleetRun
    let performAction: (CommandCenterAction) -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DesignTokens.Spacing.md) {
                inspectorHeader
                inspectorActions
                inspectorRunContext
                if let attentionSummary = run.attentionSummary {
                    inspectorIncident(attentionSummary: attentionSummary)
                }
                inspectorTimeline
            }
            .padding(DesignTokens.Spacing.md)
        }
        .background(ChromeSurfaceStyle.inspector.color)
    }

    private var inspectorHeader: some View {
        CommandCenterInspectorGroup(title: "Selected run", systemImage: "scope") {
            VStack(alignment: .leading, spacing: DesignTokens.Spacing.sm) {
                HStack(alignment: .top, spacing: DesignTokens.Spacing.sm) {
                    VStack(alignment: .leading, spacing: DesignTokens.Spacing.xs) {
                        Text(run.title)
                            .font(.title3.bold())
                            .lineLimit(2)
                        Text(run.workspaceName)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        if !run.subtitle.isEmpty {
                            Text(run.subtitle)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    Spacer(minLength: DesignTokens.Spacing.sm)
                    StateBadge(run: run)
                }

                HStack(spacing: DesignTokens.Spacing.sm) {
                    InspectorValueChip(label: "Last output") {
                        Text(run.run.lastActivityAt, style: .relative)
                    }
                    InspectorValueChip(label: "Started") {
                        Text(run.run.startedAt, style: .relative)
                    }
                    if run.run.retryCount > 0 {
                        InspectorValueChip(label: "Retries") {
                            Text("\(run.run.retryCount)")
                        }
                    }
                }
            }
        }
    }

    private var inspectorActions: some View {
        CommandCenterInspectorGroup(title: "Quick actions", systemImage: "bolt.fill") {
            VStack(alignment: .leading, spacing: DesignTokens.Spacing.sm) {
                if !run.primaryActions.isEmpty {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 96), spacing: DesignTokens.Spacing.sm)], spacing: DesignTokens.Spacing.sm) {
                        ForEach(run.primaryActions.indices, id: \.self) { index in
                            let action = run.primaryActions[index]
                            if index == 0 {
                                Button(action.title, systemImage: action.systemImage) {
                                    performAction(action)
                                }
                                .frame(maxWidth: .infinity)
                                .buttonStyle(BorderedProminentButtonStyle())
                                .controlSize(.small)
                            } else {
                                Button(action.title, systemImage: action.systemImage) {
                                    performAction(action)
                                }
                                .frame(maxWidth: .infinity)
                                .buttonStyle(BorderedButtonStyle())
                                .controlSize(.small)
                            }
                        }
                    }
                }

                if !run.destructiveActions.isEmpty {
                    Divider()
                    HStack(spacing: DesignTokens.Spacing.sm) {
                        ForEach(run.destructiveActions) { action in
                            Button(action.title, systemImage: action.systemImage, role: .destructive) {
                                performAction(action)
                            }
                            .frame(maxWidth: .infinity)
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                        }
                    }
                }
            }
        }
    }

    private var inspectorRunContext: some View {
        CommandCenterInspectorGroup(title: "Run context", systemImage: "point.3.connected.trianglepath.dotted") {
            VStack(alignment: .leading, spacing: DesignTokens.Spacing.md) {
                InspectorSectionBlock(title: "Operational") {
                    InspectorDetailRow(label: "Task status", value: run.taskStatusDisplay)
                    InspectorDetailRow(label: "Session health", value: run.sessionHealthDisplay)
                    InspectorDetailRow(label: "Session", value: run.run.sessionID)
                    InspectorDetailRow(label: "Retry after", value: run.run.retryAfter.map(formatDateTime))
                }

                Divider()

                InspectorSectionBlock(title: "Code context") {
                    InspectorDetailRow(label: "Branch", value: run.run.branch)
                    InspectorDetailRow(label: "Worktree", value: run.run.worktreeID)
                    InspectorDetailRow(label: "Worktree path", value: run.run.worktreePath)
                    InspectorDetailRow(label: "Primary file", value: run.run.primaryFilePath)
                    if !run.run.scopePaths.isEmpty {
                        VStack(alignment: .leading, spacing: DesignTokens.Spacing.xs) {
                            Text("Related files")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            ForEach(run.run.scopePaths.prefix(4), id: \.self) { path in
                                Text(path)
                                    .font(.caption.monospaced())
                                    .foregroundStyle(.primary)
                                    .textSelection(.enabled)
                                    .lineLimit(1)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }

                Divider()

                InspectorSectionBlock(title: "Provider + usage") {
                    InspectorDetailRow(label: "Provider", value: run.run.provider)
                    InspectorDetailRow(label: "Model", value: run.run.model)
                    InspectorDetailRow(label: "Profile", value: run.run.agentProfile)
                    InspectorDetailRow(label: "Cost", value: run.run.costUsd.formatted(.currency(code: "USD")))
                    InspectorDetailRow(label: "Tokens", value: "\(run.run.tokensIn) in / \(run.run.tokensOut) out")
                }
            }
        }
    }

    private func inspectorIncident(attentionSummary: String) -> some View {
        CommandCenterInspectorGroup(title: "Incident detail", systemImage: "exclamationmark.triangle.fill") {
            Text(attentionSummary)
                .font(.caption)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var inspectorTimeline: some View {
        CommandCenterInspectorGroup(title: "Timeline", systemImage: "clock.arrow.circlepath") {
            VStack(spacing: DesignTokens.Spacing.sm) {
                ForEach(run.timelineEntries.prefix(6)) { entry in
                    HStack(alignment: .top, spacing: DesignTokens.Spacing.sm) {
                        Circle()
                            .fill(Color(nsColor: .controlAccentColor))
                            .frame(width: 7, height: 7)
                            .padding(.top, 5)
                        VStack(alignment: .leading, spacing: 2) {
                            HStack {
                                Text(entry.title)
                                    .font(.caption.bold())
                                Spacer(minLength: DesignTokens.Spacing.sm)
                                Text(entry.timestamp, style: .relative)
                                    .font(.caption.monospacedDigit())
                                    .foregroundStyle(.secondary)
                            }
                            Text(entry.detail)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
    }

    private func formatDateTime(_ date: Date) -> String {
        date.formatted(date: .abbreviated, time: .shortened)
    }
}

struct CommandCenterInspectorGroup<Content: View>: View {
    let title: String
    let systemImage: String
    @ViewBuilder let content: Content

    var body: some View {
        GroupBox {
            content
        } label: {
            Label(title, systemImage: systemImage)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct InspectorDetailRow: View {
    let label: String
    let value: String?

    var body: some View {
        LabeledContent(label) {
            Text(value ?? "—")
                .foregroundStyle(value == nil ? .tertiary : .primary)
                .textSelection(.enabled)
        }
        .font(.caption)
    }
}

struct InspectorSectionBlock<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.sm) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            content
        }
    }
}

struct InspectorValueChip<Value: View>: View {
    let label: String
    let value: Value

    init(label: String, @ViewBuilder value: () -> Value) {
        self.label = label
        self.value = value()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
            value
                .font(.caption.bold())
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(ChromeSurfaceStyle.groupedCard.color)
        )
    }
}
