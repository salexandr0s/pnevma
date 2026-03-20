import Cocoa
import Observation
import SwiftUI

enum SettingsNavigationSection: String, CaseIterable, Identifiable {
    case general
    case appShortcuts
    case terminal
    case ghostty
    case usage
    case telemetry

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: "General"
        case .appShortcuts: "App Shortcuts"
        case .terminal: "Terminal"
        case .ghostty: "Ghostty"
        case .usage: "Usage"
        case .telemetry: "Telemetry"
        }
    }

    var systemImage: String {
        switch self {
        case .general: "gearshape"
        case .appShortcuts: "keyboard"
        case .terminal: "terminal"
        case .ghostty: "slider.horizontal.3"
        case .usage: "chart.line.uptrend.xyaxis"
        case .telemetry: "chart.bar.xaxis"
        }
    }

    var iconTintColor: Color {
        switch self {
        case .general:
            Color(nsColor: .systemGray)
        case .appShortcuts:
            Color(nsColor: .systemIndigo)
        case .terminal:
            Color(nsColor: .labelColor)
        case .ghostty:
            Color(nsColor: .systemOrange)
        case .usage:
            Color(nsColor: .systemGreen)
        case .telemetry:
            Color(nsColor: .systemPink)
        }
    }

    var iconFillColor: Color {
        switch self {
        case .general:
            Color(nsColor: .quaternaryLabelColor)
        case .appShortcuts:
            Color(nsColor: .systemIndigo)
        case .terminal:
            Color(nsColor: .secondaryLabelColor)
        case .ghostty:
            Color(nsColor: .systemOrange)
        case .usage:
            Color(nsColor: .systemGreen)
        case .telemetry:
            Color(nsColor: .systemPink)
        }
    }

    var subtitle: String {
        switch self {
        case .general:
            "App behavior, window restoration, chrome appearance, and update preferences."
        case .appShortcuts:
            "Review and customize the shortcuts used across Pnevma windows and panes."
        case .terminal:
            "Default shell, typography, and scrollback behavior for new terminal sessions."
        case .ghostty:
            "Embedded terminal rendering, config-backed Ghostty options, and terminal keybindings."
        case .usage:
            "Provider usage sources, refresh cadence, and dashboard integration settings."
        case .telemetry:
            "Analytics and diagnostics preferences for future release quality improvements."
        }
    }

    private var searchTerms: [String] {
        switch self {
        case .general:
            ["updates", "restore", "sidebar", "focus border", "tool dock"]
        case .appShortcuts:
            ["keyboard", "hotkeys", "bindings", "commands"]
        case .terminal:
            ["shell", "font", "scrollback", "terminal defaults"]
        case .ghostty:
            ["terminal config", "themes", "rendering", "keybinds"]
        case .usage:
            ["providers", "codex", "claude", "quota", "dashboard"]
        case .telemetry:
            ["analytics", "crash reports", "privacy", "diagnostics"]
        }
    }

    func matches(_ query: String) -> Bool {
        let normalized = query
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard !normalized.isEmpty else { return true }

        return ([title, subtitle] + searchTerms)
            .joined(separator: " ")
            .lowercased()
            .contains(normalized)
    }

    static func filtered(for query: String) -> [SettingsNavigationSection] {
        allCases.filter { $0.matches(query) }
    }

    static func resolvedSelection(
        current: SettingsNavigationSection?,
        query: String
    ) -> SettingsNavigationSection? {
        let filtered = filtered(for: query)
        guard !filtered.isEmpty else { return current }
        if let current, filtered.contains(current) {
            return current
        }
        return filtered.first
    }
}

struct SettingsView: View {
    @State private var appViewModel = SettingsViewModel()
    @State private var ghosttyViewModel = GhosttySettingsViewModel()
    @State private var providerUsageViewModel = ProviderUsageSettingsViewModel()
    @State private var searchText = ""
    @State private var selectedSection: SettingsNavigationSection? = .general

    private var filteredSections: [SettingsNavigationSection] {
        SettingsNavigationSection.filtered(for: searchText)
    }

    var body: some View {
        HStack(spacing: 0) {
            SettingsSidebar(
                searchText: $searchText,
                selectedSection: $selectedSection,
                filteredSections: filteredSections
            )
            .frame(width: 248)

            Divider()

            Group {
                if filteredSections.isEmpty {
                    SettingsSearchEmptyState(query: searchText)
                } else {
                    selectedSectionView
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(nsColor: .windowBackgroundColor))
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity, alignment: .topLeading)
        .task {
            appViewModel.load()
            ghosttyViewModel.load()
            providerUsageViewModel.load()
            syncSelectionToSearch()
        }
        .onAppear(perform: syncSelectionToSearch)
        .onChange(of: searchText) { syncSelectionToSearch() }
        .accessibilityIdentifier("settings.root")
    }

    @ViewBuilder
    private var selectedSectionView: some View {
        switch selectedSection ?? filteredSections.first ?? .general {
        case .general:
            GeneralSettingsTab(viewModel: appViewModel)
        case .appShortcuts:
            AppKeybindingsSettingsTab(viewModel: appViewModel)
        case .terminal:
            TerminalSettingsTab(viewModel: appViewModel)
        case .ghostty:
            GhosttySettingsTab(viewModel: ghosttyViewModel)
        case .usage:
            ProviderUsageSettingsTab(viewModel: providerUsageViewModel)
        case .telemetry:
            TelemetrySettingsTab(viewModel: appViewModel)
        }
    }

    private func syncSelectionToSearch() {
        selectedSection = SettingsNavigationSection.resolvedSelection(
            current: selectedSection,
            query: searchText
        )
    }
}

struct SettingsSidebar: View {
    @Binding var searchText: String
    @Binding var selectedSection: SettingsNavigationSection?
    let filteredSections: [SettingsNavigationSection]

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.md) {
            SettingsAppHeaderCard()

            SettingsSidebarSearchField(text: $searchText)
                .accessibilityIdentifier("settings.sidebar.search")

            if filteredSections.isEmpty {
                VStack(alignment: .leading, spacing: DesignTokens.Spacing.xs) {
                    Text("No matching settings")
                        .font(.subheadline.weight(.semibold))
                    Text("Try a different search term.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 4)

                Spacer()
            } else {
                ScrollView {
                    LazyVStack(spacing: 4) {
                        ForEach(filteredSections) { section in
                            SettingsSidebarRow(
                                section: section,
                                isSelected: selectedSection == section
                            ) {
                                selectedSection = section
                            }
                            .accessibilityIdentifier("settings.sidebar.\(section.id)")
                        }
                    }
                    .padding(.vertical, 2)
                }
            }

            Spacer(minLength: 0)
        }
        .padding(12)
        .background(Color(nsColor: .underPageBackgroundColor))
    }
}

struct SettingsAppHeaderCard: View {
    private var versionLabel: String? {
        guard let info = Bundle.main.infoDictionary else { return nil }
        let version = info["CFBundleShortVersionString"] as? String
        let build = info["CFBundleVersion"] as? String

        switch (version, build) {
        case let (version?, build?) where version != build:
            return "Version \(version) (\(build))"
        case let (version?, _):
            return "Version \(version)"
        case let (_, build?):
            return "Build \(build)"
        default:
            return nil
        }
    }

    var body: some View {
        HStack(spacing: 12) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .scaledToFit()
                .frame(width: 42, height: 42)
                .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))

            VStack(alignment: .leading, spacing: 2) {
                Text("Pnevma")
                    .font(.headline)

                Text("Settings")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                if let versionLabel {
                    Text(versionLabel)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }

            Spacer()
        }
        .padding(12)
        .background(ChromeSurfaceStyle.groupedCard.color)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Color(nsColor: ChromeSurfaceStyle.groupedCard.separatorColor).opacity(0.45), lineWidth: 1)
        )
    }
}

struct SettingsSidebarSearchField: View {
    @Binding var text: String

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)

            TextField("Search", text: $text)
                .textFieldStyle(.plain)
                .font(.system(size: 13))

            if !text.isEmpty {
                Button {
                    text = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(Color.primary.opacity(0.05), lineWidth: 1)
        )
    }
}

struct SettingsSidebarRow: View {
    let section: SettingsNavigationSection
    let isSelected: Bool
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(iconBackground)
                    .frame(width: 24, height: 24)
                    .overlay {
                        Image(systemName: section.systemImage)
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(iconForeground)
                    }

                Text(section.title)
                    .font(.system(size: 13, weight: isSelected ? .semibold : .medium))
                    .foregroundStyle(rowForeground)

                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(rowBackground)
            )
        }
        .buttonStyle(.plain)
        .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .onHover { isHovering = $0 }
    }

    private var rowBackground: Color {
        if isSelected {
            return Color.accentColor
        }
        if isHovering {
            return Color.primary.opacity(0.06)
        }
        return .clear
    }

    private var rowForeground: Color {
        isSelected ? .white : Color.primary
    }

    private var iconBackground: Color {
        if isSelected {
            return .white.opacity(0.18)
        }
        return section.iconFillColor.opacity(section == .general ? 0.65 : 0.92)
    }

    private var iconForeground: Color {
        if isSelected {
            return .white
        }
        return section == .general ? Color.primary : .white
    }
}

struct SettingsSearchEmptyState: View {
    let query: String

    var body: some View {
        EmptyStateView(
            icon: "magnifyingglass",
            title: "No Matching Settings",
            message: "No settings matched “\(query)”. Try a broader term."
        )
    }
}

struct SettingsDetailPage<Content: View>: View {
    let section: SettingsNavigationSection
    var contentWidth: CGFloat? = 760
    @ViewBuilder let content: () -> Content

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                SettingsDetailHeader(section: section)
                content()
            }
            .frame(maxWidth: contentWidth, alignment: .leading)
            .padding(.horizontal, 28)
            .padding(.top, 24)
            .padding(.bottom, 28)
            .frame(maxWidth: .infinity, alignment: .top)
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

struct SettingsFramedDetailPage<Content: View>: View {
    let section: SettingsNavigationSection
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            SettingsDetailHeader(section: section)
            content()
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .padding(.horizontal, 28)
        .padding(.top, 24)
        .padding(.bottom, 28)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

struct SettingsDetailHeader: View {
    let section: SettingsNavigationSection

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(section.title)
                .font(.system(size: 28, weight: .semibold))
            Text(section.subtitle)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

struct SettingsHeroCard: View {
    let systemImage: String
    let title: String
    let message: String

    var body: some View {
        HStack(spacing: DesignTokens.Spacing.md) {
            ZStack {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(Color.primary.opacity(0.06))
                    .frame(width: 72, height: 72)

                Image(systemName: systemImage)
                    .font(.system(size: 28, weight: .medium))
                    .foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: DesignTokens.Spacing.xs) {
                Text(title)
                    .font(.title3.weight(.semibold))
                Text(message)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer()
        }
        .padding(20)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Color.primary.opacity(0.035))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(Color.primary.opacity(0.05), lineWidth: 1)
        )
    }
}

struct SettingsGroupCard<Content: View>: View {
    let title: String
    let description: String?
    @ViewBuilder let content: () -> Content

    init(
        title: String,
        description: String? = nil,
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.title = title
        self.description = description
        self.content = content
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.md) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.headline)
                if let description {
                    Text(description)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            content()
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(Color.primary.opacity(0.05), lineWidth: 1)
        )
    }
}

struct SettingsControlRow<Control: View>: View {
    let title: String
    let description: String?
    var alignment: VerticalAlignment = .center
    @ViewBuilder let control: () -> Control

    var body: some View {
        HStack(alignment: alignment, spacing: DesignTokens.Spacing.md) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.body.weight(.medium))
                if let description {
                    Text(description)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Spacer(minLength: DesignTokens.Spacing.md)

            control()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct SettingsStatusValueView: View {
    let status: AppUpdateStatus

    var body: some View {
        switch status {
        case .idle:
            Text("Idle")
                .foregroundStyle(.secondary)
        case .checking:
            HStack(spacing: 4) {
                ProgressView()
                    .controlSize(.mini)
                Text("Checking\u{2026}")
            }
        case .updateAvailable(let version, _):
            Text("Update available: \(version)")
                .foregroundStyle(.orange)
        case .upToDate:
            Text("Up to date")
                .foregroundStyle(.green)
        case .failed(let msg):
            Text("Failed: \(msg)")
                .foregroundStyle(.red)
        }
    }
}

struct GeneralSettingsTab: View {
    @Bindable var viewModel: SettingsViewModel

    var body: some View {
        SettingsDetailPage(section: .general) {
            SettingsHeroCard(
                systemImage: "gearshape",
                title: "Pnevma Settings",
                message: "Configure launch behavior, workspace chrome, and focus affordances in one place."
            )

            SettingsGroupCard(
                title: "Workspace Behavior",
                description: "Defaults that affect launch, restore, and shell selection across Pnevma."
            ) {
                VStack(spacing: 12) {
                    SettingsControlRow(
                        title: "Auto-save workspace on quit",
                        description: "Persist open workspaces automatically when you close the app."
                    ) {
                        Toggle("", isOn: $viewModel.autoSave)
                            .labelsHidden()
                    }

                    Divider()

                    SettingsControlRow(
                        title: "Restore windows on launch",
                        description: "Bring back your last workspace windows the next time Pnevma opens."
                    ) {
                        Toggle("", isOn: $viewModel.restoreWindows)
                            .labelsHidden()
                    }

                    Divider()

                    SettingsControlRow(
                        title: "Check for updates automatically",
                        description: "Periodically look for newer Pnevma builds in the background."
                    ) {
                        Toggle("", isOn: $viewModel.autoUpdate)
                            .labelsHidden()
                    }

                    Divider()

                    SettingsControlRow(
                        title: "Default shell",
                        description: "Used for new local terminal sessions unless a project overrides it."
                    ) {
                        Picker("", selection: $viewModel.defaultShell) {
                            Text("System default").tag("")
                            Text("/bin/zsh").tag("/bin/zsh")
                            Text("/bin/bash").tag("/bin/bash")
                        }
                        .labelsHidden()
                        .pickerStyle(.menu)
                        .frame(width: 180)
                    }
                }
            }

            SettingsGroupCard(
                title: "Updates & Version",
                description: "Current build details and the state of release checks."
            ) {
                if let coordinator = viewModel.updateCoordinator {
                    VStack(spacing: 12) {
                        SettingsControlRow(title: "Current version", description: nil) {
                            Text("\(coordinator.state.currentVersion) (build \(coordinator.state.currentBuild))")
                                .foregroundStyle(.secondary)
                        }

                        if let latest = coordinator.state.latestVersion {
                            Divider()

                            SettingsControlRow(title: "Latest release", description: nil) {
                                Text(latest)
                                    .foregroundStyle(.secondary)
                            }
                        }

                        if let lastCheck = coordinator.state.lastCheckAt {
                            Divider()

                            SettingsControlRow(title: "Last checked", description: nil) {
                                Text(lastCheck, style: .relative)
                                    .foregroundStyle(.secondary)
                            }
                        }

                        Divider()

                        SettingsControlRow(title: "Status", description: nil) {
                            SettingsStatusValueView(status: coordinator.state.status)
                        }
                    }
                } else {
                    Text("Version checking initializes after settings load completes.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            SettingsGroupCard(
                title: "Workspace Chrome",
                description: "Tune the surrounding surfaces so the workspace feels closer to your preferred contrast."
            ) {
                VStack(spacing: 12) {
                    SettingsControlRow(
                        title: "Sidebar background tint",
                        description: "Adjust how much the workspace sidebar diverges from the system background.",
                        alignment: .top
                    ) {
                        sliderRow(
                            value: $viewModel.sidebarBackgroundOffset,
                            label: percentageText(for: viewModel.sidebarBackgroundOffset)
                        )
                    }

                    Divider()

                    SettingsControlRow(
                        title: "Auto-hide bottom tool bar",
                        description: "Collapse the bottom tool bar into a slim reveal strip until you hover it."
                    ) {
                        Toggle("", isOn: $viewModel.bottomToolBarAutoHide)
                            .labelsHidden()
                    }

                    Divider()

                    SettingsControlRow(
                        title: "Tool dock background tint",
                        description: "Apply the same subtle tint treatment to the bottom tool dock.",
                        alignment: .top
                    ) {
                        sliderRow(
                            value: $viewModel.toolDockBackgroundOffset,
                            label: percentageText(for: viewModel.toolDockBackgroundOffset)
                        )
                    }

                    Divider()

                    SettingsControlRow(
                        title: "Right inspector background tint",
                        description: "Adjust the inspector surface so it stays visually distinct without overwhelming content.",
                        alignment: .top
                    ) {
                        sliderRow(
                            value: $viewModel.rightInspectorBackgroundOffset,
                            label: percentageText(for: viewModel.rightInspectorBackgroundOffset)
                        )
                    }
                }
            }

            SettingsGroupCard(
                title: "Focus Border",
                description: "Highlight the currently active pane with a configurable accent border."
            ) {
                VStack(spacing: 12) {
                    SettingsControlRow(
                        title: "Show focus border on active pane",
                        description: "Display a border around whichever pane currently owns keyboard focus."
                    ) {
                        Toggle("", isOn: $viewModel.focusBorderEnabled)
                            .labelsHidden()
                    }

                    if viewModel.focusBorderEnabled {
                        Divider()

                        SettingsControlRow(
                            title: "Use system accent color",
                            description: "Follow the current macOS accent color automatically."
                        ) {
                            Toggle("", isOn: $viewModel.focusBorderUseAccent)
                                .labelsHidden()
                        }

                        Divider()

                        SettingsControlRow(
                            title: "Custom color",
                            description: "Pick a manual border color when accent following is disabled."
                        ) {
                            ColorPicker("", selection: $viewModel.focusBorderColor, supportsOpacity: false)
                                .labelsHidden()
                                .disabled(viewModel.focusBorderUseAccent)
                        }

                        Divider()

                        SettingsControlRow(
                            title: "Opacity",
                            description: "Set how strongly the focus border should read against pane backgrounds.",
                            alignment: .top
                        ) {
                            HStack(spacing: 8) {
                                Slider(value: $viewModel.focusBorderOpacity, in: 0.1...1.0, step: 0.05)
                                    .frame(width: 180)
                                Text("\(Int(viewModel.focusBorderOpacity * 100))%")
                                    .font(.caption.monospacedDigit())
                                    .foregroundStyle(.secondary)
                                    .frame(width: 42, alignment: .trailing)
                            }
                        }

                        Divider()

                        SettingsControlRow(
                            title: "Width",
                            description: "Choose how thick the border should appear around the focused pane."
                        ) {
                            Stepper(
                                "\(viewModel.focusBorderWidth, specifier: "%.0f") px",
                                value: $viewModel.focusBorderWidth,
                                in: 1...6,
                                step: 1
                            )
                            .frame(width: 120, alignment: .trailing)
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func sliderRow(value: Binding<Double>, label: String) -> some View {
        HStack(spacing: 8) {
            Slider(value: value, in: 0.0...0.3, step: 0.01)
                .frame(width: 180)
            Text(label)
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 48, alignment: .trailing)
        }
    }

    private func percentageText(for value: Double) -> String {
        value == 0 ? "Exact" : "\(Int(value * 100))%"
    }
}

struct AppKeybindingsSettingsTab: View {
    @Bindable var viewModel: SettingsViewModel
    @State private var searchText = ""
    @State private var crossLayerConflicts: [KeybindingConflict] = []

    private var filteredBindings: [KeybindingEntry] {
        let bindings = viewModel.keybindings
        guard !searchText.isEmpty else { return bindings }
        let query = searchText.lowercased()
        return bindings.filter {
            $0.displayName.lowercased().contains(query)
            || $0.action.lowercased().contains(query)
            || $0.shortcut.lowercased().contains(query)
        }
    }

    private var groupedBindings: [(String, [KeybindingEntry])] {
        let grouped = Dictionary(grouping: filteredBindings, by: \.category)
        return grouped.sorted { $0.key < $1.key }
    }

    private func crossLayerConflictActions(for shortcut: String) -> [String] {
        let normalized = ConflictDetector.normalizeShortcut(shortcut)
        for conflict in crossLayerConflicts where ConflictDetector.normalizeShortcut(conflict.shortcut) == normalized {
            return conflict.claimants
                .filter { $0.layer == "ghostty" }
                .map { "ghostty: \($0.action)" }
        }
        return []
    }

    var body: some View {
        SettingsDetailPage(section: .appShortcuts, contentWidth: 860) {
            SettingsGroupCard(
                title: "Find & Reset",
                description: "Search shortcut names, action identifiers, or recorded key combinations."
            ) {
                VStack(alignment: .leading, spacing: 12) {
                    HStack(spacing: 12) {
                        TextField("Filter shortcuts…", text: $searchText)
                            .textFieldStyle(.roundedBorder)

                        if viewModel.keybindings.contains(where: { !$0.isDefault }) {
                            Button("Reset All") {
                                viewModel.resetAllKeybindings()
                            }
                            .controlSize(.small)
                        }
                    }

                    Text("These are Pnevma window and pane shortcuts. Embedded terminal keybindings live in the Ghostty section.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            if groupedBindings.isEmpty {
                EmptyStateView(
                    icon: "keyboard",
                    title: "No Matching Shortcuts",
                    message: "Try a broader filter or clear the search field."
                )
                .frame(minHeight: 240)
            } else {
                VStack(spacing: 16) {
                    ForEach(groupedBindings, id: \.0) { category, bindings in
                        SettingsGroupCard(title: category) {
                            VStack(spacing: 0) {
                                ForEach(Array(bindings.enumerated()), id: \.element.id) { index, binding in
                                    keybindingRow(binding)
                                        .padding(.vertical, 10)

                                    if index < bindings.count - 1 {
                                        Divider()
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
        .onAppear { refreshCrossLayerConflicts() }
        .onChange(of: viewModel.keybindings) { refreshCrossLayerConflicts() }
    }

    @ViewBuilder
    private func keybindingRow(_ binding: KeybindingEntry) -> some View {
        HStack(alignment: .center, spacing: DesignTokens.Spacing.md) {
            VStack(alignment: .leading, spacing: 4) {
                Text(binding.displayName)
                    .font(.body.weight(.medium))
                Text(binding.action)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
            }

            Spacer()

            let intraConflicts = binding.conflictsWith
            let crossConflicts = crossLayerConflictActions(for: binding.shortcut)
            let allConflicts = intraConflicts + crossConflicts

            if !allConflicts.isEmpty {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.yellow)
                    .help("Conflicts with: \(allConflicts.joined(separator: ", "))")
            }

            ShortcutRecorderView(
                shortcut: Binding(
                    get: { binding.shortcut },
                    set: { newValue in
                        viewModel.updateKeybinding(action: binding.action, shortcut: newValue)
                    }
                ),
                isProtected: binding.isProtected
            )
            .frame(width: 140, height: 22)

            if !binding.isDefault {
                Button {
                    viewModel.resetKeybinding(action: binding.action)
                } label: {
                    Image(systemName: "arrow.counterclockwise")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Reset to default")
            }
        }
    }

    private func refreshCrossLayerConflicts() {
        let ghosttyBindings = (try? GhosttyConfigController.shared.loadSnapshot().keybinds) ?? []
        crossLayerConflicts = ConflictDetector.detect(
            pnevmaBindings: viewModel.keybindings,
            ghosttyBindings: ghosttyBindings
        )
    }
}

struct TerminalSettingsTab: View {
    @Bindable var viewModel: SettingsViewModel

    var body: some View {
        SettingsDetailPage(section: .terminal) {
            SettingsGroupCard(
                title: "Terminal Defaults",
                description: "Choose the typography and scrollback values that new sessions should start from."
            ) {
                VStack(spacing: 12) {
                    SettingsControlRow(
                        title: "Font",
                        description: "Default monospace face for newly created terminals."
                    ) {
                        Picker("", selection: $viewModel.terminalFont) {
                            Text("SF Mono").tag("SF Mono")
                            Text("Menlo").tag("Menlo")
                            Text("Monaco").tag("Monaco")
                            Text("Fira Code").tag("Fira Code")
                        }
                        .labelsHidden()
                        .pickerStyle(.menu)
                        .frame(width: 180)
                    }

                    Divider()

                    SettingsControlRow(
                        title: "Font size",
                        description: "Adjust the default terminal type size."
                    ) {
                        Stepper(
                            "\(viewModel.terminalFontSize) pt",
                            value: $viewModel.terminalFontSize,
                            in: 8...32
                        )
                        .frame(width: 120, alignment: .trailing)
                    }

                    Divider()

                    SettingsControlRow(
                        title: "Scrollback lines",
                        description: "Limit how many lines each terminal keeps in memory."
                    ) {
                        Stepper(
                            "\(viewModel.scrollbackLines)",
                            value: $viewModel.scrollbackLines,
                            in: 1000...100000,
                            step: 1000
                        )
                        .frame(width: 140, alignment: .trailing)
                    }
                }
            }

            SettingsGroupCard(title: "Current Runtime Behavior") {
                Text("These defaults are saved now, but the live embedded terminal still follows Ghostty configuration until runtime application is wired through.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}

// MARK: - Ghostty Settings Tab (Two-Column Layout)

struct GhosttySettingsTab: View {
    @Bindable var viewModel: GhosttySettingsViewModel
    @State private var showDiagnostics = false
    @State private var showPreview = false
    @State private var showThemeBrowser = false

    var body: some View {
        SettingsFramedDetailPage(section: .ghostty) {
            Group {
                if viewModel.snapshot != nil {
                    VStack(spacing: 0) {
                        GhosttySettingsToolbar(
                            viewModel: viewModel,
                            showDiagnostics: $showDiagnostics,
                            showThemeBrowser: $showThemeBrowser
                        )
                        Divider()
                        HStack(spacing: 0) {
                            GhosttyCategorySidebar(viewModel: viewModel)
                                .frame(minWidth: 220, idealWidth: 220, maxWidth: 220, maxHeight: .infinity)
                            Divider()
                            GhosttySettingsDetail(viewModel: viewModel)
                                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        Divider()
                        GhosttySettingsBottomBar(
                            viewModel: viewModel,
                            showPreview: $showPreview
                        )
                    }
                    .background(
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .fill(Color(nsColor: .controlBackgroundColor))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .stroke(Color.primary.opacity(0.05), lineWidth: 1)
                    )
                    .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                } else if viewModel.isLoading {
                    ProgressView("Loading Ghostty configuration\u{2026}")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    EmptyStateView(
                        icon: "exclamationmark.triangle",
                        title: "Ghostty Settings Unavailable",
                        message: viewModel.errorMessage,
                        actionTitle: "Retry",
                        action: { viewModel.reload() }
                    )
                }
            }
        }
        .onChange(of: viewModel.snapshot == nil) {
            if viewModel.snapshot == nil { showPreview = false }
        }
        .sheet(isPresented: $showPreview) {
            GhosttyPreviewSheet(preview: viewModel.snapshot?.generatedPreview ?? "")
        }
        .sheet(isPresented: $showThemeBrowser) {
            GhosttyThemeBrowserSheet(
                currentThemeName: viewModel.editedValues["theme"]?.first
                    ?? viewModel.snapshot?.effectiveValues["theme"],
                onApply: { themeName in
                    viewModel.editedValues["theme"] = [themeName]
                    viewModel.saveAndApply()
                }
            )
        }
    }
}

// MARK: - Toolbar

private struct GhosttySettingsToolbar: View {
    @Bindable var viewModel: GhosttySettingsViewModel
    @Binding var showDiagnostics: Bool
    @Binding var showThemeBrowser: Bool

    private var hasDiagnostics: Bool {
        let hasErrors = viewModel.errorMessage != nil && !(viewModel.errorMessage ?? "").isEmpty
        let hasValidation = !viewModel.validationMessages.isEmpty
        let hasDiags = !(viewModel.snapshot?.diagnostics.isEmpty ?? true)
        return hasErrors || hasValidation || hasDiags
    }

    var body: some View {
        HStack(spacing: DesignTokens.Spacing.sm) {
            TextField("Search settings\u{2026}", text: $viewModel.searchText)
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 280)
                .accessibilityLabel("Search Ghostty settings")

            Picker("Filter", selection: $viewModel.filterMode) {
                ForEach(GhosttySettingsViewModel.FilterMode.allCases) { mode in
                    Text(mode.title).tag(mode)
                }
            }
            .labelsHidden()
            .pickerStyle(.segmented)
            .frame(width: 200)

            Spacer()

            Button {
                showThemeBrowser = true
            } label: {
                Image(systemName: "paintbrush")
            }
            .buttonStyle(.plain)
            .help("Browse themes")
            .accessibilityLabel("Browse themes")

            if hasDiagnostics {
                Button {
                    showDiagnostics.toggle()
                } label: {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Show diagnostics")
                .popover(isPresented: $showDiagnostics) {
                    GhosttyDiagnosticsPopover(viewModel: viewModel)
                }
            }
        }
        .padding(.horizontal, DesignTokens.Spacing.md)
        .padding(.vertical, DesignTokens.Spacing.sm)
    }
}

// MARK: - Diagnostics Popover

private struct GhosttyDiagnosticsPopover: View {
    @Bindable var viewModel: GhosttySettingsViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.sm) {
            Text("Diagnostics")
                .font(.headline)

            if let error = viewModel.errorMessage, !error.isEmpty {
                Label(error, systemImage: "xmark.circle")
                    .foregroundStyle(.red)
                    .font(.caption)
            }

            ForEach(viewModel.validationMessages, id: \.self) { msg in
                Label(msg, systemImage: "exclamationmark.circle")
                    .foregroundStyle(.orange)
                    .font(.caption)
            }

            if let diags = viewModel.snapshot?.diagnostics {
                ForEach(diags, id: \.self) { msg in
                    Label(msg, systemImage: "info.circle")
                        .foregroundStyle(.secondary)
                        .font(.caption)
                }
            }
        }
        .padding(DesignTokens.Spacing.md)
        .frame(minWidth: 300, maxWidth: 400)
    }
}

// MARK: - Category Sidebar

private struct GhosttyCategorySidebar: View {
    @Bindable var viewModel: GhosttySettingsViewModel

    var body: some View {
        List(selection: $viewModel.selectedCategory) {
            ForEach(GhosttyConfigCategory.allCases) { category in
                if viewModel.shouldShowCategory(category) {
                    Label {
                        HStack {
                            Text(category.title)
                            Spacer()
                            let count = viewModel.changedCount(for: category)
                            if count > 0 {
                                Text("\(count)")
                                    .font(.caption2.weight(.bold))
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(Capsule().fill(Color.orange))
                                    .foregroundStyle(.white)
                            }
                        }
                    } icon: {
                        Image(systemName: category.systemImage)
                    }
                    .tag(category)
                }
            }
        }
        .listStyle(.sidebar)
        .onChange(of: viewModel.searchText) {
            autoSelectFirstVisible()
        }
        .onChange(of: viewModel.filterMode) {
            autoSelectFirstVisible()
        }
    }

    private func autoSelectFirstVisible() {
        if !viewModel.shouldShowCategory(viewModel.selectedCategory) {
            if let first = GhosttyConfigCategory.allCases.first(where: { viewModel.shouldShowCategory($0) }) {
                viewModel.selectedCategory = first
            }
        }
    }
}

// MARK: - Settings Detail

private struct GhosttySettingsDetail: View {
    @Bindable var viewModel: GhosttySettingsViewModel

    var body: some View {
        VStack(spacing: 0) {
            if let error = viewModel.errorMessage, !error.isEmpty {
                HStack(spacing: DesignTokens.Spacing.sm) {
                    Image(systemName: "exclamationmark.triangle.fill")
                    Text(error)
                        .lineLimit(2)
                }
                .font(.caption)
                .foregroundStyle(.red)
                .padding(DesignTokens.Spacing.sm)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.red.opacity(0.08))
            }

            if viewModel.selectedCategory == .keybindings {
                GhosttyKeybindingsPanel(viewModel: viewModel)
            } else {
                let items = viewModel.descriptors(for: viewModel.selectedCategory)
                if items.isEmpty {
                    EmptyStateView(
                        icon: "magnifyingglass",
                        title: "No Matching Settings",
                        message: viewModel.filterMode == .changed
                            ? "No changes in this category."
                            : "Try a different search term or filter."
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(Array(items.enumerated()), id: \.element.id) { index, descriptor in
                                GhosttyCompactFieldRow(viewModel: viewModel, descriptor: descriptor)
                                    .padding(.horizontal, DesignTokens.Spacing.md)
                                    .padding(.vertical, 10)

                                if index < items.count - 1 {
                                    Divider()
                                        .padding(.leading, DesignTokens.Spacing.md)
                                }
                            }
                        }
                        .padding(.vertical, 6)
                    }
                    .background(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .fill(Color(nsColor: .windowBackgroundColor))
                    )
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

// MARK: - Compact Field Row

private struct GhosttyCompactFieldRow: View {
    @Bindable var viewModel: GhosttySettingsViewModel
    let descriptor: GhosttyConfigDescriptor
    @State private var isHovering = false

    private enum SpecialControl {
        case stepper(min: Double, max: Double, step: Double, unit: String)
        case slider(min: Double, max: Double)
    }

    private static let specialControls: [String: SpecialControl] = [
        "font-size": .stepper(min: 6, max: 48, step: 0.5, unit: "pt"),
        "background-opacity": .slider(min: 0.1, max: 1.0),
        "background-blur": .stepper(min: 0, max: 80, step: 1, unit: ""),
        "window-padding-x": .stepper(min: 0, max: 128, step: 1, unit: "px"),
        "window-padding-y": .stepper(min: 0, max: 128, step: 1, unit: "px"),
        "scrollback-limit": .stepper(min: 0, max: 1_000_000, step: 1_000, unit: ""),
    ]

    var body: some View {
        HStack(spacing: DesignTokens.Spacing.sm) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: DesignTokens.Spacing.xs) {
                    Text(descriptor.title)
                        .font(.body)
                    if viewModel.isChanged(descriptor.key) {
                        Circle()
                            .fill(Color.orange)
                            .frame(width: 6, height: 6)
                    }
                }
                Text(descriptor.key)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }

            Spacer()

            controlForDescriptor

            if isHovering {
                HStack(spacing: DesignTokens.Spacing.xs) {
                    Link(destination: descriptor.docsURL) {
                        Image(systemName: "questionmark.circle")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)

                    Button {
                        viewModel.reset(key: descriptor.key)
                    } label: {
                        Image(systemName: "arrow.counterclockwise")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .disabled(!viewModel.isChanged(descriptor.key) && viewModel.origin(for: descriptor.key) != .managed)
                }
                .transition(.opacity.animation(.easeInOut(duration: DesignTokens.Motion.fast)))
            }
        }
        .onHover { isHovering = $0 }
    }

    @ViewBuilder
    private var controlForDescriptor: some View {
        if let special = Self.specialControls[descriptor.key] {
            specialControlView(special)
        } else if let options = GhosttySchema.enumOptions[descriptor.key] {
            Picker("", selection: viewModel.stringChoiceBinding(for: descriptor.key, defaultValue: options.first ?? "")) {
                ForEach(options, id: \.self) { option in
                    Text(option).tag(option)
                }
            }
            .pickerStyle(.menu)
            .frame(width: 200)
        } else {
            fallbackControl
        }
    }

    @ViewBuilder
    private func specialControlView(_ control: SpecialControl) -> some View {
        switch control {
        case let .stepper(min, max, step, unit):
            if step == 0.5 || descriptor.valueKind == .double {
                let binding = viewModel.doubleBinding(for: descriptor.key, defaultValue: min)
                Stepper(value: binding, in: min...max, step: step) {
                    Text("\(binding.wrappedValue, specifier: step < 1 ? "%.1f" : "%.0f")\(unit.isEmpty ? "" : " \(unit)")")
                        .font(.body.monospacedDigit())
                        .frame(width: 80, alignment: .trailing)
                }
            } else {
                let binding = viewModel.intBinding(for: descriptor.key, defaultValue: Int(min))
                Stepper(value: binding, in: Int(min)...Int(max), step: Int(step)) {
                    Text("\(binding.wrappedValue)\(unit.isEmpty ? "" : " \(unit)")")
                        .font(.body.monospacedDigit())
                        .frame(width: 80, alignment: .trailing)
                }
            }
        case let .slider(min, max):
            let binding = viewModel.doubleBinding(for: descriptor.key, defaultValue: max)
            HStack(spacing: DesignTokens.Spacing.sm) {
                Slider(value: binding, in: min...max)
                    .frame(width: 120)
                Text("\(binding.wrappedValue, specifier: "%.2f")")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(width: 36, alignment: .trailing)
            }
        }
    }

    @ViewBuilder
    private var fallbackControl: some View {
        switch descriptor.valueKind {
        case .toggle:
            Toggle("", isOn: viewModel.boolBinding(for: descriptor.key))
                .toggleStyle(.switch)
                .labelsHidden()
        case .integer:
            TextField("", text: viewModel.rawTextBinding(for: descriptor.key))
                .textFieldStyle(.roundedBorder)
                .frame(width: 100)
        case .double:
            TextField("", text: viewModel.rawTextBinding(for: descriptor.key))
                .textFieldStyle(.roundedBorder)
                .frame(width: 100)
        case .color:
            HStack(spacing: DesignTokens.Spacing.xs) {
                ColorPicker("", selection: viewModel.colorBinding(for: descriptor.key, defaultHex: "#FFFFFF"))
                    .labelsHidden()
                TextField("", text: viewModel.rawTextBinding(for: descriptor.key))
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 100)
            }
        case .multiLine:
            TextField("", text: viewModel.rawTextBinding(for: descriptor.key, multiLine: true), axis: .vertical)
                .font(.system(.body, design: .monospaced))
                .lineLimit(3...6)
                .textFieldStyle(.roundedBorder)
                .frame(minWidth: 200)
        case .string, .raw:
            TextField("", text: viewModel.rawTextBinding(for: descriptor.key))
                .textFieldStyle(.roundedBorder)
                .frame(width: 200)
        case .keybinds:
            EmptyView()
        }
    }
}

// MARK: - Keybindings Panel

private struct GhosttyKeybindingsPanel: View {
    @Bindable var viewModel: GhosttySettingsViewModel
    @State private var crossLayerConflicts: [KeybindingConflict] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Terminal Keybindings")
                    .font(.headline)
                Spacer()
                Button("Add Keybinding") {
                    viewModel.addKeybind()
                }
            }
            .padding(DesignTokens.Spacing.md)

            if viewModel.keybinds.isEmpty {
                EmptyStateView(
                    icon: "command",
                    title: "No Keybindings",
                    message: "Add custom Ghostty keybindings for the embedded terminal.",
                    actionTitle: "Add Keybinding",
                    action: { viewModel.addKeybind() }
                )
            } else {
                List {
                    ForEach(Array(viewModel.keybinds.enumerated()), id: \.element.id) { index, keybind in
                        GhosttyKeybindRow(
                            keybind: $viewModel.keybinds[index],
                            actionDescriptor: viewModel.keybindActionDescriptor(for: keybind.action),
                            onRemove: { viewModel.removeKeybind(keybind.id) },
                            pnevmaConflict: pnevmaConflictForTrigger(keybind.trigger)
                        )
                    }
                }
                .listStyle(.plain)
            }
        }
        .onAppear { refreshConflicts() }
        .onChange(of: viewModel.keybinds) { refreshConflicts() }
    }

    private func pnevmaConflictForTrigger(_ trigger: String) -> String? {
        let normalized = ConflictDetector.normalizeGhosttyTrigger(trigger)
        for conflict in crossLayerConflicts {
            if ConflictDetector.normalizeGhosttyTrigger(conflict.shortcut) == normalized
                || ConflictDetector.normalizeShortcut(conflict.shortcut) == normalized {
                let pnevmaActions = conflict.claimants
                    .filter { $0.layer == "pnevma" }
                    .map(\.action)
                if !pnevmaActions.isEmpty {
                    return pnevmaActions.joined(separator: ", ")
                }
            }
        }
        return nil
    }

    private func refreshConflicts() {
        let pnevmaBindings = AppRuntimeSettings.shared.snapshot.keybindings
        crossLayerConflicts = ConflictDetector.detect(
            pnevmaBindings: pnevmaBindings,
            ghosttyBindings: viewModel.keybinds
        )
    }
}

// MARK: - Keybind Row

private struct GhosttyKeybindRow: View {
    @Binding var keybind: GhosttyManagedKeybind
    let actionDescriptor: GhosttyKeybindActionDescriptor?
    let onRemove: () -> Void
    var pnevmaConflict: String?
    @State private var isHovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 8) {
                TextField("Trigger", text: $keybind.trigger)
                    .textFieldStyle(.roundedBorder)
                    .frame(minWidth: 180)

                if let conflict = pnevmaConflict {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.yellow)
                        .help("Conflicts with Pnevma: \(conflict)")
                }

                Picker("Action", selection: $keybind.action) {
                    ForEach(GhosttySchema.keybindActions) { action in
                        Text(action.name).tag(action.name)
                    }
                }
                .pickerStyle(.menu)
                .frame(width: 220)

                if let actionDescriptor, let placeholder = actionDescriptor.parameterPlaceholder {
                    TextField(placeholder, text: $keybind.parameter)
                        .textFieldStyle(.roundedBorder)
                        .frame(minWidth: 180)
                }

                Spacer()

                if isHovering, let actionDescriptor {
                    Link(destination: actionDescriptor.docsURL) {
                        Image(systemName: "questionmark.circle")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .transition(.opacity.animation(.easeInOut(duration: DesignTokens.Motion.fast)))
                }

                Button(role: .destructive, action: onRemove) {
                    Image(systemName: "trash")
                }
                .buttonStyle(.plain)
            }

            HStack(spacing: 12) {
                Toggle("Global", isOn: $keybind.isGlobal)
                Toggle("All", isOn: $keybind.isAll)
                Toggle("Unconsumed", isOn: $keybind.isUnconsumed)
                Toggle("Performable", isOn: $keybind.isPerformable)
            }
            .toggleStyle(.checkbox)

            Text(keybind.rawBinding)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)
        }
        .onHover { isHovering = $0 }
    }
}

// MARK: - Bottom Bar

private struct GhosttySettingsBottomBar: View {
    @Bindable var viewModel: GhosttySettingsViewModel
    @Binding var showPreview: Bool

    var body: some View {
        HStack(spacing: DesignTokens.Spacing.md) {
            if let snapshot = viewModel.snapshot {
                let editablePath = snapshot.includeIntegrated ? snapshot.managedPath : snapshot.configPath

                Text(editablePath.lastPathComponent)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .help(editablePath.path)

                Image(systemName: snapshot.includeIntegrated ? "checkmark.circle.fill" : "pencil.circle")
                    .font(.caption)
                    .foregroundStyle(snapshot.includeIntegrated ? Color.secondary : Color.orange)
                    .help(snapshot.includeIntegrated ? "Editing the Pnevma-managed Ghostty include file." : "Editing the main Ghostty config directly.")
            }

            Spacer()

            if let status = viewModel.statusMessage, !status.isEmpty {
                Text(status)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if viewModel.isDirty {
                Label("Unsaved", systemImage: "circle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }

            Spacer()

            Button {
                showPreview = true
            } label: {
                Image(systemName: "doc.text.magnifyingglass")
            }
            .help("Preview the editable Ghostty settings file")
            .accessibilityLabel("Preview the editable Ghostty settings file")

            Button("Reload") { viewModel.reload() }
            Button("Revert") { viewModel.revert() }
                .disabled(!viewModel.isDirty)
            Button("Save & Apply") { viewModel.saveAndApply() }
                .keyboardShortcut(.defaultAction)
                .disabled(viewModel.snapshot == nil)
        }
        .padding(.horizontal, DesignTokens.Spacing.md)
        .padding(.vertical, DesignTokens.Spacing.sm)
    }
}

// MARK: - Preview Sheet

private struct GhosttyPreviewSheet: View {
    let preview: String
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Ghostty File Preview")
                    .font(.headline)
                Spacer()
                Button("Copy") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(preview, forType: .string)
                }
                Button("Done") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
            .padding(DesignTokens.Spacing.md)

            Divider()

            ScrollView {
                Text(preview.isEmpty ? "# Ghostty config preview unavailable." : preview)
                    .font(.system(.body, design: .monospaced))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
                    .padding(DesignTokens.Spacing.md)
            }
        }
        .frame(minWidth: 500, minHeight: 400)
    }
}

@Observable @MainActor
final class SettingsViewModel {
    private let commandBus: (any CommandCalling)?

    var autoSave = true {
        didSet {
            guard !isRestoring else { return }
            scheduleSave()
        }
    }
    var restoreWindows = true {
        didSet {
            guard !isRestoring else { return }
            scheduleSave()
        }
    }
    var autoUpdate = true {
        didSet {
            guard !isRestoring else { return }
            scheduleSave()
        }
    }
    var defaultShell = "" {
        didSet {
            guard !isRestoring else { return }
            scheduleSave()
        }
    }
    var keybindings: [KeybindingEntry] = [] {
        didSet {
            guard !isRestoring else { return }
            scheduleSave()
        }
    }

    /// Track whether keybindings have been modified (to distinguish nil vs empty in save)
    private var keybindingsModified = false

    func updateKeybinding(action: String, shortcut: String) {
        guard let index = keybindings.firstIndex(where: { $0.action == action }) else { return }
        guard !keybindings[index].isProtected else { return }
        isRestoring = true
        keybindings[index].shortcut = shortcut
        keybindings[index].isDefault = false
        recalculateConflicts()
        isRestoring = false
        keybindingsModified = true
        scheduleSave()
    }

    func resetKeybinding(action: String) {
        guard let index = keybindings.firstIndex(where: { $0.action == action }) else { return }
        guard !keybindings[index].isProtected else { return }
        isRestoring = true
        keybindings[index].isDefault = true
        // Restore the shortcut from the stable defaults captured on first load.
        if let defaultShortcut = defaultKeybindingShortcuts[action] {
            keybindings[index].shortcut = defaultShortcut
        }
        recalculateConflicts()
        isRestoring = false
        keybindingsModified = true
        scheduleSave()
    }

    func resetAllKeybindings() {
        isRestoring = true
        for i in keybindings.indices {
            keybindings[i].isDefault = true
            if let defaultShortcut = defaultKeybindingShortcuts[keybindings[i].action] {
                keybindings[i].shortcut = defaultShortcut
            }
        }
        recalculateConflicts()
        isRestoring = false
        keybindingsModified = true
        scheduleSave()
    }

    private func recalculateConflicts() {
        let normalized = keybindings.map { ($0.action, ConflictDetector.normalizeShortcut($0.shortcut)) }
        var shortcutMap: [String: [String]] = [:]
        for (action, norm) in normalized {
            shortcutMap[norm, default: []].append(action)
        }
        for i in keybindings.indices {
            let norm = ConflictDetector.normalizeShortcut(keybindings[i].shortcut)
            keybindings[i].conflictsWith = shortcutMap[norm, default: []]
                .filter { $0 != keybindings[i].action }
        }
    }
    var terminalFont = "SF Mono" {
        didSet {
            guard !isRestoring else { return }
            scheduleSave()
        }
    }
    var terminalFontSize = 13 {
        didSet {
            guard !isRestoring else { return }
            scheduleSave()
        }
    }
    var scrollbackLines = 10000 {
        didSet {
            guard !isRestoring else { return }
            scheduleSave()
        }
    }
    var sidebarBackgroundOffset: Double = SidebarPreferences.backgroundOffset {
        didSet {
            guard !isRestoring else { return }
            SidebarPreferences.backgroundOffset = sidebarBackgroundOffset
            notifyBackgroundTintChanged()
            scheduleSave()
        }
    }
    var bottomToolBarAutoHide = false {
        didSet {
            guard !isRestoring else { return }
            scheduleSave()
        }
    }
    var toolDockBackgroundOffset: Double = ToolDockPreferences.backgroundOffset {
        didSet {
            guard !isRestoring else { return }
            ToolDockPreferences.backgroundOffset = toolDockBackgroundOffset
            notifyBackgroundTintChanged()
        }
    }
    var rightInspectorBackgroundOffset: Double = RightInspectorPreferences.backgroundOffset {
        didSet {
            guard !isRestoring else { return }
            RightInspectorPreferences.backgroundOffset = rightInspectorBackgroundOffset
            notifyBackgroundTintChanged()
        }
    }
    var focusBorderEnabled: Bool = FocusBorderPreferences.enabled {
        didSet {
            guard !isRestoring else { return }
            FocusBorderPreferences.enabled = focusBorderEnabled
            notifyFocusBorderChanged()
            scheduleSave()
        }
    }
    var focusBorderOpacity: CGFloat = FocusBorderPreferences.opacity {
        didSet {
            guard !isRestoring else { return }
            FocusBorderPreferences.opacity = focusBorderOpacity
            notifyFocusBorderChanged()
            scheduleSave()
        }
    }
    var focusBorderWidth: CGFloat = FocusBorderPreferences.width {
        didSet {
            guard !isRestoring else { return }
            FocusBorderPreferences.width = focusBorderWidth
            notifyFocusBorderChanged()
            scheduleSave()
        }
    }
    var focusBorderColor: Color = Color(nsColor: .controlAccentColor) {
        didSet {
            guard !isRestoring else { return }
            let ns = NSColor(focusBorderColor).usingColorSpace(.sRGB)
            FocusBorderPreferences.colorHex = ns?.hexString
            notifyFocusBorderChanged()
            scheduleSave()
        }
    }
    var focusBorderUseAccent: Bool = true {
        didSet {
            guard !isRestoring else { return }
            if focusBorderUseAccent {
                FocusBorderPreferences.colorHex = "accent"
                // Suppress the color didSet from overwriting "accent"
                isRestoring = true
                focusBorderColor = Color(nsColor: .controlAccentColor)
                isRestoring = false
            } else {
                let ns = NSColor(focusBorderColor).usingColorSpace(.sRGB)
                FocusBorderPreferences.colorHex = ns?.hexString
            }
            notifyFocusBorderChanged()
            scheduleSave()
        }
    }
    var telemetryEnabled = false {
        didSet {
            guard !isRestoring else { return }
            scheduleSave()
        }
    }
    var crashReports = false {
        didSet {
            guard !isRestoring else { return }
            scheduleSave()
        }
    }

    var updateCoordinator: AppUpdateCoordinator?
    private var isRestoring = false
    private var didLoadFromBackend = false
    private var saveTask: Task<Void, Never>?
    private var latestSaveGeneration: UInt64 = 0
    private var latestLoadedSnapshot: AppSettingsSnapshot?
    /// Default shortcut strings from the initial backend load (action → shortcut).
    /// Used by resetKeybinding to restore defaults without an async round-trip.
    private var defaultKeybindingShortcuts: [String: String] = [:]

    init(commandBus: (any CommandCalling)? = CommandBus.shared) {
        self.commandBus = commandBus
    }

    func load() {
        saveTask?.cancel()
        didLoadFromBackend = false

        guard let commandBus else {
            applyLocalPreferencesFallback()
            return
        }

        Task {
            do {
                let snapshot: AppSettingsSnapshot = try await commandBus.call(
                    method: "settings.app.get",
                    params: nil
                )
                latestLoadedSnapshot = snapshot
                didLoadFromBackend = true
                // Capture default shortcuts on first load for reset support.
                if defaultKeybindingShortcuts.isEmpty {
                    for kb in snapshot.keybindings where kb.isDefault {
                        defaultKeybindingShortcuts[kb.action] = kb.shortcut
                    }
                }
                AppRuntimeSettings.shared.apply(snapshot)
                apply(snapshot: snapshot)
                if self.updateCoordinator == nil,
                   let delegate = NSApp?.delegate as? AppDelegate {
                    self.updateCoordinator = delegate.updateCoordinator
                }
            } catch {
                Log.general.error("Failed to load app settings: \(error.localizedDescription, privacy: .public)")
                if let latestLoadedSnapshot {
                    didLoadFromBackend = true
                    apply(snapshot: latestLoadedSnapshot)
                } else {
                    applyLocalPreferencesFallback()
                }
            }
        }
    }

    func save() {
        latestSaveGeneration &+= 1
        persistSettings(generation: latestSaveGeneration)
    }

    private func persistSettings(generation: UInt64) {
        guard didLoadFromBackend, let commandBus else { return }

        // Build keybinding overrides:
        // - nil = don't touch keybindings (normal non-keybinding settings saves)
        // - [] = clear all overrides (reset all)
        // - [overrides] = set specific overrides
        let keybindingOverrides: [KeybindingOverrideSave]? = {
            guard keybindingsModified else { return nil }
            let nonDefaults = keybindings.filter { !$0.isDefault && !$0.isProtected }
            return nonDefaults.map {
                KeybindingOverrideSave(action: $0.action, shortcut: $0.shortcut)
            }
        }()

        let request = AppSettingsSaveRequest(
            autoSaveWorkspaceOnQuit: autoSave,
            restoreWindowsOnLaunch: restoreWindows,
            autoUpdate: autoUpdate,
            defaultShell: defaultShell,
            terminalFont: terminalFont,
            terminalFontSize: terminalFontSize,
            scrollbackLines: scrollbackLines,
            sidebarBackgroundOffset: sidebarBackgroundOffset,
            bottomToolBarAutoHide: bottomToolBarAutoHide,
            focusBorderEnabled: focusBorderEnabled,
            focusBorderOpacity: Double(focusBorderOpacity),
            focusBorderWidth: Double(focusBorderWidth),
            focusBorderColor: focusBorderUseAccent
                ? "accent"
                : (NSColor(focusBorderColor).usingColorSpace(.sRGB)?.hexString ?? "accent"),
            telemetryEnabled: telemetryEnabled,
            crashReports: crashReports,
            keybindings: keybindingOverrides
        )

        Task {
            do {
                let snapshot: AppSettingsSnapshot = try await commandBus.call(
                    method: "settings.app.set",
                    params: request
                )
                guard generation == latestSaveGeneration else { return }
                latestLoadedSnapshot = snapshot
                keybindingsModified = false
                AppRuntimeSettings.shared.apply(snapshot)
                apply(snapshot: snapshot)
            } catch {
                guard generation == latestSaveGeneration else { return }
                Log.general.error("Failed to save app settings: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    private func notifyBackgroundTintChanged() {
        NotificationCenter.default.post(name: .backgroundTintDidChange, object: nil)
    }

    private func notifyFocusBorderChanged() {
        NotificationCenter.default.post(name: .focusBorderPreferencesChanged, object: nil)
    }

    private func scheduleSave() {
        guard didLoadFromBackend else { return }
        saveTask?.cancel()
        latestSaveGeneration &+= 1
        let generation = latestSaveGeneration
        saveTask = Task {
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            persistSettings(generation: generation)
        }
    }

    private func apply(snapshot: AppSettingsSnapshot) {
        isRestoring = true
        defer {
            isRestoring = false
            notifyFocusBorderChanged()
            GhosttyThemeProvider.shared.refresh()
        }

        autoSave = snapshot.autoSaveWorkspaceOnQuit
        restoreWindows = snapshot.restoreWindowsOnLaunch
        autoUpdate = snapshot.autoUpdate
        defaultShell = snapshot.defaultShell
        terminalFont = snapshot.terminalFont
        terminalFontSize = Int(snapshot.terminalFontSize)
        scrollbackLines = Int(snapshot.scrollbackLines)
        sidebarBackgroundOffset = snapshot.sidebarBackgroundOffset
        bottomToolBarAutoHide = snapshot.bottomToolBarAutoHide
        telemetryEnabled = snapshot.telemetryEnabled
        crashReports = snapshot.crashReports
        keybindings = snapshot.keybindings

        SidebarPreferences.backgroundOffset = snapshot.sidebarBackgroundOffset
        toolDockBackgroundOffset = ToolDockPreferences.backgroundOffset
        rightInspectorBackgroundOffset = RightInspectorPreferences.backgroundOffset
        FocusBorderPreferences.enabled = snapshot.focusBorderEnabled
        FocusBorderPreferences.opacity = CGFloat(snapshot.focusBorderOpacity)
        FocusBorderPreferences.width = CGFloat(snapshot.focusBorderWidth)
        FocusBorderPreferences.colorHex = snapshot.focusBorderColor == "accent"
            ? "accent"
            : snapshot.focusBorderColor

        focusBorderEnabled = snapshot.focusBorderEnabled
        focusBorderOpacity = CGFloat(snapshot.focusBorderOpacity)
        focusBorderWidth = CGFloat(snapshot.focusBorderWidth)
        focusBorderUseAccent = snapshot.focusBorderColor == "accent"
        if focusBorderUseAccent {
            focusBorderColor = Color(nsColor: .controlAccentColor)
        } else if let ns = NSColor(hexString: snapshot.focusBorderColor) {
            focusBorderColor = Color(nsColor: ns)
        } else {
            focusBorderUseAccent = true
            focusBorderColor = Color(nsColor: .controlAccentColor)
        }
    }

    private func applyLocalPreferencesFallback() {
        isRestoring = true
        defer {
            isRestoring = false
            notifyFocusBorderChanged()
        }
        sidebarBackgroundOffset = SidebarPreferences.backgroundOffset
        toolDockBackgroundOffset = ToolDockPreferences.backgroundOffset
        rightInspectorBackgroundOffset = RightInspectorPreferences.backgroundOffset
        bottomToolBarAutoHide = false
        focusBorderEnabled = FocusBorderPreferences.enabled
        focusBorderOpacity = FocusBorderPreferences.opacity
        focusBorderWidth = FocusBorderPreferences.width
        let hex = FocusBorderPreferences.colorHex
        focusBorderUseAccent = hex == nil || hex == "accent" || hex?.isEmpty == true
        if focusBorderUseAccent {
            focusBorderColor = Color(nsColor: .controlAccentColor)
        } else if let hex, let ns = NSColor(hexString: hex) {
            focusBorderColor = Color(nsColor: ns)
        }
    }
}

struct TelemetrySettingsTab: View {
    @Bindable var viewModel: SettingsViewModel

    var body: some View {
        SettingsDetailPage(section: .telemetry) {
            SettingsGroupCard(
                title: "Analytics & Diagnostics",
                description: "Control whether anonymous usage information and future crash diagnostics are allowed."
            ) {
                VStack(spacing: 12) {
                    SettingsControlRow(
                        title: "Enable usage analytics",
                        description: "Allow anonymous product usage events that help improve overall product quality."
                    ) {
                        Toggle("", isOn: $viewModel.telemetryEnabled)
                            .labelsHidden()
                    }

                    Divider()

                    SettingsControlRow(
                        title: "Share crash reports",
                        description: "Persist your preference now for the planned crash-reporting integration."
                    ) {
                        Toggle("", isOn: $viewModel.crashReports)
                            .labelsHidden()
                    }
                }
            }

            SettingsGroupCard(title: "What This Means") {
                Text("Usage analytics controls backend telemetry event collection. Crash report sharing is stored for future crash-report integration and is not active in the current build.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            if viewModel.telemetryEnabled {
                SettingsGroupCard(title: "What We Collect") {
                    Text("Anonymous usage statistics help us improve Pnevma. No code, file contents, or personal data is transmitted.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }
}

final class SettingsPaneView: NSView, PaneContent {
    let paneID = PaneID()
    let paneType = "settings"
    let shouldPersist = true
    var title: String { "Settings" }

    override init(frame: NSRect) {
        super.init(frame: frame)
        _ = addSwiftUISubview(SettingsView())
    }

    required init?(coder: NSCoder) { fatalError() }
}
