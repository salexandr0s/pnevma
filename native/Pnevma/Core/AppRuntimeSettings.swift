import Foundation

extension Notification.Name {
    static let appRuntimeSettingsDidChange = Notification.Name("appRuntimeSettingsDidChange")
}

struct KeybindingEntry: Identifiable, Codable, Equatable {
    var id: String { action }
    let action: String
    let shortcut: String
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
}

@MainActor
final class AppRuntimeSettings {
    static let shared = AppRuntimeSettings()

    private let notificationCenter: NotificationCenter
    private(set) var snapshot: AppSettingsSnapshot

    init(
        notificationCenter: NotificationCenter = .default,
        initialSnapshot: AppSettingsSnapshot = .defaults
    ) {
        self.notificationCenter = notificationCenter
        self.snapshot = initialSnapshot
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
        notificationCenter.post(name: .appRuntimeSettingsDidChange, object: self)
    }
}
