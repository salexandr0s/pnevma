import AppKit

/// Bridges Rust keybinding config to live NSMenuItem shortcuts.
///
/// Maintains the current action→shortcut map, parses shortcut strings into
/// AppKit key equivalents, and dynamically updates the menu bar when bindings change.
@MainActor
final class AppKeybindingManager {
    static let shared = AppKeybindingManager()

    struct KeyEquivalentEntry: Hashable {
        let key: String
        let modifiers: NSEvent.ModifierFlags

        static func == (lhs: KeyEquivalentEntry, rhs: KeyEquivalentEntry) -> Bool {
            lhs.key == rhs.key && lhs.modifiers.rawValue == rhs.modifiers.rawValue
        }

        func hash(into hasher: inout Hasher) {
            hasher.combine(key)
            hasher.combine(modifiers.rawValue)
        }
    }

    struct ParsedShortcut {
        let key: String
        let modifiers: NSEvent.ModifierFlags
    }

    /// Current action → shortcut string map
    private(set) var bindings: [String: String] = [:]

    /// Set of active (key, modifiers) for terminal deferral checks
    private(set) var activeKeyEquivalents: Set<KeyEquivalentEntry> = []

    private init() {}

    // MARK: - Shortcut Parsing

    /// Parse "Cmd+Shift+D" → (key: "d", modifiers: [.command, .shift])
    static func parse(_ shortcut: String) -> ParsedShortcut? {
        let parts = shortcut.split(separator: "+").map { $0.trimmingCharacters(in: .whitespaces) }
        guard !parts.isEmpty else { return nil }

        var modifiers: NSEvent.ModifierFlags = []
        var keyPart: String?

        for part in parts {
            switch part {
            case "Cmd", "Mod":
                modifiers.insert(.command)
            case "Shift":
                modifiers.insert(.shift)
            case "Opt", "Alt":
                modifiers.insert(.option)
            case "Ctrl":
                modifiers.insert(.control)
            default:
                keyPart = part
            }
        }

        guard let rawKey = keyPart else { return nil }

        let key: String
        switch rawKey {
        case "Left":
            key = String(Character(UnicodeScalar(NSLeftArrowFunctionKey)!))
        case "Right":
            key = String(Character(UnicodeScalar(NSRightArrowFunctionKey)!))
        case "Up":
            key = String(Character(UnicodeScalar(NSUpArrowFunctionKey)!))
        case "Down":
            key = String(Character(UnicodeScalar(NSDownArrowFunctionKey)!))
        case "Enter":
            key = "\r"
        case "Escape":
            key = "\u{1B}"
        case "Tab":
            key = "\t"
        case "Space":
            key = " "
        case "Delete", "Backspace":
            key = "\u{7F}"  // NSEvent uses ASCII DEL (0x7F), not BS (0x08)
        default:
            // Handle F1-F12 function keys
            if rawKey.hasPrefix("F") || rawKey.hasPrefix("f"),
               let num = Int(rawKey.dropFirst()),
               (1...12).contains(num) {
                key = String(Character(UnicodeScalar(NSF1FunctionKey + num - 1)!))
            } else {
                key = rawKey.lowercased()
            }
        }

        return ParsedShortcut(key: key, modifiers: modifiers)
    }

    // MARK: - Event Matching

    /// Check if an NSEvent matches any active app shortcut
    func isAppKeyEquivalent(_ event: NSEvent) -> Bool {
        guard event.type == .keyDown else { return false }

        let chars = event.charactersIgnoringModifiers?.lowercased() ?? ""
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)

        for entry in activeKeyEquivalents {
            // Compare key character
            guard entry.key == chars else { continue }

            // Compare modifier flags (ignore non-modifier bits)
            let entryFlags = entry.modifiers.intersection(.deviceIndependentFlagsMask)
            if flags == entryFlags {
                return true
            }
        }

        return false
    }

    // MARK: - Menu Application

    /// Walk NSMenu tree, update keyEquivalent on items tagged with action IDs.
    /// Items whose action ID is not in `bindings` or whose shortcut fails to parse
    /// have their shortcut cleared to prevent stale ghost shortcuts.
    func applyToMenu(_ menu: NSMenu) {
        for item in menu.items {
            if let actionID = item.identifier?.rawValue {
                if let shortcut = bindings[actionID],
                   let parsed = Self.parse(shortcut) {
                    item.keyEquivalent = parsed.key
                    item.keyEquivalentModifierMask = parsed.modifiers
                } else {
                    // Binding removed or unparseable — clear the shortcut
                    item.keyEquivalent = ""
                    item.keyEquivalentModifierMask = []
                }
            }

            if let submenu = item.submenu {
                applyToMenu(submenu)
            }
        }
    }

    // MARK: - Update

    /// Update from settings snapshot keybindings
    func update(from keybindings: [KeybindingEntry]) {
        bindings.removeAll()
        activeKeyEquivalents.removeAll()

        for entry in keybindings {
            bindings[entry.action] = entry.shortcut

            // Only menu actions should be deferred to AppKit — project-level
            // bindings (command_palette.*, task.*, etc.) have no menu items
            // and would swallow keystrokes from the terminal if included.
            guard entry.action.hasPrefix("menu.") else { continue }

            if let parsed = Self.parse(entry.shortcut) {
                activeKeyEquivalents.insert(
                    KeyEquivalentEntry(key: parsed.key, modifiers: parsed.modifiers)
                )
            }
        }
    }
}
