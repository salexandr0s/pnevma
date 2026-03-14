import Cocoa
import Observation
import SwiftUI

struct SettingsView: View {
    @State private var appViewModel = SettingsViewModel()
    @State private var ghosttyViewModel = GhosttySettingsViewModel()
    @State private var providerUsageViewModel = ProviderUsageSettingsViewModel()

    var body: some View {
        TabView {
            GeneralSettingsTab(viewModel: appViewModel)
                .tabItem { Label("General", systemImage: "gear") }

            AppKeybindingsSettingsTab(viewModel: appViewModel)
                .tabItem { Label("App Shortcuts", systemImage: "keyboard") }

            TerminalSettingsTab(viewModel: appViewModel)
                .tabItem { Label("Terminal", systemImage: "terminal") }

            GhosttySettingsTab(viewModel: ghosttyViewModel)
                .tabItem { Label("Ghostty", systemImage: "slider.horizontal.3") }

            ProviderUsageSettingsTab(viewModel: providerUsageViewModel)
                .tabItem { Label("Usage", systemImage: "chart.line.uptrend.xyaxis") }

            TelemetrySettingsTab(viewModel: appViewModel)
                .tabItem { Label("Telemetry", systemImage: "chart.bar") }
        }
        .padding(16)
        .task {
            appViewModel.load()
            ghosttyViewModel.load()
            providerUsageViewModel.load()
        }
        .accessibilityIdentifier("settings.root")
    }
}

struct GeneralSettingsTab: View {
    @Bindable var viewModel: SettingsViewModel

    var body: some View {
        Form {
            Toggle("Auto-save workspace on quit", isOn: $viewModel.autoSave)
            Toggle("Restore windows on launch", isOn: $viewModel.restoreWindows)
            Toggle("Check for updates automatically", isOn: $viewModel.autoUpdate)

            if let coordinator = viewModel.updateCoordinator {
                GroupBox("Version Info") {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text("Current version:")
                                .foregroundStyle(.secondary)
                            Text("\(coordinator.state.currentVersion) (build \(coordinator.state.currentBuild))")
                        }
                        .font(.caption)

                        if let latest = coordinator.state.latestVersion {
                            HStack {
                                Text("Latest release:")
                                    .foregroundStyle(.secondary)
                                Text(latest)
                            }
                            .font(.caption)
                        }

                        if let lastCheck = coordinator.state.lastCheckAt {
                            HStack {
                                Text("Last checked:")
                                    .foregroundStyle(.secondary)
                                Text(lastCheck, style: .relative)
                            }
                            .font(.caption)
                        }

                        HStack {
                            Text("Status:")
                                .foregroundStyle(.secondary)
                            updateStatusLabel(coordinator.state.status)
                        }
                        .font(.caption)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            } else {
                Text("Version checking initializes after settings load completes.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Picker("Default shell", selection: $viewModel.defaultShell) {
                Text("System default").tag("")
                Text("/bin/zsh").tag("/bin/zsh")
                Text("/bin/bash").tag("/bin/bash")
            }

            Section("Sidebar") {
                HStack {
                    Text("Background tint")
                    Slider(value: $viewModel.sidebarBackgroundOffset, in: 0.0...0.3, step: 0.01)
                    Text(viewModel.sidebarBackgroundOffset == 0 ? "Exact" : "\(Int(viewModel.sidebarBackgroundOffset * 100))%")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(width: 40, alignment: .trailing)
                }
            }

            Section("Focus Border") {
                Toggle("Show focus border on active pane", isOn: $viewModel.focusBorderEnabled)

                if viewModel.focusBorderEnabled {
                    Toggle("Use system accent color", isOn: $viewModel.focusBorderUseAccent)

                    ColorPicker("Color", selection: $viewModel.focusBorderColor, supportsOpacity: false)
                        .disabled(viewModel.focusBorderUseAccent)

                    HStack {
                        Text("Opacity")
                        Slider(value: $viewModel.focusBorderOpacity, in: 0.1...1.0, step: 0.05)
                        Text("\(Int(viewModel.focusBorderOpacity * 100))%")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .frame(width: 36, alignment: .trailing)
                    }

                    Stepper("Width: \(viewModel.focusBorderWidth, specifier: "%.0f")px",
                            value: $viewModel.focusBorderWidth, in: 1...6, step: 1)
                }
            }
        }
        .formStyle(.grouped)
    }

    @ViewBuilder
    private func updateStatusLabel(_ status: AppUpdateStatus) -> some View {
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
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Pnevma App Shortcuts")
                    .font(.headline)
                Spacer()
                if viewModel.keybindings.contains(where: { !$0.isDefault }) {
                    Button("Reset All") {
                        viewModel.resetAllKeybindings()
                    }
                    .controlSize(.small)
                }
            }

            Text("These are Pnevma window and pane shortcuts. Ghostty terminal keybindings are edited in the Ghostty tab.")
                .font(.caption)
                .foregroundStyle(.secondary)

            TextField("Filter shortcuts…", text: $searchText)
                .textFieldStyle(.roundedBorder)
                .controlSize(.small)

            List {
                ForEach(groupedBindings, id: \.0) { category, bindings in
                    Section(category) {
                        ForEach(bindings) { binding in
                            keybindingRow(binding)
                        }
                    }
                }
            }
            .listStyle(.plain)
        }
        .padding()
        .onAppear { refreshCrossLayerConflicts() }
        .onChange(of: viewModel.keybindings) { refreshCrossLayerConflicts() }
    }

    @ViewBuilder
    private func keybindingRow(_ binding: KeybindingEntry) -> some View {
        HStack {
            Text(binding.displayName)
                .frame(maxWidth: .infinity, alignment: .leading)

            // Conflict indicators
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
        Form {
            Picker("Font", selection: $viewModel.terminalFont) {
                Text("SF Mono").tag("SF Mono")
                Text("Menlo").tag("Menlo")
                Text("Monaco").tag("Monaco")
                Text("Fira Code").tag("Fira Code")
            }

            Stepper("Font size: \(viewModel.terminalFontSize)", value: $viewModel.terminalFontSize,
                    in: 8...32)

            Stepper("Scrollback lines: \(viewModel.scrollbackLines)",
                    value: $viewModel.scrollbackLines, in: 1000...100000, step: 1000)

            Text("These terminal defaults are saved but not yet applied at runtime. Current terminal font, size, and scrollback still follow Ghostty configuration in the Ghostty tab.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .formStyle(.grouped)
    }
}

// MARK: - Ghostty Settings Tab (Two-Column Layout)

struct GhosttySettingsTab: View {
    @Bindable var viewModel: GhosttySettingsViewModel
    @State private var showDiagnostics = false
    @State private var showPreview = false
    @State private var showThemeBrowser = false

    var body: some View {
        VStack(spacing: 0) {
            if viewModel.snapshot != nil {
                GhosttySettingsToolbar(
                    viewModel: viewModel,
                    showDiagnostics: $showDiagnostics,
                    showThemeBrowser: $showThemeBrowser
                )
                Divider()
                HSplitView {
                    GhosttyCategorySidebar(viewModel: viewModel)
                        .frame(minWidth: 180, idealWidth: 200, maxWidth: 240)
                    GhosttySettingsDetail(viewModel: viewModel)
                }
                Divider()
                GhosttySettingsBottomBar(
                    viewModel: viewModel,
                    showPreview: $showPreview
                )
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
                } else {
                    Form {
                        ForEach(items) { descriptor in
                            GhosttyCompactFieldRow(viewModel: viewModel, descriptor: descriptor)
                        }
                    }
                    .formStyle(.grouped)
                }
            }
        }
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
            GhosttyThemeProvider.shared.refresh()
            scheduleSave()
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
        telemetryEnabled = snapshot.telemetryEnabled
        crashReports = snapshot.crashReports
        keybindings = snapshot.keybindings

        SidebarPreferences.backgroundOffset = snapshot.sidebarBackgroundOffset
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
        Form {
            Toggle("Enable usage analytics", isOn: $viewModel.telemetryEnabled)
            Toggle("Share crash reports", isOn: $viewModel.crashReports)

            Text("Usage analytics controls backend telemetry event collection. Crash report sharing is saved for future crash-report integration and is not active in the current build.")
                .font(.caption)
                .foregroundStyle(.secondary)

            if viewModel.telemetryEnabled {
                GroupBox("What we collect") {
                    Text("Anonymous usage statistics help us improve Pnevma. No code, file contents, or personal data is transmitted.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
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
