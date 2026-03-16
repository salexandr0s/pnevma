import Cocoa

/// Detects installed editors and builds an "Open In" menu.
@MainActor
final class OpenInMenuController {
    struct EditorInfo {
        let name: String
        let bundleID: String
        let icon: String  // SF Symbol name
    }

    static let knownEditors: [EditorInfo] = [
        EditorInfo(name: "VS Code", bundleID: "com.microsoft.VSCode", icon: "chevron.left.forwardslash.chevron.right"),
        EditorInfo(name: "Cursor", bundleID: "com.todesktop.230313mzl4w4u92", icon: "cursorarrow.rays"),
        EditorInfo(name: "Zed", bundleID: "dev.zed.Zed", icon: "text.cursor"),
        EditorInfo(name: "Xcode", bundleID: "com.apple.dt.Xcode", icon: "hammer"),
        EditorInfo(name: "Finder", bundleID: "com.apple.finder", icon: "folder"),
        EditorInfo(name: "Terminal", bundleID: "com.apple.Terminal", icon: "terminal"),
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
        let editors = installedEditors
        let lastUsed = lastUsedEditorBundleID

        // Put last-used editor first if it exists
        let sorted: [EditorInfo]
        if let lastUsed, let idx = editors.firstIndex(where: { $0.bundleID == lastUsed }) {
            var reordered = editors
            let editor = reordered.remove(at: idx)
            reordered.insert(editor, at: 0)
            sorted = reordered
        } else {
            sorted = editors
        }

        for editor in sorted {
            let item = NSMenuItem(title: editor.name, action: #selector(EditorMenuTarget.openWithEditor(_:)), keyEquivalent: "")
            item.representedObject = (path, editor)
            if let img = NSImage(systemSymbolName: editor.icon, accessibilityDescription: editor.name) {
                item.image = img.withSymbolConfiguration(.init(pointSize: 12, weight: .regular))
            }
            menu.addItem(item)
        }

        return menu
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
