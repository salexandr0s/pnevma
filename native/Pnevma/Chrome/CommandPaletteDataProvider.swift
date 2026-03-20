import Foundation
import Observation

/// Category for palette items, used for prefix filtering and display.
enum PaletteCategory: String, CaseIterable {
    case command = "Commands"
    case workspace = "Workspaces"
    case task = "Tasks"
    case session = "Sessions"
    case file = "Files"
    case template = "Templates"

    var icon: String {
        switch self {
        case .command: return "terminal"
        case .workspace: return "square.grid.2x2"
        case .task: return "checklist"
        case .session: return "play.circle"
        case .file: return "doc"
        case .template: return "rectangle.3.group"
        }
    }

    /// Prefix character that filters to this category.
    var filterPrefix: Character? {
        switch self {
        case .command: return ">"
        case .workspace: return "@"
        case .task: return "#"
        case .file: return ":"
        case .session: return nil
        case .template: return nil
        }
    }

    /// Key used in `CommandItem.category` for palette prefix filtering.
    var commandItemKey: String {
        switch self {
        case .command: return "command"
        case .workspace: return "workspace"
        case .task: return "task"
        case .session: return "session"
        case .file: return "file"
        case .template: return "template"
        }
    }
}

/// Enhanced command item with category metadata.
struct PaletteItem: Identifiable {
    let id: String
    let title: String
    let subtitle: String?
    let icon: String?
    let category: PaletteCategory
    let action: @MainActor () -> Void

    init(
        id: String = UUID().uuidString,
        title: String,
        subtitle: String? = nil,
        icon: String? = nil,
        category: PaletteCategory = .command,
        action: @escaping @MainActor () -> Void
    ) {
        self.id = id
        self.title = title
        self.subtitle = subtitle
        self.icon = icon
        self.category = category
        self.action = action
    }
}

/// Palette display mode.
enum PaletteMode {
    case commands    // Default: all categories
    case files       // Cmd+P: file quick-open
    case shortcuts   // Cmd+?: shortcut sheet
}

/// Collects command items from all sources for the command palette.
@Observable
@MainActor
final class CommandPaletteDataProvider {
    private(set) var items: [PaletteItem] = []
    private(set) var cachedFiles: [String] = []
    private var filesCacheTime: Date?

    /// Register static commands.
    var staticCommands: [PaletteItem] = []

    /// Workspace items (dynamic, refreshed on each open).
    var workspaceItems: [PaletteItem] = []

    /// Task items (dynamic).
    var taskItems: [PaletteItem] = []

    /// Session items (dynamic).
    var sessionItems: [PaletteItem] = []

    /// Template items.
    var templateItems: [PaletteItem] = []

    /// Rebuild the unified item list from all sources.
    func rebuild() {
        items = staticCommands + workspaceItems + taskItems + sessionItems + fileItems + templateItems
    }

    /// File items from cached file list.
    private var fileItems: [PaletteItem] {
        cachedFiles.map { path in
            PaletteItem(
                id: "file:\(path)",
                title: (path as NSString).lastPathComponent,
                subtitle: path,
                icon: "doc",
                category: .file,
                action: {}  // Wired by caller
            )
        }
    }

    /// Cache file list from project.list_files RPC.
    func cacheFiles(_ files: [String]) {
        cachedFiles = files
        filesCacheTime = Date()
        rebuild()
    }

    /// Whether the file cache is stale (older than 30 seconds).
    var isFileCacheStale: Bool {
        guard let cacheTime = filesCacheTime else { return true }
        return Date().timeIntervalSince(cacheTime) > 30
    }

    /// Filter items by query string, respecting prefix characters.
    func filtered(by query: String) -> (category: PaletteCategory?, items: [PaletteItem]) {
        guard !query.isEmpty else {
            return (nil, items)
        }

        let firstChar = query.first!
        // Check for category prefix
        for category in PaletteCategory.allCases {
            if let prefix = category.filterPrefix, firstChar == prefix {
                let searchText = String(query.dropFirst()).trimmingCharacters(in: .whitespaces).lowercased()
                let categoryItems = items.filter { $0.category == category }
                if searchText.isEmpty {
                    return (category, categoryItems)
                }
                return (category, categoryItems.filter {
                    $0.title.lowercased().contains(searchText)
                    || ($0.subtitle?.lowercased().contains(searchText) ?? false)
                })
            }
        }

        // No prefix — search all items
        let searchText = query.lowercased()
        return (nil, items.filter {
            $0.title.lowercased().contains(searchText)
            || ($0.subtitle?.lowercased().contains(searchText) ?? false)
        })
    }
}
