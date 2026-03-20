import Cocoa

/// Detects installed editors and builds an "Open In" menu.
@MainActor
final class OpenInMenuController {
    struct EditorInfo {
        let name: String
        let bundleID: String
        let fallbackIcon: String
    }

    static let knownEditors: [EditorInfo] = [
        EditorInfo(name: "Finder", bundleID: "com.apple.finder", fallbackIcon: "folder"),
        EditorInfo(name: "Terminal", bundleID: "com.apple.Terminal", fallbackIcon: "terminal"),
        EditorInfo(name: "Ghostty", bundleID: "com.mitchellh.ghostty", fallbackIcon: "terminal.fill"),
        EditorInfo(name: "Xcode", bundleID: "com.apple.dt.Xcode", fallbackIcon: "hammer"),
        EditorInfo(name: "VS Code", bundleID: "com.microsoft.VSCode", fallbackIcon: "chevron.left.forwardslash.chevron.right"),
        EditorInfo(name: "Cursor", bundleID: "com.todesktop.230313mzl4w4u92", fallbackIcon: "cursorarrow.rays"),
        EditorInfo(name: "Zed", bundleID: "dev.zed.Zed", fallbackIcon: "text.cursor"),
    ]

    private static let lastEditorKey = "lastUsedEditor"

    static var lastUsedEditorBundleID: String? {
        get { UserDefaults.standard.string(forKey: lastEditorKey) }
        set { UserDefaults.standard.set(newValue, forKey: lastEditorKey) }
    }

    static var installedEditors: [EditorInfo] {
        knownEditors.filter { editor in
            NSWorkspace.shared.urlForApplication(withBundleIdentifier: editor.bundleID) != nil
        }
    }

    static func prioritizedEditors(
        _ editors: [EditorInfo],
        lastUsedBundleID: String?
    ) -> [EditorInfo] {
        guard let lastUsedBundleID,
              let index = editors.firstIndex(where: { $0.bundleID == lastUsedBundleID }) else {
            return editors
        }

        var reordered = editors
        let editor = reordered.remove(at: index)
        reordered.insert(editor, at: 0)
        return reordered
    }

    static func openPath(_ path: String, with editor: EditorInfo) {
        lastUsedEditorBundleID = editor.bundleID
        guard let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: editor.bundleID) else { return }
        let config = NSWorkspace.OpenConfiguration()
        config.activates = true
        NSWorkspace.shared.open(
            [URL(fileURLWithPath: path)],
            withApplicationAt: appURL,
            configuration: config
        )
    }

    static func buildMenu(for path: String, target: AnyObject?, primaryAction: Selector?) -> NSMenu {
        let menu = NSMenu()
        let sorted = prioritizedEditors(installedEditors, lastUsedBundleID: lastUsedEditorBundleID)

        for editor in sorted {
            let item = NSMenuItem(title: editor.name, action: #selector(EditorMenuTarget.openWithEditor(_:)), keyEquivalent: "")
            item.representedObject = (path, editor)
            item.target = EditorMenuTarget.shared
            item.image = icon(for: editor)
            menu.addItem(item)
        }

        return menu
    }

    private static func icon(for editor: EditorInfo) -> NSImage? {
        if let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: editor.bundleID) {
            let icon = NSWorkspace.shared.icon(forFile: appURL.path)
            icon.size = NSSize(width: 18, height: 18)
            return icon
        }

        return NSImage(systemSymbolName: editor.fallbackIcon, accessibilityDescription: editor.name)?
            .withSymbolConfiguration(.init(pointSize: 12, weight: .regular))
    }
}

/// Helper target for editor menu items.
@MainActor @objc final class EditorMenuTarget: NSObject {
    static let shared = EditorMenuTarget()

    @objc func openWithEditor(_ sender: NSMenuItem) {
        guard let (path, editor) = sender.representedObject as? (String, OpenInMenuController.EditorInfo) else { return }
        OpenInMenuController.openPath(path, with: editor)
    }
}
