import SwiftUI

// MARK: - Popover View

struct ResourceMonitorPopoverView: View {
    @State private var store: ResourceMonitorStore
    var onOpenMonitor: (() -> Void)?

    @MainActor
    init(store: ResourceMonitorStore? = nil, onOpenMonitor: (() -> Void)? = nil) {
        _store = State(initialValue: store ?? ResourceMonitorStore.shared)
        self.onOpenMonitor = onOpenMonitor
    }

    var body: some View {
        VStack(spacing: 0) {
            ResourceMonitorHeader(
                isLoading: store.isLoading,
                onRefresh: { Task { await store.refresh() } }
            )
            .padding(.horizontal, DesignTokens.Spacing.md)
            .padding(.top, DesignTokens.Spacing.md)
            .padding(.bottom, DesignTokens.Spacing.sm)

            Group {
                if let snapshot = store.snapshot {
                    VStack(spacing: 0) {
                        ResourceSummaryCard(
                            totals: snapshot.totals,
                            totalMemory: snapshot.host.totalMemoryBytes
                        )

                        Divider()
                            .padding(.horizontal, DesignTokens.Spacing.md)

                        ResourceAppSection(app: snapshot.app)
                            .padding(.horizontal, DesignTokens.Spacing.md)
                            .padding(.vertical, DesignTokens.Spacing.sm)

                        ResourceSessionsSection(sessions: snapshot.sessions)
                            .padding(.horizontal, DesignTokens.Spacing.md)
                            .padding(.bottom, DesignTokens.Spacing.sm)
                    }
                } else if let error = store.errorMessage {
                    ContentUnavailableView(
                        "Resource Monitor Unavailable",
                        systemImage: "exclamationmark.triangle",
                        description: Text(error)
                    )
                    .padding(DesignTokens.Spacing.lg)
                } else {
                    ProgressView("Collecting data\u{2026}")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .frame(minHeight: 200)

            if onOpenMonitor != nil {
                Divider()
                    .padding(.horizontal, DesignTokens.Spacing.md)

                ResourceMonitorFooter(onOpenMonitor: onOpenMonitor)
                    .padding(.horizontal, DesignTokens.Spacing.md)
                    .padding(.vertical, DesignTokens.Spacing.sm)
            }
        }
        .frame(width: 360)
        .background(Color(nsColor: .windowBackgroundColor))
        .task {
            await store.activate()
        }
    }
}

// MARK: - Header

private struct ResourceMonitorHeader: View {
    let isLoading: Bool
    let onRefresh: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: DesignTokens.Spacing.md) {
            Text("RESOURCE USAGE")
                .font(.system(size: 11, weight: .semibold))
                .tracking(0.5)
                .foregroundStyle(.primary)

            Spacer(minLength: DesignTokens.Spacing.sm)

            Button(action: onRefresh) {
                if isLoading {
                    ProgressView()
                        .controlSize(.small)
                        .frame(minWidth: 16)
                } else {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 11))
                }
            }
            .buttonStyle(.borderless)
            .controlSize(.small)
            .accessibilityLabel("Refresh resource data")
        }
    }
}

// MARK: - Summary Card

private struct ResourceSummaryCard: View {
    let totals: ResourceTotals
    let totalMemory: UInt64

    var body: some View {
        HStack(spacing: 0) {
            ResourceStatBadge(
                label: "CPU",
                value: resourceFormatCpu(totals.cpuPercent)
            )
            ResourceStatBadge(
                label: "MEMORY",
                value: resourceFormatMemory(totals.memoryBytes)
            )
            ResourceStatBadge(
                label: "RAM SHARE",
                value: resourceFormatPercent(totals.memoryPercent)
            )
        }
        .padding(.horizontal, DesignTokens.Spacing.md)
        .padding(.vertical, DesignTokens.Spacing.sm + DesignTokens.Spacing.xs)
        .accessibilityElement(children: .contain)
    }
}

private struct ResourceStatBadge: View {
    let label: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(size: 16, weight: .semibold, design: .monospaced))
                .foregroundStyle(.primary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityLabel(label)
        .accessibilityValue(value)
    }
}

// MARK: - App Section

private struct ResourceAppSection: View {
    let app: AppResourceGroup

    var body: some View {
        VStack(spacing: 0) {
            // Section header
            HStack {
                Text("Pnevma App")
                    .font(.system(size: 12, weight: .semibold))
                Spacer()
                Text(resourceFormatCpu(app.totalCpuPercent))
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(.secondary)
                Text(resourceFormatMemory(app.totalMemoryBytes))
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            .padding(.bottom, DesignTokens.Spacing.xs)

            // Process rows
            ResourceProcessRow(
                name: "Main",
                cpuPercent: app.main.cpuPercent,
                memoryBytes: app.main.memoryBytes
            )

            if !app.helpers.isEmpty {
                // Group small helpers into "Other" if there are multiple
                if app.helpers.count > 2 {
                    let totalCpu = app.helpers.reduce(Float(0)) { $0 + $1.cpuPercent }
                    let totalMem = app.helpers.reduce(UInt64(0)) { $0 + $1.memoryBytes }
                    ResourceProcessRow(
                        name: "Other",
                        cpuPercent: totalCpu,
                        memoryBytes: totalMem
                    )
                } else {
                    ForEach(app.helpers) { helper in
                        ResourceProcessRow(
                            name: helper.name.capitalized,
                            cpuPercent: helper.cpuPercent,
                            memoryBytes: helper.memoryBytes
                        )
                    }
                }
            }
        }
    }
}

private struct ResourceProcessRow: View {
    let name: String
    let cpuPercent: Float
    let memoryBytes: UInt64

    var body: some View {
        HStack(spacing: DesignTokens.Spacing.sm) {
            Text(name)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer()
            Text(resourceFormatCpu(cpuPercent))
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(.secondary)
            Text(resourceFormatMemory(memoryBytes))
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(.secondary)
        }
        .padding(.leading, DesignTokens.Spacing.md)
        .padding(.vertical, 2)
        .accessibilityLabel(name)
        .accessibilityValue(
            "CPU \(resourceFormatCpu(cpuPercent)), Memory \(resourceFormatMemory(memoryBytes))"
        )
    }
}

// MARK: - Sessions Section

private struct ResourceSessionsSection: View {
    let sessions: [SessionResources]

    private var activeSessions: [SessionResources] {
        sessions.filter { session in
            let isActive = session.status == "running" || session.status == "active"
            let hasResources = session.totalCpuPercent > 0 || session.totalMemoryBytes > 0
            return isActive || hasResources
        }
    }

    var body: some View {
        if activeSessions.isEmpty {
            Text("No active terminal sessions")
                .font(.system(size: 12))
                .foregroundStyle(.tertiary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, DesignTokens.Spacing.md)
                .accessibilityLabel("No active terminal sessions")
        } else {
            Divider()
                .padding(.horizontal, 0)
                .padding(.bottom, DesignTokens.Spacing.sm)

            VStack(spacing: 0) {
                ForEach(activeSessions) { session in
                    ResourceSessionRow(session: session)
                }
            }
        }
    }
}

private struct ResourceSessionRow: View {
    let session: SessionResources

    var body: some View {
        HStack(spacing: DesignTokens.Spacing.sm) {
            Circle()
                .fill(resourceSessionStatusColor(session.status))
                .frame(
                    width: DesignTokens.Layout.statusDotSize,
                    height: DesignTokens.Layout.statusDotSize
                )
                .accessibilityHidden(true)

            Text(session.sessionName)
                .font(.system(size: 12))
                .lineLimit(1)
                .truncationMode(.tail)

            Spacer()

            Text(resourceFormatCpu(session.totalCpuPercent))
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(.secondary)

            Text(resourceFormatMemory(session.totalMemoryBytes))
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
        .accessibilityLabel(session.sessionName)
        .accessibilityValue(
            "\(session.status), CPU \(resourceFormatCpu(session.totalCpuPercent)), Memory \(resourceFormatMemory(session.totalMemoryBytes))"
        )
    }
}

// MARK: - Footer

private struct ResourceMonitorFooter: View {
    let onOpenMonitor: (() -> Void)?

    var body: some View {
        HStack {
            Button(action: { onOpenMonitor?() }) {
                Text("Open Monitor")
                    .font(.system(size: 12))
            }
            .buttonStyle(.borderless)
            Spacer()
        }
    }
}

// MARK: - Formatting Helpers

private func resourceFormatMemory(_ bytes: UInt64) -> String {
    let mb = Double(bytes) / (1024 * 1024)
    if mb >= 1024 {
        return String(format: "%.1f GB", mb / 1024)
    }
    return String(format: "%.1f MB", mb)
}

private func resourceFormatCpu(_ percent: Float) -> String {
    String(format: "%.1f%%", percent)
}

private func resourceFormatPercent(_ percent: Float) -> String {
    if percent >= 10 {
        return String(format: "%.0f%%", percent)
    }
    return String(format: "%.1f%%", percent)
}

private func resourceSessionStatusColor(_ status: String) -> Color {
    switch status {
    case "running", "active":
        return Color(nsColor: .systemGreen)
    case "stuck", "warning":
        return Color(nsColor: .systemOrange)
    case "error", "failed":
        return Color(nsColor: .systemRed)
    default:
        return Color(nsColor: .secondaryLabelColor)
    }
}
