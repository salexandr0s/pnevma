import Foundation
import Cocoa

/// Lightweight coordinator for terminal pane lifecycle.
///
/// Since ghostty manages its own PTY internally (one per surface), SessionBridge
/// does not route PTY I/O. Its job is to:
///   - Track which TerminalHostView instances are active.
///   - Provide a factory method to spawn new terminal panes with a working directory.
///   - Relay ghostty close_surface events back to the UI layer.
///
/// The Rust session layer (via PnevmaBridge) remains a separate concern used for
/// agent tasks, not for interactive terminal I/O.
final class SessionBridge {

    // MARK: - Types

    struct TerminalEntry {
        let id: UUID
        weak var hostView: TerminalHostView?
        let workingDirectory: String?
        let createdAt: Date
    }

    // MARK: - State

    private var terminals: [UUID: TerminalEntry] = [:]
    private let lock = NSLock()

    /// Called when a terminal pane has exited (process exited or user closed).
    var onTerminalClosed: ((UUID) -> Void)?

    // MARK: - Init

    init() {}

    // MARK: - Public API

    /// Create a new TerminalHostView and begin tracking it.
    /// The view is returned; the caller is responsible for adding it to the view hierarchy.
    @discardableResult
    func createTerminal(workingDirectory: String? = nil) -> TerminalHostView {
        let view = TerminalHostView()
        view.workingDirectory = workingDirectory

        let id = UUID()
        let entry = TerminalEntry(
            id: id,
            hostView: view,
            workingDirectory: workingDirectory,
            createdAt: Date()
        )

        lock.lock()
        terminals[id] = entry
        lock.unlock()

        view.onTerminalClose = { [weak self, id] in
            self?.handleTerminalClose(id: id)
        }

        print("[SessionBridge] Created terminal \(id) cwd=\(workingDirectory ?? "~")")
        return view
    }

    /// Returns the number of active (non-deallocated) terminal panes.
    var activeCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return terminals.values.filter { $0.hostView != nil }.count
    }

    /// Remove a terminal entry explicitly (e.g. when its window/pane is torn down by UI).
    func removeTerminal(id: UUID) {
        lock.lock()
        terminals.removeValue(forKey: id)
        lock.unlock()
        print("[SessionBridge] Removed terminal \(id)")
    }

    // MARK: - Callbacks

    private func handleTerminalClose(id: UUID) {
        print("[SessionBridge] Terminal \(id) closed (process exited)")
        lock.lock()
        terminals.removeValue(forKey: id)
        lock.unlock()
        onTerminalClosed?(id)
    }
}
