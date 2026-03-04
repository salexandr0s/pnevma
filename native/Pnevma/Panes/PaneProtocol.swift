import Cocoa

/// Unique identifier for a pane instance.
typealias PaneID = UUID

/// All pane types must conform to this protocol.
/// Conforming types must be NSView subclasses (enforced by AnyObject + usage as `NSView & PaneContent`).
protocol PaneContent: AnyObject {
    /// Unique identifier for this pane instance.
    var paneID: PaneID { get }

    /// Machine-readable pane type (e.g. "terminal", "taskboard", "review").
    var paneType: String { get }

    /// Human-readable title for display in tabs, palette, etc.
    var title: String { get }

    /// Called when this pane becomes the active (focused) pane.
    func activate()

    /// Called when another pane takes focus.
    func deactivate()

    /// Called before the pane is removed from the layout. Clean up resources.
    func dispose()
}

/// Default implementations for PaneContent.
extension PaneContent {
    func activate() {}
    func deactivate() {}
    func dispose() {}
}

/// Registry of known pane types and their factory methods.
enum PaneFactory {

    /// Create a terminal pane.
    static func makeTerminal(workingDirectory: String? = nil) -> (PaneID, NSView & PaneContent) {
        let view = TerminalPaneView(workingDirectory: workingDirectory)
        return (view.paneID, view)
    }
}

// MARK: - TerminalPaneView

/// Wraps TerminalHostView to conform to PaneContent.
final class TerminalPaneView: NSView, PaneContent {

    let paneID = PaneID()
    let paneType = "terminal"
    var title: String { "Terminal" }

    private let hostView: TerminalHostView

    init(workingDirectory: String? = nil) {
        hostView = TerminalHostView()
        hostView.workingDirectory = workingDirectory
        super.init(frame: .zero)

        hostView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(hostView)
        NSLayoutConstraint.activate([
            hostView.leadingAnchor.constraint(equalTo: leadingAnchor),
            hostView.trailingAnchor.constraint(equalTo: trailingAnchor),
            hostView.topAnchor.constraint(equalTo: topAnchor),
            hostView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    override var acceptsFirstResponder: Bool { true }

    override func becomeFirstResponder() -> Bool {
        return window?.makeFirstResponder(hostView) ?? false
    }

    func activate() {
        window?.makeFirstResponder(hostView)
    }

    func deactivate() {}

    func dispose() {
        hostView.terminalSurface?.requestClose()
    }

    var onTerminalClose: (() -> Void)? {
        get { hostView.onTerminalClose }
        set { hostView.onTerminalClose = newValue }
    }
}
