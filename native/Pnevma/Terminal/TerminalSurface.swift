import Cocoa

// MARK: - TerminalSurface

/// Wraps a libghostty surface for GPU-rendered terminal output.
/// Owns the ghostty_surface_t and forwards input events from AppKit.
///
/// One instance is created per terminal pane. The ghostty_app_t singleton
/// is shared across all surfaces and lives for the application lifetime.
class TerminalSurface {

    #if canImport(GhosttyKit)

    // MARK: - Static App Singleton

    /// Internal so TerminalHostView can relay focus events via ghostty_app_set_focus.
    static var ghosttyApp: ghostty_app_t?
    private static var isAppInitialized = false

    /// Create the ghostty app singleton. Call once at launch from AppDelegate.
    static func initializeGhostty() {
        guard !isAppInitialized else { return }

        let termConfig = TerminalConfig()
        guard let ghosttyConfig = termConfig.config else {
            print("[TerminalSurface] ERROR: failed to load ghostty config")
            return
        }

        // Runtime config — userdata is nil at the app level; per-surface userdata
        // is stored in ghostty_surface_config_s.userdata and surfaced via close_surface_cb.
        var runtimeConfig = ghostty_runtime_config_s(
            userdata: nil,
            supports_selection_clipboard: true,
            wakeup_cb: { _ in
                // ghostty calls this from any thread to request a main-thread tick.
                DispatchQueue.main.async {
                    if let app = TerminalSurface.ghosttyApp {
                        ghostty_app_tick(app)
                    }
                }
            },
            action_cb: { _, _, _ in
                // Phase 1: let ghostty use its own defaults for all actions.
                return false
            },
            read_clipboard_cb: { _, _, statePtr in
                // Deliver pasteboard contents through the ghostty state callback.
                // ghostty passes a state pointer we call back with the string.
                guard let statePtr = statePtr else { return }
                let content = NSPasteboard.general.string(forType: .string) ?? ""
                content.withCString { cstr in
                    ghostty_runtime_clipboard_read_set_string(statePtr, cstr, UInt(content.utf8.count))
                }
            },
            confirm_read_clipboard_cb: { _, _, _, statePtr in
                // Auto-confirm all OSC 52 reads without prompting.
                guard let statePtr = statePtr else { return }
                ghostty_runtime_clipboard_confirm_request(statePtr, true)
            },
            write_clipboard_cb: { _, loc, content, count, confirm in
                guard let content = content, count > 0 else { return }
                let str = String(bytes: UnsafeBufferPointer(start: content, count: Int(count)), encoding: .utf8) ?? ""
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(str, forType: .string)
            },
            close_surface_cb: { userdata, processAlive in
                guard let userdata = userdata else { return }
                // userdata is the retained TerminalSurface set in ghostty_surface_config_s.
                let surface = Unmanaged<TerminalSurface>.fromOpaque(userdata).takeRetainedValue()
                DispatchQueue.main.async {
                    surface.handleClose(processAlive: processAlive)
                }
            }
        )

        ghosttyApp = ghostty_app_new(&runtimeConfig, ghosttyConfig)
        if ghosttyApp == nil {
            print("[TerminalSurface] ERROR: ghostty_app_new() returned nil")
        } else {
            isAppInitialized = true
            print("[TerminalSurface] ghostty app initialized")
        }
    }

    // MARK: - Instance

    private var surface: ghostty_surface_t?
    private let hostView: NSView

    /// Called when ghostty requests the surface to close.
    var onClose: (() -> Void)?

    init(hostView: NSView, workingDirectory: String? = nil, command: String? = nil) {
        self.hostView = hostView

        guard let app = TerminalSurface.ghosttyApp else {
            print("[TerminalSurface] ERROR: ghostty app not initialized — call initializeGhostty() first")
            return
        }

        // Retain self so close_surface_cb can recover us via userdata.
        let selfPtr = Unmanaged.passRetained(self).toOpaque()
        // NSView raw pointer — ghostty attaches its CAMetalLayer to this view.
        let nsviewPtr = Unmanaged.passUnretained(hostView).toOpaque()

        // Use ghostty_surface_config_new() to get zero-initialised defaults,
        // then override the fields we care about.
        var surfaceConfig = ghostty_surface_config_new()
        surfaceConfig.userdata = selfPtr
        surfaceConfig.platform_tag = GHOSTTY_PLATFORM_MACOS
        surfaceConfig.platform = ghostty_platform_u(
            macos: ghostty_platform_macos_s(nsview: nsviewPtr)
        )
        surfaceConfig.scale_factor = NSScreen.main?.backingScaleFactor ?? 2.0
        surfaceConfig.font_size = 13.0

        if let wd = workingDirectory {
            surfaceConfig.working_directory = (wd as NSString).utf8String
        }
        if let cmd = command {
            surfaceConfig.command = (cmd as NSString).utf8String
        }

        surface = ghostty_surface_new(app, &surfaceConfig)
        if surface == nil {
            print("[TerminalSurface] ERROR: ghostty_surface_new() returned nil")
            // Balance the passRetained — close_surface_cb will never fire.
            Unmanaged<TerminalSurface>.fromOpaque(selfPtr).release()
        }
    }

    deinit {
        if let surface = surface {
            ghostty_surface_free(surface)
        }
    }

    // MARK: - Rendering

    func refresh() {
        guard let surface = surface else { return }
        ghostty_surface_refresh(surface)
    }

    func draw() {
        guard let surface = surface else { return }
        ghostty_surface_draw(surface)
    }

    // MARK: - Layout

    func resize(width: UInt32, height: UInt32) {
        guard let surface = surface else { return }
        ghostty_surface_set_size(surface, width, height)
    }

    func setContentScale(_ scale: Double) {
        guard let surface = surface else { return }
        ghostty_surface_set_content_scale(surface, scale, scale)
    }

    func setOcclusion(_ occluded: Bool) {
        guard let surface = surface else { return }
        ghostty_surface_set_occlusion(surface, occluded)
    }

    // MARK: - Keyboard Input

    /// Returns true if ghostty consumed the key event.
    @discardableResult
    func sendKey(_ event: ghostty_input_key_s) -> Bool {
        guard let surface = surface else { return false }
        var e = event
        return ghostty_surface_key(surface, e)
    }

    func sendText(_ text: String) {
        guard let surface = surface else { return }
        text.withCString { ptr in
            ghostty_surface_text(surface, ptr, UInt(text.utf8.count))
        }
    }

    func sendPreedit(_ text: String) {
        guard let surface = surface else { return }
        text.withCString { ptr in
            ghostty_surface_preedit(surface, ptr, UInt(text.utf8.count))
        }
    }

    func imePoint() -> (x: Double, y: Double, width: Double, height: Double) {
        guard let surface = surface else { return (0, 0, 0, 0) }
        var x: Double = 0, y: Double = 0, w: Double = 0, h: Double = 0
        ghostty_surface_ime_point(surface, &x, &y, &w, &h)
        return (x, y, w, h)
    }

    // MARK: - Mouse Input

    @discardableResult
    func sendMouseButton(
        state: ghostty_input_mouse_state_e,
        button: ghostty_input_mouse_button_e,
        mods: ghostty_input_mods_e
    ) -> Bool {
        guard let surface = surface else { return false }
        return ghostty_surface_mouse_button(surface, state, button, mods)
    }

    func sendMousePos(x: Double, y: Double, mods: ghostty_input_mods_e) {
        guard let surface = surface else { return }
        ghostty_surface_mouse_pos(surface, x, y, mods)
    }

    func sendMouseScroll(x: Double, y: Double, scrollMods: ghostty_input_scroll_mods_t) {
        guard let surface = surface else { return }
        ghostty_surface_mouse_scroll(surface, x, y, scrollMods)
    }

    // MARK: - Selection

    func hasSelection() -> Bool {
        guard let surface = surface else { return false }
        return ghostty_surface_has_selection(surface)
    }

    func getSelection() -> String? {
        guard let surface = surface else { return nil }
        var text = ghostty_text_s()
        guard ghostty_surface_read_selection(surface, &text) else { return nil }
        guard let ptr = text.ptr, text.len > 0 else { return nil }
        return String(bytes: UnsafeBufferPointer(start: ptr, count: Int(text.len)), encoding: .utf8)
    }

    func requestClose() {
        guard let surface = surface else { return }
        ghostty_surface_request_close(surface)
    }

    // MARK: - Callbacks

    private func handleClose(processAlive: Bool) {
        onClose?()
    }

    #else

    // MARK: - Placeholder (no GhosttyKit)

    private let hostView: NSView
    var onClose: (() -> Void)?

    static func initializeGhostty() {
        print("[TerminalSurface] GhosttyKit not available — placeholder mode active")
    }

    init(hostView: NSView, workingDirectory: String? = nil, command: String? = nil) {
        self.hostView = hostView
        print("[TerminalSurface] Placeholder: no ghostty surface created")
    }

    func refresh() {}
    func draw() {}
    func resize(width: UInt32, height: UInt32) {}
    func setContentScale(_ scale: Double) {}
    func setOcclusion(_ occluded: Bool) {}
    @discardableResult func sendKey(_ event: Any) -> Bool { false }
    func sendText(_ text: String) {}
    func sendPreedit(_ text: String) {}
    func imePoint() -> (x: Double, y: Double, width: Double, height: Double) { (0, 0, 0, 0) }
    @discardableResult func sendMouseButton(state: Any, button: Any, mods: Any) -> Bool { false }
    func sendMousePos(x: Double, y: Double, mods: Any) {}
    func sendMouseScroll(x: Double, y: Double, scrollMods: Any) {}
    func hasSelection() -> Bool { false }
    func getSelection() -> String? { nil }
    func requestClose() {}

    #endif
}
