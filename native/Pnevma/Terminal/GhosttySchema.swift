import Foundation

enum GhosttyConfigCategory: String, CaseIterable, Identifiable {
    case appearance
    case font
    case cursor
    case mouse
    case scrolling
    case clipboard
    case shell
    case window
    case platform
    case quickTerminal
    case notifications
    case advanced
    case keybindings

    var id: String { rawValue }

    var title: String {
        switch self {
        case .appearance:
            return "Appearance"
        case .font:
            return "Font"
        case .cursor:
            return "Cursor & Selection"
        case .mouse:
            return "Mouse"
        case .scrolling:
            return "Scrolling"
        case .clipboard:
            return "Clipboard & Links"
        case .shell:
            return "Shell & Startup"
        case .window:
            return "Window & Tabs"
        case .platform:
            return "Platform"
        case .quickTerminal:
            return "Quick Terminal"
        case .notifications:
            return "Notifications"
        case .advanced:
            return "Advanced"
        case .keybindings:
            return "Keybindings"
        }
    }

    var systemImage: String {
        switch self {
        case .appearance: return "paintbrush"
        case .font: return "textformat.size"
        case .cursor: return "cursorarrow"
        case .mouse: return "computermouse"
        case .scrolling: return "scroll"
        case .clipboard: return "doc.on.clipboard"
        case .shell: return "terminal"
        case .window: return "macwindow"
        case .platform: return "desktopcomputer"
        case .quickTerminal: return "bolt.horizontal"
        case .notifications: return "bell"
        case .advanced: return "gearshape.2"
        case .keybindings: return "command"
        }
    }
}

enum GhosttyValueKind: Equatable {
    case toggle
    case integer
    case double
    case string
    case color
    case raw
    case multiLine
    case keybinds
}

struct GhosttyConfigDescriptor: Identifiable, Equatable {
    let key: String
    let rawType: String
    let category: GhosttyConfigCategory
    let title: String
    let valueKind: GhosttyValueKind
    let isCommon: Bool

    var id: String { key }
    var docsURL: URL { URL(string: "https://ghostty.org/docs/config/reference#\(key)")! }
}

struct GhosttyKeybindActionDescriptor: Identifiable, Equatable {
    let name: String
    let parameterPlaceholder: String?

    var id: String { name }
    var docsURL: URL { URL(string: "https://ghostty.org/docs/config/keybind/reference#\(name)")! }
}

enum GhosttySchema {
    static let configTypes: [String: String] = [
        "_xdg-terminal-exec": "bool",
        "abnormal-command-exit-runtime": "u32",
        "adjust-box-thickness": "?MetricModifier",
        "adjust-cell-height": "?MetricModifier",
        "adjust-cell-width": "?MetricModifier",
        "adjust-cursor-height": "?MetricModifier",
        "adjust-cursor-thickness": "?MetricModifier",
        "adjust-font-baseline": "?MetricModifier",
        "adjust-icon-height": "?MetricModifier",
        "adjust-overline-position": "?MetricModifier",
        "adjust-overline-thickness": "?MetricModifier",
        "adjust-strikethrough-position": "?MetricModifier",
        "adjust-strikethrough-thickness": "?MetricModifier",
        "adjust-underline-position": "?MetricModifier",
        "adjust-underline-thickness": "?MetricModifier",
        "alpha-blending": "AlphaBlending",
        "app-notifications": "AppNotifications",
        "async-backend": "AsyncBackend",
        "auto-update": "?AutoUpdate",
        "auto-update-channel": "?build_config.ReleaseChannel",
        "background": "Color",
        "background-blur": "BackgroundBlur",
        "background-image": "?Path",
        "background-image-fit": "BackgroundImageFit",
        "background-image-opacity": "f32",
        "background-image-position": "BackgroundImagePosition",
        "background-image-repeat": "bool",
        "background-opacity": "f64",
        "background-opacity-cells": "bool",
        "bell-audio-path": "?Path",
        "bell-audio-volume": "f64",
        "bell-features": "BellFeatures",
        "bold-color": "?BoldColor",
        "class": "?[:0]const u8",
        "click-repeat-interval": "u32",
        "clipboard-paste-bracketed-safe": "bool",
        "clipboard-paste-protection": "bool",
        "clipboard-read": "ClipboardAccess",
        "clipboard-trim-trailing-spaces": "bool",
        "clipboard-write": "ClipboardAccess",
        "command": "?Command",
        "command-palette-entry": "RepeatableCommand",
        "config-default-files": "bool",
        "config-file": "RepeatablePath",
        "confirm-close-surface": "ConfirmCloseSurface",
        "copy-on-select": "CopyOnSelect",
        "cursor-click-to-move": "bool",
        "cursor-color": "?TerminalColor",
        "cursor-opacity": "f64",
        "cursor-style": "terminal.CursorStyle",
        "cursor-style-blink": "?bool",
        "cursor-text": "?TerminalColor",
        "custom-shader": "RepeatablePath",
        "custom-shader-animation": "CustomShaderAnimation",
        "desktop-notifications": "bool",
        "enquiry-response": "[]const u8",
        "env": "RepeatableStringMap",
        "faint-opacity": "f64",
        "focus-follows-mouse": "bool",
        "font-codepoint-map": "RepeatableCodepointMap",
        "font-family": "RepeatableString",
        "font-family-bold": "RepeatableString",
        "font-family-bold-italic": "RepeatableString",
        "font-family-italic": "RepeatableString",
        "font-feature": "RepeatableString",
        "font-shaping-break": "FontShapingBreak",
        "font-size": "f32",
        "font-style": "FontStyle",
        "font-style-bold": "FontStyle",
        "font-style-bold-italic": "FontStyle",
        "font-style-italic": "FontStyle",
        "font-synthetic-style": "FontSyntheticStyle",
        "font-thicken": "bool",
        "font-thicken-strength": "u8",
        "font-variation": "RepeatableFontVariation",
        "font-variation-bold": "RepeatableFontVariation",
        "font-variation-bold-italic": "RepeatableFontVariation",
        "font-variation-italic": "RepeatableFontVariation",
        "foreground": "Color",
        "freetype-load-flags": "FreetypeLoadFlags",
        "fullscreen": "bool",
        "grapheme-width-method": "GraphemeWidthMethod",
        "gtk-custom-css": "RepeatablePath",
        "gtk-opengl-debug": "bool",
        "gtk-quick-terminal-layer": "QuickTerminalLayer",
        "gtk-quick-terminal-namespace": "[:0]const u8",
        "gtk-single-instance": "GtkSingleInstance",
        "gtk-tabs-location": "GtkTabsLocation",
        "gtk-titlebar": "bool",
        "gtk-titlebar-hide-when-maximized": "bool",
        "gtk-titlebar-style": "GtkTitlebarStyle",
        "gtk-toolbar-style": "GtkToolbarStyle",
        "gtk-wide-tabs": "bool",
        "image-storage-limit": "u32",
        "initial-command": "?Command",
        "initial-window": "bool",
        "input": "RepeatableReadableIO",
        "keybind": "Keybinds",
        "link": "RepeatableLink",
        "link-previews": "LinkPreviews",
        "link-url": "bool",
        "linux-cgroup": "LinuxCgroup",
        "linux-cgroup-hard-fail": "bool",
        "linux-cgroup-memory-limit": "?u64",
        "linux-cgroup-processes-limit": "?u64",
        "macos-auto-secure-input": "bool",
        "macos-custom-icon": "?[]const u8",
        "macos-dock-drop-behavior": "MacOSDockDropBehavior",
        "macos-hidden": "MacHidden",
        "macos-icon": "MacAppIcon",
        "macos-icon-frame": "MacAppIconFrame",
        "macos-icon-ghost-color": "?Color",
        "macos-icon-screen-color": "?ColorList",
        "macos-non-native-fullscreen": "NonNativeFullscreen",
        "macos-option-as-alt": "?OptionAsAlt",
        "macos-secure-input-indication": "bool",
        "macos-shortcuts": "MacShortcuts",
        "macos-titlebar-proxy-icon": "MacTitlebarProxyIcon",
        "macos-titlebar-style": "MacTitlebarStyle",
        "macos-window-buttons": "MacWindowButtons",
        "macos-window-shadow": "bool",
        "maximize": "bool",
        "minimum-contrast": "f64",
        "mouse-hide-while-typing": "bool",
        "mouse-scroll-multiplier": "f64",
        "mouse-shift-capture": "MouseShiftCapture",
        "osc-color-report-format": "OSCColorReportFormat",
        "palette": "Palette",
        "quick-terminal-animation-duration": "f64",
        "quick-terminal-autohide": "bool",
        "quick-terminal-keyboard-interactivity": "QuickTerminalKeyboardInteractivity",
        "quick-terminal-position": "QuickTerminalPosition",
        "quick-terminal-screen": "QuickTerminalScreen",
        "quick-terminal-size": "QuickTerminalSize",
        "quick-terminal-space-behavior": "QuickTerminalSpaceBehavior",
        "quit-after-last-window-closed": "bool",
        "quit-after-last-window-closed-delay": "?Duration",
        "resize-overlay": "ResizeOverlay",
        "resize-overlay-duration": "Duration",
        "resize-overlay-position": "ResizeOverlayPosition",
        "right-click-action": "RightClickAction",
        "scroll-to-bottom": "ScrollToBottom",
        "scrollback-limit": "usize",
        "selection-background": "?TerminalColor",
        "selection-clear-on-copy": "bool",
        "selection-clear-on-typing": "bool",
        "selection-foreground": "?TerminalColor",
        "shell-integration": "ShellIntegration",
        "shell-integration-features": "ShellIntegrationFeatures",
        "split-divider-color": "?Color",
        "term": "[]const u8",
        "theme": "?Theme",
        "title": "?[:0]const u8",
        "title-report": "bool",
        "undo-timeout": "Duration",
        "unfocused-split-fill": "?Color",
        "unfocused-split-opacity": "f64",
        "vt-kam-allowed": "bool",
        "wait-after-command": "bool",
        "window-colorspace": "WindowColorspace",
        "window-decoration": "WindowDecoration",
        "window-height": "u32",
        "window-inherit-font-size": "bool",
        "window-inherit-working-directory": "bool",
        "window-new-tab-position": "WindowNewTabPosition",
        "window-padding-balance": "bool",
        "window-padding-color": "WindowPaddingColor",
        "window-padding-x": "WindowPadding",
        "window-padding-y": "WindowPadding",
        "window-position-x": "?i16",
        "window-position-y": "?i16",
        "window-save-state": "WindowSaveState",
        "window-show-tab-bar": "WindowShowTabBar",
        "window-step-resize": "bool",
        "window-subtitle": "WindowSubtitle",
        "window-theme": "WindowTheme",
        "window-title-font-family": "?[:0]const u8",
        "window-titlebar-background": "?Color",
        "window-titlebar-foreground": "?Color",
        "window-vsync": "bool",
        "window-width": "u32",
        "working-directory": "?[]const u8",
        "x11-instance-name": "?[:0]const u8",
    ]

    static let enumOptions: [String: [String]] = [
        "alpha-blending": ["native", "linear", "linear-corrected"],
        "background-image-fit": ["contain", "cover", "stretch", "none"],
        "background-image-position": ["center", "top-left", "top-center", "top-right", "center-left", "center-right", "bottom-left", "bottom-center", "bottom-right"],
        "clipboard-read": ["allow", "deny", "ask"],
        "clipboard-write": ["allow", "deny", "ask"],
        "confirm-close-surface": ["false", "true", "always"],
        "copy-on-select": ["false", "true", "clipboard"],
        "cursor-style": ["block", "bar", "underline", "block_hollow"],
        "custom-shader-animation": ["false", "true", "always"],
        "grapheme-width-method": ["legacy", "unicode"],
        "gtk-single-instance": ["false", "true", "detect"],
        "gtk-tabs-location": ["top", "bottom"],
        "gtk-titlebar-style": ["native", "tabs"],
        "gtk-toolbar-style": ["flat", "raised", "raised-border"],
        "link-previews": ["false", "true", "osc8"],
        "linux-cgroup": ["never", "always", "single-instance"],
        "macos-dock-drop-behavior": ["new-tab", "window"],
        "macos-hidden": ["never", "always"],
        "macos-icon": ["official", "blueprint", "chalkboard", "microchip", "glass", "holographic", "paper", "retro", "xray", "custom", "custom-style"],
        "macos-icon-frame": ["aluminum", "beige", "plastic", "chrome"],
        "macos-non-native-fullscreen": ["false", "true", "visible-menu", "padded-notch"],
        "macos-option-as-alt": ["false", "true", "left", "right"],
        "macos-shortcuts": ["allow", "deny", "ask"],
        "macos-titlebar-proxy-icon": ["visible", "hidden"],
        "macos-titlebar-style": ["native", "transparent", "tabs", "hidden"],
        "macos-window-buttons": ["visible", "hidden"],
        "mouse-shift-capture": ["false", "true", "always", "never"],
        "osc-color-report-format": ["none", "8-bit", "16-bit"],
        "quick-terminal-keyboard-interactivity": ["none", "on-demand", "exclusive"],
        "quick-terminal-position": ["top", "bottom", "left", "right", "center"],
        "quick-terminal-screen": ["main", "mouse", "macos-menu-bar"],
        "quick-terminal-space-behavior": ["remain", "move"],
        "resize-overlay": ["always", "never", "after-first"],
        "resize-overlay-position": ["center", "top-left", "top-center", "top-right", "bottom-left", "bottom-center", "bottom-right"],
        "right-click-action": ["context-menu", "paste", "copy", "copy-or-paste", "ignore"],
        "shell-integration": ["none", "detect", "bash", "elvish", "fish", "zsh"],
        "window-colorspace": ["srgb", "display-p3"],
        "window-decoration": ["auto", "client", "server", "none"],
        "window-new-tab-position": ["current", "end"],
        "window-padding-color": ["background", "extend", "extend-always"],
        "window-save-state": ["default", "never", "always"],
        "window-show-tab-bar": ["always", "auto", "never"],
        "window-subtitle": ["false", "working-directory"],
        "window-theme": ["auto", "system", "light", "dark", "ghostty"],
    ]

    static let keybindActions: [GhosttyKeybindActionDescriptor] = [
        GhosttyKeybindActionDescriptor(name: "ignore", parameterPlaceholder: nil),
        GhosttyKeybindActionDescriptor(name: "unbind", parameterPlaceholder: nil),
        GhosttyKeybindActionDescriptor(name: "csi", parameterPlaceholder: "CSI payload"),
        GhosttyKeybindActionDescriptor(name: "esc", parameterPlaceholder: "ESC payload"),
        GhosttyKeybindActionDescriptor(name: "text", parameterPlaceholder: "Text payload"),
        GhosttyKeybindActionDescriptor(name: "cursor_key", parameterPlaceholder: "normal,application"),
        GhosttyKeybindActionDescriptor(name: "reset", parameterPlaceholder: nil),
        GhosttyKeybindActionDescriptor(name: "copy_to_clipboard", parameterPlaceholder: nil),
        GhosttyKeybindActionDescriptor(name: "paste_from_clipboard", parameterPlaceholder: nil),
        GhosttyKeybindActionDescriptor(name: "paste_from_selection", parameterPlaceholder: nil),
        GhosttyKeybindActionDescriptor(name: "copy_url_to_clipboard", parameterPlaceholder: nil),
        GhosttyKeybindActionDescriptor(name: "copy_title_to_clipboard", parameterPlaceholder: nil),
        GhosttyKeybindActionDescriptor(name: "increase_font_size", parameterPlaceholder: "delta points"),
        GhosttyKeybindActionDescriptor(name: "decrease_font_size", parameterPlaceholder: "delta points"),
        GhosttyKeybindActionDescriptor(name: "reset_font_size", parameterPlaceholder: nil),
        GhosttyKeybindActionDescriptor(name: "set_font_size", parameterPlaceholder: "points"),
        GhosttyKeybindActionDescriptor(name: "clear_screen", parameterPlaceholder: nil),
        GhosttyKeybindActionDescriptor(name: "select_all", parameterPlaceholder: nil),
        GhosttyKeybindActionDescriptor(name: "scroll_to_top", parameterPlaceholder: nil),
        GhosttyKeybindActionDescriptor(name: "scroll_to_bottom", parameterPlaceholder: nil),
        GhosttyKeybindActionDescriptor(name: "scroll_to_selection", parameterPlaceholder: nil),
        GhosttyKeybindActionDescriptor(name: "scroll_page_up", parameterPlaceholder: nil),
        GhosttyKeybindActionDescriptor(name: "scroll_page_down", parameterPlaceholder: nil),
        GhosttyKeybindActionDescriptor(name: "scroll_page_fractional", parameterPlaceholder: "fraction"),
        GhosttyKeybindActionDescriptor(name: "scroll_page_lines", parameterPlaceholder: "line count"),
        GhosttyKeybindActionDescriptor(name: "adjust_selection", parameterPlaceholder: "direction"),
        GhosttyKeybindActionDescriptor(name: "jump_to_prompt", parameterPlaceholder: "offset"),
        GhosttyKeybindActionDescriptor(name: "write_scrollback_file", parameterPlaceholder: "copy|paste|open"),
        GhosttyKeybindActionDescriptor(name: "write_screen_file", parameterPlaceholder: "copy|paste|open"),
        GhosttyKeybindActionDescriptor(name: "write_selection_file", parameterPlaceholder: "copy|paste|open"),
        GhosttyKeybindActionDescriptor(name: "new_window", parameterPlaceholder: nil),
        GhosttyKeybindActionDescriptor(name: "new_tab", parameterPlaceholder: nil),
        GhosttyKeybindActionDescriptor(name: "previous_tab", parameterPlaceholder: nil),
        GhosttyKeybindActionDescriptor(name: "next_tab", parameterPlaceholder: nil),
        GhosttyKeybindActionDescriptor(name: "last_tab", parameterPlaceholder: nil),
        GhosttyKeybindActionDescriptor(name: "goto_tab", parameterPlaceholder: "tab index"),
        GhosttyKeybindActionDescriptor(name: "move_tab", parameterPlaceholder: "offset"),
        GhosttyKeybindActionDescriptor(name: "toggle_tab_overview", parameterPlaceholder: nil),
        GhosttyKeybindActionDescriptor(name: "prompt_surface_title", parameterPlaceholder: nil),
        GhosttyKeybindActionDescriptor(name: "new_split", parameterPlaceholder: "direction"),
        GhosttyKeybindActionDescriptor(name: "goto_split", parameterPlaceholder: "direction"),
        GhosttyKeybindActionDescriptor(name: "toggle_split_zoom", parameterPlaceholder: nil),
        GhosttyKeybindActionDescriptor(name: "resize_split", parameterPlaceholder: "left:10,right:10,..."),
        GhosttyKeybindActionDescriptor(name: "equalize_splits", parameterPlaceholder: nil),
        GhosttyKeybindActionDescriptor(name: "reset_window_size", parameterPlaceholder: nil),
        GhosttyKeybindActionDescriptor(name: "inspector", parameterPlaceholder: "toggle|show|hide"),
        GhosttyKeybindActionDescriptor(name: "show_gtk_inspector", parameterPlaceholder: nil),
        GhosttyKeybindActionDescriptor(name: "show_on_screen_keyboard", parameterPlaceholder: nil),
        GhosttyKeybindActionDescriptor(name: "open_config", parameterPlaceholder: nil),
        GhosttyKeybindActionDescriptor(name: "reload_config", parameterPlaceholder: nil),
        GhosttyKeybindActionDescriptor(name: "close_surface", parameterPlaceholder: nil),
        GhosttyKeybindActionDescriptor(name: "close_tab", parameterPlaceholder: "visible|this|other"),
        GhosttyKeybindActionDescriptor(name: "close_window", parameterPlaceholder: nil),
        GhosttyKeybindActionDescriptor(name: "close_all_windows", parameterPlaceholder: nil),
        GhosttyKeybindActionDescriptor(name: "toggle_maximize", parameterPlaceholder: nil),
        GhosttyKeybindActionDescriptor(name: "toggle_fullscreen", parameterPlaceholder: nil),
        GhosttyKeybindActionDescriptor(name: "toggle_window_decorations", parameterPlaceholder: nil),
        GhosttyKeybindActionDescriptor(name: "toggle_window_float_on_top", parameterPlaceholder: nil),
        GhosttyKeybindActionDescriptor(name: "toggle_secure_input", parameterPlaceholder: nil),
        GhosttyKeybindActionDescriptor(name: "toggle_command_palette", parameterPlaceholder: nil),
        GhosttyKeybindActionDescriptor(name: "toggle_quick_terminal", parameterPlaceholder: nil),
        GhosttyKeybindActionDescriptor(name: "toggle_visibility", parameterPlaceholder: nil),
        GhosttyKeybindActionDescriptor(name: "check_for_updates", parameterPlaceholder: nil),
        GhosttyKeybindActionDescriptor(name: "undo", parameterPlaceholder: nil),
        GhosttyKeybindActionDescriptor(name: "redo", parameterPlaceholder: nil),
        GhosttyKeybindActionDescriptor(name: "quit", parameterPlaceholder: nil),
        GhosttyKeybindActionDescriptor(name: "crash", parameterPlaceholder: "main|io|render"),
    ]

    static let descriptors: [GhosttyConfigDescriptor] = configTypes.keys
        .sorted()
        .map { descriptor(for: $0) }

    static func descriptor(for key: String) -> GhosttyConfigDescriptor {
        let rawType = configTypes[key] ?? "String"
        return GhosttyConfigDescriptor(
            key: key,
            rawType: rawType,
            category: category(for: key),
            title: title(for: key),
            valueKind: valueKind(for: key, rawType: rawType),
            isCommon: commonKeys.contains(key)
        )
    }

    static func title(for key: String) -> String {
        key.split(separator: "-")
            .map { $0.capitalized }
            .joined(separator: " ")
    }

    static func category(for key: String) -> GhosttyConfigCategory {
        if key.hasPrefix("font") || key.hasPrefix("grapheme") || key.hasPrefix("freetype") || key.hasPrefix("adjust-") {
            return .font
        }
        if key.hasPrefix("cursor") || key.hasPrefix("selection") {
            return .cursor
        }
        if key.hasPrefix("mouse") || key == "click-repeat-interval" {
            return .mouse
        }
        if key.hasPrefix("scroll") || key == "image-storage-limit" || key == "resize-overlay" || key.hasPrefix("resize-overlay-") {
            return .scrolling
        }
        if key.hasPrefix("clipboard") || key == "copy-on-select" || key == "right-click-action" || key == "link-previews" || key == "link-url" {
            return .clipboard
        }
        if key.hasPrefix("window")
            || key == "maximize"
            || key == "fullscreen"
            || key == "focus-follows-mouse"
            || key == "title"
            || key == "class"
            || key == "theme"
            || key == "background"
            || key == "foreground"
            || key == "palette"
            || key == "background-image"
            || key.hasPrefix("background-")
            || key == "split-divider-color"
            || key.hasPrefix("unfocused-") {
            return .window
        }
        if key.hasPrefix("quick-terminal") || key.hasPrefix("gtk-quick-terminal") {
            return .quickTerminal
        }
        if key.hasPrefix("macos") || key.hasPrefix("gtk") || key.hasPrefix("linux") || key.hasPrefix("x11") || key == "desktop-notifications" {
            return .platform
        }
        if key.hasPrefix("bell") || key.contains("notifications") || key == "auto-update" || key == "auto-update-channel" {
            return .notifications
        }
        if key == "command"
            || key == "initial-command"
            || key == "wait-after-command"
            || key == "working-directory"
            || key == "term"
            || key == "shell-integration"
            || key == "shell-integration-features"
            || key == "env"
            || key == "input"
            || key == "vt-kam-allowed"
            || key == "command-palette-entry" {
            return .shell
        }
        return .advanced
    }

    static func valueKind(for key: String, rawType: String) -> GhosttyValueKind {
        if key == "keybind" {
            return .keybinds
        }
        if enumOptions[key] != nil {
            return .string
        }
        if rawType == "bool" || rawType == "?bool" {
            return .toggle
        }
        if ["u8", "u16", "u32", "u64", "usize", "i16", "i32", "i64", "isize", "Duration", "?Duration"].contains(rawType) {
            return .integer
        }
        if ["f32", "f64"].contains(rawType) {
            return .double
        }
        if rawType.hasPrefix("Repeatable") || rawType == "Palette" || rawType == "QuickTerminalSize" {
            return .multiLine
        }
        if rawType == "Color" || rawType == "?Color" {
            return .color
        }
        if rawType.contains("const u8")
            || rawType.hasPrefix("?")
            || rawType.contains("Window")
            || rawType.contains("Mac")
            || rawType.contains("Gtk")
            || rawType.contains("Shell")
            || rawType.contains("Clipboard")
            || rawType.contains("Link")
            || rawType.contains("Cursor")
            || rawType.contains("Overlay")
            || rawType.contains("Theme")
            || rawType.contains("Decoration")
            || rawType.contains("Padding")
            || rawType.contains("Contrast")
            || rawType.contains("BoldColor")
            || rawType.contains("AppNotifications")
            || rawType.contains("AsyncBackend")
            || rawType.contains("AutoUpdate")
            || rawType.contains("AlphaBlending")
            || rawType.contains("ScrollToBottom")
            || rawType.contains("OptionAsAlt")
            || rawType.contains("Bell") {
            return .string
        }
        return .raw
    }

    static let commonKeys: Set<String> = [
        "font-family",
        "font-size",
        "background",
        "foreground",
        "theme",
        "window-theme",
        "window-decoration",
        "window-padding-x",
        "window-padding-y",
        "window-show-tab-bar",
        "cursor-style",
        "cursor-style-blink",
        "cursor-color",
        "cursor-text",
        "selection-background",
        "selection-foreground",
        "mouse-hide-while-typing",
        "scrollback-limit",
        "copy-on-select",
        "right-click-action",
        "background-opacity",
        "background-blur",
        "working-directory",
        "command",
        "wait-after-command",
        "macos-titlebar-style",
        "macos-window-buttons",
        "macos-option-as-alt",
        "macos-window-shadow",
        "quick-terminal-position",
        "quick-terminal-autohide",
        "desktop-notifications",
        "window-titlebar-background",
        "window-titlebar-foreground",
    ]
}
