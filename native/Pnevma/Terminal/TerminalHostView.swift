import Cocoa

/// AppKit NSView that hosts a TerminalSurface.
/// Bridges AppKit event dispatch to libghostty input handling.
///
/// Layout lifecycle:
///   1. The view becomes layer-backed (ghostty requires Metal on a CALayer).
///   2. On first `viewDidMoveToWindow` a TerminalSurface is created pointing at self.
///   3. Every resize / scale change propagates to the surface immediately.
final class TerminalHostView: NSView, NSTextInputClient {

    // MARK: - Public

    /// The terminal surface managed by this view.
    private(set) var terminalSurface: TerminalSurface?

    /// Working directory passed to the shell on first launch.
    var workingDirectory: String?

    /// Called when the terminal process exits and ghostty requests the view close.
    var onTerminalClose: (() -> Void)?

    // MARK: - Init

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        commonInit()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        commonInit()
    }

    private func commonInit() {
        // ghostty attaches a CAMetalLayer to the view — must be layer-backed.
        wantsLayer = true
    }

    // MARK: - NSView Lifecycle

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window != nil, terminalSurface == nil else { return }
        window?.acceptsMouseMovedEvents = true
        createSurface()
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        updateSurfaceLayout()
    }

    // MARK: - First Responder

    override var acceptsFirstResponder: Bool { true }

    override func becomeFirstResponder() -> Bool {
        let result = super.becomeFirstResponder()
        #if canImport(GhosttyKit)
        if result, let app = TerminalSurface.ghosttyApp {
            ghostty_app_set_focus(app, true)
        }
        #endif
        return result
    }

    override func resignFirstResponder() -> Bool {
        let result = super.resignFirstResponder()
        #if canImport(GhosttyKit)
        if result, let app = TerminalSurface.ghosttyApp {
            ghostty_app_set_focus(app, false)
        }
        #endif
        return result
    }

    // MARK: - Keyboard Events

    override func keyDown(with event: NSEvent) {
        // interpretKeyEvents FIRST — this drives NSTextInputClient (IME, dead keys,
        // key equivalents). The input manager may call insertText or setMarkedText.
        // We also send the raw key to ghostty for non-printable keys (arrows, Ctrl+C, etc.)
        // by forwarding inside insertText after IME resolution.
        #if canImport(GhosttyKit)
        let ghosttyEvent = makeGhosttyKeyEvent(from: event, action: GHOSTTY_ACTION_PRESS)
        // Send to ghostty first; if not consumed, let the input system handle it.
        if terminalSurface?.sendKey(ghosttyEvent) == false {
            interpretKeyEvents([event])
        }
        #else
        interpretKeyEvents([event])
        #endif
    }

    override func keyUp(with event: NSEvent) {
        #if canImport(GhosttyKit)
        let ghosttyEvent = makeGhosttyKeyEvent(from: event, action: GHOSTTY_ACTION_RELEASE)
        terminalSurface?.sendKey(ghosttyEvent)
        #endif
    }

    override func flagsChanged(with event: NSEvent) {
        #if canImport(GhosttyKit)
        // Determine press vs release from whether a relevant flag is newly set.
        let relevantFlags: NSEvent.ModifierFlags = [.shift, .control, .option, .command, .capsLock]
        let active = event.modifierFlags.intersection(relevantFlags)
        let action: ghostty_input_action_e = active.isEmpty ? GHOSTTY_ACTION_RELEASE : GHOSTTY_ACTION_PRESS
        let ghosttyEvent = makeGhosttyKeyEvent(from: event, action: action)
        terminalSurface?.sendKey(ghosttyEvent)
        #endif
    }

    // MARK: - Mouse Events

    override func mouseDown(with event: NSEvent) {
        #if canImport(GhosttyKit)
        terminalSurface?.sendMouseButton(
            state: GHOSTTY_MOUSE_PRESS, button: GHOSTTY_MOUSE_LEFT,
            mods: ghosttyMods(from: event.modifierFlags))
        #endif
    }

    override func mouseUp(with event: NSEvent) {
        #if canImport(GhosttyKit)
        terminalSurface?.sendMouseButton(
            state: GHOSTTY_MOUSE_RELEASE, button: GHOSTTY_MOUSE_LEFT,
            mods: ghosttyMods(from: event.modifierFlags))
        #endif
    }

    override func rightMouseDown(with event: NSEvent) {
        #if canImport(GhosttyKit)
        terminalSurface?.sendMouseButton(
            state: GHOSTTY_MOUSE_PRESS, button: GHOSTTY_MOUSE_RIGHT,
            mods: ghosttyMods(from: event.modifierFlags))
        #endif
    }

    override func rightMouseUp(with event: NSEvent) {
        #if canImport(GhosttyKit)
        terminalSurface?.sendMouseButton(
            state: GHOSTTY_MOUSE_RELEASE, button: GHOSTTY_MOUSE_RIGHT,
            mods: ghosttyMods(from: event.modifierFlags))
        #endif
    }

    override func otherMouseDown(with event: NSEvent) {
        #if canImport(GhosttyKit)
        terminalSurface?.sendMouseButton(
            state: GHOSTTY_MOUSE_PRESS, button: GHOSTTY_MOUSE_MIDDLE,
            mods: ghosttyMods(from: event.modifierFlags))
        #endif
    }

    override func otherMouseUp(with event: NSEvent) {
        #if canImport(GhosttyKit)
        terminalSurface?.sendMouseButton(
            state: GHOSTTY_MOUSE_RELEASE, button: GHOSTTY_MOUSE_MIDDLE,
            mods: ghosttyMods(from: event.modifierFlags))
        #endif
    }

    override func mouseMoved(with event: NSEvent)      { forwardMousePosition(event) }
    override func mouseDragged(with event: NSEvent)    { forwardMousePosition(event) }
    override func rightMouseDragged(with event: NSEvent) { forwardMousePosition(event) }
    override func otherMouseDragged(with event: NSEvent) { forwardMousePosition(event) }

    override func scrollWheel(with event: NSEvent) {
        #if canImport(GhosttyKit)
        var scrollMods = ghostty_input_scroll_mods_t(rawValue: 0)
        if event.hasPreciseScrollingDeltas {
            scrollMods.insert(ghostty_input_scroll_mods_t(rawValue: GHOSTTY_SCROLL_PRECISE))
        }
        terminalSurface?.sendMouseScroll(
            x: event.scrollingDeltaX,
            y: -event.scrollingDeltaY, // ghostty: positive Y = scroll down; AppKit: inverse
            scrollMods: scrollMods
        )
        #endif
    }

    // MARK: - NSTextInputClient

    func insertText(_ string: Any, replacementRange: NSRange) {
        let text: String
        if let attributed = string as? NSAttributedString {
            text = attributed.string
        } else if let plain = string as? String {
            text = plain
        } else {
            return
        }
        terminalSurface?.sendText(text)
    }

    func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        let text: String
        if let attributed = string as? NSAttributedString {
            text = attributed.string
        } else if let plain = string as? String {
            text = plain
        } else {
            return
        }
        terminalSurface?.sendPreedit(text)
    }

    func unmarkText() {
        terminalSurface?.sendPreedit("")
    }

    func selectedRange() -> NSRange {
        NSRange(location: NSNotFound, length: 0)
    }

    func markedRange() -> NSRange {
        NSRange(location: NSNotFound, length: 0)
    }

    func hasMarkedText() -> Bool { false }

    func attributedSubstring(forProposedRange range: NSRange, actualRange: NSRangePointer?) -> NSAttributedString? {
        nil
    }

    func validAttributesForMarkedText() -> [NSAttributedString.Key] { [] }

    func firstRect(forCharacterRange range: NSRange, actualRange: NSRangePointer?) -> NSRect {
        #if canImport(GhosttyKit)
        if let surface = terminalSurface {
            let (x, y, w, h) = surface.imePoint()
            return NSRect(x: x, y: y, width: w, height: h)
        }
        #endif
        return .zero
    }

    func characterIndex(for point: NSPoint) -> Int { NSNotFound }

    // MARK: - Drawing

    override func draw(_ dirtyRect: NSRect) {
        // ghostty renders via Metal into the layer — no AppKit drawing needed.
        #if !canImport(GhosttyKit)
        NSColor.black.setFill()
        dirtyRect.fill()
        let message = "Terminal requires GhosttyKit"
        let attrs: [NSAttributedString.Key: Any] = [
            .foregroundColor: NSColor.white,
            .font: NSFont.monospacedSystemFont(ofSize: 14, weight: .regular)
        ]
        let sz = (message as NSString).size(withAttributes: attrs)
        (message as NSString).draw(
            at: NSPoint(x: (bounds.width - sz.width) / 2, y: (bounds.height - sz.height) / 2),
            withAttributes: attrs
        )
        #endif
    }

    // MARK: - Private helpers

    private func createSurface() {
        let surface = TerminalSurface(hostView: self, workingDirectory: workingDirectory)
        surface.onClose = { [weak self] in self?.onTerminalClose?() }
        self.terminalSurface = surface
        updateSurfaceLayout()
    }

    private func updateSurfaceLayout() {
        guard terminalSurface != nil else { return }
        // Use convertToBacking to get pixel dimensions — handles retina scaling correctly.
        let backing = convertToBacking(bounds)
        let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2.0
        terminalSurface?.setContentScale(scale)
        terminalSurface?.resize(width: UInt32(backing.width), height: UInt32(backing.height))
    }

    private func forwardMousePosition(_ event: NSEvent) {
        #if canImport(GhosttyKit)
        let pos = convert(event.locationInWindow, from: nil)
        // ghostty uses top-left origin; AppKit uses bottom-left — flip Y.
        let flippedY = frame.height - pos.y
        terminalSurface?.sendMousePos(
            x: pos.x, y: flippedY,
            mods: ghosttyMods(from: event.modifierFlags)
        )
        #endif
    }
}

// MARK: - NSEvent → Ghostty Conversion

#if canImport(GhosttyKit)

private func makeGhosttyKeyEvent(from event: NSEvent, action: ghostty_input_action_e) -> ghostty_input_key_s {
    var key = ghostty_input_key_s()
    key.action = action
    key.mods = ghosttyMods(from: event.modifierFlags)
    key.consumed_mods = ghostty_input_mods_e(rawValue: 0)
    key.keycode = UInt32(event.keyCode)
    key.composing = false

    // text: characters as typed (with shift/option applied).
    // Bind NSString to local so it outlives the key struct usage.
    var charsNSString: NSString?
    if let chars = event.characters, !chars.isEmpty {
        charsNSString = chars as NSString
        key.text = charsNSString!.utf8String
    }

    // unshifted_codepoint: the base key without shift/option modifiers.
    // characters(byApplyingModifiers:[]) strips shift+option to give the hardware key value.
    if let base = event.characters(byApplyingModifiers: []),
       let scalar = base.unicodeScalars.first {
        key.unshifted_codepoint = scalar.value
    }

    return key
}

private func ghosttyMods(from flags: NSEvent.ModifierFlags) -> ghostty_input_mods_e {
    var mods = ghostty_input_mods_e(rawValue: 0)
    if flags.contains(.shift)      { mods.insert(GHOSTTY_MODS_SHIFT) }
    if flags.contains(.control)    { mods.insert(GHOSTTY_MODS_CTRL) }
    if flags.contains(.option)     { mods.insert(GHOSTTY_MODS_ALT) }
    if flags.contains(.command)    { mods.insert(GHOSTTY_MODS_SUPER) }
    if flags.contains(.capsLock)   { mods.insert(GHOSTTY_MODS_CAPS) }
    if flags.contains(.numericPad) { mods.insert(GHOSTTY_MODS_NUM) }
    return mods
}

#endif
