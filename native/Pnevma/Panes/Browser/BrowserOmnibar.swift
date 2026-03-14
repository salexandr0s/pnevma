import AppKit
import SwiftUI

// MARK: - OmnibarTextField (NSViewRepresentable for proper focus/select behavior)

struct OmnibarTextField: NSViewRepresentable {
    @Binding var text: String
    var focusToken: Int = 0
    var onCommit: () -> Void
    var onChange: (String) -> Void

    func makeNSView(context: Context) -> NSTextField {
        let field = NSTextField()
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.placeholderString = "Search or enter URL"
        field.font = NSFont.systemFont(ofSize: 13)
        field.delegate = context.coordinator
        field.cell?.isScrollable = true
        field.cell?.wraps = false
        field.cell?.truncatesLastVisibleLine = true
        return field
    }

    func updateNSView(_ nsView: NSTextField, context: Context) {
        if nsView.stringValue != text {
            nsView.stringValue = text
        }
        if context.coordinator.lastFocusToken != focusToken {
            context.coordinator.lastFocusToken = focusToken
            DispatchQueue.main.async {
                guard nsView.window != nil else { return }
                nsView.window?.makeFirstResponder(nsView)
                nsView.selectText(nil)
            }
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        let parent: OmnibarTextField
        var lastFocusToken: Int

        init(_ parent: OmnibarTextField) {
            self.parent = parent
            self.lastFocusToken = parent.focusToken
        }

        func controlTextDidChange(_ obj: Notification) {
            guard let field = obj.object as? NSTextField else { return }
            parent.text = field.stringValue
            parent.onChange(field.stringValue)
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            if commandSelector == #selector(NSResponder.insertNewline(_:)) {
                parent.onCommit()
                return true
            }
            if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
                // Dismiss suggestions on Escape
                parent.onChange("")
                return false
            }
            return false
        }
    }
}
