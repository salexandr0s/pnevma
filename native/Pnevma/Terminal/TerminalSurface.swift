import Cocoa
#if canImport(GhosttyKit)
import GhosttyKit
#endif
import os

struct TerminalSurfaceEnvironmentVariable: Equatable {
    let key: String
    let value: String
}

struct TerminalSurfaceLaunchConfiguration: Equatable {
    let workingDirectory: String?
    let command: String?
    let env: [TerminalSurfaceEnvironmentVariable]
    let waitAfterCommand: Bool
    let initialInput: String?

    static func shell(
        workingDirectory: String? = nil,
        command: String? = nil
    ) -> Self {
        Self(
            workingDirectory: workingDirectory,
            command: command,
            env: [],
            waitAfterCommand: false,
            initialInput: nil
        )
    }
}

// MARK: - TerminalSurface

/// Wraps a libghostty surface for GPU-rendered terminal output.
/// Owns the ghostty_surface_t and forwards input events from AppKit.
///
/// One instance is created per terminal pane. The ghostty_app_t singleton
/// is shared across all surfaces and lives for the application lifetime.
class TerminalSurface {

    @MainActor static var clipboardStringProvider: () -> String = {
        NSPasteboard.general.string(forType: .string) ?? ""
    }
    @MainActor static var clipboardStringWriter: (String) -> Void = { string in
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(string, forType: .string)
    }

    static func decodeSelectionText(
        text: UnsafePointer<CChar>?,
        length: Int
    ) -> String? {
        guard let text, length > 0 else { return nil }
        let bytes = UnsafeRawBufferPointer(start: text, count: length)
        let selection = String(decoding: bytes, as: UTF8.self)
        return selection.isEmpty ? nil : selection
    }

    @MainActor
    static func clipboardStringForRequest(confirmed _: Bool) -> String {
        clipboardStringProvider()
    }

    @MainActor
    static func writeClipboardString(_ string: String) {
        clipboardStringWriter(string)
    }

    #if canImport(GhosttyKit)
    private struct ClipboardWriteContent {
        let mime: String
        let data: String

        static func from(content: ghostty_clipboard_content_s) -> ClipboardWriteContent? {
            guard let mimePtr = content.mime,
                  let dataPtr = content.data else {
                return nil
            }

            return ClipboardWriteContent(
                mime: String(cString: mimePtr),
                data: String(cString: dataPtr)
            )
        }
    }

    private static func preferredClipboardWriteString(
        content: UnsafePointer<ghostty_clipboard_content_s>?,
        length: Int
    ) -> String? {
        guard let content, length > 0 else { return nil }

        let items = (0..<length).compactMap { ClipboardWriteContent.from(content: content[$0]) }
        guard !items.isEmpty else { return nil }

        if let plainText = items.first(where: { $0.mime == "text/plain" })?.data,
           !plainText.isEmpty {
            return plainText
        }

        return items.first(where: { !$0.data.isEmpty })?.data
    }
    #endif

    #if canImport(GhosttyKit)

    // MARK: - Static App Singleton

    /// Internal so TerminalHostView can relay focus events via ghostty_app_set_focus.
    nonisolated(unsafe) static var ghosttyApp: ghostty_app_t?
    @MainActor private static var ghosttyConfigOwner: TerminalConfig?
    @MainActor private static var isAppInitialized = false
    nonisolated(unsafe) private static let surfaceRegistry = NSHashTable<TerminalSurface>.weakObjects()
    private static let surfaceRegistryLock = NSLock()

    /// Create the ghostty app singleton. Returns true when this call created it.
    @MainActor
    @discardableResult
    static func initializeGhostty() -> Bool {
        guard !isAppInitialized else { return false }

        let termConfig = GhosttyConfigController.shared.runtimeConfigOwner()
        ghosttyConfigOwner = termConfig
        guard let ghosttyConfig = termConfig.config else {
            Log.terminal.error("Failed to load ghostty config")
            emitSmokeDiagnostic("failed to load ghostty config")
            ghosttyConfigOwner = nil
            return false
        }

        var runtimeConfig = Self.makeRuntimeConfig()

        ghosttyApp = ghostty_app_new(&runtimeConfig, ghosttyConfig)
        if ghosttyApp == nil {
            Log.terminal.error("ghostty_app_new() returned nil")
            emitSmokeDiagnostic("ghostty_app_new returned nil")
            ghosttyConfigOwner = nil
            return false
        } else {
            isAppInitialized = true
            // Tell ghostty the current color scheme so conditional themes
            // (e.g. "light:X,dark:Y") resolve correctly at the app level.
            let scheme = NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                ? GHOSTTY_COLOR_SCHEME_DARK : GHOSTTY_COLOR_SCHEME_LIGHT
            if let app = ghosttyApp { ghostty_app_set_color_scheme(app, scheme) }
            Log.terminal.info("ghostty app initialized")
            return true
        }
    }

    @MainActor
    static func shutdownGhostty() {
        if let app = ghosttyApp {
            ghostty_app_free(app)
        }
        ghosttyApp = nil
        ghosttyConfigOwner = nil
        isAppInitialized = false
    }

    // MARK: - Instance

    private var surface: ghostty_surface_t?

    /// Tracks the `Unmanaged.passRetained(self)` pointer handed to ghostty
    /// as surface userdata. Must be released exactly once when the surface
    /// is torn down to avoid leaking `self`.
    private var retainedSelfPtr: UnsafeMutableRawPointer?

    /// The raw ghostty surface pointer, used for identity comparison
    /// when routing action callbacks to the correct TerminalHostView.
    var surfacePointer: ghostty_surface_t? { surface }

    /// Whether the terminal surface is alive (has a backing ghostty surface).
    var isAlive: Bool { surface != nil }

    /// Whether the foreground process for this surface has exited.
    var processExited: Bool {
        guard let surface else { return true }
        return ghostty_surface_process_exited(surface)
    }

    var isRendererReady: Bool {
        surface != nil
    }

    static var isRealRendererAvailable: Bool {
        ghosttyApp != nil
    }

    /// Called when ghostty requests the surface to close.
    var onClose: ((Bool) -> Void)?

    init(
        hostView: NSView,
        launchConfiguration: TerminalSurfaceLaunchConfiguration = .shell()
    ) {
        guard let app = TerminalSurface.ghosttyApp else {
            Log.terminal.error("ghostty app not initialized - call initializeGhostty() first")
            Self.emitSmokeDiagnostic("ghostty app was not initialized before surface creation")
            return
        }

        let selfPtr = Unmanaged.passRetained(self).toOpaque()
        let nsviewPtr = Unmanaged.passUnretained(hostView).toOpaque()

        var surfaceConfig = ghostty_surface_config_new()
        surfaceConfig.userdata = selfPtr
        surfaceConfig.platform_tag = GHOSTTY_PLATFORM_MACOS
        surfaceConfig.platform = ghostty_platform_u(
            macos: ghostty_platform_macos_s(nsview: nsviewPtr)
        )
        surfaceConfig.scale_factor = Double(NSScreen.main?.backingScaleFactor ?? 2.0)
        // font_size = 0 means "inherit from ghostty config" (e.g. ~/.config/ghostty/config).
        // A positive value would override the user's configured font-size.
        surfaceConfig.font_size = 0

        var wdNSString: NSString?
        var cmdNSString: NSString?
        var initialInputNSString: NSString?
        var envKeys: [NSString] = []
        var envValues: [NSString] = []
        var envVars: [ghostty_env_var_s] = []
        if let workingDirectory = launchConfiguration.workingDirectory {
            wdNSString = workingDirectory as NSString
            surfaceConfig.working_directory = wdNSString?.utf8String
        }
        if let command = launchConfiguration.command {
            cmdNSString = command as NSString
            surfaceConfig.command = cmdNSString?.utf8String
        }
        if let initialInput = launchConfiguration.initialInput {
            initialInputNSString = initialInput as NSString
            surfaceConfig.initial_input = initialInputNSString?.utf8String
        }
        surfaceConfig.wait_after_command = launchConfiguration.waitAfterCommand

        if !launchConfiguration.env.isEmpty {
            for item in launchConfiguration.env {
                let key = item.key as NSString
                let value = item.value as NSString
                envKeys.append(key)
                envValues.append(value)
            }
            for index in envKeys.indices {
                envVars.append(
                    ghostty_env_var_s(
                        key: envKeys[index].utf8String,
                        value: envValues[index].utf8String
                    )
                )
            }
            envVars.withUnsafeMutableBufferPointer { buffer in
                surfaceConfig.env_vars = buffer.baseAddress
                surfaceConfig.env_var_count = buffer.count
                surface = ghostty_surface_new(app, &surfaceConfig)
            }
        } else {
            surface = ghostty_surface_new(app, &surfaceConfig)
        }

        if surface == nil {
            Log.terminal.error("ghostty_surface_new() returned nil")
            Self.emitSmokeDiagnostic("ghostty_surface_new returned nil")
            Unmanaged<TerminalSurface>.fromOpaque(selfPtr).release()
        } else {
            retainedSelfPtr = selfPtr
            Self.surfaceRegistryLock.lock()
            Self.surfaceRegistry.add(self)
            Self.surfaceRegistryLock.unlock()
        }
    }

    /// Releases the retained `self` pointer previously passed to ghostty
    /// as surface userdata. Safe to call multiple times — only the first
    /// call releases; subsequent calls are no-ops.
    func releaseRetainedSelfIfNeeded() {
        guard let ptr = retainedSelfPtr else { return }
        retainedSelfPtr = nil
        Unmanaged<TerminalSurface>.fromOpaque(ptr).release()
    }

    deinit {
        releaseRetainedSelfIfNeeded()
        if let surface {
            ghostty_surface_free(surface)
        }
        Self.surfaceRegistryLock.lock()
        Self.surfaceRegistry.remove(self)
        Self.surfaceRegistryLock.unlock()
    }

    // MARK: - Layout

    func resize(width: UInt32, height: UInt32) {
        guard let surface else { return }
        ghostty_surface_set_size(surface, width, height)
    }

    func size() -> (columns: UInt16, rows: UInt16)? {
        guard let surface else { return nil }
        let size = ghostty_surface_size(surface)
        return (size.columns, size.rows)
    }

    func setContentScale(_ scale: Double) {
        guard let surface else { return }
        ghostty_surface_set_content_scale(surface, scale, scale)
    }

    func setFocus(_ focused: Bool) {
        guard let surface else { return }
        ghostty_surface_set_focus(surface, focused)
    }

    func setDisplayID(_ displayID: UInt32) {
        guard let surface else { return }
        ghostty_surface_set_display_id(surface, displayID)
    }

    func setColorScheme(_ scheme: ghostty_color_scheme_e) {
        guard let surface else { return }
        ghostty_surface_set_color_scheme(surface, scheme)
    }

    fileprivate func updateConfig(_ config: ghostty_config_t) {
        guard let surface else { return }
        ghostty_surface_update_config(surface, config)
    }

    @MainActor
    static func applyGhosttyConfig(_ owner: TerminalConfig) {
        ghosttyConfigOwner = owner
        guard let config = owner.config else { return }
        if let ghosttyApp {
            ghostty_app_update_config(ghosttyApp, config)
        }
        surfaceRegistryLock.lock()
        let surfaces = surfaceRegistry.allObjects
        surfaceRegistryLock.unlock()
        for surface in surfaces {
            surface.updateConfig(config)
        }
    }

    /// Re-apply the current color scheme to the ghostty app so that
    /// conditional themes (e.g. "light:X,dark:Y") resolve correctly
    /// after a config update.
    @MainActor
    static func reapplyColorScheme() {
        guard let ghosttyApp else { return }
        let scheme = NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? GHOSTTY_COLOR_SCHEME_DARK : GHOSTTY_COLOR_SCHEME_LIGHT
        ghostty_app_set_color_scheme(ghosttyApp, scheme)
    }

    // MARK: - Keyboard Input

    @discardableResult
    func sendKey(_ event: ghostty_input_key_s) -> Bool {
        guard let surface else { return false }
        return ghostty_surface_key(surface, event)
    }

    func sendText(_ text: String) {
        guard let surface else { return }
        text.withCString { ptr in
            ghostty_surface_text(surface, ptr, UInt(text.utf8.count))
        }
    }

    /// Sends a synthetic Return key press + release to the terminal surface.
    func sendReturn() {
        guard let surface else { return }
        var key = ghostty_input_key_s()
        key.mods = GHOSTTY_MODS_NONE
        key.consumed_mods = GHOSTTY_MODS_NONE
        key.keycode = 36 // kVK_Return
        key.composing = false
        key.unshifted_codepoint = 13
        "\r".withCString { ptr in
            key.text = ptr
            key.action = GHOSTTY_ACTION_PRESS
            ghostty_surface_key(surface, key)
        }
        key.text = nil
        key.action = GHOSTTY_ACTION_RELEASE
        ghostty_surface_key(surface, key)
    }

    func sendPreedit(_ text: String) {
        guard let surface else { return }
        text.withCString { ptr in
            ghostty_surface_preedit(surface, ptr, UInt(text.utf8.count))
        }
    }

    func imePoint() -> (x: Double, y: Double, width: Double, height: Double) {
        guard let surface else { return (0, 0, 0, 0) }
        var x: Double = 0
        var y: Double = 0
        var width: Double = 0
        var height: Double = 0
        ghostty_surface_ime_point(surface, &x, &y, &width, &height)
        return (x, y, width, height)
    }

    // MARK: - Mouse Input

    @discardableResult
    func sendMouseButton(
        state: ghostty_input_mouse_state_e,
        button: ghostty_input_mouse_button_e,
        mods: ghostty_input_mods_e
    ) -> Bool {
        guard let surface else { return false }
        return ghostty_surface_mouse_button(surface, state, button, mods)
    }

    func sendMousePos(x: Double, y: Double, mods: ghostty_input_mods_e) {
        guard let surface else { return }
        ghostty_surface_mouse_pos(surface, x, y, mods)
    }

    func sendMouseScroll(x: Double, y: Double, scrollMods: ghostty_input_scroll_mods_t) {
        guard let surface else { return }
        ghostty_surface_mouse_scroll(surface, x, y, scrollMods)
    }

    func requestClose() {
        guard let surface else { return }
        ghostty_surface_request_close(surface)
    }

    // MARK: - Callbacks

    private func handleClose(processAlive: Bool) {
        // The close callback already consumed the retained pointer via
        // takeRetainedValue(), so clear our tracking to prevent double-release.
        retainedSelfPtr = nil
        onClose?(processAlive)
    }

    @MainActor
    private func completeClipboardRead(state: UnsafeMutableRawPointer?, confirmed: Bool) {
        let content = Self.clipboardStringForRequest(confirmed: confirmed)
        completeClipboardRequest(content, state: state, confirmed: confirmed)
    }

    @MainActor
    private func completeClipboardRequest(
        _ data: String,
        state: UnsafeMutableRawPointer?,
        confirmed: Bool = false
    ) {
        guard let surface, let state else { return }
        data.withCString { ptr in
            ghostty_surface_complete_clipboard_request(surface, ptr, state, confirmed)
        }
    }

    // MARK: - Runtime Config (nonisolated)

    /// Build the ghostty runtime config with C callbacks.
    /// MUST be nonisolated — ghostty calls these callbacks from its io-reader
    /// background thread. Defining them inside an @MainActor method causes
    /// Swift 6 to add runtime isolation checks that crash on the wrong queue.
    nonisolated static func makeRuntimeConfig() -> ghostty_runtime_config_s {
        ghostty_runtime_config_s(
            userdata: nil,
            supports_selection_clipboard: false,
            wakeup_cb: { _ in
                Task { @MainActor in
                    if let app = TerminalSurface.ghosttyApp {
                        ghostty_app_tick(app)
                    }
                }
            },
            action_cb: { userdata, target, action in
                return TerminalSurface.handleAction(userdata: userdata, action: action, target: target)
            },
            read_clipboard_cb: { userdata, _, statePtr in
                // Convert pointers to Int (Sendable) so we can cross the actor boundary.
                let udBits = userdata.map { Int(bitPattern: $0) }
                let spBits = statePtr.map { Int(bitPattern: $0) }
                Task { @MainActor in
                    let ud = udBits.flatMap { UnsafeMutableRawPointer(bitPattern: $0) }
                    guard let surface = TerminalSurface.surface(from: ud) else { return }
                    let sp = spBits.flatMap { UnsafeMutableRawPointer(bitPattern: $0) }
                    surface.completeClipboardRead(state: sp, confirmed: false)
                }
            },
            confirm_read_clipboard_cb: { userdata, _, statePtr, _ in
                let udBits = userdata.map { Int(bitPattern: $0) }
                let spBits = statePtr.map { Int(bitPattern: $0) }
                Task { @MainActor in
                    let ud = udBits.flatMap { UnsafeMutableRawPointer(bitPattern: $0) }
                    guard let surface = TerminalSurface.surface(from: ud) else { return }
                    let sp = spBits.flatMap { UnsafeMutableRawPointer(bitPattern: $0) }
                    surface.completeClipboardRead(state: sp, confirmed: true)
                }
            },
            write_clipboard_cb: { _, _, content, length, confirm in
                guard !confirm,
                      let string = TerminalSurface.preferredClipboardWriteString(content: content, length: length) else { return }
                Task { @MainActor in
                    TerminalSurface.writeClipboardString(string)
                }
            },
            close_surface_cb: { userdata, processAlive in
                guard let userdata else { return }
                let udBits = Int(bitPattern: userdata)
                Task { @MainActor in
                    guard let ptr = UnsafeMutableRawPointer(bitPattern: udBits) else { return }
                    let surface = Unmanaged<TerminalSurface>.fromOpaque(ptr).takeRetainedValue()
                    surface.handleClose(processAlive: processAlive)
                }
            }
        )
    }

    private static func surface(from userdata: UnsafeMutableRawPointer?) -> TerminalSurface? {
        guard let userdata else { return nil }
        return Unmanaged<TerminalSurface>.fromOpaque(userdata).takeUnretainedValue()
    }

    // MARK: - Action Callback Dispatcher

    private static func handleAction(
        userdata: UnsafeMutableRawPointer?,
        action: ghostty_action_s,
        target: ghostty_target_s
    ) -> Bool {
        switch action.tag {
        case GHOSTTY_ACTION_DESKTOP_NOTIFICATION:
            let n = action.action.desktop_notification
            let title = n.title.map { String(cString: $0) } ?? ""
            let body = n.body.map { String(cString: $0) } ?? ""
            let surfacePtr = target.target.surface
            Task { @MainActor in
                NotificationCenter.default.post(
                    name: .ghosttyDesktopNotification,
                    object: nil,
                    userInfo: [
                        "surface": surfacePtr as Any,
                        "title": title,
                        "body": body,
                    ]
                )
            }
            return true

        case GHOSTTY_ACTION_SET_TITLE:
            let v = action.action.set_title
            let title = v.title.map { String(cString: $0) } ?? ""
            let surfacePtr = target.target.surface
            Task { @MainActor in
                NotificationCenter.default.post(
                    name: .ghosttySetTitle,
                    object: nil,
                    userInfo: ["surface": surfacePtr as Any, "title": title]
                )
            }
            return true

        case GHOSTTY_ACTION_PWD:
            let v = action.action.pwd
            let path = v.pwd.map { String(cString: $0) } ?? ""
            let surfacePtr = target.target.surface
            Task { @MainActor in
                NotificationCenter.default.post(
                    name: .ghosttyPwdChanged,
                    object: nil,
                    userInfo: ["surface": surfacePtr as Any, "path": path]
                )
            }
            return true

        case GHOSTTY_ACTION_RING_BELL:
            let surfacePtr = target.target.surface
            Task { @MainActor in
                NotificationCenter.default.post(
                    name: .ghosttyRingBell,
                    object: nil,
                    userInfo: ["surface": surfacePtr as Any]
                )
            }
            return true

        case GHOSTTY_ACTION_COLOR_CHANGE, GHOSTTY_ACTION_CONFIG_CHANGE, GHOSTTY_ACTION_RELOAD_CONFIG:
            Task { @MainActor in
                GhosttyThemeProvider.shared.refresh()
            }
            return true

        case GHOSTTY_ACTION_OPEN_URL:
            let v = action.action.open_url
            if let urlPtr = v.url, v.len > 0 {
                let data = Data(bytes: urlPtr, count: Int(v.len))
                if let urlString = String(data: data, encoding: .utf8),
                   let url = URL(string: urlString),
                   let scheme = url.scheme?.lowercased() {
                    let surfacePtr = target.target.surface
                    Task { @MainActor in
                        if ["http", "https"].contains(scheme) {
                            NotificationCenter.default.post(
                                name: .ghosttyOpenURL,
                                object: nil,
                                userInfo: [
                                    "surface": surfacePtr as Any,
                                    "url": url.absoluteString,
                                ]
                            )
                        } else if ["mailto", "file"].contains(scheme) {
                            NSWorkspace.shared.open(url)
                        }
                    }
                }
            }
            return true

        case GHOSTTY_ACTION_MOUSE_VISIBILITY:
            let v = action.action.mouse_visibility
            Task { @MainActor in
                switch v {
                case GHOSTTY_MOUSE_HIDDEN:
                    NSCursor.setHiddenUntilMouseMoves(true)
                case GHOSTTY_MOUSE_VISIBLE:
                    NSCursor.setHiddenUntilMouseMoves(false)
                default:
                    break
                }
            }
            return true

        case GHOSTTY_ACTION_MOUSE_SHAPE:
            let shape = action.action.mouse_shape
            let surfacePtr = target.target.surface
            Task { @MainActor in
                NotificationCenter.default.post(
                    name: .ghosttyMouseShape,
                    object: nil,
                    userInfo: ["surface": surfacePtr as Any, "shape": shape.rawValue]
                )
            }
            return true

        // Window/tab/split management — Pnevma manages its own layout,
        // so consume these to prevent libghostty from attempting to handle them.
        case GHOSTTY_ACTION_QUIT,
             GHOSTTY_ACTION_NEW_WINDOW,
             GHOSTTY_ACTION_NEW_TAB,
             GHOSTTY_ACTION_NEW_SPLIT,
             GHOSTTY_ACTION_CLOSE_TAB,
             GHOSTTY_ACTION_CLOSE_ALL_WINDOWS,
             GHOSTTY_ACTION_CLOSE_WINDOW,
             GHOSTTY_ACTION_TOGGLE_FULLSCREEN,
             GHOSTTY_ACTION_TOGGLE_MAXIMIZE,
             GHOSTTY_ACTION_TOGGLE_QUICK_TERMINAL,
             GHOSTTY_ACTION_TOGGLE_COMMAND_PALETTE,
             GHOSTTY_ACTION_TOGGLE_VISIBILITY,
             GHOSTTY_ACTION_TOGGLE_SPLIT_ZOOM,
             GHOSTTY_ACTION_MOVE_TAB,
             GHOSTTY_ACTION_GOTO_TAB,
             GHOSTTY_ACTION_GOTO_SPLIT,
             GHOSTTY_ACTION_RESIZE_SPLIT,
             GHOSTTY_ACTION_EQUALIZE_SPLITS,
             GHOSTTY_ACTION_FLOAT_WINDOW,
             GHOSTTY_ACTION_INITIAL_SIZE,
             GHOSTTY_ACTION_RESET_WINDOW_SIZE,
             GHOSTTY_ACTION_OPEN_CONFIG,
             GHOSTTY_ACTION_CHECK_FOR_UPDATES:
            return true

        default:
            // Return false for actions we don't explicitly handle so libghostty
            // performs its default behavior (e.g. Kitty image rendering, mouse
            // cursor shape, cell size reporting, etc.).
            return false
        }
    }

    private static func emitSmokeDiagnostic(_ message: String) {
        guard AppSmokeMode.current != nil else { return }
        let line = "Smoke diagnostic: \(message)\n"
        if let data = line.data(using: .utf8) {
            FileHandle.standardError.write(data)
        }
    }

    #else

    // MARK: - Placeholder (no GhosttyKit)

    var onClose: ((Bool) -> Void)?

    var isRendererReady: Bool { false }
    var isAlive: Bool { false }
    var processExited: Bool { true }

    static var isRealRendererAvailable: Bool { false }

    @MainActor
    static func initializeGhostty() {
        Log.terminal.info("GhosttyKit not available - placeholder mode active")
    }

    @MainActor
    static func shutdownGhostty() {}

    @MainActor
    static func applyGhosttyConfig(_ owner: TerminalConfig) {
        _ = owner
    }

    init(
        hostView: NSView,
        launchConfiguration: TerminalSurfaceLaunchConfiguration = .shell()
    ) {
        _ = hostView
        _ = launchConfiguration
        Log.terminal.info("Placeholder: no ghostty surface created")
    }

    func resize(width: UInt32, height: UInt32) {}
    func size() -> (columns: UInt16, rows: UInt16)? { nil }
    func setContentScale(_ scale: Double) {}
    func setFocus(_ focused: Bool) {}
    func setDisplayID(_ displayID: UInt32) {}
    @discardableResult func sendKey(_ event: Any) -> Bool { false }
    func sendText(_ text: String) {}
    func sendReturn() {}
    func sendPreedit(_ text: String) {}
    func imePoint() -> (x: Double, y: Double, width: Double, height: Double) { (0, 0, 0, 0) }
    @discardableResult func sendMouseButton(state: Any, button: Any, mods: Any) -> Bool { false }
    func sendMousePos(x: Double, y: Double, mods: Any) {}
    func sendMouseScroll(x: Double, y: Double, scrollMods: Any) {}
    func requestClose() {}

    #endif
}

// MARK: - Ghostty Action Notification Names

extension Notification.Name {
    static let ghosttyDesktopNotification = Notification.Name("ghosttyDesktopNotification")
    static let ghosttySetTitle = Notification.Name("ghosttySetTitle")
    static let ghosttyPwdChanged = Notification.Name("ghosttyPwdChanged")
    static let ghosttyRingBell = Notification.Name("ghosttyRingBell")
    static let ghosttyMouseShape = Notification.Name("ghosttyMouseShape")
    static let ghosttyOpenURL = Notification.Name("ghosttyOpenURL")
}
