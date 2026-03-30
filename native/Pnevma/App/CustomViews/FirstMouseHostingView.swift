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

