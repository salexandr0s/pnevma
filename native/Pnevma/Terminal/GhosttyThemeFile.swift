import AppKit

struct GhosttyThemeFile: Identifiable {
    let id: String
    let name: String
    let source: Source
    let background: String
    let foreground: String
    let cursorColor: String?
    let selectionBackground: String?
    let selectionForeground: String?
    let palette: [Int: String]

    enum Source { case builtIn, user }

    var isDark: Bool {
        guard let color = NSColor(hexString: background) else { return true }
        guard let rgb = color.usingColorSpace(.sRGB) else { return true }
        let luminance = 0.299 * rgb.redComponent + 0.587 * rgb.greenComponent + 0.114 * rgb.blueComponent
        return luminance < 0.5
    }

    static func loadAll() -> [GhosttyThemeFile] {
        var themes: [GhosttyThemeFile] = []

        let builtInDir = URL(fileURLWithPath: "/Applications/Ghostty.app/Contents/Resources/ghostty/themes")
        themes.append(contentsOf: loadThemes(from: builtInDir, source: .builtIn))

        let userDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/ghostty/themes")
        themes.append(contentsOf: loadThemes(from: userDir, source: .user))

        return themes.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private static func loadThemes(from directory: URL, source: Source) -> [GhosttyThemeFile] {
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else { return [] }

        return entries.compactMap { url in
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
            return parse(text: text, name: url.lastPathComponent, source: source)
        }
    }

    private static func parse(text: String, name: String, source: Source) -> GhosttyThemeFile? {
        var background: String?
        var foreground: String?
        var cursorColor: String?
        var selectionBackground: String?
        var selectionForeground: String?
        var palette: [Int: String] = [:]

        for line in text.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty, !trimmed.hasPrefix("#"),
                  let eqIndex = trimmed.firstIndex(of: "=") else { continue }

            let key = trimmed[..<eqIndex].trimmingCharacters(in: .whitespaces)
            let value = trimmed[trimmed.index(after: eqIndex)...].trimmingCharacters(in: .whitespaces)
            guard !key.isEmpty, !value.isEmpty else { continue }

            switch key {
            case "background":
                background = value
            case "foreground":
                foreground = value
            case "cursor-color":
                cursorColor = value
            case "selection-background":
                selectionBackground = value
            case "selection-foreground":
                selectionForeground = value
            case "palette":
                // palette = N=#hex
                let parts = value.split(separator: "=", maxSplits: 1)
                if parts.count == 2, let index = Int(parts[0]) {
                    palette[index] = String(parts[1])
                }
            default:
                break
            }
        }

        guard let bg = background, let fg = foreground else { return nil }

        return GhosttyThemeFile(
            id: name,
            name: name,
            source: source,
            background: bg,
            foreground: fg,
            cursorColor: cursorColor,
            selectionBackground: selectionBackground,
            selectionForeground: selectionForeground,
            palette: palette
        )
    }
}
