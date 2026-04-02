import SwiftUI

struct CommandCenterSidebarView: View {
    let store: CommandCenterStore
    let onIncidentSelection: (CommandCenterIncident) -> Void
    let onWorkspaceSelection: (UUID?) -> Void

    var body: some View {
        List {
            Section {
                if store.attentionItems.isEmpty {
                    EmptyRailState(
                        title: "No active incidents",
                        detail: "Stuck, failed, and review-blocked runs will surface here."
                    )
                    .listRowInsets(EdgeInsets(top: 8, leading: 12, bottom: 8, trailing: 12))
                    .listRowBackground(Color.clear)
                } else {
                    ForEach(store.attentionItems) { incident in
                        AttentionIncidentRow(incident: incident) {
                            onIncidentSelection(incident)
                        }
                        .listRowInsets(EdgeInsets(top: 4, leading: 12, bottom: 4, trailing: 12))
                        .listRowBackground(Color.clear)
                    }
                }
            } header: {
                CommandCenterSectionHeader(title: "Attention Queue", systemImage: "bell.badge.fill")
            }

            Section {
                WorkspaceScopeRow(
                    title: "All workspaces",
                    subtitle: "Fleet-wide view",
                    cluster: nil,
                    isSelected: store.selectedWorkspaceID == nil,
                    action: { onWorkspaceSelection(nil) }
                )
                .listRowInsets(EdgeInsets(top: 4, leading: 12, bottom: 4, trailing: 12))
                .listRowBackground(Color.clear)

                ForEach(store.workspaceClusters) { cluster in
                    WorkspaceScopeRow(
                        title: cluster.workspaceName,
                        subtitle: cluster.workspacePath,
                        cluster: cluster,
                        isSelected: store.selectedWorkspaceID == cluster.id,
                        action: { onWorkspaceSelection(cluster.id) }
                    )
                    .listRowInsets(EdgeInsets(top: 4, leading: 12, bottom: 4, trailing: 12))
                    .listRowBackground(Color.clear)
                }
            } header: {
                CommandCenterSectionHeader(title: "Workspaces", systemImage: "square.grid.2x2.fill")
            }
        }
        .listStyle(.sidebar)
        .scrollContentBackground(.hidden)
        .background(ChromeSurfaceStyle.sidebar.color)
    }
}

struct CommandCenterSectionHeader: View {
    let title: String
    let systemImage: String

    var body: some View {
        Label(title, systemImage: systemImage)
            .font(.caption)
            .foregroundStyle(.secondary)
            .textCase(nil)
    }
}

struct AttentionIncidentRow: View {
    let incident: CommandCenterIncident
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: DesignTokens.Spacing.sm) {
                Image(systemName: incident.kind.systemImage)
                    .foregroundStyle(CommandCenterVisualTone.incidentColor(for: incident))
                    .frame(width: 16)

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: DesignTokens.Spacing.sm) {
                        Text(incident.title)
                            .font(.caption.bold())
                            .foregroundStyle(.primary)
                        Spacer(minLength: DesignTokens.Spacing.sm)
                        Text("\(incident.count)")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                    Text(incident.summary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                    if let oldestAt = incident.oldestAt {
                        Text("Oldest \(oldestAt.formatted(date: .omitted, time: .shortened))")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(ChromeSurfaceStyle.groupedCard.color)
            )
            .overlay(alignment: .leading) {
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(CommandCenterVisualTone.incidentColor(for: incident).opacity(0.18), lineWidth: 1)
            }
        }
        .buttonStyle(.plain)
    }
}

struct WorkspaceScopeRow: View {
    let title: String
    let subtitle: String
    let cluster: CommandCenterWorkspaceCluster?
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: DesignTokens.Spacing.xs) {
                HStack(spacing: DesignTokens.Spacing.sm) {
                    Text(title)
                        .font(.caption.bold())
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    Spacer(minLength: DesignTokens.Spacing.sm)
                    if let cluster {
                        Text("\(cluster.totalCount)")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                if let cluster {
                    Text(summaryText(for: cluster))
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .lineLimit(2)
                    if let errorMessage = cluster.errorMessage {
                        Text(errorMessage)
                            .font(.caption)
                            .foregroundStyle(Color(nsColor: .systemOrange))
                            .lineLimit(2)
                    }
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(isSelected ? ChromeSurfaceStyle.sidebar.selectionColor : ChromeSurfaceStyle.groupedCard.color)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(borderColor, lineWidth: 1)
            }
        }
        .buttonStyle(.plain)
    }

    private var borderColor: Color {
        if isSelected {
            return Color(nsColor: .controlAccentColor).opacity(0.45)
        }
        if cluster?.errorMessage != nil {
            return Color(nsColor: .systemOrange).opacity(0.22)
        }
        return CommandCenterVisualTone.border
    }

    private func summaryText(for cluster: CommandCenterWorkspaceCluster) -> String {
        let summary = [
            cluster.attentionCount > 0 ? "\(cluster.attentionCount) attention" : nil,
            cluster.activeCount > 0 ? "\(cluster.activeCount) active" : nil,
            cluster.queuedCount > 0 ? "\(cluster.queuedCount) queued" : nil,
            cluster.idleCount > 0 ? "\(cluster.idleCount) idle" : nil,
        ]
        .compactMap { $0 }

        if summary.isEmpty {
            return "No visible runs"
        }

        return summary.joined(separator: " • ")
    }
}

struct EmptyRailState: View {
    let title: String
    let detail: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption.bold())
            Text(detail)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
