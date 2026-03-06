import Cocoa
import SwiftUI

struct SettingsView: View {
    @StateObject private var appViewModel = SettingsViewModel()
    @StateObject private var ghosttyViewModel = GhosttySettingsViewModel()

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

            TelemetrySettingsTab(viewModel: appViewModel)
                .tabItem { Label("Telemetry", systemImage: "chart.bar") }
        }
        .padding(16)
        .onAppear {
            appViewModel.load()
            ghosttyViewModel.load()
        }
    }
}

struct GeneralSettingsTab: View {
    @ObservedObject var viewModel: SettingsViewModel

    var body: some View {
        Form {
            Toggle("Auto-save workspace on quit", isOn: $viewModel.autoSave)
            Toggle("Restore windows on launch", isOn: $viewModel.restoreWindows)
            Toggle("Check for updates automatically", isOn: $viewModel.autoUpdate)

            Picker("Default shell", selection: $viewModel.defaultShell) {
                Text("System default").tag("")
                Text("/bin/zsh").tag("/bin/zsh")
                Text("/bin/bash").tag("/bin/bash")
            }
        }
        .formStyle(.grouped)
    }
}

struct AppKeybindingsSettingsTab: View {
    @ObservedObject var viewModel: SettingsViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Pnevma App Shortcuts")
                .font(.headline)

            Text("These are Pnevma window and pane shortcuts. Ghostty terminal keybindings are edited in the Ghostty tab.")
                .font(.caption)
                .foregroundStyle(.secondary)

            List(viewModel.keybindings) { binding in
                HStack {
                    Text(binding.action)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Text(binding.shortcut)
                        .font(.system(.body, design: .monospaced))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 2)
                        .background(
                            RoundedRectangle(cornerRadius: 4)
                                .fill(Color(nsColor: .controlBackgroundColor))
                        )
                }
            }
            .listStyle(.plain)
        }
        .padding()
    }
}

struct TerminalSettingsTab: View {
    @ObservedObject var viewModel: SettingsViewModel

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

            Text("These settings are Pnevma-local terminal defaults. Embedded Ghostty behavior and appearance are edited in the Ghostty tab.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .formStyle(.grouped)
    }
}

struct GhosttySettingsTab: View {
    @ObservedObject var viewModel: GhosttySettingsViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            if let snapshot = viewModel.snapshot {
                diagnostics(snapshot: snapshot)
                content(snapshot: snapshot)
            } else if viewModel.isLoading {
                ProgressView("Loading Ghostty configuration…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ContentUnavailableView("Ghostty Settings Unavailable", systemImage: "exclamationmark.triangle")
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Ghostty Configuration")
                        .font(.title3.weight(.semibold))
                    Text("Structured editor for the Ghostty config that Pnevma embeds. Freeform fields use Ghostty literal syntax.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                HStack(spacing: 8) {
                    Button("Reload") { viewModel.reload() }
                    Button("Validate") { viewModel.validateOnly() }
                    Button("Revert") { viewModel.revert() }
                        .disabled(!viewModel.isDirty)
                    Button("Save & Apply") { viewModel.saveAndApply() }
                        .keyboardShortcut(.defaultAction)
                        .disabled(viewModel.snapshot == nil)
                }
            }

            if let snapshot = viewModel.snapshot {
                HStack(spacing: 10) {
                    Label(snapshot.configPath.path, systemImage: "doc.text")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Label(snapshot.includeIntegrated ? "Managed include active" : "Managed include will be added on save", systemImage: snapshot.includeIntegrated ? "checkmark.circle" : "wrench.and.screwdriver")
                        .font(.caption)
                        .foregroundStyle(snapshot.includeIntegrated ? Color.secondary : Color.orange)
                    if viewModel.isDirty {
                        Label("Unsaved changes", systemImage: "circle.fill")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                }
            }

            HStack(spacing: 12) {
                TextField("Search Ghostty settings", text: $viewModel.searchText)
                    .textFieldStyle(.roundedBorder)

                Picker("Filter", selection: $viewModel.filterMode) {
                    ForEach(GhosttySettingsViewModel.FilterMode.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .frame(width: 240)
            }
        }
    }

    private func diagnostics(snapshot: GhosttyConfigSnapshot) -> some View {
        GroupBox("Diagnostics") {
            VStack(alignment: .leading, spacing: 6) {
                if let statusMessage = viewModel.statusMessage, !statusMessage.isEmpty {
                    Text(statusMessage)
                        .foregroundStyle(.secondary)
                }

                if let errorMessage = viewModel.errorMessage, !errorMessage.isEmpty {
                    Text(errorMessage)
                        .foregroundStyle(.red)
                }

                if !viewModel.validationMessages.isEmpty {
                    ForEach(viewModel.validationMessages, id: \.self) { message in
                        Text("• \(message)")
                            .foregroundStyle(.orange)
                    }
                }

                if snapshot.diagnostics.isEmpty {
                    Text("No Ghostty diagnostics reported.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(snapshot.diagnostics, id: \.self) { message in
                        Text("• \(message)")
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func content(snapshot: GhosttyConfigSnapshot) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                ForEach(GhosttyConfigCategory.allCases) { category in
                    if viewModel.shouldShowCategory(category) {
                        GroupBox(category.title) {
                            VStack(alignment: .leading, spacing: 16) {
                                ForEach(viewModel.descriptors(for: category)) { descriptor in
                                    GhosttyFieldEditor(viewModel: viewModel, descriptor: descriptor)
                                    Divider()
                                }
                            }
                            .padding(.top, 6)
                        }
                    }
                }

                if viewModel.shouldShowKeybinds() {
                    GroupBox("Keybindings") {
                        VStack(alignment: .leading, spacing: 12) {
                            Text("Ghostty keybindings are written into the Pnevma-managed include file. Sequence triggers and action parameters use Ghostty syntax.")
                                .font(.caption)
                                .foregroundStyle(.secondary)

                            ForEach(Array(viewModel.keybinds.enumerated()), id: \.element.id) { index, keybind in
                                GhosttyKeybindRow(
                                    keybind: $viewModel.keybinds[index],
                                    actionDescriptor: viewModel.keybindActionDescriptor(for: keybind.action),
                                    onRemove: { viewModel.removeKeybind(keybind.id) }
                                )
                                Divider()
                            }

                            Button("Add Keybinding") {
                                viewModel.addKeybind()
                            }
                        }
                        .padding(.top, 6)
                    }
                }

                GroupBox("Generated File Preview") {
                    Text(snapshot.generatedPreview.isEmpty ? "# Pnevma has not written a managed Ghostty file yet." : snapshot.generatedPreview)
                        .font(.system(.caption, design: .monospaced))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                }
            }
            .padding(.vertical, 4)
        }
    }
}

private struct GhosttyFieldEditor: View {
    @ObservedObject var viewModel: GhosttySettingsViewModel
    let descriptor: GhosttyConfigDescriptor

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(descriptor.title)
                    .font(.headline)
                SettingsBadge(title: viewModel.originLabel(for: descriptor.key), color: badgeColor)
                if viewModel.isChanged(descriptor.key) {
                    SettingsBadge(title: "Changed", color: .orange)
                }
                Spacer()
                Link(destination: descriptor.docsURL) {
                    Label("Docs", systemImage: "link")
                        .font(.caption)
                }
                Button("Reset") {
                    viewModel.reset(key: descriptor.key)
                }
                .buttonStyle(.link)
                .disabled(viewModel.origin(for: descriptor.key) != .managed && !viewModel.isChanged(descriptor.key))
            }

            switch descriptor.key {
            case "cursor-style":
                selector(["block", "bar", "underline", "block_hollow"], binding: viewModel.stringChoiceBinding(for: descriptor.key, defaultValue: "block"))
            case "window-theme":
                selector(["auto", "system", "light", "dark", "ghostty"], binding: viewModel.stringChoiceBinding(for: descriptor.key, defaultValue: "auto"))
            case "window-decoration":
                selector(["auto", "none", "server", "client"], binding: viewModel.stringChoiceBinding(for: descriptor.key, defaultValue: "auto"))
            case "window-show-tab-bar":
                selector(["auto", "always", "never"], binding: viewModel.stringChoiceBinding(for: descriptor.key, defaultValue: "auto"))
            case "right-click-action":
                selector(["context-menu", "paste", "copy", "copy-or-paste", "ignore"], binding: viewModel.stringChoiceBinding(for: descriptor.key, defaultValue: "context-menu"))
            case "copy-on-select":
                selector(["false", "true", "clipboard"], binding: viewModel.stringChoiceBinding(for: descriptor.key, defaultValue: "true"))
            case "macos-titlebar-style":
                selector(["native", "transparent", "tabs", "hidden"], binding: viewModel.stringChoiceBinding(for: descriptor.key, defaultValue: "transparent"))
            case "macos-window-buttons":
                selector(["visible", "hidden"], binding: viewModel.stringChoiceBinding(for: descriptor.key, defaultValue: "visible"))
            case "macos-option-as-alt":
                selector(["false", "true", "left", "right"], binding: viewModel.stringChoiceBinding(for: descriptor.key, defaultValue: "false"))
            case "quick-terminal-position":
                selector(["top", "bottom", "left", "right", "center"], binding: viewModel.stringChoiceBinding(for: descriptor.key, defaultValue: "top"))
            case "background", "foreground", "window-titlebar-background", "window-titlebar-foreground":
                VStack(alignment: .leading, spacing: 8) {
                    ColorPicker("Color", selection: viewModel.colorBinding(for: descriptor.key, defaultHex: "#FFFFFF"))
                    TextField("Hex color", text: viewModel.rawTextBinding(for: descriptor.key))
                        .textFieldStyle(.roundedBorder)
                }
            case "font-size":
                Stepper(value: viewModel.doubleBinding(for: descriptor.key, defaultValue: 13), in: 6...48, step: 0.5) {
                    Text("Font size: \(viewModel.doubleBinding(for: descriptor.key, defaultValue: 13).wrappedValue, specifier: "%.1f")")
                }
            case "background-opacity":
                VStack(alignment: .leading, spacing: 8) {
                    Slider(value: viewModel.doubleBinding(for: descriptor.key, defaultValue: 1), in: 0.1...1)
                    Text("\(viewModel.doubleBinding(for: descriptor.key, defaultValue: 1).wrappedValue, specifier: "%.2f")")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            case "background-blur":
                Stepper(value: viewModel.intBinding(for: descriptor.key, defaultValue: 0), in: 0...80) {
                    Text("Blur radius: \(viewModel.intBinding(for: descriptor.key, defaultValue: 0).wrappedValue)")
                }
            case "window-padding-x", "window-padding-y":
                Stepper(value: viewModel.intBinding(for: descriptor.key, defaultValue: 0), in: 0...128) {
                    Text("\(descriptor.title): \(viewModel.intBinding(for: descriptor.key, defaultValue: 0).wrappedValue)")
                }
            case "scrollback-limit":
                Stepper(value: viewModel.intBinding(for: descriptor.key, defaultValue: 10000), in: 0...1_000_000, step: 1_000) {
                    Text("Scrollback limit: \(viewModel.intBinding(for: descriptor.key, defaultValue: 10000).wrappedValue)")
                }
            case "mouse-hide-while-typing", "wait-after-command", "desktop-notifications", "macos-window-shadow", "quick-terminal-autohide", "cursor-style-blink":
                Toggle("Enabled", isOn: viewModel.boolBinding(for: descriptor.key))
            default:
                fallbackControl
            }
        }
    }

    private var badgeColor: Color {
        switch viewModel.origin(for: descriptor.key) {
        case .managed:
            return .blue
        case .manual:
            return .orange
        case .inherited:
            return .secondary
        }
    }

    @ViewBuilder
    private var fallbackControl: some View {
        switch descriptor.valueKind {
        case .toggle:
            Toggle("Enabled", isOn: viewModel.boolBinding(for: descriptor.key))
        case .integer:
            TextField("Number", text: viewModel.rawTextBinding(for: descriptor.key))
                .textFieldStyle(.roundedBorder)
        case .double:
            TextField("Number", text: viewModel.rawTextBinding(for: descriptor.key))
                .textFieldStyle(.roundedBorder)
        case .color:
            VStack(alignment: .leading, spacing: 8) {
                ColorPicker("Color", selection: viewModel.colorBinding(for: descriptor.key, defaultHex: "#FFFFFF"))
                TextField("Hex color", text: viewModel.rawTextBinding(for: descriptor.key))
                    .textFieldStyle(.roundedBorder)
            }
        case .multiLine:
            TextEditor(text: viewModel.rawTextBinding(for: descriptor.key, multiLine: true))
                .font(.system(.body, design: .monospaced))
                .frame(minHeight: 90)
                .overlay {
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(Color.secondary.opacity(0.2))
                }
        case .string, .raw:
            TextField("Ghostty literal", text: viewModel.rawTextBinding(for: descriptor.key))
                .textFieldStyle(.roundedBorder)
        case .keybinds:
            EmptyView()
        }
    }

    private func selector(_ options: [String], binding: Binding<String>) -> some View {
        Picker(descriptor.title, selection: binding) {
            ForEach(options, id: \.self) { option in
                Text(option).tag(option)
            }
        }
        .pickerStyle(.menu)
    }
}

private struct GhosttyKeybindRow: View {
    @Binding var keybind: GhosttyManagedKeybind
    let actionDescriptor: GhosttyKeybindActionDescriptor?
    let onRemove: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 8) {
                TextField("Trigger", text: $keybind.trigger)
                    .textFieldStyle(.roundedBorder)
                    .frame(minWidth: 180)

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

                if let actionDescriptor {
                    Link(destination: actionDescriptor.docsURL) {
                        Image(systemName: "link")
                    }
                    .buttonStyle(.plain)
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
    }
}

private struct SettingsBadge: View {
    let title: String
    let color: Color

    var body: some View {
        Text(title)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(
                Capsule()
                    .fill(color.opacity(0.15))
            )
            .foregroundStyle(color)
    }
}

struct KeybindingEntry: Identifiable, Codable {
    var id: String { action }
    let action: String
    let shortcut: String
}

final class SettingsViewModel: ObservableObject {
    @Published var autoSave = true
    @Published var restoreWindows = true
    @Published var autoUpdate = true
    @Published var defaultShell = ""
    @Published var keybindings: [KeybindingEntry] = [
        KeybindingEntry(action: "Split Right", shortcut: "Cmd+D"),
        KeybindingEntry(action: "Split Down", shortcut: "Shift+Cmd+D"),
        KeybindingEntry(action: "Close Pane", shortcut: "Cmd+W"),
        KeybindingEntry(action: "Navigate Left", shortcut: "Opt+Cmd+Left"),
        KeybindingEntry(action: "Navigate Right", shortcut: "Opt+Cmd+Right"),
        KeybindingEntry(action: "Navigate Up", shortcut: "Opt+Cmd+Up"),
        KeybindingEntry(action: "Navigate Down", shortcut: "Opt+Cmd+Down"),
        KeybindingEntry(action: "Command Palette", shortcut: "Cmd+K"),
        KeybindingEntry(action: "Toggle Sidebar", shortcut: "Cmd+B"),
    ]
    @Published var terminalFont = "SF Mono"
    @Published var terminalFontSize = 13
    @Published var scrollbackLines = 10000
    @Published var telemetryEnabled = false
    @Published var crashReports = false

    func load() {
        // TODO: Replace local stubs with backend-backed settings.
    }

    func save() {
        // TODO: Replace local stubs with backend-backed settings.
    }
}

struct TelemetrySettingsTab: View {
    @ObservedObject var viewModel: SettingsViewModel

    var body: some View {
        Form {
            Toggle("Enable usage analytics", isOn: $viewModel.telemetryEnabled)
            Toggle("Share crash reports", isOn: $viewModel.crashReports)

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
    var title: String { "Settings" }

    override init(frame: NSRect) {
        super.init(frame: frame)
        _ = addSwiftUISubview(SettingsView())
    }

    required init?(coder: NSCoder) { fatalError() }
}
