@preconcurrency import ObjectiveC
import Cocoa
#if canImport(GhosttyKit)
import GhosttyKit
#endif

/// AppKit NSView that hosts a TerminalSurface.
/// Bridges AppKit event dispatch to libghostty input handling.
///
/// Layout lifecycle:
///   1. The view becomes layer-backed (ghostty requires Metal on a CALayer).
///   2. Surface creation is deferred until the view has a window, screen, and non-zero backing size.
///   3. Every resize / scale change propagates to the surface immediately.
final class TerminalHostView: NSView, @preconcurrency NSTextInputClient {
    struct PendingSurfaceLayout: Equatable {
        let width: UInt32
        let height: UInt32
        let scale: Double
    }

    // MARK: - Public

    /// The terminal surface managed by this view.
    private(set) var terminalSurface: TerminalSurface?

    /// Launch configuration passed to Ghostty when the surface is created.
    var launchConfiguration: TerminalSurfaceLaunchConfiguration = .shell()

    /// Backend session bound to this surface, if any.
    var attachedSessionID: String?

    /// Called when the terminal process exits and ghostty requests the view close.
    var onTerminalClose: ((Bool) -> Void)?

    /// Called once a real terminal surface is attached to the host view.
    var onSurfaceReady: (() -> Void)?

    /// Called when the visible terminal grid size changes.
    var onTerminalResize: ((UInt16, UInt16) -> Void)?

    /// Called when a desktop notification arrives for this surface.
    var onDesktopNotification: ((String, String) -> Void)?

    /// Called when the terminal title changes.
    var onTitleChanged: ((String) -> Void)?

    /// Called when the working directory changes.
    var onPwdChanged: ((String) -> Void)?

    /// Called when the terminal bell rings.
    var onBell: (() -> Void)?

    // MARK: - Private

    private var surfaceCreateScheduled = false
    private var windowObservers: [NSObjectProtocol] = []
    private var actionObservers: [NSObjectProtocol] = []
    private var lastReportedGridSize: (columns: UInt16, rows: UInt16)?
    private var currentCursor: NSCursor = .iBeam
    private let closeCoordinator = TerminalCloseCoordinator()
    nonisolated(unsafe) private var chromeTransitionObserver: NSObjectProtocol?
    private var pendingSurfaceLayout: PendingSurfaceLayout?
    private var lastAppliedSurfaceLayout: PendingSurfaceLayout?

    // MARK: - Init

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        commonInit()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        MainActor.assumeIsolated {
            commonInit()
        }
    }

    deinit {
        MainActor.assumeIsolated {
            removeWindowObservers()
            removeActionObservers()
        }
        if let chromeTransitionObserver {
            NotificationCenter.default.removeObserver(chromeTransitionObserver)
        }
    }

    private func commonInit() {
        // ghostty attaches a CAMetalLayer to the view, so the view must be layer-backed.
        wantsLayer = true

        // When background-opacity < 1.0, allow the terminal to be transparent
        // so the desktop shows through. Otherwise use an opaque black backing.
        let bgOpacity = GhosttyThemeProvider.shared.backgroundOpacity
        if bgOpacity < 1.0 {
            layer?.backgroundColor = NSColor.clear.cgColor
            layer?.isOpaque = false
        } else {
            layer?.backgroundColor = GhosttyThemeProvider.shared.backgroundColor.cgColor
            layer?.isOpaque = true
        }
        // Track mouse movement so ghostty always has up-to-date cursor position.
        let trackingArea = NSTrackingArea(
            rect: .zero,
            options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(trackingArea)
        chromeTransitionObserver = NotificationCenter.default.addObserver(
            forName: .chromeTransitionDidEnd,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.flushDeferredSurfaceLayout()
            }
        }
    }

    func ensureSurfaceCreated() {
        guard terminalSurface == nil else { return }
        guard let window else { return }
        guard window.screen != nil else {
            scheduleEnsureSurfaceCreated()
            return
        }

        let backingBounds = convertToBacking(bounds)
        guard backingBounds.width > 0, backingBounds.height > 0 else {
            scheduleEnsureSurfaceCreated()
            return
        }

        createSurface()
    }

    func teardownSurface() {
        removeActionObservers()
        terminalSurface = nil
        lastReportedGridSize = nil
        pendingSurfaceLayout = nil
        lastAppliedSurfaceLayout = nil
        removeWindowObservers()
    }

    func requestCloseDecision(_ completion: @escaping (Bool) -> Void) {
        guard terminalSurface != nil else {
            completion(false)
            return
        }
        closeCoordinator.requestClose(
            using: { [weak self] in self?.terminalSurface?.requestClose() },
            completion: completion
        )
    }

    func closeSurfaceSilently() {
        guard terminalSurface != nil else { return }
        onTerminalClose = nil
        onSurfaceReady = nil
        onTerminalResize = nil
        onDesktopNotification = nil
        onTitleChanged = nil
        onPwdChanged = nil
        onBell = nil
        closeCoordinator.suppressNextSurfaceClose()
        terminalSurface?.requestClose()
    }

    // MARK: - NSView Lifecycle

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        MainActor.assumeIsolated {
            updateWindowObservers()
            guard window != nil else { return }
            window?.acceptsMouseMovedEvents = true
            scheduleEnsureSurfaceCreated()
        }
    }

    override func resetCursorRects() {
        // Don't register a cursor rect in the rightmost 5pt of the window — that zone
        // belongs to NSThemeFrame's resize handle. Covering it with the terminal cursor
        // would hide the resize cursor and prevent horizontal window resize.
        let resizeEdge: CGFloat = 5
        let insetRect: NSRect
        if let window, convertedRightEdgeIsWindowEdge(resizeEdge: resizeEdge, window: window) {
            insetRect = NSRect(x: bounds.minX, y: bounds.minY,
                               width: max(bounds.width - resizeEdge, 0), height: bounds.height)
        } else {
            insetRect = bounds
        }
        if !insetRect.isEmpty {
            addCursorRect(insetRect, cursor: currentCursor)
        }
    }

    /// Returns true when this view's right edge coincides with the window's right edge.
    private func convertedRightEdgeIsWindowEdge(resizeEdge: CGFloat, window: NSWindow) -> Bool {
        // Convert right edge from self's local coordinate system to window coordinates.
        let myRightInWindow = convert(NSPoint(x: bounds.maxX, y: bounds.midY), to: nil).x
        return myRightInWindow >= window.frame.width - resizeEdge
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        updateSurfaceLayout()
    }

    override func layout() {
        super.layout()
        if terminalSurface == nil {
            scheduleEnsureSurfaceCreated()
        }
        updateSurfaceLayout()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        if terminalSurface == nil {
            scheduleEnsureSurfaceCreated()
        }
        updateSurfaceLayout(deferringForChromeTransition: false)
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        #if canImport(GhosttyKit)
        let scheme = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? GHOSTTY_COLOR_SCHEME_DARK : GHOSTTY_COLOR_SCHEME_LIGHT
        terminalSurface?.setColorScheme(scheme)
        #endif
    }

    // MARK: - First Responder

    override var acceptsFirstResponder: Bool { true }

    override func becomeFirstResponder() -> Bool {
        let result = super.becomeFirstResponder()
        #if canImport(GhosttyKit)
        if result, let app = TerminalSurface.ghosttyApp {
            ghostty_app_set_focus(app, true)
        }
        if result {
            terminalSurface?.setFocus(true)
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
        if result {
            terminalSurface?.setFocus(false)
        }
        #endif
        return result
    }

    /// Apply an unfocused overlay when this terminal's pane loses focus.
    /// Uses the ghostty `unfocused-split-fill` color and `unfocused-split-opacity` setting.
    func setPaneFocused(_ focused: Bool) {
        if focused {
            unfocusedOverlay?.isHidden = true
        } else {
            ensureUnfocusedOverlay()
            unfocusedOverlay?.isHidden = false
        }
    }

    private var unfocusedOverlay: NSView?

    private func ensureUnfocusedOverlay() {
        if unfocusedOverlay != nil {
            unfocusedOverlay?.frame = bounds
            return
        }

        let overlay = UnfocusedOverlayView(frame: bounds)
        overlay.autoresizingMask = [.width, .height]
        addSubview(overlay)
        unfocusedOverlay = overlay
    }

    // MARK: - Keyboard Events

    override func keyDown(with event: NSEvent) {
        if Self.shouldDeferKeyEquivalentToAppKit(event),
           NSApp.mainMenu?.performKeyEquivalent(with: event) == true {
            return
        }

        // interpretKeyEvents FIRST. This drives NSTextInputClient for IME, dead keys,
        // and key equivalents. Raw key events still go to ghostty for non-printable keys.
        #if canImport(GhosttyKit)
        let consumed = withGhosttyKeyEvent(from: event, action: GHOSTTY_ACTION_PRESS) {
            terminalSurface?.sendKey($0) ?? false
        }
        if !consumed {
            interpretKeyEvents([event])
        }
        #else
        interpretKeyEvents([event])
        #endif
    }

    override func keyUp(with event: NSEvent) {
        #if canImport(GhosttyKit)
        withGhosttyKeyEvent(from: event, action: GHOSTTY_ACTION_RELEASE) {
            terminalSurface?.sendKey($0)
        }
        #endif
    }

    override func flagsChanged(with event: NSEvent) {
        #if canImport(GhosttyKit)
        let relevantFlags: NSEvent.ModifierFlags = [.shift, .control, .option, .command, .capsLock]
        let active = event.modifierFlags.intersection(relevantFlags)
        let action: ghostty_input_action_e = active.isEmpty ? GHOSTTY_ACTION_RELEASE : GHOSTTY_ACTION_PRESS
        withGhosttyKeyEvent(from: event, action: action) {
            terminalSurface?.sendKey($0)
        }
        #endif
    }

    // MARK: - Mouse Events

    #if canImport(GhosttyKit)
    private func forwardMouseButton(
        state: ghostty_input_mouse_state_e,
        button: ghostty_input_mouse_button_e,
        event: NSEvent
    ) -> Bool {
        terminalSurface?.sendMouseButton(
            state: state,
            button: button,
            mods: ghosttyMods(from: event.modifierFlags)
        ) ?? false
    }

    override func mouseDown(with event: NSEvent) {
        claimFirstResponderIfNeeded()
        forwardMousePosition(event)
        _ = forwardMouseButton(state: GHOSTTY_MOUSE_PRESS, button: GHOSTTY_MOUSE_LEFT, event: event)
    }

    override func mouseUp(with event: NSEvent) {
        forwardMousePosition(event)
        _ = forwardMouseButton(state: GHOSTTY_MOUSE_RELEASE, button: GHOSTTY_MOUSE_LEFT, event: event)
    }

    override func rightMouseDown(with event: NSEvent) {
        claimFirstResponderIfNeeded()
        forwardMousePosition(event)
        if !forwardMouseButton(state: GHOSTTY_MOUSE_PRESS, button: GHOSTTY_MOUSE_RIGHT, event: event) {
            super.rightMouseDown(with: event)
        }
    }

    override func rightMouseUp(with event: NSEvent) {
        forwardMousePosition(event)
        if !forwardMouseButton(state: GHOSTTY_MOUSE_RELEASE, button: GHOSTTY_MOUSE_RIGHT, event: event) {
            super.rightMouseUp(with: event)
        }
    }

    override func otherMouseDown(with event: NSEvent) {
        guard let button = Self.ghosttyMouseButton(for: event.buttonNumber) else {
            super.otherMouseDown(with: event)
            return
        }
        claimFirstResponderIfNeeded()
        forwardMousePosition(event)
        _ = forwardMouseButton(state: GHOSTTY_MOUSE_PRESS, button: button, event: event)
    }

    override func otherMouseUp(with event: NSEvent) {
        guard let button = Self.ghosttyMouseButton(for: event.buttonNumber) else {
            super.otherMouseUp(with: event)
            return
        }
        forwardMousePosition(event)
        _ = forwardMouseButton(state: GHOSTTY_MOUSE_RELEASE, button: button, event: event)
    }
    #endif

    override func mouseMoved(with event: NSEvent) { forwardMousePosition(event) }
    override func mouseDragged(with event: NSEvent) { forwardMousePosition(event) }
    override func rightMouseDragged(with event: NSEvent) { forwardMousePosition(event) }
    override func otherMouseDragged(with event: NSEvent) { forwardMousePosition(event) }

    override func scrollWheel(with event: NSEvent) {
        claimFirstResponderIfNeeded()
        #if canImport(GhosttyKit)
        var x = event.scrollingDeltaX
        var y = event.scrollingDeltaY
        if event.hasPreciseScrollingDeltas {
            x *= 2
            y *= 2
        }
        terminalSurface?.sendMouseScroll(
            x: x,
            y: y,
            scrollMods: ghosttyScrollMods(from: event)
        )
        #endif
    }

    // MARK: - NSTextInputClient

    func insertText(_ string: Any, replacementRange: NSRange) {
        guard let text = extractText(string) else { return }
        terminalSurface?.sendText(text)
    }

    func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        guard let text = extractText(string) else { return }
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
            return screenRectFromGhosttyRect(x: x, y: y, width: w, height: h)
        }
        #endif
        return .zero
    }

    func characterIndex(for point: NSPoint) -> Int { NSNotFound }

    // MARK: - Drawing

    override func draw(_ dirtyRect: NSRect) {
        // ghostty renders via Metal into the layer. AppKit only paints a fallback.
        #if !canImport(GhosttyKit)
        NSColor.black.setFill()
        bounds.fill()
        let message = "Terminal requires GhosttyKit"
        let attrs: [NSAttributedString.Key: Any] = [
            .foregroundColor: NSColor.white,
            .font: NSFont.monospacedSystemFont(ofSize: 14, weight: .regular)
        ]
        let size = (message as NSString).size(withAttributes: attrs)
        (message as NSString).draw(
            at: NSPoint(x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2),
            withAttributes: attrs
        )
        #endif
    }

    // MARK: - Private helpers

    private func createSurface() {
        guard let window else { return }
        window.displayIfNeeded()

        let surface = TerminalSurface(hostView: self, launchConfiguration: launchConfiguration)
        surface.onClose = { [weak self] processAlive in
            guard let self else { return }
            self.closeCoordinator.handleSurfaceClose(
                processAlive: processAlive,
                onTerminalClose: self.onTerminalClose
            )
        }
        terminalSurface = surface
        updateSurfaceLayout(deferringForChromeTransition: false)

        // Ghostty attaches a CAMetalLayer as a sublayer. CAMetalLayer defaults
        // to isOpaque=true which prevents background-opacity transparency.
        // Propagate the host view's opacity setting to all sublayers so the
        // terminal background matches the chrome.
        if GhosttyThemeProvider.shared.backgroundOpacity < 1.0 {
            layer?.isOpaque = false
            for sublayer in layer?.sublayers ?? [] {
                sublayer.isOpaque = false
            }
        }

        #if canImport(GhosttyKit)
        // Tell the surface the current color scheme so conditional themes resolve correctly.
        let scheme = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? GHOSTTY_COLOR_SCHEME_DARK : GHOSTTY_COLOR_SCHEME_LIGHT
        surface.setColorScheme(scheme)
        #endif

        installActionObservers()

        if surface.isRendererReady {
            updateSurfaceDisplayID()
            onSurfaceReady?()
        } else if AppSmokeMode.current != nil {
            let message = "Smoke diagnostic: terminal surface was not ready after creation\n"
            if let data = message.data(using: .utf8) {
                FileHandle.standardError.write(data)
            }
        }
    }

    private func updateSurfaceLayout(deferringForChromeTransition: Bool = true) {
        guard terminalSurface != nil else { return }
        let backing = convertToBacking(bounds)
        let layout = PendingSurfaceLayout(
            width: UInt32(max(0, Int(backing.width.rounded(.toNearestOrEven)))),
            height: UInt32(max(0, Int(backing.height.rounded(.toNearestOrEven)))),
            scale: Double(window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2.0)
        )

        if deferringForChromeTransition, ChromeTransitionCoordinator.shared.isActive {
            pendingSurfaceLayout = layout
            return
        }

        applySurfaceLayout(layout)
    }

    private func flushDeferredSurfaceLayout() {
        guard let layout = pendingSurfaceLayout else { return }
        pendingSurfaceLayout = nil
        applySurfaceLayout(layout)
    }

    private func applySurfaceLayout(_ layout: PendingSurfaceLayout) {
        guard lastAppliedSurfaceLayout != layout else { return }
        layer?.contentsScale = layout.scale
        terminalSurface?.setContentScale(layout.scale)
        terminalSurface?.resize(width: layout.width, height: layout.height)
        lastAppliedSurfaceLayout = layout
        PerformanceDiagnostics.shared.recordTerminalSurfaceResize()
        if let size = terminalSurface?.size(),
           size.columns > 0,
           size.rows > 0,
           lastReportedGridSize.map({ $0.columns != size.columns || $0.rows != size.rows }) ?? true {
            lastReportedGridSize = size
            onTerminalResize?(size.columns, size.rows)
        }
    }

    private func updateSurfaceDisplayID() {
        guard let screen = window?.screen else { return }
        let key = NSDeviceDescriptionKey("NSScreenNumber")
        let screenNumber = screen.deviceDescription[key] as? NSNumber
        terminalSurface?.setDisplayID(screenNumber?.uint32Value ?? 0)
    }

    private func scheduleEnsureSurfaceCreated() {
        guard terminalSurface == nil, !surfaceCreateScheduled else { return }
        surfaceCreateScheduled = true
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.surfaceCreateScheduled = false
            self.ensureSurfaceCreated()
        }
    }

    private func updateWindowObservers() {
        removeWindowObservers()
        guard let window else { return }

        let center = NotificationCenter.default
        let names: [Notification.Name] = [
            NSWindow.didBecomeKeyNotification,
            NSWindow.didBecomeMainNotification,
            NSWindow.didChangeScreenNotification,
            NSWindow.didChangeOcclusionStateNotification,
        ]

        for name in names {
            let observer = center.addObserver(
                forName: name,
                object: window,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.updateSurfaceDisplayID()
                    self?.scheduleEnsureSurfaceCreated()
                }
            }
            windowObservers.append(observer)
        }
    }

    private func removeWindowObservers() {
        let center = NotificationCenter.default
        for observer in windowObservers {
            center.removeObserver(observer)
        }
        windowObservers.removeAll()
    }

    // MARK: - Action Observers

    private func installActionObservers() {
        removeActionObservers()
        let center = NotificationCenter.default

        let notifObserver = center.addObserver(
            forName: .ghosttyDesktopNotification, object: nil, queue: .main
        ) { [weak self] notification in
            let surfaceAddr = (notification.userInfo?["surface"] as? UnsafeMutableRawPointer).map { Int(bitPattern: $0) }
            let title = notification.userInfo?["title"] as? String ?? ""
            let body = notification.userInfo?["body"] as? String ?? ""
            MainActor.assumeIsolated {
                guard let self, self.matchesSurfaceAddr(surfaceAddr) else { return }
                self.onDesktopNotification?(title, body)
            }
        }
        actionObservers.append(notifObserver)

        let titleObserver = center.addObserver(
            forName: .ghosttySetTitle, object: nil, queue: .main
        ) { [weak self] notification in
            let surfaceAddr = (notification.userInfo?["surface"] as? UnsafeMutableRawPointer).map { Int(bitPattern: $0) }
            let title = notification.userInfo?["title"] as? String ?? ""
            MainActor.assumeIsolated {
                guard let self, self.matchesSurfaceAddr(surfaceAddr) else { return }
                self.onTitleChanged?(title)
            }
        }
        actionObservers.append(titleObserver)

        let pwdObserver = center.addObserver(
            forName: .ghosttyPwdChanged, object: nil, queue: .main
        ) { [weak self] notification in
            let surfaceAddr = (notification.userInfo?["surface"] as? UnsafeMutableRawPointer).map { Int(bitPattern: $0) }
            let path = notification.userInfo?["path"] as? String ?? ""
            MainActor.assumeIsolated {
                guard let self, self.matchesSurfaceAddr(surfaceAddr) else { return }
                self.onPwdChanged?(path)
            }
        }
        actionObservers.append(pwdObserver)

        let bellObserver = center.addObserver(
            forName: .ghosttyRingBell, object: nil, queue: .main
        ) { [weak self] notification in
            let surfaceAddr = (notification.userInfo?["surface"] as? UnsafeMutableRawPointer).map { Int(bitPattern: $0) }
            MainActor.assumeIsolated {
                guard let self, self.matchesSurfaceAddr(surfaceAddr) else { return }
                self.onBell?()
            }
        }
        actionObservers.append(bellObserver)

        #if canImport(GhosttyKit)
        let mouseShapeObserver = center.addObserver(
            forName: .ghosttyMouseShape, object: nil, queue: .main
        ) { [weak self] notification in
            let surfaceAddr = (notification.userInfo?["surface"] as? UnsafeMutableRawPointer).map { Int(bitPattern: $0) }
            let rawValue = notification.userInfo?["shape"] as? UInt32
            MainActor.assumeIsolated {
                guard let self, self.matchesSurfaceAddr(surfaceAddr) else { return }
                guard let rawValue else { return }
                let shape = ghostty_action_mouse_shape_e(rawValue)
                self.currentCursor = Self.nsCursor(for: shape)
                self.window?.invalidateCursorRects(for: self)
            }
        }
        actionObservers.append(mouseShapeObserver)
        #endif
    }

    private func removeActionObservers() {
        let center = NotificationCenter.default
        for observer in actionObservers {
            center.removeObserver(observer)
        }
        actionObservers.removeAll()
    }

    /// Check if a ghostty action notification targets this view's surface.
    private func matchesSurface(_ notification: Notification) -> Bool {
        matchesSurfaceAddr((notification.userInfo?["surface"] as? UnsafeMutableRawPointer).map { Int(bitPattern: $0) })
    }

    private func matchesSurfaceAddr(_ surfaceAddr: Int?) -> Bool {
        guard let surfaceAddr else { return true }
        #if canImport(GhosttyKit)
        guard let ownPtr = terminalSurface?.surfacePointer else { return false }
        return Int(bitPattern: ownPtr) == surfaceAddr
        #else
        return true
        #endif
    }

    #if canImport(GhosttyKit)
    private static func nsCursor(for shape: ghostty_action_mouse_shape_e) -> NSCursor {
        switch shape {
        case GHOSTTY_MOUSE_SHAPE_TEXT:
            return .iBeam
        case GHOSTTY_MOUSE_SHAPE_VERTICAL_TEXT:
            return .iBeamCursorForVerticalLayout
        case GHOSTTY_MOUSE_SHAPE_POINTER:
            return .pointingHand
        case GHOSTTY_MOUSE_SHAPE_CROSSHAIR:
            return .crosshair
        case GHOSTTY_MOUSE_SHAPE_GRAB, GHOSTTY_MOUSE_SHAPE_GRABBING:
            return .closedHand
        case GHOSTTY_MOUSE_SHAPE_NOT_ALLOWED, GHOSTTY_MOUSE_SHAPE_NO_DROP:
            return .operationNotAllowed
        case GHOSTTY_MOUSE_SHAPE_N_RESIZE, GHOSTTY_MOUSE_SHAPE_S_RESIZE,
             GHOSTTY_MOUSE_SHAPE_NS_RESIZE, GHOSTTY_MOUSE_SHAPE_ROW_RESIZE:
            return .resizeUpDown
        case GHOSTTY_MOUSE_SHAPE_E_RESIZE, GHOSTTY_MOUSE_SHAPE_W_RESIZE,
             GHOSTTY_MOUSE_SHAPE_EW_RESIZE, GHOSTTY_MOUSE_SHAPE_COL_RESIZE:
            return .resizeLeftRight
        case GHOSTTY_MOUSE_SHAPE_CONTEXT_MENU:
            return .contextualMenu
        default:
            return .arrow
        }
    }
    #endif

    private func forwardMousePosition(_ event: NSEvent) {
        #if canImport(GhosttyKit)
        let pos = convert(event.locationInWindow, from: nil)
        let flippedY = bounds.height - pos.y
        terminalSurface?.sendMousePos(
            x: pos.x,
            y: flippedY,
            mods: ghosttyMods(from: event.modifierFlags)
        )
        #endif
    }

    // Ghostty reports IME geometry in top-left view coordinates; AppKit expects screen coordinates.
    func screenRectFromGhosttyRect(x: Double, y: Double, width: Double, height: Double) -> NSRect {
        let viewRect = NSRect(x: x, y: bounds.height - y, width: width, height: height)
        let windowRect = convert(viewRect, to: nil)
        guard let window else { return windowRect }
        return window.convertToScreen(windowRect)
    }

    static func shouldTreatAsMiddleMouseButton(_ buttonNumber: Int) -> Bool {
        buttonNumber == 2
    }

    #if canImport(GhosttyKit)
    static func ghosttyMouseButton(for buttonNumber: Int) -> ghostty_input_mouse_button_e? {
        switch buttonNumber {
        case 2: return GHOSTTY_MOUSE_MIDDLE
        default: return nil
        }
    }
    #endif

    static func shouldDeferKeyEquivalentToAppKit(_ event: NSEvent) -> Bool {
        guard event.type == .keyDown else { return false }
        return AppKeybindingManager.shared.isAppKeyEquivalent(event)
    }

    private func extractText(_ string: Any) -> String? {
        (string as? NSAttributedString)?.string ?? (string as? String)
    }

    @discardableResult
    private func claimFirstResponderIfNeeded() -> Bool {
        guard window?.firstResponder !== self else { return true }
        return window?.makeFirstResponder(self) ?? false
    }
}

@MainActor
final class TerminalCloseCoordinator {
    private var pendingCloseDecision: ((Bool) -> Void)?
    private var suppressNextClose = false

    func requestClose(using closeRequest: () -> Void, completion: @escaping (Bool) -> Void) {
        pendingCloseDecision = completion
        closeRequest()
    }

    func suppressNextSurfaceClose() {
        suppressNextClose = true
    }

    func handleSurfaceClose(
        processAlive: Bool,
        onTerminalClose: ((Bool) -> Void)?
    ) {
        if suppressNextClose {
            suppressNextClose = false
            return
        }
        if let pendingCloseDecision {
            self.pendingCloseDecision = nil
            pendingCloseDecision(processAlive)
            return
        }
        onTerminalClose?(processAlive)
    }
}

// MARK: - UnfocusedOverlayView

/// Semi-transparent overlay drawn on top of an unfocused terminal pane.
/// Uses the ghostty `unfocused-split-fill` color with alpha derived from
/// `unfocused-split-opacity`. Passes through all mouse events.
private final class UnfocusedOverlayView: NSView {
    nonisolated(unsafe) private var themeObserver: NSObjectProtocol?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        updateOverlayColor()

        themeObserver = NotificationCenter.default.addObserver(
            forName: GhosttyThemeProvider.didChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.updateOverlayColor()
            }
        }
    }

    required init?(coder: NSCoder) { fatalError() }

    deinit {
        if let themeObserver {
            NotificationCenter.default.removeObserver(themeObserver)
        }
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    private func updateOverlayColor() {
        let theme = GhosttyThemeProvider.shared
        let fill = theme.unfocusedSplitFill ?? theme.backgroundColor
        let alpha = 1.0 - theme.unfocusedSplitOpacity
        layer?.backgroundColor = fill.withAlphaComponent(alpha).cgColor
    }
}

// MARK: - NSEvent -> Ghostty Conversion

#if canImport(GhosttyKit)

@discardableResult
private func withGhosttyKeyEvent<T>(
    from event: NSEvent,
    action: ghostty_input_action_e,
    execute: (ghostty_input_key_s) -> T
) -> T {
    var key = ghostty_input_key_s()
    key.action = action
    key.mods = ghosttyMods(from: event.modifierFlags)
    key.consumed_mods = computeConsumedMods(from: event)
    key.keycode = UInt32(event.keyCode)
    key.composing = false

    if let chars = eventText(for: event), !chars.isEmpty {
        return chars.withCString { ptr in
            key.text = ptr
            applyUnshiftedCodepoint(to: &key, event: event)
            return execute(key)
        }
    }

    key.text = nil
    applyUnshiftedCodepoint(to: &key, event: event)
    return execute(key)
}

private func applyUnshiftedCodepoint(to key: inout ghostty_input_key_s, event: NSEvent) {
    if let base = eventTextIgnoringModifiers(for: event),
       let scalar = base.unicodeScalars.first {
        key.unshifted_codepoint = scalar.value
    }
}

private func computeConsumedMods(from event: NSEvent) -> ghostty_input_mods_e {
    var consumed: UInt32 = GHOSTTY_MODS_NONE.rawValue
    guard let chars = eventText(for: event), !chars.isEmpty,
          let baseChars = eventTextIgnoringModifiers(for: event), !baseChars.isEmpty else {
        return ghostty_input_mods_e(consumed)
    }
    if chars != baseChars {
        if event.modifierFlags.contains(.shift) {
            consumed |= GHOSTTY_MODS_SHIFT.rawValue
        }
        if event.modifierFlags.contains(.option) {
            consumed |= GHOSTTY_MODS_ALT.rawValue
        }
    }
    return ghostty_input_mods_e(consumed)
}

private func eventText(for event: NSEvent) -> String? {
    switch event.type {
    case .keyDown, .keyUp:
        return event.characters
    default:
        return nil
    }
}

private func eventTextIgnoringModifiers(for event: NSEvent) -> String? {
    switch event.type {
    case .keyDown, .keyUp:
        return event.characters(byApplyingModifiers: [])
    default:
        return nil
    }
}

private func ghosttyMods(from flags: NSEvent.ModifierFlags) -> ghostty_input_mods_e {
    var mods: UInt32 = GHOSTTY_MODS_NONE.rawValue
    if flags.contains(.shift) { mods |= GHOSTTY_MODS_SHIFT.rawValue }
    if flags.contains(.control) { mods |= GHOSTTY_MODS_CTRL.rawValue }
    if flags.contains(.option) { mods |= GHOSTTY_MODS_ALT.rawValue }
    if flags.contains(.command) { mods |= GHOSTTY_MODS_SUPER.rawValue }
    if flags.contains(.capsLock) { mods |= GHOSTTY_MODS_CAPS.rawValue }
    if flags.contains(.numericPad) { mods |= GHOSTTY_MODS_NUM.rawValue }

    let rawFlags = flags.rawValue
    if rawFlags & UInt(NX_DEVICERSHIFTKEYMASK) != 0 { mods |= GHOSTTY_MODS_SHIFT_RIGHT.rawValue }
    if rawFlags & UInt(NX_DEVICERCTLKEYMASK) != 0 { mods |= GHOSTTY_MODS_CTRL_RIGHT.rawValue }
    if rawFlags & UInt(NX_DEVICERALTKEYMASK) != 0 { mods |= GHOSTTY_MODS_ALT_RIGHT.rawValue }
    if rawFlags & UInt(NX_DEVICERCMDKEYMASK) != 0 { mods |= GHOSTTY_MODS_SUPER_RIGHT.rawValue }

    return ghostty_input_mods_e(mods)
}

private func ghosttyScrollMods(from event: NSEvent) -> ghostty_input_scroll_mods_t {
    var rawValue: Int32 = 0
    if event.hasPreciseScrollingDeltas {
        rawValue |= 0b0000_0001
    }

    rawValue |= Int32(ghosttyMomentum(from: event.momentumPhase)) << 1
    return rawValue
}

private func ghosttyMomentum(from phase: NSEvent.Phase) -> UInt8 {
    switch phase {
    case .began: return 1
    case .stationary: return 2
    case .changed: return 3
    case .ended: return 4
    case .cancelled: return 5
    case .mayBegin: return 6
    default: return 0
    }
}

#endif
