import AppKit
import SwiftUI

/// NSHostingView variant for clickable window chrome hosted with SwiftUI.
///
/// SwiftUI controls inside an inactive macOS window can otherwise require a
/// focus click before the action click. Chrome surfaces such as the bottom tool
/// dock and drawer should behave like the custom AppKit buttons elsewhere in
/// the app and respond on the first click.
class FirstMouseHostingView<Content: View>: NSHostingView<Content> {
    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// Click-capturing hosting view for terminal chrome overlays.
///
/// Terminal overlays sit above Ghostty and must consume pointer events within
/// their visible bounds so clicks do not fall through and begin terminal text
/// selection underneath.
final class AgentLauncherOverlayHostingView<Content: View>: FirstMouseHostingView<Content> {
    required init(rootView: Content) {
        super.init(rootView: rootView)
        isFlipped = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard bounds.contains(point) else { return nil }
        return super.hitTest(point) ?? self
    }
}
