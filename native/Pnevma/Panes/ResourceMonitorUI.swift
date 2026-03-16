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

            Divider()

            Group {
                if let snapshot = store.snapshot {
                    ScrollView {
                        VStack(spacing: 0) {
                            ResourceSummaryCard(
                                totals: snapshot.totals,
                                totalMemory: snapshot.host.totalMemoryBytes
                            )

                            Divider()

                            ResourceAppSection(app: snapshot.app)

                            Divider()

                            ResourceSessionsSection(sessions: snapshot.sessions)
                        }
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
            .frame(minHeight: 240)

            Divider()

            ResourceMonitorFooter(onOpenMonitor: onOpenMonitor)
                .padding(.horizontal, DesignTokens.Spacing.md)
                .padding(.vertical, DesignTokens.Spacing.sm + DesignTokens.Spacing.md)
        }
        .frame(width: 380)
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
        HStack(alignment: .top, spacing: DesignTokens.Spacing.md) {
            VStack(alignment: .leading, spacing: DesignTokens.Spacing.xs) {
                Text("Resource Usage")
                    .font(.headline)
                    .bold()
                Text("Pnevma process metrics")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: DesignTokens.Spacing.sm)

            Button(action: onRefresh) {
                if isLoading {
                    ProgressView()
                        .controlSize(.small)
                        .frame(minWidth: 16)
                } else {
                    Image(systemName: "arrow.clockwise")
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
        HStack(spacing: DesignTokens.Spacing.lg) {
            ResourceStatBadge(
                label: "CPU",
                value: resourceFormatCpu(totals.cpuPercent),
                color: resourceSeverityColor(totals.cpuPercent)
            )
            ResourceStatBadge(
                label: "MEMORY",
                value: resourceFormatMemory(totals.memoryBytes),
                color: resourceSeverityColor(totals.memoryPercent)
            )
            ResourceStatBadge(
                label: "RAM SHARE",
                value: resourceFormatCpu(totals.memoryPercent),
                color: resourceSeverityColor(totals.memoryPercent)
            )
        }
        .padding(.horizontal, DesignTokens.Spacing.md)
        .padding(.vertical, DesignTokens.Spacing.sm)
        .accessibilityElement(children: .contain)
    }
}

private struct ResourceStatBadge: View {
    let label: String
    let value: String
    let color: Color

    var body: some View {
        VStack(alignment: .center, spacing: DesignTokens.Spacing.xs) {
            Text(value)
                .font(.system(.callout, design: .monospaced))
                .bold()
                .foregroundStyle(color)
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .accessibilityLabel(label)
        .accessibilityValue(value)
    }
}

// MARK: - App Section

private struct ResourceAppSection: View {
    let app: AppResourceGroup
    @State private var isExpanded = true

    var body: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            VStack(spacing: 0) {
                ResourceProcessRow(
                    name: app.main.name,
                    pid: app.main.pid,
                    cpuPercent: app.main.cpuPercent,
                    memoryBytes: app.main.memoryBytes
                )

                if !app.helpers.isEmpty {
                    ForEach(app.helpers) { helper in
                        Divider()
                            .padding(.leading, DesignTokens.Spacing.md)
                        ResourceProcessRow(
                            name: helper.name,
                            pid: helper.pid,
                            cpuPercent: helper.cpuPercent,
                            memoryBytes: helper.memoryBytes
                        )
                    }
                }
            }
        } label: {
            HStack(spacing: DesignTokens.Spacing.sm) {
                Image(systemName: "app.fill")
                    .foregroundStyle(.secondary)
                    .font(.caption)
                Text("Pnevma App")
                    .font(.subheadline)
                    .bold()
                Spacer()
                Text(resourceFormatCpu(app.totalCpuPercent))
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(resourceSeverityColor(app.totalCpuPercent))
                Text(resourceFormatMemory(app.totalMemoryBytes))
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            .accessibilityLabel("Pnevma App")
            .accessibilityValue(
                "CPU \(resourceFormatCpu(app.totalCpuPercent)), Memory \(resourceFormatMemory(app.totalMemoryBytes))"
            )
        }
        .padding(.horizontal, DesignTokens.Spacing.md)
        .padding(.vertical, DesignTokens.Spacing.sm)
    }
}

private struct ResourceProcessRow: View {
    let name: String
    let pid: UInt32
    let cpuPercent: Float
    let memoryBytes: UInt64

    var body: some View {
        HStack(spacing: DesignTokens.Spacing.sm) {
            Text(name)
                .font(.system(.caption, design: .monospaced))
                .lineLimit(1)
                .truncationMode(.middle)
            Text("(\(pid))")
                .font(.system(.caption2, design: .monospaced))
                .foregroundStyle(.tertiary)
            Spacer()
            Text(resourceFormatCpu(cpuPercent))
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(resourceSeverityColor(cpuPercent))
            Text(resourceFormatMemory(memoryBytes))
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, DesignTokens.Spacing.md)
        .padding(.vertical, DesignTokens.Spacing.xs)
        .accessibilityLabel(name)
        .accessibilityValue(
            "CPU \(resourceFormatCpu(cpuPercent)), Memory \(resourceFormatMemory(memoryBytes))"
        )
    }
}

// MARK: - Sessions Section

private struct ResourceSessionsSection: View {
    let sessions: [SessionResources]
    @State private var isExpanded = true

    var body: some View {
        if sessions.isEmpty {
            HStack {
                Image(systemName: "terminal")
                    .foregroundStyle(.tertiary)
                    .font(.caption)
                Text("No active sessions")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .padding(.horizontal, DesignTokens.Spacing.md)
            .padding(.vertical, DesignTokens.Spacing.sm)
            .accessibilityLabel("No active sessions")
        } else {
            DisclosureGroup(isExpanded: $isExpanded) {
                VStack(spacing: 0) {
                    ForEach(sessions) { session in
                        if session.id != sessions.first?.id {
                            Divider()
                                .padding(.leading, DesignTokens.Spacing.md)
                        }
                        ResourceSessionRow(session: session)
                    }
                }
            } label: {
                HStack(spacing: DesignTokens.Spacing.sm) {
                    Image(systemName: "terminal")
                        .foregroundStyle(.secondary)
                        .font(.caption)
                    Text("Sessions")
                        .font(.subheadline)
                        .bold()
                    Text("(\(sessions.count))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                .accessibilityLabel("Sessions")
                .accessibilityValue("\(sessions.count) active")
            }
            .padding(.horizontal, DesignTokens.Spacing.md)
            .padding(.vertical, DesignTokens.Spacing.sm)
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
                .font(.system(.caption, design: .monospaced))
                .lineLimit(1)
                .truncationMode(.tail)

            Spacer()

            Text(resourceFormatCpu(session.totalCpuPercent))
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(resourceSeverityColor(session.totalCpuPercent))

            Text(resourceFormatMemory(session.totalMemoryBytes))
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, DesignTokens.Spacing.md)
        .padding(.vertical, DesignTokens.Spacing.xs)
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
        return String(format: "%.2f GB", mb / 1024)
    }
    return String(format: "%.1f MB", mb)
}

private func resourceFormatCpu(_ percent: Float) -> String {
    String(format: "%.1f%%", percent)
}

private func resourceSeverityColor(_ percent: Float) -> Color {
    if percent >= 80 { return .red }
    if percent >= 50 { return .orange }
    return .green
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
