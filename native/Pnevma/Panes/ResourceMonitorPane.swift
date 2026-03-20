import SwiftUI
import Observation
import Cocoa
import Charts

// MARK: - NSView Wrapper

final class ResourceMonitorPaneView: NSView, PaneContent {
    let paneID = PaneID()
    let paneType = "resource_monitor"
    let shouldPersist = true
    var title: String { "Resources" }

    override init(frame: NSRect) {
        super.init(frame: frame)
        _ = addSwiftUISubview(ResourceMonitorDetailView())
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil {
            ResourceMonitorStore.shared.setInteractiveMode(true)
            Task { await ResourceMonitorStore.shared.activate() }
        }
    }
}

// MARK: - Detail View

struct ResourceMonitorDetailView: View {
    @State private var store: ResourceMonitorStore
    @State private var selectedTab: MonitorTab = .overview

    enum MonitorTab: String, CaseIterable {
        case overview = "Overview"
        case processes = "Processes"
        case host = "Host"
    }

    @MainActor
    init(store: ResourceMonitorStore? = nil) {
        _store = State(initialValue: store ?? ResourceMonitorStore.shared)
    }

    var body: some View {
        NativePaneScaffold(
            title: "Resource Monitor",
            subtitle: "Host, process, and live usage data for the current workspace",
            systemImage: "chart.bar.xaxis",
            role: .monitor
        ) {
            Picker("Tab", selection: $selectedTab) {
                ForEach(MonitorTab.allCases, id: \.self) { tab in
                    Text(tab.rawValue).tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 260)
        } content: {
            Group {
                if let error = store.errorMessage, store.snapshot == nil {
                    ContentUnavailableView(
                        "Resource Monitor Unavailable",
                        systemImage: "exclamationmark.triangle",
                        description: Text(error)
                    )
                } else {
                    switch selectedTab {
                    case .overview: overviewTab
                    case .processes: processesTab
                    case .host: hostTab
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .task {
            await store.activate()
        }
    }

    // MARK: - Overview Tab

    @ViewBuilder
    private var overviewTab: some View {
        ScrollView {
            VStack(spacing: DesignTokens.Spacing.md) {
                if let snapshot = store.snapshot {
                    statCardsRow(snapshot: snapshot)
                }

                cpuChart
                memoryChart
            }
            .padding(DesignTokens.Spacing.md)
        }
    }

    private func statCardsRow(snapshot: ResourceSnapshot) -> some View {
        HStack(spacing: DesignTokens.Spacing.sm) {
            MonitorStatCard(
                label: "CPU",
                value: monitorFormatCpu(snapshot.totals.cpuPercent),
                color: monitorSeverityColor(snapshot.totals.cpuPercent)
            )
            MonitorStatCard(
                label: "Memory",
                value: monitorFormatMemory(snapshot.totals.memoryBytes),
                color: monitorSeverityColor(snapshot.totals.memoryPercent)
            )
            MonitorStatCard(
                label: "Processes",
                value: "\(snapshot.totals.processCount)",
                color: .primary
            )
        }
    }

    // MARK: - CPU Chart

    @ViewBuilder
    private var cpuChart: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: DesignTokens.Spacing.sm) {
                Text("CPU Usage")
                    .font(.subheadline)
                    .bold()

                if store.timeSeriesBuffer.count < 2 {
                    Text("Collecting data\u{2026}")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, minHeight: 150, alignment: .center)
                } else {
                    Chart(store.timeSeriesBuffer) { point in
                        LineMark(
                            x: .value("Time", point.date),
                            y: .value("CPU %", point.cpuPercent)
                        )
                        .interpolationMethod(.catmullRom)
                        .foregroundStyle(.blue)

                        AreaMark(
                            x: .value("Time", point.date),
                            y: .value("CPU %", point.cpuPercent)
                        )
                        .interpolationMethod(.catmullRom)
                        .foregroundStyle(.blue.opacity(0.1))
                    }
                    .chartYAxis {
                        AxisMarks(position: .leading) { _ in
                            AxisGridLine()
                            AxisTick()
                            AxisValueLabel()
                        }
                    }
                    .chartXAxis {
                        AxisMarks(values: .stride(by: .minute)) { _ in
                            AxisGridLine()
                            AxisTick()
                            AxisValueLabel(format: .dateTime.minute(.twoDigits).second(.twoDigits))
                        }
                    }
                    .chartYScale(domain: 0 ... max(cpuYMax, 10))
                    .frame(height: 150)
                    .drawingGroup()
                    .accessibilityLabel("CPU usage over time")
                    .accessibilityValue(
                        store.timeSeriesBuffer.last.map { "Current: \(monitorFormatCpu($0.cpuPercent))" } ?? ""
                    )
                }
            }
        }
    }

    private var cpuYMax: Float {
        let peak = store.timeSeriesBuffer.map(\.cpuPercent).max() ?? 0
        return ceil(peak / 10) * 10
    }

    // MARK: - Memory Chart

    @ViewBuilder
    private var memoryChart: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: DesignTokens.Spacing.sm) {
                Text("Memory Usage")
                    .font(.subheadline)
                    .bold()

                if store.timeSeriesBuffer.count < 2 {
                    Text("Collecting data\u{2026}")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, minHeight: 150, alignment: .center)
                } else {
                    Chart(store.timeSeriesBuffer) { point in
                        let megabytes = Double(point.memoryBytes) / (1024 * 1024)

                        LineMark(
                            x: .value("Time", point.date),
                            y: .value("MB", megabytes)
                        )
                        .interpolationMethod(.catmullRom)
                        .foregroundStyle(.purple)

                        AreaMark(
                            x: .value("Time", point.date),
                            y: .value("MB", megabytes)
                        )
                        .interpolationMethod(.catmullRom)
                        .foregroundStyle(.purple.opacity(0.1))
                    }
                    .chartYAxis {
                        AxisMarks(position: .leading) { _ in
                            AxisGridLine()
                            AxisTick()
                            AxisValueLabel()
                        }
                    }
                    .chartXAxis {
                        AxisMarks(values: .stride(by: .minute)) { _ in
                            AxisGridLine()
                            AxisTick()
                            AxisValueLabel(format: .dateTime.minute(.twoDigits).second(.twoDigits))
                        }
                    }
                    .frame(height: 150)
                    .drawingGroup()
                    .accessibilityLabel("Memory usage over time")
                    .accessibilityValue(
                        store.timeSeriesBuffer.last.map { "Current: \(monitorFormatMemory($0.memoryBytes))" } ?? ""
                    )
                }
            }
        }
    }

    // MARK: - Processes Tab

    @ViewBuilder
    private var processesTab: some View {
        if let snapshot = store.snapshot {
            let allProcesses = monitorFlattenProcesses(snapshot: snapshot)

            if allProcesses.isEmpty {
                ContentUnavailableView(
                    "No Processes",
                    systemImage: "gearshape",
                    description: Text("No tracked processes found.")
                )
            } else {
                processTable(allProcesses)
            }
        } else {
            ProgressView("Collecting data\u{2026}")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    @ViewBuilder
    private func processTable(_ processes: [MonitorProcessEntry]) -> some View {
        VStack(spacing: 0) {
            // Header
            HStack(spacing: 0) {
                monitorColumnHeader("PID", width: 60, alignment: .trailing)
                monitorColumnHeader("Name", width: nil, alignment: .leading)
                monitorColumnHeader("CPU %", width: 70, alignment: .trailing)
                monitorColumnHeader("Memory", width: 90, alignment: .trailing)
                monitorColumnHeader("Category", width: 80, alignment: .center)
            }
            .padding(.horizontal, DesignTokens.Spacing.md)
            .padding(.vertical, DesignTokens.Spacing.xs)
            .background(Color.primary.opacity(DesignTokens.Opacity.subtle))

            Divider()

            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(processes) { entry in
                        VStack(spacing: 0) {
                            HStack(spacing: 0) {
                                Text("\(entry.pid)")
                                    .font(.system(.caption, design: .monospaced))
                                    .frame(width: 60, alignment: .trailing)

                                Text(entry.name)
                                    .font(.system(.caption, design: .monospaced))
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(.leading, DesignTokens.Spacing.sm)

                                Text(monitorFormatCpu(entry.cpuPercent))
                                    .font(.system(.caption, design: .monospaced))
                                    .foregroundStyle(monitorSeverityColor(entry.cpuPercent))
                                    .frame(width: 70, alignment: .trailing)

                                Text(monitorFormatMemory(entry.memoryBytes))
                                    .font(.system(.caption, design: .monospaced))
                                    .foregroundStyle(.secondary)
                                    .frame(width: 90, alignment: .trailing)

                                Text(entry.category.rawValue)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                    .frame(width: 80, alignment: .center)
                            }
                            .padding(.horizontal, DesignTokens.Spacing.md)
                            .padding(.vertical, DesignTokens.Spacing.xs)
                            .accessibilityLabel("\(entry.name), PID \(entry.pid)")
                            .accessibilityValue(
                                "CPU \(monitorFormatCpu(entry.cpuPercent)), Memory \(monitorFormatMemory(entry.memoryBytes)), \(entry.category.rawValue)"
                            )

                            Divider()
                                .padding(.leading, DesignTokens.Spacing.md)
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func monitorColumnHeader(_ title: String, width: CGFloat?, alignment: Alignment) -> some View {
        if let width {
            Text(title)
                .font(.caption2)
                .bold()
                .foregroundStyle(.secondary)
                .frame(width: width, alignment: alignment)
        } else {
            Text(title)
                .font(.caption2)
                .bold()
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: alignment)
                .padding(.leading, DesignTokens.Spacing.sm)
        }
    }

    // MARK: - Host Tab

    @ViewBuilder
    private var hostTab: some View {
        if let snapshot = store.snapshot {
            ScrollView {
                VStack(spacing: DesignTokens.Spacing.md) {
                    GroupBox {
                        VStack(spacing: 0) {
                            monitorInfoRow(label: "Hostname", value: snapshot.host.hostname)
                            Divider()
                            monitorInfoRow(label: "OS Version", value: snapshot.host.osVersion)
                            Divider()
                            monitorInfoRow(label: "CPU Cores", value: "\(snapshot.host.cpuCores)")
                            Divider()
                            monitorInfoRow(
                                label: "Total RAM",
                                value: monitorFormatMemory(snapshot.host.totalMemoryBytes)
                            )
                            Divider()
                            monitorInfoRow(
                                label: "Uptime",
                                value: monitorFormatUptime(snapshot.host.uptimeSeconds)
                            )
                        }
                    }
                }
                .padding(DesignTokens.Spacing.md)
            }
        } else {
            ProgressView("Collecting data\u{2026}")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func monitorInfoRow(label: String, value: String) -> some View {
        HStack {
            Text(label)
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .font(.system(.subheadline, design: .monospaced))
        }
        .padding(.horizontal, DesignTokens.Spacing.sm)
        .padding(.vertical, DesignTokens.Spacing.sm)
        .accessibilityLabel(label)
        .accessibilityValue(value)
    }
}

// MARK: - Stat Card

private struct MonitorStatCard: View {
    let label: String
    let value: String
    let color: Color

    var body: some View {
        VStack(spacing: DesignTokens.Spacing.xs) {
            Text(value)
                .font(.system(.title2, design: .monospaced))
                .bold()
                .foregroundStyle(color)
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(DesignTokens.Spacing.sm + DesignTokens.Spacing.xs)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.primary.opacity(DesignTokens.Opacity.subtle))
        )
        .accessibilityLabel(label)
        .accessibilityValue(value)
    }
}

// MARK: - Process Entry Model

enum MonitorProcessCategory: String, Sendable {
    case app = "App"
    case helper = "Helper"
    case session = "Session"
}

struct MonitorProcessEntry: Identifiable, Sendable {
    let id: String
    let pid: UInt32
    let name: String
    let cpuPercent: Float
    let memoryBytes: UInt64
    let category: MonitorProcessCategory
}

// MARK: - Helpers

private func monitorFlattenProcesses(snapshot: ResourceSnapshot) -> [MonitorProcessEntry] {
    var entries: [MonitorProcessEntry] = []

    entries.append(MonitorProcessEntry(
        id: "app-\(snapshot.app.main.pid)",
        pid: snapshot.app.main.pid,
        name: snapshot.app.main.name,
        cpuPercent: snapshot.app.main.cpuPercent,
        memoryBytes: snapshot.app.main.memoryBytes,
        category: .app
    ))

    for helper in snapshot.app.helpers {
        entries.append(MonitorProcessEntry(
            id: "helper-\(helper.pid)",
            pid: helper.pid,
            name: helper.name,
            cpuPercent: helper.cpuPercent,
            memoryBytes: helper.memoryBytes,
            category: .helper
        ))
    }

    for session in snapshot.sessions {
        if let process = session.process {
            entries.append(MonitorProcessEntry(
                id: "session-\(process.pid)",
                pid: process.pid,
                name: process.name,
                cpuPercent: process.cpuPercent,
                memoryBytes: process.memoryBytes,
                category: .session
            ))
        }
        for child in session.children {
            entries.append(MonitorProcessEntry(
                id: "session-child-\(child.pid)",
                pid: child.pid,
                name: child.name,
                cpuPercent: child.cpuPercent,
                memoryBytes: child.memoryBytes,
                category: .session
            ))
        }
    }

    return entries.sorted { $0.cpuPercent > $1.cpuPercent }
}

private func monitorFormatMemory(_ bytes: UInt64) -> String {
    let mb = Double(bytes) / (1024 * 1024)
    if mb >= 1024 {
        return String(format: "%.2f GB", mb / 1024)
    }
    return String(format: "%.1f MB", mb)
}

private func monitorFormatCpu(_ percent: Float) -> String {
    String(format: "%.1f%%", percent)
}

private func monitorSeverityColor(_ percent: Float) -> Color {
    if percent >= 80 { return .red }
    if percent >= 50 { return .orange }
    return .green
}

private func monitorFormatUptime(_ seconds: UInt64) -> String {
    let days = seconds / 86400
    let hours = (seconds % 86400) / 3600
    let minutes = (seconds % 3600) / 60
    if days > 0 { return "\(days)d \(hours)h \(minutes)m" }
    if hours > 0 { return "\(hours)h \(minutes)m" }
    return "\(minutes)m"
}
