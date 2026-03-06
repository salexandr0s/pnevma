import Foundation

/// Reads and applies Ghostty configuration for terminal instances.
/// Merges user config with per-pane overrides.
class TerminalConfig {

    #if canImport(GhosttyKit)
    private(set) var config: ghostty_config_t?

    init() {
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
    }

    deinit {
        if let config = config {
            ghostty_config_free(config)
        }
    }

    #else

    init() {
        print("[TerminalConfig] GhosttyKit not available — running in placeholder mode")
    }

    #endif
}
