import Foundation
import Cocoa
import os

/// Auto-saves and restores session state (window frame, workspaces, layouts, pane metadata).
/// Saves to ~/.config/pnevma/session.json every 8 seconds when dirty.
final class SessionPersistence: @unchecked Sendable {

    // MARK: - Types

    struct SessionState: Codable {
        let windowFrame: CodableRect?
        let commandCenterWindowFrame: CodableRect?
        let commandCenterVisible: Bool
        let agentTeamWindows: [AgentTeamWindowState]
        let workspaces: [Workspace.Snapshot]
        let activeWorkspaceID: UUID?
        let sidebarVisible: Bool
        let rightInspectorVisible: Bool
        let rightInspectorWidth: Double?

        init(
            windowFrame: CodableRect?,
            commandCenterWindowFrame: CodableRect? = nil,
            commandCenterVisible: Bool = false,
            agentTeamWindows: [AgentTeamWindowState] = [],
            workspaces: [Workspace.Snapshot],
            activeWorkspaceID: UUID?,
            sidebarVisible: Bool,
            rightInspectorVisible: Bool = true,
            rightInspectorWidth: Double? = nil
        ) {
            self.windowFrame = windowFrame
            self.commandCenterWindowFrame = commandCenterWindowFrame
            self.commandCenterVisible = commandCenterVisible
            self.agentTeamWindows = agentTeamWindows
            self.workspaces = workspaces
            self.activeWorkspaceID = activeWorkspaceID
            self.sidebarVisible = sidebarVisible
            self.rightInspectorVisible = rightInspectorVisible
            self.rightInspectorWidth = rightInspectorWidth
        }

        private enum CodingKeys: String, CodingKey {
            case windowFrame
            case commandCenterWindowFrame
            case commandCenterVisible
            case agentTeamWindows
            case workspaces
            case activeWorkspaceID
            case sidebarVisible
            case rightInspectorVisible
            case rightInspectorWidth
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            windowFrame = try container.decodeIfPresent(CodableRect.self, forKey: .windowFrame)
            commandCenterWindowFrame = try container.decodeIfPresent(CodableRect.self, forKey: .commandCenterWindowFrame)
            commandCenterVisible = try container.decodeIfPresent(Bool.self, forKey: .commandCenterVisible) ?? false
            agentTeamWindows = try container.decodeIfPresent([AgentTeamWindowState].self, forKey: .agentTeamWindows) ?? []
            workspaces = try container.decode([Workspace.Snapshot].self, forKey: .workspaces)
            activeWorkspaceID = try container.decodeIfPresent(UUID.self, forKey: .activeWorkspaceID)
            sidebarVisible = try container.decode(Bool.self, forKey: .sidebarVisible)
            rightInspectorVisible = try container.decodeIfPresent(Bool.self, forKey: .rightInspectorVisible) ?? true
            rightInspectorWidth = try container.decodeIfPresent(Double.self, forKey: .rightInspectorWidth)
        }
    }

    struct CodableRect: Codable, Equatable {
        let x: Double, y: Double, width: Double, height: Double

        init(_ rect: NSRect) {
            x = Double(rect.origin.x)
            y = Double(rect.origin.y)
            width = Double(rect.size.width)
            height = Double(rect.size.height)
        }

        var nsRect: NSRect {
            NSRect(x: x, y: y, width: width, height: height)
        }
    }

    struct AgentTeamWindowState: Codable, Equatable {
        let teamID: String
        let projectID: String
        let leaderSessionID: String
        let leaderPaneID: String
        let memberSessionID: String
        let memberPaneID: String
        let provider: String
        let memberIndex: Int
        let title: String
        let frame: CodableRect?

        private enum CodingKeys: String, CodingKey {
            case teamID
            case projectID
            case leaderSessionID
            case leaderPaneID
            case memberSessionID
            case memberPaneID
            case provider
            case memberIndex
            case title
            case frame
        }
    }

    // MARK: - Properties

    private let saveURL: URL
    private var autoSaveTimer: Timer?
    private let dirtyLock = OSAllocatedUnfairLock(initialState: false)
    var isPersistenceEnabled = true

    /// Closure that provides the current session state for auto-save.
    var stateProvider: (() -> SessionState)?

    // MARK: - Init

    init(saveURL: URL? = nil) {
        if let saveURL = saveURL {
            self.saveURL = saveURL
        } else {
            let configDir = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".config/pnevma", isDirectory: true)
            try? Self.ensureSecureDirectory(configDir)
            self.saveURL = configDir.appendingPathComponent("session.json")
        }
    }

    // MARK: - Auto-save

    func startAutoSave(interval: TimeInterval = 8.0) {
        autoSaveTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            self?.saveIfDirty()
        }
    }

    func stopAutoSave() {
        autoSaveTimer?.invalidate()
        autoSaveTimer = nil
    }

    func markDirty() {
        dirtyLock.withLock { $0 = true }
    }

    private func saveIfDirty() {
        guard isPersistenceEnabled else { return }
        let wasDirty = dirtyLock.withLock { val -> Bool in
            let was = val; val = false; return was
        }
        guard wasDirty else { return }
        guard let state = stateProvider?() else { return }
        save(state: state)
    }

    // MARK: - Save / Restore

    func save(state: SessionState) {
        guard isPersistenceEnabled else { return }
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(state)
            if let parent = saveURL.deletingLastPathComponent() as URL? {
                try Self.ensureSecureDirectory(parent)
            }
            try data.write(to: saveURL, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: saveURL.path)
        } catch {
            Log.persistence.error("Save failed: \(error)")
        }
    }

    func restore(ifEnabled enabled: Bool) -> SessionState? {
        guard enabled else { return nil }
        return restore()
    }

    func restore() -> SessionState? {
        guard FileManager.default.fileExists(atPath: saveURL.path) else { return nil }
        do {
            let data = try Data(contentsOf: saveURL)
            return try JSONDecoder().decode(SessionState.self, from: data)
        } catch {
            Log.persistence.error("Restore failed: \(error)")
            return nil
        }
    }

    private static func ensureSecureDirectory(_ url: URL) throws {
        try FileManager.default.createDirectory(
            at: url,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
    }
}
