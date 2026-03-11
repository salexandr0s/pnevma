import Cocoa

/// Confirmation dialog for dangerous operations.
/// For Danger-level actions, requires typing a confirmation phrase.
final class ProtectedActionSheet {

    enum RiskLevel {
        case warning   // Simple "Are you sure?" confirmation
        case danger    // Must type confirmation phrase
    }

    /// Show a confirmation alert. Returns true if the user confirmed.
    @MainActor
    static func confirm(
        title: String,
        message: String,
        riskLevel: RiskLevel,
        confirmPhrase: String? = nil,
        in window: NSWindow?
    ) async -> Bool {
        switch riskLevel {
        case .warning:
            return await showWarningAlert(title: title, message: message, in: window)
        case .danger:
            return await showDangerAlert(title: title, message: message,
                                          confirmPhrase: confirmPhrase ?? "CONFIRM", in: window)
        }
    }

    // MARK: - Warning Level

    @MainActor
    private static func showWarningAlert(title: String, message: String, in window: NSWindow?) async -> Bool {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Continue")

        guard let window = window ?? NSApplication.shared.keyWindow else { return false }
        return await withCheckedContinuation { continuation in
            alert.beginSheetModal(for: window) { response in
                continuation.resume(returning: response == .alertSecondButtonReturn)
            }
        }
    }

    // MARK: - Danger Level

    @MainActor
    private static func showDangerAlert(title: String, message: String,
                                         confirmPhrase: String, in window: NSWindow?) async -> Bool {
        let alert = NSAlert()
        alert.alertStyle = .critical
        alert.messageText = title
        alert.informativeText = "\(message)\n\nType \"\(confirmPhrase)\" to confirm:"

        let inputField = NSTextField(frame: NSRect(x: 0, y: 0, width: 280, height: 24))
        inputField.placeholderString = confirmPhrase
        alert.accessoryView = inputField

        alert.addButton(withTitle: "Cancel")
        let confirmButton = alert.addButton(withTitle: "Confirm")
        confirmButton.hasDestructiveAction = true

        guard let window = window ?? NSApplication.shared.keyWindow else { return false }
        return await withCheckedContinuation { continuation in
            alert.beginSheetModal(for: window) { response in
                let confirmed = response == .alertSecondButtonReturn
                    && inputField.stringValue == confirmPhrase
                continuation.resume(returning: confirmed)
            }
        }
    }
}
