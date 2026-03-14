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

struct AppSettingsSnapshot: Equatable {
    let autoSaveWorkspaceOnQuit: Bool
    let restoreWindowsOnLaunch: Bool
    let autoUpdate: Bool
    let defaultShell: String
    let terminalFont: String
    let terminalFontSize: UInt32
    let scrollbackLines: UInt32
    let sidebarBackgroundOffset: Double
    let bottomToolBarAutoHide: Bool
    let focusBorderEnabled: Bool
    let focusBorderOpacity: Double
    let focusBorderWidth: Double
    let focusBorderColor: String
    let telemetryEnabled: Bool
    let crashReports: Bool
    let keybindings: [KeybindingEntry]
    let toolPresentationOverrides: [String: String]

    static let defaults = Self(
        autoSaveWorkspaceOnQuit: true,
        restoreWindowsOnLaunch: true,
        autoUpdate: true,
        defaultShell: "",
        terminalFont: "SF Mono",
        terminalFontSize: 13,
        scrollbackLines: 10_000,
        sidebarBackgroundOffset: 0.05,
        bottomToolBarAutoHide: false,
        focusBorderEnabled: true,
        focusBorderOpacity: 0.4,
        focusBorderWidth: 2.0,
        focusBorderColor: "accent",
        telemetryEnabled: false,
        crashReports: false,
        keybindings: [],
        toolPresentationOverrides: [:]
    )

    var normalizedDefaultShell: String? {
        let trimmed = defaultShell.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

extension AppSettingsSnapshot: Decodable {
    private enum CodingKeys: String, CodingKey {
        case autoSaveWorkspaceOnQuit, restoreWindowsOnLaunch, autoUpdate, defaultShell
        case terminalFont, terminalFontSize, scrollbackLines, sidebarBackgroundOffset
        case bottomToolBarAutoHide, focusBorderEnabled, focusBorderOpacity, focusBorderWidth
        case focusBorderColor, telemetryEnabled, crashReports, keybindings
        case toolPresentationOverrides
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        autoSaveWorkspaceOnQuit = try c.decode(Bool.self, forKey: .autoSaveWorkspaceOnQuit)
        restoreWindowsOnLaunch = try c.decode(Bool.self, forKey: .restoreWindowsOnLaunch)
        autoUpdate = try c.decode(Bool.self, forKey: .autoUpdate)
        defaultShell = try c.decode(String.self, forKey: .defaultShell)
        terminalFont = try c.decode(String.self, forKey: .terminalFont)
        terminalFontSize = try c.decode(UInt32.self, forKey: .terminalFontSize)
        scrollbackLines = try c.decode(UInt32.self, forKey: .scrollbackLines)
        sidebarBackgroundOffset = try c.decode(Double.self, forKey: .sidebarBackgroundOffset)
        bottomToolBarAutoHide = try c.decode(Bool.self, forKey: .bottomToolBarAutoHide)
        focusBorderEnabled = try c.decode(Bool.self, forKey: .focusBorderEnabled)
        focusBorderOpacity = try c.decode(Double.self, forKey: .focusBorderOpacity)
        focusBorderWidth = try c.decode(Double.self, forKey: .focusBorderWidth)
        focusBorderColor = try c.decode(String.self, forKey: .focusBorderColor)
        telemetryEnabled = try c.decode(Bool.self, forKey: .telemetryEnabled)
        crashReports = try c.decode(Bool.self, forKey: .crashReports)
        keybindings = try c.decode([KeybindingEntry].self, forKey: .keybindings)
        toolPresentationOverrides = try c.decodeIfPresent([String: String].self, forKey: .toolPresentationOverrides) ?? [:]
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
    let bottomToolBarAutoHide: Bool
    let focusBorderEnabled: Bool
    let focusBorderOpacity: Double
    let focusBorderWidth: Double
    let focusBorderColor: String
    let telemetryEnabled: Bool
    let crashReports: Bool
    let keybindings: [KeybindingOverrideSave]?
    let toolPresentationOverrides: [String: String]?
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

    var bottomToolBarAutoHide: Bool {
        snapshot.bottomToolBarAutoHide
    }

    var normalizedDefaultShell: String? {
        snapshot.normalizedDefaultShell
    }

    var autoUpdate: Bool {
        snapshot.autoUpdate
    }

    var toolPresentationOverrides: [String: String] {
        snapshot.toolPresentationOverrides
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
