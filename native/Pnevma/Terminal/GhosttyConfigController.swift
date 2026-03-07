import AppKit
import Foundation

enum GhosttyValueOrigin: String {
    case managed
    case manual
    case inherited
}

struct GhosttyManagedKeybind: Identifiable, Equatable {
    let id: UUID
    var trigger: String
    var action: String
    var parameter: String
    var isGlobal: Bool
    var isAll: Bool
    var isUnconsumed: Bool
    var isPerformable: Bool

    init(
        id: UUID = UUID(),
        trigger: String = "",
        action: String = "ignore",
        parameter: String = "",
        isGlobal: Bool = false,
        isAll: Bool = false,
        isUnconsumed: Bool = false,
        isPerformable: Bool = false
    ) {
        self.id = id
        self.trigger = trigger
        self.action = action
        self.parameter = parameter
        self.isGlobal = isGlobal
        self.isAll = isAll
        self.isUnconsumed = isUnconsumed
        self.isPerformable = isPerformable
    }

    var rawBinding: String {
        let prefixes = [
            isAll ? "all" : nil,
            isGlobal ? "global" : nil,
            isUnconsumed ? "unconsumed" : nil,
            isPerformable ? "performable" : nil,
        ]
        .compactMap { $0 }
        .joined(separator: ":")
        let trimmedTrigger = trigger.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedParameter = parameter.trimmingCharacters(in: .whitespacesAndNewlines)
        let actionValue = trimmedParameter.isEmpty ? action : "\(action):\(trimmedParameter)"
        if prefixes.isEmpty {
            return "\(trimmedTrigger)=\(actionValue)"
        }
        return "\(prefixes):\(trimmedTrigger)=\(actionValue)"
    }
}

struct GhosttyConfigSnapshot {
    let configPath: URL
    let managedPath: URL
    let includeIntegrated: Bool
    let diagnostics: [String]
    let managedValues: [String: [String]]
    let keybinds: [GhosttyManagedKeybind]
    let effectiveValues: [String: String]
    let manualKeys: Set<String>
    let generatedPreview: String

    func origin(for key: String) -> GhosttyValueOrigin {
        if key == "keybind" {
            return keybinds.isEmpty ? .inherited : .managed
        }
        if let values = managedValues[key], !values.isEmpty {
            return .managed
        }
        if manualKeys.contains(key) {
            return .manual
        }
        return .inherited
    }
}

enum GhosttyConfigControllerError: LocalizedError {
    case runtimeUnavailable
    case configPathUnavailable
    case invalidConfig([String])
    case saveFailed(String)

    var errorDescription: String? {
        switch self {
        case .runtimeUnavailable:
            return "GhosttyKit is not available in this build."
        case .configPathUnavailable:
            return "Ghostty did not return a writable config path."
        case .invalidConfig(let diagnostics):
            return diagnostics.joined(separator: "\n")
        case .saveFailed(let message):
            return message
        }
    }
}

enum GhosttyManagedConfigCodec {
    static let markerStart = "# >>> pnevma managed include >>>"
    static let markerEnd = "# <<< pnevma managed include <<<"
    static let managedHeader = [
        "# Managed by Pnevma.",
        "# Edit Ghostty settings in Pnevma to update this file.",
    ]

    static func includeBlock(for managedPath: URL) -> String {
        [
            markerStart,
            "config-file = \"?\(escapeStringLiteral(managedPath.path))\"",
            markerEnd,
        ]
        .joined(separator: "\n")
    }

    static func ensureIncludeBlock(in text: String, managedPath: URL) -> (text: String, alreadyIntegrated: Bool) {
        let block = includeBlock(for: managedPath)
        let newline = text.contains("\r\n") ? "\r\n" : "\n"
        if let startRange = text.range(of: markerStart), let endRange = text.range(of: markerEnd) {
            let replaceRange = startRange.lowerBound..<endRange.upperBound
            var updated = text
            updated.replaceSubrange(replaceRange, with: block)
            return (updated, true)
        }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            return (block + newline, false)
        }
        return (trimmed + newline + newline + block + newline, false)
    }

    static func removeIncludeBlock(from text: String) -> String {
        guard let startRange = text.range(of: markerStart), let endRange = text.range(of: markerEnd) else {
            return text
        }
        var updated = text
        updated.removeSubrange(startRange.lowerBound..<endRange.upperBound)
        return updated.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func manualKeys(from text: String) -> Set<String> {
        let withoutManagedBlock = removeIncludeBlock(from: text)
        var keys = Set<String>()
        withoutManagedBlock.enumerateLines { line, _ in
            guard let entry = parseEntry(line) else { return }
            keys.insert(entry.key)
        }
        return keys
    }

    static func parseManagedFile(_ text: String) -> (values: [String: [String]], keybinds: [GhosttyManagedKeybind]) {
        var values: [String: [String]] = [:]
        var keybinds: [GhosttyManagedKeybind] = []
        text.enumerateLines { line, _ in
            guard let entry = parseEntry(line) else { return }
            if entry.key == "keybind", let binding = parseKeybind(entry.value) {
                keybinds.append(binding)
                return
            }
            values[entry.key, default: []].append(entry.value)
        }
        return (values, keybinds)
    }

    static func renderManagedFile(values: [String: [String]], keybinds: [GhosttyManagedKeybind]) -> String {
        var lines = managedHeader
        let orderedKeys = values.keys.sorted()
        for key in orderedKeys {
            guard let rawValues = values[key] else { continue }
            let cleaned = rawValues
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            guard !cleaned.isEmpty else { continue }
            lines.append("")
            for rawValue in cleaned {
                lines.append("\(key) = \(rawValue)")
            }
        }
        let cleanedBindings = keybinds.filter { !$0.trigger.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        if !cleanedBindings.isEmpty {
            lines.append("")
            for binding in cleanedBindings {
                lines.append("keybind = \"\(escapeStringLiteral(binding.rawBinding))\"")
            }
        }
        return lines.joined(separator: "\n") + "\n"
    }

    static func escapeStringLiteral(_ raw: String) -> String {
        raw
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }

    private static func parseEntry(_ line: String) -> (key: String, value: String)? {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.hasPrefix("#"), let separator = trimmed.firstIndex(of: "=") else {
            return nil
        }
        let key = trimmed[..<separator].trimmingCharacters(in: .whitespaces)
        let value = trimmed[trimmed.index(after: separator)...].trimmingCharacters(in: .whitespaces)
        guard !key.isEmpty, !value.isEmpty else { return nil }
        return (key, value)
    }

    private static func parseKeybind(_ rawValue: String) -> GhosttyManagedKeybind? {
        let unquoted = stripQuotes(from: rawValue)
        guard let equalsIndex = unquoted.lastIndex(of: "=") else { return nil }
        let prefixAndTrigger = String(unquoted[..<equalsIndex])
        let actionPart = String(unquoted[unquoted.index(after: equalsIndex)...])
        var flags = (isGlobal: false, isAll: false, isUnconsumed: false, isPerformable: false)
        var trigger = prefixAndTrigger
        while let colonIndex = trigger.firstIndex(of: ":") {
            let prefix = String(trigger[..<colonIndex])
            let remainder = String(trigger[trigger.index(after: colonIndex)...])
            switch prefix {
            case "global":
                flags.isGlobal = true
            case "all":
                flags.isAll = true
            case "unconsumed":
                flags.isUnconsumed = true
            case "performable":
                flags.isPerformable = true
            default:
                break
            }
            if ["global", "all", "unconsumed", "performable"].contains(prefix) {
                trigger = remainder
                continue
            }
            break
        }
        let actionParts = actionPart.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
        let action = String(actionParts.first ?? "")
        let parameter = actionParts.count > 1 ? String(actionParts[1]) : ""
        guard !trigger.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, !action.isEmpty else {
            return nil
        }
        return GhosttyManagedKeybind(
            trigger: trigger,
            action: action,
            parameter: parameter,
            isGlobal: flags.isGlobal,
            isAll: flags.isAll,
            isUnconsumed: flags.isUnconsumed,
            isPerformable: flags.isPerformable
        )
    }

    private static func stripQuotes(from value: String) -> String {
        guard value.hasPrefix("\""), value.hasSuffix("\""), value.count >= 2 else {
            return value
        }
        let start = value.index(after: value.startIndex)
        let end = value.index(before: value.endIndex)
        return String(value[start..<end])
            .replacingOccurrences(of: "\\\"", with: "\"")
            .replacingOccurrences(of: "\\\\", with: "\\")
    }
}

@MainActor
final class GhosttyConfigController {
    static let shared = GhosttyConfigController()

    private init() {}

    private var activeConfigOwner: TerminalConfig?

    func runtimeConfigOwner() -> TerminalConfig {
        if let activeConfigOwner {
            return activeConfigOwner
        }
        let owner = TerminalConfig()
        activeConfigOwner = owner
        return owner
    }

    /// Replace the cached config owner (e.g. after reloading config with correct color scheme).
    func updateConfigOwner(_ config: TerminalConfig) {
        activeConfigOwner = config
    }

    struct ThemeSnapshot {
        let background: String?
        let foreground: String?
        let backgroundOpacity: Double
        let splitDividerColor: String?
        let unfocusedSplitFill: String?
        let unfocusedSplitOpacity: Double
    }

    func themeSnapshot() -> ThemeSnapshot {
        let config = runtimeConfigOwner()

        // Read non-theme-dependent values from config directly.
        let bgOpacity = config.scalarRawValue(for: "background-opacity", rawType: "f64")
            .flatMap(Double.init) ?? 1.0
        let divider = config.scalarRawValue(for: "split-divider-color", rawType: "?Color")
        let unfocusedFill = config.scalarRawValue(for: "unfocused-split-fill", rawType: "?Color")
        let unfocusedOpacity = config.scalarRawValue(for: "unfocused-split-opacity", rawType: "f64")
            .flatMap(Double.init) ?? 0.85

        // For background/foreground, the config may resolve conditional themes
        // (e.g. "light:X,dark:Y") to the wrong variant because the standalone
        // config doesn't know the app's color scheme. Read theme colors from
        // the theme file directly as a fallback.
        var bg = config.scalarRawValue(for: "background", rawType: "Color")
        var fg = config.scalarRawValue(for: "foreground", rawType: "Color")

        // If a theme file overrides bg/fg, prefer those colors.
        let themeColors = resolvedThemeColors()
        if let themeBg = themeColors?.background { bg = themeBg }
        if let themeFg = themeColors?.foreground { fg = themeFg }

        return ThemeSnapshot(
            background: bg,
            foreground: fg,
            backgroundOpacity: bgOpacity,
            splitDividerColor: divider,
            unfocusedSplitFill: unfocusedFill,
            unfocusedSplitOpacity: unfocusedOpacity
        )
    }

    /// Resolve the active theme file and extract its background/foreground colors.
    private func resolvedThemeColors() -> (background: String?, foreground: String?)? {
        // Read the raw theme string from the user's ghostty config file.
        // ghostty_config_get can't read the theme key as a simple scalar,
        // so we parse it from the config file directly.
        let configPath = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/ghostty/config")
        guard let configText = try? String(contentsOf: configPath, encoding: .utf8) else {
            return nil
        }

        // Find the theme line
        var themeName: String?
        for line in configText.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("theme") && trimmed.contains("=") {
                let parts = trimmed.split(separator: "=", maxSplits: 1)
                guard parts.count == 2 else { continue }
                let key = parts[0].trimmingCharacters(in: .whitespaces)
                guard key == "theme" else { continue }
                themeName = parts[1].trimmingCharacters(in: .whitespaces)
            }
        }

        guard var name = themeName else { return nil }

        // Handle conditional themes: "light:X,dark:Y"
        if name.contains(",") && name.contains(":") {
            let isDark = NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            let variants = name.split(separator: ",")
            for variant in variants {
                let pair = variant.trimmingCharacters(in: .whitespaces)
                if isDark && pair.hasPrefix("dark:") {
                    name = String(pair.dropFirst("dark:".count))
                    break
                } else if !isDark && pair.hasPrefix("light:") {
                    name = String(pair.dropFirst("light:".count))
                    break
                }
            }
        }

        // Search for the theme file in standard locations
        let searchPaths = [
            FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".config/ghostty/themes/\(name)"),
            URL(fileURLWithPath: "/Applications/Ghostty.app/Contents/Resources/ghostty/themes/\(name)"),
        ]

        var themeText: String?
        for path in searchPaths {
            if let text = try? String(contentsOf: path, encoding: .utf8) {
                themeText = text
                break
            }
        }

        guard let text = themeText else { return nil }

        var background: String?
        var foreground: String?
        for line in text.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("background") && trimmed.contains("=") {
                let parts = trimmed.split(separator: "=", maxSplits: 1)
                if parts.count == 2 {
                    let key = parts[0].trimmingCharacters(in: .whitespaces)
                    if key == "background" {
                        background = parts[1].trimmingCharacters(in: .whitespaces)
                    }
                }
            }
            if trimmed.hasPrefix("foreground") && trimmed.contains("=") {
                let parts = trimmed.split(separator: "=", maxSplits: 1)
                if parts.count == 2 {
                    let key = parts[0].trimmingCharacters(in: .whitespaces)
                    if key == "foreground" {
                        foreground = parts[1].trimmingCharacters(in: .whitespaces)
                    }
                }
            }
        }

        // If we found nothing from the theme, the config values are fine.
        guard background != nil || foreground != nil else { return nil }
        return (background, foreground)
    }

    func loadSnapshot() throws -> GhosttyConfigSnapshot {
        let paths = try resolvedPaths()
        let configText = (try? String(contentsOf: paths.configPath, encoding: .utf8)) ?? ""
        let managedText = (try? String(contentsOf: paths.managedPath, encoding: .utf8)) ?? ""
        let parsedConfig = GhosttyManagedConfigCodec.parseManagedFile(configText)
        let configOwner = runtimeConfigOwner()
        let effectiveValues = buildEffectiveValues(from: configOwner, configText: configText, managedText: managedText)
        return GhosttyConfigSnapshot(
            configPath: paths.configPath,
            managedPath: paths.managedPath,
            includeIntegrated: true,
            diagnostics: configOwner.diagnostics,
            managedValues: parsedConfig.values,
            keybinds: parsedConfig.keybinds,
            effectiveValues: effectiveValues,
            manualKeys: [],
            generatedPreview: configText
        )
    }

    func saveAndApply(values: [String: [String]], keybinds: [GhosttyManagedKeybind]) throws -> GhosttyConfigSnapshot {
        let baseline = runtimeConfigOwner()
        let baselineDiagnostics = Set(baseline.diagnostics)
        let paths = try resolvedPaths()

        let originalText = (try? String(contentsOf: paths.configPath, encoding: .utf8)) ?? ""
        let updatedText = updateConfigText(originalText, with: values, keybinds: keybinds)

        do {
            try writeAtomically(updatedText, to: paths.configPath)

            let reloaded = TerminalConfig()
            let introducedDiagnostics = reloaded.diagnostics.filter { !baselineDiagnostics.contains($0) }
            if !introducedDiagnostics.isEmpty {
                try writeAtomically(originalText, to: paths.configPath)
                audit(
                    action: "ghostty_settings_apply_failed",
                    changedKeys: [],
                    diagnostics: introducedDiagnostics,
                    applied: false,
                    managedPath: paths.configPath.path
                )
                throw GhosttyConfigControllerError.invalidConfig(introducedDiagnostics)
            }

            activeConfigOwner = reloaded
            TerminalSurface.applyGhosttyConfig(reloaded)
            TerminalSurface.reapplyColorScheme()

            audit(
                action: "ghostty_settings_saved",
                changedKeys: [],
                diagnostics: reloaded.diagnostics,
                applied: true,
                managedPath: paths.configPath.path
            )

            return try loadSnapshot()
        } catch let error as GhosttyConfigControllerError {
            throw error
        } catch {
            try? writeAtomically(originalText, to: paths.configPath)
            audit(
                action: "ghostty_settings_apply_failed",
                changedKeys: [],
                diagnostics: [error.localizedDescription],
                applied: false,
                managedPath: paths.configPath.path
            )
            throw GhosttyConfigControllerError.saveFailed(error.localizedDescription)
        }
    }

    /// Update config file text in-place: replace existing keys, append new ones,
    /// and rebuild keybind lines. Preserves comments and structure.
    private func updateConfigText(_ text: String, with values: [String: [String]], keybinds: [GhosttyManagedKeybind]) -> String {
        var remainingValues = values
        var lines: [String] = []
        let inputLines = text.components(separatedBy: "\n")

        // Track which keys we've already written (handles duplicate keys)
        var writtenKeys = Set<String>()
        var insideManagedBlock = false

        for line in inputLines {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)

            // Skip the old managed include block if present
            if trimmed == GhosttyManagedConfigCodec.markerStart {
                insideManagedBlock = true
                continue
            }
            if insideManagedBlock {
                if trimmed == GhosttyManagedConfigCodec.markerEnd {
                    insideManagedBlock = false
                }
                continue
            }

            // Skip existing keybind lines — we'll rewrite all keybinds at the end
            if !trimmed.isEmpty, !trimmed.hasPrefix("#"), trimmed.contains("=") {
                let eqIdx = trimmed.firstIndex(of: "=")!
                let lineKey = trimmed[..<eqIdx].trimmingCharacters(in: .whitespaces)
                if lineKey == "keybind" {
                    continue
                }
            }

            // Check if this is a key=value line we have a new value for
            guard !trimmed.isEmpty, !trimmed.hasPrefix("#"),
                  let eqIndex = trimmed.firstIndex(of: "=") else {
                lines.append(line)
                continue
            }

            let key = trimmed[..<eqIndex].trimmingCharacters(in: .whitespaces)

            if let newValues = remainingValues[key] {
                if !writtenKeys.contains(key) {
                    for val in newValues {
                        let cleaned = val.trimmingCharacters(in: .whitespacesAndNewlines)
                        if !cleaned.isEmpty {
                            lines.append("\(key) = \(cleaned)")
                        }
                    }
                    writtenKeys.insert(key)
                    remainingValues.removeValue(forKey: key)
                }
                // Skip duplicate lines of the same key from the original file
            } else if GhosttySchema.configTypes[key] != nil {
                // Known schema key was removed from edited values — drop it
                continue
            } else {
                // Unknown key (not in schema) — preserve it
                lines.append(line)
            }
        }

        // Append any new keys that weren't in the original file
        for (key, vals) in remainingValues.sorted(by: { $0.key < $1.key }) {
            let cleaned = vals
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            if !cleaned.isEmpty {
                lines.append("")
                for val in cleaned {
                    lines.append("\(key) = \(val)")
                }
            }
        }

        // Append keybinds
        let cleanedBindings = keybinds.filter { !$0.trigger.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        if !cleanedBindings.isEmpty {
            lines.append("")
            for binding in cleanedBindings {
                lines.append("keybind = \(binding.rawBinding)")
            }
        }

        // Clean up excessive blank lines
        var result: [String] = []
        var lastWasBlank = false
        for line in lines {
            let isBlank = line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            if isBlank && lastWasBlank { continue }
            result.append(line)
            lastWasBlank = isBlank
        }

        // Ensure trailing newline
        let joined = result.joined(separator: "\n")
        return joined.hasSuffix("\n") ? joined : joined + "\n"
    }

    private func buildEffectiveValues(from config: TerminalConfig, configText: String, managedText: String) -> [String: String] {
        var values: [String: String] = [:]

        // First, read values the C API can handle (bool, numbers, Color).
        for descriptor in GhosttySchema.descriptors where descriptor.valueKind != .keybinds && descriptor.valueKind != .multiLine {
            if let rawValue = config.scalarRawValue(for: descriptor.key, rawType: descriptor.rawType) {
                values[descriptor.key] = rawValue
            }
        }

        // For keys that scalarRawValue can't read (complex types like ?Theme,
        // ?TerminalColor, RepeatableString, enums, etc.), fall back to parsing
        // the config files directly. The managed file takes precedence.
        let fileParsed = parseConfigText(managedText, thenFallback: configText)
        for descriptor in GhosttySchema.descriptors where descriptor.valueKind != .keybinds {
            if values[descriptor.key] == nil, let fileValue = fileParsed[descriptor.key] {
                values[descriptor.key] = fileValue
            }
        }

        return values
    }

    /// Parse key=value pairs from config text. If a key appears in both texts,
    /// the primary text wins (last occurrence of each key wins within a file).
    private func parseConfigText(_ primary: String, thenFallback fallback: String) -> [String: String] {
        var values: [String: String] = [:]
        for line in fallback.components(separatedBy: .newlines) {
            if let entry = parseSimpleEntry(line) {
                values[entry.key] = entry.value
            }
        }
        for line in primary.components(separatedBy: .newlines) {
            if let entry = parseSimpleEntry(line) {
                values[entry.key] = entry.value
            }
        }
        return values
    }

    private func parseSimpleEntry(_ line: String) -> (key: String, value: String)? {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.hasPrefix("#"),
              let eqIndex = trimmed.firstIndex(of: "=") else { return nil }
        let key = trimmed[..<eqIndex].trimmingCharacters(in: .whitespaces)
        let value = trimmed[trimmed.index(after: eqIndex)...].trimmingCharacters(in: .whitespaces)
        guard !key.isEmpty, !value.isEmpty else { return nil }
        return (key, value)
    }

    private func resolvedPaths() throws -> (configPath: URL, managedPath: URL) {
        guard let configPath = resolveConfigPath() else {
            throw GhosttyConfigControllerError.configPathUnavailable
        }
        let managedPath = configPath
            .deletingLastPathComponent()
            .appendingPathComponent("pnevma-ui.generated.ghostty")
        return (configPath, managedPath)
    }

    private func resolveConfigPath() -> URL? {
        #if canImport(GhosttyKit)
        let path = ghostty_config_open_path()
        defer { ghostty_string_free(path) }
        if let ptr = path.ptr, path.len > 0 {
            let buffer = UnsafeBufferPointer(start: ptr, count: Int(path.len))
            let bytes = buffer.map { UInt8(bitPattern: $0) }
            return URL(fileURLWithPath: String(decoding: bytes, as: UTF8.self))
        }
        #endif

        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/ghostty", isDirectory: true)
            .appendingPathComponent("config.ghostty")
    }

    private func writeAtomically(_ content: String, to url: URL) throws {
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: nil
        )
        let temporaryURL = directory.appendingPathComponent(".\(url.lastPathComponent).tmp")
        try content.write(to: temporaryURL, atomically: true, encoding: .utf8)
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
        try FileManager.default.moveItem(at: temporaryURL, to: url)
    }

    private func restoreMainFile(_ content: String, to url: URL) throws {
        try writeAtomically(content, to: url)
    }

    private func restoreManagedFile(_ content: String, existed: Bool, to url: URL) throws {
        if existed {
            try writeAtomically(content, to: url)
            return
        }
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
    }

    private func changedKeys(previous: String, next: String) -> [String] {
        let previousParsed = GhosttyManagedConfigCodec.parseManagedFile(previous)
        let nextParsed = GhosttyManagedConfigCodec.parseManagedFile(next)
        let previousKeys = Set(previousParsed.values.keys).union(previousParsed.keybinds.isEmpty ? Set<String>() : Set(["keybind"]))
        let nextKeys = Set(nextParsed.values.keys).union(nextParsed.keybinds.isEmpty ? Set<String>() : Set(["keybind"]))
        let allKeys = previousKeys.union(nextKeys)
        return allKeys
            .filter { key in
                if key == "keybind" {
                    return previousParsed.keybinds.map(\.rawBinding) != nextParsed.keybinds.map(\.rawBinding)
                }
                return previousParsed.values[key] != nextParsed.values[key]
            }
            .sorted()
    }

    private func audit(
        action: String,
        changedKeys: [String],
        diagnostics: [String],
        applied: Bool,
        managedPath: String
    ) {
        guard let bus = CommandBus.shared else { return }
        Task {
            struct Payload: Encodable {
                let action: String
                let changedKeys: [String]
                let diagnostics: [String]
                let applied: Bool
                let managedPath: String
            }
            let _: OkResponse? = try? await bus.call(
                method: "settings.ghostty.audit",
                params: Payload(
                    action: action,
                    changedKeys: changedKeys,
                    diagnostics: diagnostics,
                    applied: applied,
                    managedPath: managedPath
                )
            )
        }
    }
}
