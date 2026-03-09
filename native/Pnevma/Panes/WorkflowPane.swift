import SwiftUI
import Cocoa

// MARK: - NSView Wrapper

final class WorkflowPaneView: NSView, PaneContent {
    let paneID = PaneID()
    let paneType = "workflow"
    let shouldPersist = false
    var title: String { "Agents" }

    override init(frame: NSRect) {
        super.init(frame: frame)
        _ = addSwiftUISubview(WorkflowView())
    }

    required init?(coder: NSCoder) { fatalError() }
}
