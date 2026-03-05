import Foundation
import Cocoa
import os

/// Auto-saves and restores session state (window frame, workspaces, layouts, pane metadata).
/// Saves to ~/.config/pnevma/session.json every 8 seconds when dirty.
final class SessionPersistence {

    // MARK: - Types

    struct SessionState: Codable {
        let windowFrame: CodableRect?
        let workspaces: [Workspace.Snapshot]
        let activeWorkspaceID: UUID?
        let sidebarVisible: Bool
    }

    struct CodableRect: Codable {
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

    // MARK: - Properties

    private let saveURL: URL
    private var autoSaveTimer: Timer?
    private let dirtyLock = OSAllocatedUnfairLock(initialState: false)

    /// Closure that provides the current session state for auto-save.
    var stateProvider: (() -> SessionState)?

    // MARK: - Init

    init(saveURL: URL? = nil) {
        if let saveURL = saveURL {
            self.saveURL = saveURL
        } else {
            let configDir = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".config/pnevma", isDirectory: true)
            try? FileManager.default.createDirectory(at: configDir, withIntermediateDirectories: true)
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
        let wasDirty = dirtyLock.withLock { val -> Bool in
            let was = val; val = false; return was
        }
        guard wasDirty else { return }
        guard let state = stateProvider?() else { return }
        save(state: state)
    }

    // MARK: - Save / Restore

    func save(state: SessionState) {
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(state)
            try data.write(to: saveURL, options: .atomic)
        } catch {
            Log.persistence.error("Save failed: \(error)")
        }
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
}
