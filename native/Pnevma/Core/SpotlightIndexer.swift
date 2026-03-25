import CoreSpotlight
import UniformTypeIdentifiers

/// Indexes Pnevma workspaces in Spotlight so they appear in Cmd+Space search.
@MainActor
final class SpotlightIndexer {
    static let shared = SpotlightIndexer()
    private let index = CSSearchableIndex.default()

    func indexWorkspace(_ workspace: Workspace) {
        let attrs = CSSearchableItemAttributeSet(contentType: .folder)
        attrs.title = workspace.name
        attrs.contentDescription = workspace.projectPath ?? "Terminal workspace"
        attrs.path = workspace.projectPath

        let item = CSSearchableItem(
            uniqueIdentifier: "workspace.\(workspace.id.uuidString)",
            domainIdentifier: "com.pnevma.workspaces",
            attributeSet: attrs
        )
        item.expirationDate = .distantFuture
        index.indexSearchableItems([item])
    }

    func removeWorkspace(_ id: UUID) {
        index.deleteSearchableItems(withIdentifiers: ["workspace.\(id.uuidString)"])
    }

    func reindexAll(_ workspaces: [Workspace]) {
        index.deleteSearchableItems(withDomainIdentifiers: ["com.pnevma.workspaces"]) { _ in }
        let items = workspaces.map { ws -> CSSearchableItem in
            let attrs = CSSearchableItemAttributeSet(contentType: .folder)
            attrs.title = ws.name
            attrs.contentDescription = ws.projectPath ?? "Terminal workspace"
            attrs.path = ws.projectPath
            let item = CSSearchableItem(
                uniqueIdentifier: "workspace.\(ws.id.uuidString)",
                domainIdentifier: "com.pnevma.workspaces",
                attributeSet: attrs
            )
            item.expirationDate = .distantFuture
            return item
        }
        if !items.isEmpty {
            index.indexSearchableItems(items)
        }
    }
}
