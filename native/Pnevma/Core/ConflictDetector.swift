import Foundation

/// Represents a shortcut collision across keybinding layers.
struct KeybindingConflict: Identifiable {
    var id: String { shortcut }
    let shortcut: String
    let claimants: [(layer: String, action: String)]
}

/// Detects keybinding conflicts across Pnevma app shortcuts and Ghostty terminal keybindings.
enum ConflictDetector {
    /// Detect all cross-layer shortcut collisions.
    ///
    /// Both datasets are available in Swift — Pnevma bindings from `AppSettingsSnapshot.keybindings`
    /// and Ghostty bindings from `GhosttyConfigController.keybinds`.
    static func detect(
        pnevmaBindings: [KeybindingEntry],
        ghosttyBindings: [GhosttyManagedKeybind]
    ) -> [KeybindingConflict] {
        // Normalize all shortcuts to a canonical form for comparison
        var shortcutMap: [String: [(layer: String, action: String)]] = [:]

        for binding in pnevmaBindings {
            let normalized = normalizeShortcut(binding.shortcut)
            shortcutMap[normalized, default: []].append(
                (layer: "pnevma", action: binding.action)
            )
        }

        for binding in ghosttyBindings where !binding.trigger.isEmpty {
            let normalized = normalizeGhosttyTrigger(binding.trigger)
            guard !normalized.isEmpty else { continue }
            let actionLabel = binding.parameter.isEmpty
                ? binding.action
                : "\(binding.action):\(binding.parameter)"
            shortcutMap[normalized, default: []].append(
                (layer: "ghostty", action: actionLabel)
            )
        }

        return shortcutMap
            .filter { $0.value.count > 1 }
            .filter { entry in
                // Only report cross-layer conflicts (not within same layer)
                let layers = Set(entry.value.map(\.layer))
                return layers.count > 1
            }
            .map { KeybindingConflict(shortcut: $0.key, claimants: $0.value) }
            .sorted { $0.shortcut < $1.shortcut }
    }

    // MARK: - Normalization

    /// Normalize a Pnevma-format shortcut string to a canonical form.
    /// e.g. "Cmd+Shift+D" → "cmd+shift+d"
    static func normalizeShortcut(_ shortcut: String) -> String {
        let parts = shortcut.split(separator: "+").map {
            $0.trimmingCharacters(in: .whitespaces).lowercased()
        }

        // Separate modifiers from key
        var modifiers: [String] = []
        var key = ""
        for part in parts {
            switch part {
            case "cmd", "mod", "super":
                modifiers.append("cmd")
            case "shift":
                modifiers.append("shift")
            case "opt", "alt":
                modifiers.append("opt")
            case "ctrl", "control":
                modifiers.append("ctrl")
            default:
                // Canonicalize key names to match Ghostty normalizer
                key = canonicalKeyName(part)
            }
        }

        modifiers.sort()
        if !key.isEmpty {
            modifiers.append(key)
        }
        return modifiers.joined(separator: "+")
    }

    /// Normalize a Ghostty trigger format to canonical form.
    /// Ghostty uses formats like "super+shift+d", "ctrl+a", etc.
    static func normalizeGhosttyTrigger(_ trigger: String) -> String {
        let parts = trigger.split(separator: "+").map {
            $0.trimmingCharacters(in: .whitespaces).lowercased()
        }

        var modifiers: [String] = []
        var key = ""
        for part in parts {
            switch part {
            case "super":
                modifiers.append("cmd")
            case "shift":
                modifiers.append("shift")
            case "alt":
                modifiers.append("opt")
            case "ctrl", "control":
                modifiers.append("ctrl")
            default:
                key = canonicalKeyName(part)
            }
        }

        modifiers.sort()
        if !key.isEmpty {
            modifiers.append(key)
        }
        return modifiers.joined(separator: "+")
    }

    /// Shared key name canonicalization used by both normalizers.
    private static func canonicalKeyName(_ name: String) -> String {
        switch name {
        case "return": return "enter"
        case "backspace": return "delete"
        default: return name
        }
    }
}
