import AppKit
import Observation
import SwiftUI

enum CommandCenterVisualTone {
    static func toneColor(for run: CommandCenterFleetRun) -> Color {
        switch run.normalizedState {
        case "running":
            Color(nsColor: .systemGreen)
        case "queued":
            Color(nsColor: .systemBlue)
        case "idle":
            Color(nsColor: .quaternaryLabelColor)
        case "review_needed":
            Color(nsColor: .systemYellow)
        case "retrying":
            Color(nsColor: .systemBlue)
        case "failed":
            Color(nsColor: .systemRed)
        case "stuck":
            Color(nsColor: .systemOrange)
        default:
            Color(nsColor: .secondaryLabelColor)
        }
    }

    static func incidentColor(for incident: CommandCenterIncident) -> Color {
        switch incident.kind {
        case .workspaceError, .failed:
            Color(nsColor: .systemRed)
        case .stuck:
            Color(nsColor: .systemOrange)
        case .review, .attention:
            Color(nsColor: .systemYellow)
        case .retrying:
            Color(nsColor: .systemBlue)
        case .idle:
            Color(nsColor: .quaternaryLabelColor)
        }
    }

    static let border = Color(nsColor: .separatorColor).opacity(0.45)
}

struct CommandCenterBoardView: View {
    @Bindable var store: CommandCenterStore
    let boardFocusToken: Int
    let onClearFilters: () -> Void
    let onRunAction: (CommandCenterAction, CommandCenterFleetRun) -> Void
    let onPrimaryAction: (CommandCenterFleetRun) -> Void

    @State private var hoveredRunID: String?

    var body: some View {
        VStack(spacing: 0) {
            boardHeader

            if store.boardSections.isEmpty {
                ContentUnavailableView(
                    boardEmptyTitle,
                    systemImage: boardEmptyImage,
                    description: Text(boardEmptyMessage)
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(selection: $store.selectedRunID) {
                    ForEach(store.boardSections) { section in
                        Section {
                            ForEach(section.runs) { run in
                                CommandCenterRunBoardRow(
                                    run: run,
                                    isSelected: store.selectedRunID == run.id,
                                    isHovered: hoveredRunID == run.id,
                                    onAction: { action in
                                        onRunAction(action, run)
                                    },
                                    onPrimaryAction: {
                                        onPrimaryAction(run)
                                    }
                                )
                                .tag(run.id)
                                .listRowInsets(EdgeInsets(top: 4, leading: 12, bottom: 4, trailing: 12))
                                .listRowSeparator(.hidden)
                                .listRowBackground(Color.clear)
                                .onHover { isHovering in
                                    hoveredRunID = isHovering ? run.id : (hoveredRunID == run.id ? nil : hoveredRunID)
                                }
                            }
                        } header: {
                            BoardSectionHeader(section: section)
                                .padding(.top, section.kind == .attention ? 0 : 8)
                        }
                    }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
                .background(Color.clear)
                .background(CommandCenterBoardFocusBridge(focusToken: boardFocusToken))
            }
        }
        .background(ChromeSurfaceStyle.pane.color)
    }

    private var boardHeader: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.sm) {
            HStack(alignment: .top, spacing: DesignTokens.Spacing.md) {
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: DesignTokens.Spacing.sm) {
                        Text("Fleet board")
                            .font(.headline)
                        FleetHealthBadge(health: store.fleetHealth)
                    }
                    Text(boardSubtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }

                Spacer(minLength: DesignTokens.Spacing.md)

                Text("\(store.visibleRuns.count) visible")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)

                LiveStateBadge(isStale: store.isStale)

                Picker("Filter", selection: $store.filter) {
                    ForEach(CommandCenterStore.Filter.allCases) { filter in
                        Text(filter.title).tag(filter)
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .controlSize(.small)

                if store.hasActiveConstraints {
                    Button("Clear", action: onClearFilters)
                        .buttonStyle(.borderless)
                }
            }

            GroupBox {
                LazyVGrid(
                    columns: [GridItem(.adaptive(minimum: 110), spacing: DesignTokens.Spacing.md)],
                    alignment: .leading,
                    spacing: DesignTokens.Spacing.sm
                ) {
                    OverviewMetric(title: "Scope", value: store.scopeTitle)
                    OverviewMetric(title: "Attention", value: "\(store.attentionRunCount)", tint: Color(nsColor: .systemOrange))
                    OverviewMetric(title: "Active", value: "\(store.fleetSummary.activeCount)", tint: Color(nsColor: .systemGreen))
                    OverviewMetric(title: "Queue", value: "\(store.fleetSummary.queuedCount)", tint: Color(nsColor: .systemBlue))
                    OverviewMetric(title: "Review", value: "\(store.fleetSummary.reviewNeededCount)", tint: Color(nsColor: .systemYellow))
                    OverviewMetric(title: "Failed", value: "\(store.fleetSummary.failedCount)", tint: Color(nsColor: .systemRed))
                    OverviewMetric(
                        title: "Slots",
                        value: "\(store.fleetSummary.slotInUse)/\(max(store.fleetSummary.slotLimit, 0))"
                    )
                    OverviewMetric(title: "Spend", value: store.fleetSummary.costTodayUsd.formatted(.currency(code: "USD")))
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            } label: {
                Label("Overview", systemImage: "chart.bar.xaxis")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, DesignTokens.Spacing.md)
        .padding(.top, DesignTokens.Spacing.md)
        .padding(.bottom, DesignTokens.Spacing.sm)
        .background(ChromeSurfaceStyle.pane.color)
    }

    private var boardSubtitle: String {
        if store.filter == .all {
            return "Attention-first ordering in \(store.scopeTitle.lowercased())"
        }
        return "Showing \(store.filter.title.lowercased()) runs in \(store.scopeTitle.lowercased())"
    }

    private var boardEmptyTitle: String {
        if store.workspaceSnapshots.isEmpty {
            return "No command-center runs"
        }
        return "No runs match the current view"
    }

    private var boardEmptyImage: String {
        if store.workspaceSnapshots.isEmpty {
            return "square.grid.3x3.topleft.fill"
        }
        return "line.3.horizontal.decrease.circle"
    }

    private var boardEmptyMessage: String {
        if store.workspaceSnapshots.isEmpty {
            return "Open a project workspace and dispatch work to populate the command center."
        }
        return "Try clearing search, widening the scope, or selecting an incident from the attention queue."
    }
}

struct CommandCenterRunBoardRow: View {
    let run: CommandCenterFleetRun
    let isSelected: Bool
    let isHovered: Bool
    let onAction: (CommandCenterAction) -> Void
    let onPrimaryAction: () -> Void

    var body: some View {
        HStack(spacing: 0) {
            RoundedRectangle(cornerRadius: 2)
                .fill(accentColor)
                .frame(width: run.needsAttention ? 4 : 3)

            VStack(alignment: .leading, spacing: DesignTokens.Spacing.sm) {
                HStack(alignment: .top, spacing: DesignTokens.Spacing.sm) {
                    VStack(alignment: .leading, spacing: DesignTokens.Spacing.xs) {
                        HStack(spacing: DesignTokens.Spacing.sm) {
                            Text(run.title)
                                .font(.body.bold())
                                .lineLimit(1)
                            WorkspaceMiniChip(title: run.workspaceName)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)

                        if !run.metadataBadges.isEmpty {
                            FlowLine(tokens: run.metadataBadges)
                        }
                    }

                    VStack(alignment: .trailing, spacing: DesignTokens.Spacing.xs) {
                        HStack(spacing: DesignTokens.Spacing.sm) {
                            if isSelected || isHovered {
                                HStack(spacing: 4) {
                                    ForEach(run.quickActions, id: \.id) { action in
                                        ActionIconButton(action: action) {
                                            onAction(action)
                                        }
                                    }
                                }
                            }
                            Text(run.run.lastActivityAt, style: .relative)
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                                .frame(minWidth: 44, alignment: .trailing)
                        }
                        StateBadge(run: run)
                    }
                }

                if let attentionSummary = run.attentionSummary {
                    Label(attentionSummary, systemImage: run.needsAttention ? "exclamationmark.triangle.fill" : "info.circle.fill")
                        .font(.caption)
                        .foregroundStyle(run.needsAttention ? accentColor : .secondary)
                        .lineLimit(2)
                } else if !run.relatedFileLabels.isEmpty {
                    FlowLine(tokens: run.relatedFileLabels, style: .files)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, run.needsAttention ? 10 : 8)
        }
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(backgroundColor)
        )
        .overlay(alignment: .center) {
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(borderColor, lineWidth: isSelected ? 1.15 : 1)
        }
        .contentShape(.rect(cornerRadius: 10))
        .contextMenu {
            ForEach(run.orderedActions) { action in
                Button(action.title, systemImage: action.systemImage) {
                    onAction(action)
                }
            }
        }
        .onTapGesture(count: 2, perform: onPrimaryAction)
        .accessibilityAddTraits(.isButton)
        .accessibilityAction(named: Text(run.primaryAction?.title ?? "Open")) {
            onPrimaryAction()
        }
    }

    private var accentColor: Color {
        CommandCenterVisualTone.toneColor(for: run)
    }

    private var backgroundColor: Color {
        if isSelected {
            return ChromeSurfaceStyle.pane.selectionColor
        }
        if run.needsAttention {
            return accentColor.opacity(0.08)
        }
        if isHovered {
            return Color(nsColor: .controlBackgroundColor)
        }
        return ChromeSurfaceStyle.groupedCard.color
    }

    private var borderColor: Color {
        if isSelected {
            return accentColor.opacity(0.55)
        }
        if run.needsAttention {
            return accentColor.opacity(0.22)
        }
        return CommandCenterVisualTone.border
    }
}

struct BoardSectionHeader: View {
    let section: CommandCenterBoardSection

    var body: some View {
        HStack(spacing: DesignTokens.Spacing.sm) {
            Label(section.kind.title, systemImage: section.kind.systemImage)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text("\(section.runs.count)")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
            Spacer()
        }
        .textCase(nil)
    }
}

struct OverviewMetric: View {
    let title: String
    let value: String
    var tint: Color = .primary

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.subheadline.monospacedDigit())
                .foregroundStyle(tint)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct LiveStateBadge: View {
    let isStale: Bool

    var body: some View {
        Label(label, systemImage: icon)
            .font(.caption)
            .foregroundStyle(color)
    }

    private var color: Color {
        if isStale {
            return Color(nsColor: .systemOrange)
        }
        return Color(nsColor: .systemGreen)
    }

    private var icon: String {
        if isStale {
            return "exclamationmark.circle.fill"
        }
        return "checkmark.circle.fill"
    }

    private var label: String {
        if isStale { return "Stale" }
        return "Live"
    }
}

struct FleetHealthBadge: View {
    let health: CommandCenterFleetHealth

    var body: some View {
        Label(health.title, systemImage: icon)
            .font(.caption)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(
                Capsule()
                    .fill(color.opacity(0.14))
            )
            .foregroundStyle(color)
    }

    private var color: Color {
        switch health {
        case .healthy:
            Color(nsColor: .systemGreen)
        case .degraded:
            Color(nsColor: .systemOrange)
        case .interventionNeeded:
            Color(nsColor: .systemRed)
        }
    }

    private var icon: String {
        switch health {
        case .healthy:
            "checkmark.circle.fill"
        case .degraded:
            "eye.circle.fill"
        case .interventionNeeded:
            "exclamationmark.triangle.fill"
        }
    }
}

struct StateBadge: View {
    let run: CommandCenterFleetRun

    var body: some View {
        Label(run.stateDisplayTitle, systemImage: icon)
            .font(.caption)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(
                Capsule()
                    .fill(color.opacity(0.14))
            )
            .foregroundStyle(color)
    }

    private var color: Color {
        CommandCenterVisualTone.toneColor(for: run)
    }

    private var icon: String {
        switch run.normalizedState {
        case "running": "bolt.fill"
        case "queued": "clock.fill"
        case "idle": "pause.fill"
        case "review_needed": "checklist"
        case "retrying": "arrow.clockwise"
        case "failed": "xmark.octagon.fill"
        case "stuck": "exclamationmark.triangle.fill"
        default: "circle.fill"
        }
    }
}

struct WorkspaceMiniChip: View {
    let title: String

    var body: some View {
        Text(title)
            .font(.caption)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(
                Capsule()
                    .fill(Color(nsColor: .quaternaryLabelColor).opacity(0.14))
            )
            .foregroundStyle(.secondary)
    }
}

struct FlowLine: View {
    enum Style {
        case metadata
        case files
    }

    let tokens: [String]
    var style: Style = .metadata

    var body: some View {
        if style == .metadata {
            Text(Array(tokens.prefix(4)).joined(separator: " • "))
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        } else {
            HStack(spacing: 6) {
                ForEach(Array(tokens.prefix(3)), id: \.self) { token in
                    Text(token)
                        .font(.caption)
                        .lineLimit(1)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2)
                        .background(
                            Capsule()
                                .fill(Color(nsColor: .quaternaryLabelColor).opacity(0.10))
                        )
                        .foregroundStyle(.primary)
                }
            }
        }
    }
}

struct ActionIconButton: View {
    let action: CommandCenterAction
    let handler: () -> Void

    var body: some View {
        Button(action.title, systemImage: action.systemImage, action: handler)
            .labelStyle(.iconOnly)
            .controlSize(.small)
            .buttonStyle(.borderless)
            .accessibilityLabel(action.title)
            .help(action.title)
    }
}

/// Manual verification:
/// 1. ⌘F → type search → Return → ↑/↓ moves the board selection.
/// 2. Clicking the sidebar or selecting text in the detail pane does not route ↑/↓ back into the board.
struct CommandCenterBoardFocusBridge: NSViewRepresentable {
    let focusToken: Int

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> NSView {
        NSView(frame: .zero)
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.hostView = nsView
        context.coordinator.resolveBoardViewIfNeeded()

        if context.coordinator.lastAppliedFocusToken != focusToken {
            context.coordinator.lastAppliedFocusToken = focusToken
            context.coordinator.focusBoard()
        }
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        coordinator.hostView = nil
        coordinator.boardView = nil
    }

    @MainActor final class Coordinator {
        weak var hostView: NSView?
        weak var boardView: NSView?
        var lastAppliedFocusToken = 0

        func resolveBoardViewIfNeeded() {
            guard let hostView else { return }
            if boardView == nil || boardView?.window !== hostView.window {
                Task { @MainActor [weak self] in
                    self?.boardView = self?.locateBoardView()
                }
            }
        }

        func focusBoard() {
            Task { @MainActor [weak self] in
                guard let self else { return }
                if self.boardView == nil || self.boardView?.window == nil {
                    self.boardView = self.locateBoardView()
                }
                guard let boardView = self.boardView,
                      let window = boardView.window else { return }
                window.makeFirstResponder(boardView)
            }
        }

        private func locateBoardView() -> NSView? {
            guard let hostView else { return nil }

            var current: NSView? = hostView
            while let currentView = current {
                if let scrollView = currentView as? NSScrollView,
                   let boardView = findBoardView(in: scrollView) {
                    return boardView
                }
                current = currentView.superview
            }

            current = hostView
            while let currentView = current {
                if let boardView = findBoardView(in: currentView) {
                    return boardView
                }
                current = currentView.superview
            }

            return nil
        }

        private func findBoardView(in root: NSView) -> NSView? {
            if let outlineView = root as? NSOutlineView {
                return outlineView
            }
            if let tableView = root as? NSTableView {
                return tableView
            }
            for child in root.subviews {
                if let boardView = findBoardView(in: child) {
                    return boardView
                }
            }
            return nil
        }
    }
}
