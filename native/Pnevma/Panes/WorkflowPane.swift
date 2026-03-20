import SwiftUI
import Cocoa

// MARK: - NSView Wrapper

final class WorkflowPaneView: NSView, PaneContent {
    let paneID = PaneID()
    let paneType = "workflow"
    let shouldPersist = true
    var title: String { "Agents" }

    init(frame: NSRect, chromeContext: PaneChromeContext = .standard) {
        super.init(frame: frame)
        _ = addSwiftUISubview(WorkflowView(), chromeContext: chromeContext)
    }

    required init?(coder: NSCoder) { fatalError() }
}
