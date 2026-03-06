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

    static func makeTaskBoard() -> (PaneID, NSView & PaneContent) {
        let view = TaskBoardPaneView(frame: .zero)
        return (view.paneID, view)
    }

    static func makeReplay() -> (PaneID, NSView & PaneContent) {
        let view = ReplayPaneView(frame: .zero)
        return (view.paneID, view)
    }

    static func makeFileBrowser() -> (PaneID, NSView & PaneContent) {
        let view = FileBrowserPaneView(frame: .zero)
        return (view.paneID, view)
    }

    static func makeSshManager() -> (PaneID, NSView & PaneContent) {
        let view = SshManagerPaneView(frame: .zero)
        return (view.paneID, view)
    }

    static func makeWorkflow() -> (PaneID, NSView & PaneContent) {
        let view = WorkflowPaneView(frame: .zero)
        return (view.paneID, view)
    }

    static func makeReview() -> (PaneID, NSView & PaneContent) {
        let view = ReviewPaneView(frame: .zero)
        return (view.paneID, view)
    }

    static func makeMergeQueue() -> (PaneID, NSView & PaneContent) {
        let view = MergeQueuePaneView(frame: .zero)
        return (view.paneID, view)
    }

    static func makeDiff() -> (PaneID, NSView & PaneContent) {
        let view = DiffPaneView(frame: .zero)
        return (view.paneID, view)
    }

    static func makeSearch() -> (PaneID, NSView & PaneContent) {
        let view = SearchPaneView(frame: .zero)
        return (view.paneID, view)
    }

    static func makeAnalytics() -> (PaneID, NSView & PaneContent) {
        let view = AnalyticsPaneView(frame: .zero)
        return (view.paneID, view)
    }

    static func makeSettings() -> (PaneID, NSView & PaneContent) {
        let view = SettingsPaneView(frame: .zero)
        return (view.paneID, view)
    }

    static func makeNotifications() -> (PaneID, NSView & PaneContent) {
        let view = NotificationsPaneView(frame: .zero)
        return (view.paneID, view)
    }

    static func makeDailyBrief() -> (PaneID, NSView & PaneContent) {
        let view = DailyBriefPaneView(frame: .zero)
        return (view.paneID, view)
    }

    static func makeRulesManager() -> (PaneID, NSView & PaneContent) {
        let view = RulesManagerPaneView(frame: .zero)
        return (view.paneID, view)
    }

    /// Create a pane by type string.
    /// - Note: Pane type metadata is not currently stored in the layout engine,
    ///   so non-terminal panes cannot be recreated automatically on layout restore.
    ///   TODO: Store pane type in PaneLayoutEngine to fully support non-terminal pane recreation.
    static func make(type paneType: String) -> (PaneID, NSView & PaneContent)? {
        switch paneType {
        case "terminal":      return makeTerminal()
        case "taskboard":     return makeTaskBoard()
        case "replay":        return makeReplay()
        case "file_browser":  return makeFileBrowser()
        case "ssh":           return makeSshManager()
        case "workflow":      return makeWorkflow()
        case "review":        return makeReview()
        case "merge_queue":   return makeMergeQueue()
        case "diff":          return makeDiff()
        case "search":        return makeSearch()
        case "analytics":     return makeAnalytics()
        case "settings":      return makeSettings()
        case "notifications": return makeNotifications()
        case "daily_brief":   return makeDailyBrief()
        case "rules":         return makeRulesManager()
        default:              return nil
        }
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
