import AppKit
import Foundation

extension Notification.Name {
    static let appRuntimeSettingsDidChange = Notification.Name("appRuntimeSettingsDidChange")
}

struct KeybindingEntry: Identifiable, Codable, Equatable {
    var id: String { action }
    let action: String
    var shortcut: String
    var isDefault: Bool
    var conflictsWith: [String]
    var isProtected: Bool

    init(action: String, shortcut: String, isDefault: Bool = true, conflictsWith: [String] = [], isProtected: Bool = false) {
        self.action = action
        self.shortcut = shortcut
        self.isDefault = isDefault
        self.conflictsWith = conflictsWith
        self.isProtected = isProtected
    }

    /// Display name derived from action ID (e.g. "menu.split_right" → "Split Right")
    var displayName: String {
        // For non-menu actions, include the full dotted path as title-cased words
        // e.g. "command_palette.toggle" → "Command Palette Toggle"
        let base = action
            .replacing("menu.", with: "")
            .replacing("_", with: " ")
            .replacing(".", with: " ")
        return base
            .split(separator: " ")
            .map { $0.prefix(1).uppercased() + $0.dropFirst() }
            .joined(separator: " ")
    }

    /// Category derived from action prefix
    var category: String {
        if action.hasPrefix("menu.") { return "Menu Shortcuts" }
        return "Project Shortcuts"
    }
}

struct AppSettingsSnapshot: Decodable, Equatable {
    let autoSaveWorkspaceOnQuit: Bool
    let restoreWindowsOnLaunch: Bool
    let autoUpdate: Bool
    let defaultShell: String
    let terminalFont: String
    let terminalFontSize: UInt32
    let scrollbackLines: UInt32
    let sidebarBackgroundOffset: Double
    let focusBorderEnabled: Bool
    let focusBorderOpacity: Double
    let focusBorderWidth: Double
    let focusBorderColor: String
    let telemetryEnabled: Bool
    let crashReports: Bool
    let keybindings: [KeybindingEntry]

    static let defaults = Self(
        autoSaveWorkspaceOnQuit: true,
        restoreWindowsOnLaunch: true,
        autoUpdate: true,
        defaultShell: "",
        terminalFont: "SF Mono",
        terminalFontSize: 13,
        scrollbackLines: 10_000,
        sidebarBackgroundOffset: 0.05,
        focusBorderEnabled: true,
        focusBorderOpacity: 0.4,
        focusBorderWidth: 2.0,
        focusBorderColor: "accent",
        telemetryEnabled: false,
        crashReports: false,
        keybindings: []
    )

    var normalizedDefaultShell: String? {
        let trimmed = defaultShell.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

struct KeybindingOverrideSave: Encodable, Equatable {
    let action: String
    let shortcut: String
}

struct AppSettingsSaveRequest: Encodable, Equatable {
    let autoSaveWorkspaceOnQuit: Bool
    let restoreWindowsOnLaunch: Bool
    let autoUpdate: Bool
    let defaultShell: String
    let terminalFont: String
    let terminalFontSize: Int
    let scrollbackLines: Int
    let sidebarBackgroundOffset: Double
    let focusBorderEnabled: Bool
    let focusBorderOpacity: Double
    let focusBorderWidth: Double
    let focusBorderColor: String
    let telemetryEnabled: Bool
    let crashReports: Bool
    let keybindings: [KeybindingOverrideSave]?
}

@MainActor
final class AppRuntimeSettings {
    static let shared = AppRuntimeSettings()

    private let notificationCenter: NotificationCenter
    private(set) var snapshot: AppSettingsSnapshot
    private var configFileWatcher: ConfigFileWatcher?

    init(
        notificationCenter: NotificationCenter = .default,
        initialSnapshot: AppSettingsSnapshot = .defaults
    ) {
        self.notificationCenter = notificationCenter
        self.snapshot = initialSnapshot
    }

    /// Start watching the Pnevma config file for external changes.
    func startWatchingConfigFile() {
        let configURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/pnevma/config.toml")
        configFileWatcher = ConfigFileWatcher(url: configURL) {
            Task { @MainActor in
                await AppRuntimeSettings.shared.load()
            }
        }
        configFileWatcher?.start()
    }

    var autoSaveWorkspaceOnQuit: Bool {
        snapshot.autoSaveWorkspaceOnQuit
    }

    var restoreWindowsOnLaunch: Bool {
        snapshot.restoreWindowsOnLaunch
    }

    var normalizedDefaultShell: String? {
        snapshot.normalizedDefaultShell
    }

    var autoUpdate: Bool {
        snapshot.autoUpdate
    }

    func load(commandBus: (any CommandCalling)? = CommandBus.shared) async {
        guard let commandBus else { return }

        do {
            let snapshot: AppSettingsSnapshot = try await commandBus.call(
                method: "settings.app.get",
                params: nil
            )
            apply(snapshot)
        } catch {
            Log.general.error(
                "Failed to load runtime app settings: \(error.localizedDescription, privacy: .public)"
            )
        }
    }

    func apply(_ snapshot: AppSettingsSnapshot) {
        self.snapshot = snapshot
        AppKeybindingManager.shared.update(from: snapshot.keybindings)
        if let mainMenu = NSApp?.mainMenu {
            AppKeybindingManager.shared.applyToMenu(mainMenu)
        }
        notificationCenter.post(name: .appRuntimeSettingsDidChange, object: self)
    }
}
