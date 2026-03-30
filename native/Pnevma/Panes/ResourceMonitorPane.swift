import SwiftUI
import Observation
import Charts

// MARK: - NSView Wrapper

final class ResourceMonitorPaneView: NSView, PaneContent {
    let paneID = PaneID()
    let paneType = "resource_monitor"
    let shouldPersist = true
    var title: String { "Resources" }

    init(frame: NSRect, chromeContext: PaneChromeContext = .standard) {
        super.init(frame: frame)
        _ = addSwiftUISubview(ResourceMonitorDetailView(), chromeContext: chromeContext)
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

    @MainActor
    init(store: ResourceMonitorStore? = nil) {
        _store = State(initialValue: store ?? ResourceMonitorStore.shared)
    }

    /// Monochrome chart color — neutral grey that works in both light and dark mode
    private static let chartStroke = Color.primary.opacity(0.45)
    private static let chartFill = Color.primary.opacity(0.06)
    private static let chartGridLine = Color.primary.opacity(0.08)

    var body: some View {
        NativePaneScaffold(
            title: "Resource Monitor",
            subtitle: "Host, process, and live usage data for the current workspace",
            systemImage: "chart.bar.xaxis",
            role: .monitor,
            inlineHeaderIdentifier: "pane.resourceMonitor.inlineHeader",
            inlineHeaderLabel: "Resource Monitor inline header"
        ) {
            if let error = store.errorMessage, store.snapshot == nil {
                ContentUnavailableView(
                    "Resource Monitor Unavailable",
                    systemImage: "exclamationmark.triangle",
                    description: Text(error)
                )
            } else {
                ScrollView {
                    VStack(spacing: DesignTokens.Spacing.sm) {
                        // Host info
                        hostInfoSection

                        // Charts stacked
                        cpuChartSection
                        memoryChartSection

                        // Process table
                        processSection
                    }
                    .padding(DesignTokens.Spacing.sm)
                }
            }
        }
        .task {
            await store.activate()
        }
        .accessibilityIdentifier("pane.resourceMonitor")
    }

    // MARK: - Host Info Section

    @ViewBuilder
    private var hostInfoSection: some View {
        if let snapshot = store.snapshot {
            GroupBox {
                Grid(alignment: .leading, horizontalSpacing: DesignTokens.Spacing.lg, verticalSpacing: DesignTokens.Spacing.xs) {
                    GridRow {
                        monitorHostLabel("Host")
                        monitorHostLabel("OS")
                        monitorHostLabel("Cores")
                        monitorHostLabel("RAM")
                        monitorHostLabel("Uptime")
                    }
                    GridRow {
                        monitorHostValue(snapshot.host.hostname)
                        monitorHostValue(snapshot.host.osVersion)
                        monitorHostValue("\(snapshot.host.cpuCores)")
                        monitorHostValue(monitorFormatMemory(snapshot.host.totalMemoryBytes))
                        monitorHostValue(monitorFormatUptime(snapshot.host.uptimeSeconds))
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Host information")
        }
    }

    private func monitorHostLabel(_ text: String) -> some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(.secondary)
    }

    private func monitorHostValue(_ text: String) -> some View {
        Text(text)
            .font(.system(.caption, design: .monospaced))
            .lineLimit(1)
    }

    // MARK: - CPU Chart

    @ViewBuilder
    private var cpuChartSection: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: DesignTokens.Spacing.sm) {
                HStack(alignment: .firstTextBaseline) {
                    Text("CPU Usage")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    if let snapshot = store.snapshot {
                        Text(monitorFormatCpu(snapshot.totals.cpuPercent))
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(monitorSeverityColor(snapshot.totals.cpuPercent))
                    }
                }

                if store.timeSeriesBuffer.count < 2 {
                    Text("Collecting data\u{2026}")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .frame(maxWidth: .infinity, minHeight: 100, alignment: .center)
                } else {
                    Chart(store.timeSeriesBuffer) { point in
                        LineMark(
                            x: .value("Time", point.date),
                            y: .value("CPU %", point.cpuPercent)
                        )
                        .interpolationMethod(.catmullRom)
                        .foregroundStyle(Self.chartStroke)
                        .lineStyle(StrokeStyle(lineWidth: 1.5))

                        AreaMark(
                            x: .value("Time", point.date),
                            y: .value("CPU %", point.cpuPercent)
                        )
                        .interpolationMethod(.catmullRom)
                        .foregroundStyle(
                            LinearGradient(
                                colors: [Self.chartFill, Self.chartFill.opacity(0)],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        )
                    }
                    .chartYAxis {
                        AxisMarks(position: .leading, values: .automatic(desiredCount: 3)) { _ in
                            AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5))
                                .foregroundStyle(Self.chartGridLine)
                            AxisValueLabel()
                                .font(.system(.caption2, design: .monospaced))
                                .foregroundStyle(.tertiary)
                        }
                    }
                    .chartXAxis {
                        AxisMarks(values: .stride(by: .minute)) { _ in
                            AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5))
                                .foregroundStyle(Self.chartGridLine)
                            AxisValueLabel(format: .dateTime.minute(.twoDigits).second(.twoDigits))
                                .font(.system(.caption2, design: .monospaced))
                                .foregroundStyle(.tertiary)
                        }
                    }
                    .chartYScale(domain: 0 ... cpuYMax)
                    .chartPlotStyle { plotArea in
                        plotArea.background(Color.clear)
                    }
                    .frame(height: 100)
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
        // Round up to next nice interval with 20% headroom
        let withHeadroom = peak * 1.2
        let interval: Float = withHeadroom <= 20 ? 5 : withHeadroom <= 50 ? 10 : withHeadroom <= 200 ? 25 : 50
        return max(ceil(withHeadroom / interval) * interval, 10)
    }

    // MARK: - Memory Chart

    @ViewBuilder
    private var memoryChartSection: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: DesignTokens.Spacing.sm) {
                HStack(alignment: .firstTextBaseline) {
                    Text("Memory Usage")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    if let snapshot = store.snapshot {
                        Text(monitorFormatMemory(snapshot.totals.memoryBytes))
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                }

                if store.timeSeriesBuffer.count < 2 {
                    Text("Collecting data\u{2026}")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .frame(maxWidth: .infinity, minHeight: 100, alignment: .center)
                } else {
                    let memoryMBValues = store.timeSeriesBuffer.map { Double($0.memoryBytes) / (1024 * 1024) }

                    Chart(store.timeSeriesBuffer) { point in
                        let megabytes = Double(point.memoryBytes) / (1024 * 1024)

                        LineMark(
                            x: .value("Time", point.date),
                            y: .value("MB", megabytes)
                        )
                        .interpolationMethod(.catmullRom)
                        .foregroundStyle(Self.chartStroke)
                        .lineStyle(StrokeStyle(lineWidth: 1.5))

                        AreaMark(
                            x: .value("Time", point.date),
                            y: .value("MB", megabytes)
                        )
                        .interpolationMethod(.catmullRom)
                        .foregroundStyle(
                            LinearGradient(
                                colors: [Self.chartFill, Self.chartFill.opacity(0)],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        )
                    }
                    .chartYAxis {
                        AxisMarks(position: .leading, values: .automatic(desiredCount: 3)) { _ in
                            AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5))
                                .foregroundStyle(Self.chartGridLine)
                            AxisValueLabel()
                                .font(.system(.caption2, design: .monospaced))
                                .foregroundStyle(.tertiary)
                        }
                    }
                    .chartXAxis {
                        AxisMarks(values: .stride(by: .minute)) { _ in
                            AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5))
                                .foregroundStyle(Self.chartGridLine)
                            AxisValueLabel(format: .dateTime.minute(.twoDigits).second(.twoDigits))
                                .font(.system(.caption2, design: .monospaced))
                                .foregroundStyle(.tertiary)
                        }
                    }
                    .chartYScale(domain: monitorMemoryYRange(memoryMBValues))
                    .chartPlotStyle { plotArea in
                        plotArea.background(Color.clear)
                    }
                    .frame(height: 100)
                    .drawingGroup()
                    .accessibilityLabel("Memory usage over time")
                    .accessibilityValue(
                        store.timeSeriesBuffer.last.map { "Current: \(monitorFormatMemory($0.memoryBytes))" } ?? ""
                    )
                }
            }
        }
    }

    // MARK: - Processes Section

    @ViewBuilder
    private var processSection: some View {
        if let snapshot = store.snapshot {
            let allProcesses = monitorFlattenProcesses(snapshot: snapshot)

            GroupBox {
                VStack(spacing: 0) {
                    // Section header
                    HStack(alignment: .firstTextBaseline) {
                        Text("Processes")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text("\(allProcesses.count)")
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(.tertiary)
                    }
                    .padding(.bottom, DesignTokens.Spacing.sm)

                    if allProcesses.isEmpty {
                        Text("No tracked processes")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                            .frame(maxWidth: .infinity, alignment: .center)
                            .padding(DesignTokens.Spacing.lg)
                    } else {
                        processTable(allProcesses)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func processTable(_ processes: [MonitorProcessEntry]) -> some View {
        VStack(spacing: 0) {
            // Column headers
            HStack(spacing: 0) {
                monitorColumnHeader("PID", width: 54, alignment: .trailing)
                monitorColumnHeader("Name", width: nil, alignment: .leading)
                monitorColumnHeader("CPU", width: 60, alignment: .trailing)
                monitorColumnHeader("Memory", width: 80, alignment: .trailing)
                monitorColumnHeader("Type", width: 60, alignment: .trailing)
            }
            .padding(.vertical, DesignTokens.Spacing.xs)

            Divider()

            LazyVStack(spacing: 0) {
                ForEach(processes) { entry in
                    HStack(spacing: 0) {
                        Text("\(entry.pid)")
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .frame(width: 54, alignment: .trailing)

                        Text(entry.name)
                            .font(.system(.caption, design: .monospaced))
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.leading, DesignTokens.Spacing.sm)

                        Text(monitorFormatCpu(entry.cpuPercent))
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(monitorSeverityColor(entry.cpuPercent))
                            .frame(width: 60, alignment: .trailing)

                        Text(monitorFormatMemory(entry.memoryBytes))
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .frame(width: 80, alignment: .trailing)

                        Text(entry.category.rawValue)
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                            .frame(width: 60, alignment: .trailing)
                    }
                    .padding(.vertical, 3)
                    .accessibilityLabel("\(entry.name), PID \(entry.pid)")
                    .accessibilityValue(
                        "CPU \(monitorFormatCpu(entry.cpuPercent)), Memory \(monitorFormatMemory(entry.memoryBytes)), \(entry.category.rawValue)"
                    )
                }
            }
        }
    }

    @ViewBuilder
    private func monitorColumnHeader(_ title: String, width: CGFloat?, alignment: Alignment) -> some View {
        if let width {
            Text(title)
                .font(.caption)
                .foregroundStyle(.tertiary)
                .frame(width: width, alignment: alignment)
        } else {
            Text(title)
                .font(.caption)
                .foregroundStyle(.tertiary)
                .frame(maxWidth: .infinity, alignment: alignment)
                .padding(.leading, DesignTokens.Spacing.sm)
        }
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
    ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .memory)
}

private func monitorFormatCpu(_ percent: Float) -> String {
    percent.formatted(.number.precision(.fractionLength(1))) + "%"
}

/// Compute a Y-axis range for memory that fits the data with headroom, avoiding 0-origin when values are clustered high
private func monitorMemoryYRange(_ values: [Double]) -> ClosedRange<Double> {
    guard let minVal = values.min(), let maxVal = values.max() else {
        return 0 ... 100
    }
    let spread = maxVal - minVal
    let padding = max(spread * 0.3, maxVal * 0.1, 10)
    let lower = max(floor((minVal - padding) / 10) * 10, 0)
    let upper = ceil((maxVal + padding) / 10) * 10
    return lower ... max(upper, lower + 20)
}

private func monitorSeverityColor(_ percent: Float) -> Color {
    if percent >= 80 { return .red }
    if percent >= 50 { return .orange }
    return .primary
}

private func monitorFormatUptime(_ seconds: UInt64) -> String {
    let days = seconds / 86400
    let hours = (seconds % 86400) / 3600
    let minutes = (seconds % 3600) / 60
    if days > 0 { return "\(days)d \(hours)h \(minutes)m" }
    if hours > 0 { return "\(hours)h \(minutes)m" }
    return "\(minutes)m"
}
