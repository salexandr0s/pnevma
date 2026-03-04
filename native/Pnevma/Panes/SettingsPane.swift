import SwiftUI
import Cocoa

// MARK: - SettingsView

struct SettingsView: View {
    @StateObject private var viewModel = SettingsViewModel()

    var body: some View {
        TabView {
            GeneralSettingsTab(viewModel: viewModel)
                .tabItem { Label("General", systemImage: "gear") }

            KeybindingsSettingsTab(viewModel: viewModel)
                .tabItem { Label("Keybindings", systemImage: "keyboard") }

            TerminalSettingsTab(viewModel: viewModel)
                .tabItem { Label("Terminal", systemImage: "terminal") }

            TelemetrySettingsTab(viewModel: viewModel)
                .tabItem { Label("Telemetry", systemImage: "chart.bar") }
        }
        .padding(16)
        .onAppear { viewModel.load() }
    }
}

// MARK: - General

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

// MARK: - Keybindings

struct KeybindingsSettingsTab: View {
    @ObservedObject var viewModel: SettingsViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Keybindings")
                .font(.headline)

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

// MARK: - Terminal

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
        }
        .formStyle(.grouped)
    }
}

// MARK: - Telemetry

struct TelemetrySettingsTab: View {
    @ObservedObject var viewModel: SettingsViewModel

    var body: some View {
        Form {
            Toggle("Enable usage analytics", isOn: $viewModel.telemetryEnabled)
            Toggle("Share crash reports", isOn: $viewModel.crashReports)

            if viewModel.telemetryEnabled {
                GroupBox("What we collect") {
                    Text("Anonymous usage statistics help us improve Pnevma. No code, file contents, or personal data is ever transmitted.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Keybinding Model

struct KeybindingEntry: Identifiable, Codable {
    var id: String { action }
    let action: String
    let shortcut: String
}

// MARK: - ViewModel

final class SettingsViewModel: ObservableObject {
    // General
    @Published var autoSave = true
    @Published var restoreWindows = true
    @Published var autoUpdate = true
    @Published var defaultShell = ""

    // Keybindings
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

    // Terminal
    @Published var terminalFont = "SF Mono"
    @Published var terminalFontSize = 13
    @Published var scrollbackLines = 10000

    // Telemetry
    @Published var telemetryEnabled = false
    @Published var crashReports = false

    func load() {
        // pnevma_call("settings.get", "{}")
    }

    func save() {
        // pnevma_call("settings.set", ...)
    }
}

// MARK: - NSView Wrapper

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
