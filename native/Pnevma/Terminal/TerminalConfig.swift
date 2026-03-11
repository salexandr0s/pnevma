import Foundation
#if canImport(GhosttyKit)
import GhosttyKit
#endif

enum GhosttyRuntime {
    private(set) static var isInitialized = false

    static func markInitialized() {
        isInitialized = true
    }

    static func reset() {
        isInitialized = false
    }
}

/// Reads and applies Ghostty configuration for terminal instances.
/// Merges user config with per-pane overrides.
class TerminalConfig {

    #if canImport(GhosttyKit)
    private(set) var config: ghostty_config_t?
    private(set) var diagnostics: [String] = []

    init() {
        guard GhosttyRuntime.isInitialized else {
            print("[TerminalConfig] Ghostty runtime not initialized — using placeholder config")
            return
        }
        config = ghostty_config_new()
        guard config != nil else {
            print("[TerminalConfig] ERROR: ghostty_config_new() returned nil")
            return
        }
        if AppSmokeMode.current == nil {
            ghostty_config_load_default_files(config)
            ghostty_config_load_recursive_files(config)
        }
        ghostty_config_finalize(config)
        diagnostics = Self.readDiagnostics(config)
    }

    deinit {
        if let config = config {
            ghostty_config_free(config)
        }
    }

    /// Only read types whose C representation we know. Calling ghostty_config_get
    /// with the wrong output type causes a hard crash, so we whitelist rather than blacklist.
    func scalarRawValue(for key: String, rawType: String) -> String? {
        guard let config else { return nil }

        switch rawType {
        case "bool", "?bool":
            var value = false
            guard ghostty_config_get(config, &value, key, UInt(key.count)) else { return nil }
            return value ? "true" : "false"
        case "u8":
            var value: UInt8 = 0
            guard ghostty_config_get(config, &value, key, UInt(key.count)) else { return nil }
            return String(value)
        case "u16":
            var value: UInt16 = 0
            guard ghostty_config_get(config, &value, key, UInt(key.count)) else { return nil }
            return String(value)
        case "u32":
            var value: UInt32 = 0
            guard ghostty_config_get(config, &value, key, UInt(key.count)) else { return nil }
            return String(value)
        case "u64":
            var value: UInt64 = 0
            guard ghostty_config_get(config, &value, key, UInt(key.count)) else { return nil }
            return String(value)
        case "usize":
            var value: UInt = 0
            guard ghostty_config_get(config, &value, key, UInt(key.count)) else { return nil }
            return String(value)
        case "i16":
            var value: Int16 = 0
            guard ghostty_config_get(config, &value, key, UInt(key.count)) else { return nil }
            return String(value)
        case "i32":
            var value: Int32 = 0
            guard ghostty_config_get(config, &value, key, UInt(key.count)) else { return nil }
            return String(value)
        case "i64":
            var value: Int64 = 0
            guard ghostty_config_get(config, &value, key, UInt(key.count)) else { return nil }
            return String(value)
        case "isize":
            var value: Int = 0
            guard ghostty_config_get(config, &value, key, UInt(key.count)) else { return nil }
            return String(value)
        case "f32":
            var value: Float = 0
            guard ghostty_config_get(config, &value, key, UInt(key.count)) else { return nil }
            return String(value)
        case "f64":
            var value: Double = 0
            guard ghostty_config_get(config, &value, key, UInt(key.count)) else { return nil }
            return String(value)
        case "Color", "?Color":
            var value = ghostty_config_color_s()
            guard ghostty_config_get(config, &value, key, UInt(key.count)) else { return nil }
            return String(format: "#%02X%02X%02X", value.r, value.g, value.b)
        default:
            // Unknown C representation — skip to avoid a hard crash in ghostty_config_get.
            return nil
        }
    }

    private static func readDiagnostics(_ config: ghostty_config_t?) -> [String] {
        guard let config else { return [] }
        let count = ghostty_config_diagnostics_count(config)
        guard count > 0 else { return [] }
        return (0..<count).map { index in
            String(cString: ghostty_config_get_diagnostic(config, index).message)
        }
    }

    #else

    init() {
        print("[TerminalConfig] GhosttyKit not available — running in placeholder mode")
    }

    var diagnostics: [String] { [] }

    func scalarRawValue(for _: String, rawType _: String) -> String? { nil }

    #endif
}
