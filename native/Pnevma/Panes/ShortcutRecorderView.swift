import AppKit
import SwiftUI

/// A view that captures keyboard shortcuts from the user.
/// Displays the current shortcut as a styled badge. On click, enters recording mode
/// and captures the next key combination.
struct ShortcutRecorderView: NSViewRepresentable {
    @Binding var shortcut: String
    let isProtected: Bool
    let onRecorded: ((String) -> Void)?

    init(shortcut: Binding<String>, isProtected: Bool = false, onRecorded: ((String) -> Void)? = nil) {
        self._shortcut = shortcut
        self.isProtected = isProtected
        self.onRecorded = onRecorded
    }

    func makeNSView(context: Context) -> ShortcutRecorderNSView {
        let view = ShortcutRecorderNSView()
        view.shortcut = shortcut
        view.isProtected = isProtected
        view.onRecorded = { newShortcut in
            shortcut = newShortcut
            onRecorded?(newShortcut)
        }
        return view
    }

    func updateNSView(_ nsView: ShortcutRecorderNSView, context: Context) {
        nsView.shortcut = shortcut
        nsView.isProtected = isProtected
        nsView.updateDisplay()
    }
}

final class ShortcutRecorderNSView: NSView {
    var shortcut: String = ""
    var isProtected = false
    var onRecorded: ((String) -> Void)?

    private var isRecording = false
    private var eventMonitor: Any?
    private let label = NSTextField(labelWithString: "")
    private let backgroundLayer = CALayer()

    override init(frame: NSRect) {
        super.init(frame: frame)
        setup()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setup()
    }

    private func setup() {
        wantsLayer = true
        layer?.cornerRadius = 4

        label.font = .monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        label.alignment = .center
        label.isEditable = false
        label.isBordered = false
        label.drawsBackground = false
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)

        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])

        let trackingArea = NSTrackingArea(
            rect: .zero,
            options: [.activeInKeyWindow, .inVisibleRect, .mouseEnteredAndExited],
            owner: self
        )
        addTrackingArea(trackingArea)

        updateDisplay()
    }

    func updateDisplay() {
        if isRecording {
            label.stringValue = "Type shortcut…"
            label.textColor = .placeholderTextColor
            layer?.backgroundColor = NSColor.controlAccentColor.withAlphaComponent(0.15).cgColor
        } else {
            label.stringValue = shortcut.isEmpty ? "None" : shortcut
            label.textColor = isProtected ? .tertiaryLabelColor : .labelColor
            layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor
        }
    }

    override var intrinsicContentSize: NSSize {
        let labelSize = label.intrinsicContentSize
        return NSSize(width: max(labelSize.width + 16, 80), height: max(labelSize.height + 4, 22))
    }

    override func mouseDown(with event: NSEvent) {
        guard !isProtected else { return }

        if isRecording {
            stopRecording()
        } else {
            startRecording()
        }
    }

    override var acceptsFirstResponder: Bool { !isProtected }

    private func startRecording() {
        isRecording = true
        updateDisplay()

        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { [weak self] event in
            guard let self else { return event }
            self.handleKeyEvent(event)
            return nil  // Consume the event
        }
    }

    private func stopRecording() {
        isRecording = false
        if let monitor = eventMonitor {
            NSEvent.removeMonitor(monitor)
            eventMonitor = nil
        }
        updateDisplay()
    }

    private func handleKeyEvent(_ event: NSEvent) {
        // Escape cancels recording
        if event.keyCode == 53 {
            stopRecording()
            return
        }

        let shortcutString = shortcutStringFromEvent(event)
        if !shortcutString.isEmpty {
            shortcut = shortcutString
            onRecorded?(shortcutString)
        }
        stopRecording()
    }

    private func shortcutStringFromEvent(_ event: NSEvent) -> String {
        var parts: [String] = []
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)

        // Order must match Rust defaults: Cmd, Ctrl, Opt, Shift
        if flags.contains(.command) { parts.append("Cmd") }
        if flags.contains(.control) { parts.append("Ctrl") }
        if flags.contains(.option) { parts.append("Opt") }
        if flags.contains(.shift) { parts.append("Shift") }

        // Must have at least one modifier (except for special keys)
        guard !parts.isEmpty else { return "" }

        let chars = event.charactersIgnoringModifiers ?? ""
        let keyPart: String

        if chars == "\r" {
            keyPart = "Enter"
        } else if chars == "\u{1B}" {
            keyPart = "Escape"
        } else if chars == "\t" {
            keyPart = "Tab"
        } else if chars == " " {
            keyPart = "Space"
        } else if chars == "\u{08}" || chars == "\u{7F}" {
            keyPart = "Delete"
        } else if let scalar = chars.unicodeScalars.first {
            switch Int(scalar.value) {
            case NSLeftArrowFunctionKey: keyPart = "Left"
            case NSRightArrowFunctionKey: keyPart = "Right"
            case NSUpArrowFunctionKey: keyPart = "Up"
            case NSDownArrowFunctionKey: keyPart = "Down"
            case NSF1FunctionKey...NSF12FunctionKey:
                keyPart = "F\(Int(scalar.value) - NSF1FunctionKey + 1)"
            default:
                keyPart = chars.uppercased()
            }
        } else {
            return ""
        }

        parts.append(keyPart)
        return parts.joined(separator: "+")
    }
}
