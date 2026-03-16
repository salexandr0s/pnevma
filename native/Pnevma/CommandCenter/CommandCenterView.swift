import SwiftUI
import Observation

struct CommandCenterView: View {
    @Bindable var store: CommandCenterStore
    @Environment(GhosttyThemeProvider.self) var theme
    @AppStorage("sidebarBackgroundOffset") private var sidebarOffset: Double = BackgroundTint.defaultOffset
    @FocusState private var searchFieldFocused: Bool
    @State private var hoveredRunID: String?
    @State private var boardFocusToken = 0

    /// Background derived from the ghostty terminal theme, matching the main sidebar.
    private var sidebarBackground: Color {
        let bg = theme.backgroundColor
        let offset = BackgroundTint.clamped(sidebarOffset)
        if offset == 0 {
            return Color(nsColor: bg)
        }
        let tinted = bg.blended(withFraction: offset, of: .white) ?? bg
        return Color(nsColor: tinted)
    }

    var body: some View {
        VStack(spacing: 0) {
            commandStrip
            HSplitView {
                leftRail
                centerBoard
                detailPane
            }
        }
        .frame(minWidth: 1180, minHeight: 760)
        .background(Color(nsColor: theme.backgroundColor))
        .background(commandShortcuts)
    }

    private var commandStrip: some View {
        VStack(spacing: 0) {
            HStack(alignment: .center, spacing: DesignTokens.Spacing.md) {
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: DesignTokens.Spacing.sm) {
                        Text("Command Center")
                            .font(.title3.weight(.semibold))
                        FleetHealthBadge(health: store.fleetHealth)
                    }
                    Text(store.healthSummaryText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer(minLength: DesignTokens.Spacing.md)

                TextField("Search runs, branches, models, files", text: $store.searchQuery)
                    .textFieldStyle(.roundedBorder)
                    .frame(minWidth: 280, maxWidth: 380)
                    .focused($searchFieldFocused)
                    .onSubmit(handleSearchSubmit)

                HStack(spacing: DesignTokens.Spacing.sm) {
                    LiveStateBadge(isRefreshing: store.isRefreshing, isStale: store.isStale)
                    Button(store.isRefreshing ? "Refreshing…" : "Refresh", systemImage: "arrow.clockwise") {
                        store.refreshNow()
                    }
                    .controlSize(.small)
                    .disabled(store.isRefreshing)
                }
            }
            .padding(.horizontal, DesignTokens.Spacing.md)
            .padding(.top, 12)
            .padding(.bottom, 8)

            HStack(alignment: .center, spacing: DesignTokens.Spacing.sm) {
                WorkspaceScopePill(
                    title: store.scopeTitle,
                    isScoped: store.selectedWorkspaceID != nil,
                    onClear: { handleWorkspaceSelection(nil) }
                )

                ScrollView(.horizontal) {
                    HStack(spacing: DesignTokens.Spacing.sm) {
                        ForEach(CommandCenterStore.Filter.allCases) { filter in
                            FilterPill(
                                title: filter.title,
                                count: store.filterCount(for: filter),
                                isSelected: store.filter == filter
                            ) {
                                handleFilterSelection(filter)
                            }
                        }
                    }
                    .padding(.vertical, 1)
                }
                .scrollIndicators(.hidden)

                if store.hasActiveConstraints {
                    Button("Clear") {
                        clearFiltersAndFocusBoard()
                    }
                    .buttonStyle(.borderless)
                }

                if let lastErrorMessage = store.lastErrorMessage, !lastErrorMessage.isEmpty {
                    StatusInlineBanner(message: lastErrorMessage)
                }

                Spacer(minLength: DesignTokens.Spacing.sm)

                ScrollView(.horizontal) {
                    HStack(spacing: DesignTokens.Spacing.sm) {
                        MetricCapsule(title: "Attention", value: "\(store.attentionRunCount)", accent: .systemOrange)
                        MetricCapsule(title: "Active", value: "\(store.fleetSummary.activeCount)", accent: .systemGreen)
                        MetricCapsule(title: "Queue", value: "\(store.fleetSummary.queuedCount)", accent: .systemBlue)
                        MetricCapsule(title: "Review", value: "\(store.fleetSummary.reviewNeededCount)", accent: .systemYellow)
                        MetricCapsule(title: "Failed", value: "\(store.fleetSummary.failedCount)", accent: .systemRed)
                        MetricCapsule(
                            title: "Slots",
                            value: "\(store.fleetSummary.slotInUse)/\(max(store.fleetSummary.slotLimit, 0))",
                            accent: store.fleetSummary.slotLimit > 0 && store.fleetSummary.slotInUse >= store.fleetSummary.slotLimit ? .systemOrange : .controlAccentColor,
                            progress: store.fleetSummary.slotLimit > 0 ? Double(store.fleetSummary.slotInUse) / Double(store.fleetSummary.slotLimit) : nil
                        )
                        MetricCapsule(title: "Spend", currencyValue: store.fleetSummary.costTodayUsd, accent: .systemMint)
                    }
                    .padding(.vertical, 1)
                }
                .scrollIndicators(.hidden)
            }
            .padding(.horizontal, DesignTokens.Spacing.md)
            .padding(.bottom, 10)

            Divider()
        }
        .background(
            Rectangle()
                .fill(sidebarBackground)
        )
    }

    private var leftRail: some View {
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
                            handleIncidentSelection(incident)
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
                    action: { handleWorkspaceSelection(nil) }
                )
                .listRowInsets(EdgeInsets(top: 4, leading: 12, bottom: 4, trailing: 12))
                .listRowBackground(Color.clear)

                ForEach(store.workspaceClusters) { cluster in
                    WorkspaceScopeRow(
                        title: cluster.workspaceName,
                        subtitle: cluster.workspacePath,
                        cluster: cluster,
                        isSelected: store.selectedWorkspaceID == cluster.id,
                        action: { handleWorkspaceSelection(cluster.id) }
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
        .frame(minWidth: 240, idealWidth: 258, maxWidth: 300)
        .background(sidebarBackground)
    }

    private var centerBoard: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: DesignTokens.Spacing.xs) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Fleet board")
                            .font(.headline)
                        Text(boardSubtitle)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Text("\(store.visibleRuns.count) visible")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }

                ScrollView(.horizontal) {
                    HStack(spacing: DesignTokens.Spacing.sm) {
                        KeyboardHintToken(keys: "⌘1–7", description: "filter")
                        KeyboardHintToken(keys: "↑↓", description: "move")
                        KeyboardHintToken(keys: "↩", description: "open")
                        KeyboardHintToken(keys: "⌥⌘T/R/D/F", description: "actions")
                        KeyboardHintToken(keys: "Esc", description: "clear")
                    }
                }
                .scrollIndicators(.hidden)
            }
            .padding(.horizontal, DesignTokens.Spacing.md)
            .padding(.top, DesignTokens.Spacing.md)
            .padding(.bottom, DesignTokens.Spacing.sm)

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
                                        store.performAction(action, on: run)
                                    },
                                    onPrimaryAction: {
                                        store.performPrimaryAction(on: run)
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
        .frame(minWidth: 560, idealWidth: 760)
        .background(Color(nsColor: theme.backgroundColor))
    }

    private var detailPane: some View {
        Group {
            if let run = store.selectedRun {
                ScrollView {
                    VStack(alignment: .leading, spacing: DesignTokens.Spacing.md) {
                        inspectorHeader(for: run)
                        inspectorActions(for: run)
                        inspectorRunContext(for: run)
                        if let attentionSummary = run.attentionSummary {
                            inspectorIncident(attentionSummary: attentionSummary)
                        }
                        inspectorTimeline(for: run)
                    }
                    .padding(DesignTokens.Spacing.md)
                }
            } else {
                ContentUnavailableView(
                    "Select a run",
                    systemImage: "cursorarrow.click",
                    description: Text("Choose a run from the board to inspect the session, files, review context, and recovery actions.")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(minWidth: 360, idealWidth: 390, maxWidth: 460)
        .background(Color(nsColor: theme.backgroundColor))
    }

    private func inspectorHeader(for run: CommandCenterFleetRun) -> some View {
        CommandCenterPanel(title: "Selected run", systemImage: "scope") {
            VStack(alignment: .leading, spacing: DesignTokens.Spacing.sm) {
                HStack(alignment: .top, spacing: DesignTokens.Spacing.sm) {
                    VStack(alignment: .leading, spacing: DesignTokens.Spacing.xs) {
                        Text(run.title)
                            .font(.title3.weight(.semibold))
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

    private func inspectorActions(for run: CommandCenterFleetRun) -> some View {
        CommandCenterPanel(title: "Quick actions", systemImage: "bolt.fill") {
            VStack(alignment: .leading, spacing: DesignTokens.Spacing.sm) {
                if !run.primaryActions.isEmpty {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 96), spacing: DesignTokens.Spacing.sm)], spacing: DesignTokens.Spacing.sm) {
                        ForEach(Array(run.primaryActions.enumerated()), id: \.element.id) { index, action in
                            if index == 0 {
                                Button {
                                    store.performAction(action, on: run)
                                } label: {
                                    Label(action.title, systemImage: action.systemImage)
                                        .frame(maxWidth: .infinity)
                                }
                                .buttonStyle(BorderedProminentButtonStyle())
                                .controlSize(.small)
                            } else {
                                Button {
                                    store.performAction(action, on: run)
                                } label: {
                                    Label(action.title, systemImage: action.systemImage)
                                        .frame(maxWidth: .infinity)
                                }
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
                            Button(role: .destructive) {
                                store.performAction(action, on: run)
                            } label: {
                                Label(action.title, systemImage: action.systemImage)
                                    .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                        }
                    }
                }
            }
        }
    }

    private func inspectorRunContext(for run: CommandCenterFleetRun) -> some View {
        CommandCenterPanel(title: "Run context", systemImage: "point.3.connected.trianglepath.dotted") {
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
        CommandCenterPanel(title: "Incident detail", systemImage: "exclamationmark.triangle.fill") {
            Text(attentionSummary)
                .font(.caption)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func inspectorTimeline(for run: CommandCenterFleetRun) -> some View {
        CommandCenterPanel(title: "Timeline", systemImage: "clock.arrow.circlepath") {
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
                                    .font(.caption.weight(.semibold))
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

    private var commandShortcuts: some View {
        Group {
            HiddenShortcutButton(title: "Focus search", key: "f", modifiers: [.command]) {
                searchFieldFocused = true
            }
            HiddenShortcutButton(title: "Refresh command center", key: "r", modifiers: [.command]) {
                store.refreshNow()
            }
            HiddenShortcutButton(title: "All runs", key: "1", modifiers: [.command]) {
                handleFilterSelection(.all)
            }
            HiddenShortcutButton(title: "Attention runs", key: "2", modifiers: [.command]) {
                handleFilterSelection(.attention)
            }
            HiddenShortcutButton(title: "Active runs", key: "3", modifiers: [.command]) {
                handleFilterSelection(.active)
            }
            HiddenShortcutButton(title: "Queued runs", key: "4", modifiers: [.command]) {
                handleFilterSelection(.queued)
            }
            HiddenShortcutButton(title: "Review runs", key: "5", modifiers: [.command]) {
                handleFilterSelection(.review)
            }
            HiddenShortcutButton(title: "Failed runs", key: "6", modifiers: [.command]) {
                handleFilterSelection(.failed)
            }
            HiddenShortcutButton(title: "Idle runs", key: "7", modifiers: [.command]) {
                handleFilterSelection(.idle)
            }
            HiddenShortcutButton(title: "Attention queue", key: "a", modifiers: [.command, .shift]) {
                store.focusAttentionQueue()
                handOffToBoard()
            }
            HiddenShortcutButton(title: "Clear search or filters", key: .escape, modifiers: []) {
                handleEscapeShortcut()
            }
            HiddenShortcutButton(title: "Open selected run", key: .return, modifiers: []) {
                handleReturnShortcut()
            }
            HiddenShortcutButton(title: "Open terminal", key: "t", modifiers: [.command, .option]) {
                store.performSelectedAction(.openTerminal)
            }
            HiddenShortcutButton(title: "Open replay", key: "r", modifiers: [.command, .option]) {
                store.performSelectedAction(.openReplay)
            }
            HiddenShortcutButton(title: "Open diff", key: "d", modifiers: [.command, .option]) {
                store.performSelectedAction(.openDiff)
            }
            HiddenShortcutButton(title: "Open review", key: "v", modifiers: [.command, .option]) {
                store.performSelectedAction(.openReview)
            }
            HiddenShortcutButton(title: "Open files", key: "f", modifiers: [.command, .option]) {
                store.performSelectedAction(.openFiles)
            }
            HiddenShortcutButton(title: "Restart session", key: "s", modifiers: [.command, .option]) {
                store.performSelectedAction(.restartSession)
            }
            HiddenShortcutButton(title: "Kill session", key: "k", modifiers: [.command, .option]) {
                store.performSelectedAction(.killSession)
            }
            HiddenShortcutButton(title: "Reattach session", key: "e", modifiers: [.command, .option]) {
                store.performSelectedAction(.reattachSession)
            }
        }
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

    private func formatDateTime(_ date: Date) -> String {
        date.formatted(date: .abbreviated, time: .shortened)
    }

    private func handleSearchSubmit() {
        store.selectFirstRun()
        handOffToBoard()
    }

    private func handleReturnShortcut() {
        if searchFieldFocused {
            handleSearchSubmit()
            return
        }

        guard let selectedRun = store.selectedRun else { return }
        store.performPrimaryAction(on: selectedRun)
    }

    private func handleEscapeShortcut() {
        let hadSearch = !store.searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let hadConstraints = store.hasActiveConstraints
        if searchFieldFocused {
            searchFieldFocused = false
        }
        store.clearSearchOrFilters()
        if hadSearch || hadConstraints {
            handOffToBoard()
        }
    }

    private func handleFilterSelection(_ filter: CommandCenterStore.Filter) {
        store.filter = filter
        handOffToBoard()
    }

    private func handleWorkspaceSelection(_ workspaceID: UUID?) {
        store.selectWorkspace(workspaceID)
        handOffToBoard()
    }

    private func handleIncidentSelection(_ incident: CommandCenterIncident) {
        store.focusIncident(incident)
        handOffToBoard()
    }

    private func clearFiltersAndFocusBoard() {
        store.clearFilters()
        handOffToBoard()
    }

    private func handOffToBoard() {
        searchFieldFocused = false
        boardFocusToken &+= 1
    }

}

private struct CommandCenterRunBoardRow: View {
    let run: CommandCenterFleetRun
    let isSelected: Bool
    let isHovered: Bool
    let onAction: (CommandCenterAction) -> Void
    let onPrimaryAction: () -> Void

    var body: some View {
        HStack(spacing: 0) {
            RoundedRectangle(cornerRadius: 2, style: .continuous)
                .fill(accentColor)
                .frame(width: run.needsAttention ? 4 : 3)

            VStack(alignment: .leading, spacing: DesignTokens.Spacing.sm) {
                HStack(alignment: .top, spacing: DesignTokens.Spacing.sm) {
                    VStack(alignment: .leading, spacing: DesignTokens.Spacing.xs) {
                        HStack(spacing: DesignTokens.Spacing.sm) {
                            Text(run.title)
                                .font(.body.weight(.semibold))
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
                                HStack(spacing: 6) {
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
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(backgroundColor)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(borderColor, lineWidth: isSelected ? 1.15 : 1)
        )
        .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .contextMenu {
            ForEach(run.orderedActions) { action in
                Button {
                    onAction(action)
                } label: {
                    Label(action.title, systemImage: action.systemImage)
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
        toneColor(for: run)
    }

    private var backgroundColor: Color {
        if isSelected {
            return accentColor.opacity(0.14)
        }
        if run.needsAttention {
            return accentColor.opacity(0.08)
        }
        let fg = Color(nsColor: GhosttyThemeProvider.shared.foregroundColor)
        if isHovered {
            return fg.opacity(DesignTokens.Opacity.light)
        }
        return fg.opacity(DesignTokens.Opacity.subtle)
    }

    private var borderColor: Color {
        if isSelected {
            return accentColor.opacity(0.75)
        }
        return run.needsAttention
            ? accentColor.opacity(0.18)
            : Color(nsColor: GhosttyThemeProvider.shared.foregroundColor).opacity(DesignTokens.Opacity.subtle)
    }
}

private struct CommandCenterPanel<Content: View>: View {
    let title: String
    let systemImage: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.sm) {
            Label(title, systemImage: systemImage)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            content
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color(nsColor: GhosttyThemeProvider.shared.foregroundColor).opacity(DesignTokens.Opacity.subtle))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color(nsColor: GhosttyThemeProvider.shared.foregroundColor).opacity(DesignTokens.Opacity.subtle), lineWidth: 1)
        )
    }
}

private struct CommandCenterSectionHeader: View {
    let title: String
    let systemImage: String

    var body: some View {
        Label(title, systemImage: systemImage)
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            .textCase(nil)
    }
}

private struct BoardSectionHeader: View {
    let section: CommandCenterBoardSection

    var body: some View {
        HStack(spacing: DesignTokens.Spacing.sm) {
            Label(section.kind.title, systemImage: section.kind.systemImage)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Text("\(section.runs.count)")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
            Spacer()
        }
        .textCase(nil)
    }
}

private struct KeyboardHintToken: View {
    let keys: String
    let description: String

    var body: some View {
        HStack(spacing: 6) {
            Text(keys)
                .font(.caption.monospaced())
                .foregroundStyle(.primary)
            Text(description)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(
            Capsule()
                .fill(Color(nsColor: GhosttyThemeProvider.shared.foregroundColor).opacity(DesignTokens.Opacity.subtle))
        )
        .overlay(
            Capsule()
                .strokeBorder(Color(nsColor: GhosttyThemeProvider.shared.foregroundColor).opacity(DesignTokens.Opacity.subtle), lineWidth: 1)
        )
    }
}

private struct StatusInlineBanner: View {
    let message: String

    var body: some View {
        Label(message, systemImage: "exclamationmark.triangle.fill")
            .font(.caption)
            .foregroundStyle(Color(nsColor: .systemOrange))
            .lineLimit(1)
            .help(message)
    }
}

private struct AttentionIncidentRow: View {
    let incident: CommandCenterIncident
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 0) {
                RoundedRectangle(cornerRadius: 2)
                    .fill(incidentColor(for: incident))
                    .frame(width: 3)

                HStack(alignment: .top, spacing: DesignTokens.Spacing.sm) {
                    Image(systemName: incident.kind.systemImage)
                        .foregroundStyle(incidentColor(for: incident))
                        .frame(width: 16)
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: DesignTokens.Spacing.sm) {
                            Text(incident.title)
                                .font(.caption.weight(.semibold))
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
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(Color(nsColor: GhosttyThemeProvider.shared.foregroundColor).opacity(DesignTokens.Opacity.subtle))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(incidentColor(for: incident).opacity(0.18), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }
}

private struct WorkspaceScopeRow: View {
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
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    Spacer(minLength: DesignTokens.Spacing.sm)
                    if let cluster {
                        Text(summaryText(for: cluster))
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                if let cluster {
                    WorkspaceClusterBar(cluster: cluster)
                        .frame(height: 6)
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
                RoundedRectangle(cornerRadius: 10)
                    .fill(isSelected ? Color(nsColor: .controlAccentColor).opacity(0.18) : Color(nsColor: GhosttyThemeProvider.shared.foregroundColor).opacity(DesignTokens.Opacity.subtle))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(isSelected ? Color(nsColor: .controlAccentColor).opacity(0.45) : Color(nsColor: GhosttyThemeProvider.shared.foregroundColor).opacity(DesignTokens.Opacity.subtle), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }

    private func summaryText(for cluster: CommandCenterWorkspaceCluster) -> String {
        "\(cluster.attentionCount) attn • \(cluster.activeCount) active • \(cluster.queuedCount) queued"
    }
}

private struct WorkspaceClusterBar: View {
    let cluster: CommandCenterWorkspaceCluster

    var body: some View {
        GeometryReader { proxy in
            let total = max(cluster.activeCount + cluster.attentionCount + cluster.queuedCount + cluster.idleCount, 1)
            HStack(spacing: 2) {
                if cluster.attentionCount > 0 {
                    Rectangle()
                        .fill(Color(nsColor: .systemOrange))
                        .frame(width: max(8, proxy.size.width * CGFloat(cluster.attentionCount) / CGFloat(total)))
                }
                if cluster.activeCount > 0 {
                    Rectangle()
                        .fill(Color(nsColor: .systemGreen))
                        .frame(width: max(8, proxy.size.width * CGFloat(cluster.activeCount) / CGFloat(total)))
                }
                if cluster.queuedCount > 0 {
                    Rectangle()
                        .fill(Color(nsColor: .systemBlue))
                        .frame(width: max(8, proxy.size.width * CGFloat(cluster.queuedCount) / CGFloat(total)))
                }
                if cluster.idleCount > 0 {
                    Rectangle()
                        .fill(Color(nsColor: .quaternaryLabelColor))
                        .frame(width: max(8, proxy.size.width * CGFloat(cluster.idleCount) / CGFloat(total)))
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .clipShape(Capsule())
        }
    }
}

private struct MetricCapsule: View {
    let title: String
    let valueText: String
    let accent: NSColor
    let progress: Double?

    init(title: String, value: String, accent: NSColor = .quaternaryLabelColor, progress: Double? = nil) {
        self.title = title
        self.valueText = value
        self.accent = accent
        self.progress = progress
    }

    init(title: String, currencyValue: Double, accent: NSColor) {
        self.title = title
        self.valueText = currencyValue.formatted(.currency(code: "USD"))
        self.accent = accent
        self.progress = nil
    }

    var body: some View {
        HStack(spacing: DesignTokens.Spacing.sm) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(valueText)
                .font(.caption.monospacedDigit().weight(.semibold))
                .foregroundStyle(Color(nsColor: accent))
            if let progress {
                ProgressView(value: min(max(progress, 0), 1))
                    .frame(width: 34)
                    .tint(Color(nsColor: accent))
                    .scaleEffect(x: 1, y: 0.55, anchor: .center)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
            Capsule()
                .fill(Color(nsColor: GhosttyThemeProvider.shared.foregroundColor).opacity(DesignTokens.Opacity.subtle))
        )
        .overlay(
            Capsule()
                .strokeBorder(Color(nsColor: GhosttyThemeProvider.shared.foregroundColor).opacity(DesignTokens.Opacity.subtle), lineWidth: 1)
        )
    }
}

private struct FilterPill: View {
    let title: String
    let count: Int
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Text(title)
                Text("\(count)")
                    .font(.caption.monospacedDigit())
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(Color(nsColor: .quaternaryLabelColor).opacity(isSelected ? 0.20 : 0.12)))
            }
            .font(.caption.weight(.medium))
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(
                Capsule()
                    .fill(isSelected ? Color(nsColor: .controlAccentColor).opacity(0.18) : Color(nsColor: GhosttyThemeProvider.shared.foregroundColor).opacity(DesignTokens.Opacity.subtle))
            )
            .overlay(
                Capsule()
                    .strokeBorder(isSelected ? Color(nsColor: .controlAccentColor).opacity(0.55) : Color(nsColor: GhosttyThemeProvider.shared.foregroundColor).opacity(DesignTokens.Opacity.subtle), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }
}

private struct WorkspaceScopePill: View {
    let title: String
    let isScoped: Bool
    let onClear: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: isScoped ? "scope" : "square.grid.2x2")
            Text(title)
                .lineLimit(1)
            if isScoped {
                Button(action: onClear) {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .font(.caption.weight(.medium))
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
            Capsule()
                .fill(Color(nsColor: GhosttyThemeProvider.shared.foregroundColor).opacity(DesignTokens.Opacity.subtle))
        )
        .overlay(
            Capsule()
                .strokeBorder(Color(nsColor: GhosttyThemeProvider.shared.foregroundColor).opacity(DesignTokens.Opacity.subtle), lineWidth: 1)
        )
    }
}

private struct LiveStateBadge: View {
    let isRefreshing: Bool
    let isStale: Bool

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(badgeColor)
                .frame(width: 7, height: 7)
            Text(label)
                .font(.caption.weight(.semibold))
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(
            Capsule()
                .fill(badgeColor.opacity(0.12))
        )
        .foregroundStyle(badgeColor)
    }

    private var badgeColor: Color {
        if isRefreshing {
            return Color(nsColor: .controlAccentColor)
        }
        if isStale {
            return Color(nsColor: .systemOrange)
        }
        return Color(nsColor: .systemGreen)
    }

    private var label: String {
        if isRefreshing { return "Refreshing" }
        if isStale { return "Stale" }
        return "Live"
    }
}

private struct FleetHealthBadge: View {
    let health: CommandCenterFleetHealth

    var body: some View {
        Label(health.title, systemImage: icon)
            .font(.caption.weight(.semibold))
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
            return Color(nsColor: .systemGreen)
        case .degraded:
            return Color(nsColor: .systemOrange)
        case .interventionNeeded:
            return Color(nsColor: .systemRed)
        }
    }

    private var icon: String {
        switch health {
        case .healthy: return "checkmark.circle.fill"
        case .degraded: return "eye.circle.fill"
        case .interventionNeeded: return "exclamationmark.triangle.fill"
        }
    }
}

private struct StateBadge: View {
    let run: CommandCenterFleetRun

    var body: some View {
        Label(run.stateDisplayTitle, systemImage: icon)
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(
                Capsule()
                    .fill(color.opacity(0.14))
            )
            .foregroundStyle(color)
    }

    private var color: Color {
        toneColor(for: run)
    }

    private var icon: String {
        switch run.normalizedState {
        case "running": return "bolt.fill"
        case "queued": return "clock.fill"
        case "idle": return "pause.fill"
        case "review_needed": return "checklist"
        case "retrying": return "arrow.clockwise"
        case "failed": return "xmark.octagon.fill"
        case "stuck": return "exclamationmark.triangle.fill"
        default: return "circle.fill"
        }
    }
}

private struct WorkspaceMiniChip: View {
    let title: String

    var body: some View {
        Text(title)
            .font(.caption.weight(.medium))
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(
                Capsule()
                    .fill(Color(nsColor: .quaternaryLabelColor).opacity(0.14))
            )
            .foregroundStyle(.secondary)
    }
}

private struct FlowLine: View {
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

private struct ActionIconButton: View {
    let action: CommandCenterAction
    let handler: () -> Void

    var body: some View {
        Button(action.title, systemImage: action.systemImage, action: handler)
            .labelStyle(.iconOnly)
            .font(.system(size: 11, weight: .semibold))
            .frame(width: 22, height: 22)
        .buttonStyle(.plain)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(Color(nsColor: GhosttyThemeProvider.shared.foregroundColor).opacity(DesignTokens.Opacity.subtle))
        )
        .accessibilityLabel(action.title)
        .help(action.title)
    }
}

private struct InspectorDetailRow: View {
    let label: String
    let value: String?

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: DesignTokens.Spacing.sm) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 86, alignment: .leading)
            Text(value ?? "—")
                .font(.caption)
                .textSelection(.enabled)
            Spacer(minLength: 0)
        }
    }
}

private struct InspectorSectionBlock<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.sm) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            content
        }
    }
}

private struct InspectorValueChip<Value: View>: View {
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
                .font(.caption.weight(.semibold))
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color(nsColor: GhosttyThemeProvider.shared.foregroundColor).opacity(DesignTokens.Opacity.subtle))
        )
    }
}

private struct HiddenShortcutButton: View {
    let title: String
    let key: KeyEquivalent
    let modifiers: EventModifiers
    let action: () -> Void

    init(title: String, key: String, modifiers: EventModifiers, action: @escaping () -> Void) {
        self.title = title
        self.key = KeyEquivalent(Character(key))
        self.modifiers = modifiers
        self.action = action
    }

    init(title: String, key: KeyEquivalent, modifiers: EventModifiers, action: @escaping () -> Void) {
        self.title = title
        self.key = key
        self.modifiers = modifiers
        self.action = action
    }

    var body: some View {
        Button(title, action: action)
            .keyboardShortcut(key, modifiers: modifiers)
            .opacity(0.001)
            .frame(width: 0, height: 0)
    }
}

/// Manual verification:
/// 1. ⌘F → type search → Return → ↑/↓ moves the board selection.
/// 2. Clicking the sidebar or selecting text in the detail pane does not route ↑/↓ back into the board.
private struct CommandCenterBoardFocusBridge: NSViewRepresentable {
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

    final class Coordinator {
        weak var hostView: NSView?
        weak var boardView: NSView?
        var lastAppliedFocusToken = 0

        func resolveBoardViewIfNeeded() {
            guard let hostView else { return }
            if boardView == nil || boardView?.window !== hostView.window {
                DispatchQueue.main.async { [weak self] in
                    self?.boardView = self?.locateBoardView()
                }
            }
        }

        func focusBoard() {
            DispatchQueue.main.async { [weak self] in
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

private struct EmptyRailState: View {
    let title: String
    let detail: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption.weight(.semibold))
            Text(detail)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private func toneColor(for run: CommandCenterFleetRun) -> Color {
    switch run.normalizedState {
    case "running":
        return Color(nsColor: .systemGreen)
    case "queued":
        return Color(nsColor: .systemBlue)
    case "idle":
        return Color(nsColor: .quaternaryLabelColor)
    case "review_needed":
        return Color(nsColor: .systemYellow)
    case "retrying":
        return Color(nsColor: .systemBlue)
    case "failed":
        return Color(nsColor: .systemRed)
    case "stuck":
        return Color(nsColor: .systemOrange)
    default:
        return Color(nsColor: .secondaryLabelColor)
    }
}

private func incidentColor(for incident: CommandCenterIncident) -> Color {
    switch incident.kind {
    case .workspaceError, .failed:
        return Color(nsColor: .systemRed)
    case .stuck:
        return Color(nsColor: .systemOrange)
    case .review, .attention:
        return Color(nsColor: .systemYellow)
    case .retrying:
        return Color(nsColor: .systemBlue)
    case .idle:
        return Color(nsColor: .quaternaryLabelColor)
    }
}
