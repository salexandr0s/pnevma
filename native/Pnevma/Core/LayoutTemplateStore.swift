import Cocoa

/// Persisted layout template — stored as JSON in ~/.config/pnevma/layout-templates/.
/// Project-agnostic: captures only the split tree structure and pane types,
/// not session IDs, file paths, or working directories.
struct LayoutTemplate: Codable, Identifiable {
    let id: UUID
    var name: String
    let createdAt: Date
    let root: SplitNode
    let panes: [TemplatePaneDescriptor]

    struct TemplatePaneDescriptor: Codable {
        let paneID: PaneID
        let type: String
    }
}

/// Reads and writes layout templates from ~/.config/pnevma/layout-templates/.
@MainActor
enum LayoutTemplateStore {
    private static var templatesDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/pnevma/layout-templates", isDirectory: true)
    }

    static func ensureDirectory() {
        try? FileManager.default.createDirectory(
            at: templatesDirectory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
    }

    static func list() -> [LayoutTemplate] {
        ensureDirectory()
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: templatesDirectory,
            includingPropertiesForKeys: nil,
            options: .skipsHiddenFiles
        ) else { return [] }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return files
            .filter { $0.pathExtension == "json" }
            .compactMap { url in
                guard let data = try? Data(contentsOf: url) else { return nil }
                return try? decoder.decode(LayoutTemplate.self, from: data)
            }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    // Files are named by UUID to avoid collisions from name sanitization.
    static func save(_ template: LayoutTemplate) throws {
        ensureDirectory()
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(template)
        let url = templatesDirectory.appendingPathComponent("\(template.id.uuidString).json")
        try data.write(to: url, options: .atomic)
    }

    static func delete(_ template: LayoutTemplate) {
        let url = templatesDirectory.appendingPathComponent("\(template.id.uuidString).json")
        try? FileManager.default.removeItem(at: url)
    }

    /// Build a template from the current layout engine state.
    /// Non-persistent panes (welcome, restore-error) are stripped from the tree.
    static func capture(name: String, engine: PaneLayoutEngine) -> LayoutTemplate? {
        guard let root = engine.root else { return nil }

        // Collect only pane IDs that have a persisted descriptor
        let persistedIDs = Set(root.allPaneIDs.filter { engine.paneDescriptors[$0] != nil })
        guard !persistedIDs.isEmpty else { return nil }

        // Strip leaf nodes for non-persistent panes from the tree
        guard let prunedRoot = root.strippingOrphanedLeaves(keeping: persistedIDs) else { return nil }

        let descriptors = prunedRoot.allPaneIDs.compactMap { id -> LayoutTemplate.TemplatePaneDescriptor? in
            guard let persisted = engine.paneDescriptors[id] else { return nil }
            return LayoutTemplate.TemplatePaneDescriptor(paneID: id, type: persisted.type)
        }
        guard !descriptors.isEmpty else { return nil }
        return LayoutTemplate(
            id: UUID(),
            name: name,
            createdAt: Date(),
            root: prunedRoot,
            panes: descriptors
        )
    }

    /// Apply a template by mutating the workspace's existing layout engine in-place.
    /// This preserves the engine identity that WorkspaceTab holds, so session
    /// persistence and tab switching continue to work correctly.
    static func apply(_ template: LayoutTemplate, to contentArea: ContentAreaView) {
        let engine = contentArea.layoutEngine

        // Generate new pane IDs for each template pane
        var idMapping: [PaneID: PaneID] = [:]
        for descriptor in template.panes {
            idMapping[descriptor.paneID] = PaneID()
        }

        // Remap the split tree to use new IDs
        let remappedRoot = remapSplitNode(template.root, mapping: idMapping)

        // Pick the first pane as the active one
        let firstPaneID = remappedRoot.allPaneIDs.first

        // Exit zoom state if active, then tear down old pane views
        contentArea.unzoomIfNeeded()
        contentArea.teardownAllPaneViews()

        // Mutate the existing engine in-place (preserves WorkspaceTab identity)
        engine.root = remappedRoot
        engine.activePaneID = firstPaneID
        engine.clearDescriptors()
        for descriptor in template.panes {
            guard let newID = idMapping[descriptor.paneID] else { continue }
            engine.upsertPersistedPane(PersistedPane(
                paneID: newID,
                type: descriptor.type,
                workingDirectory: nil,
                sessionID: nil,
                taskID: nil,
                metadataJSON: nil
            ))
        }

        // Rebuild pane views from the updated engine
        contentArea.installPanesFromEngine()
    }

    // MARK: - Private

    private static func remapSplitNode(_ node: SplitNode, mapping: [PaneID: PaneID]) -> SplitNode {
        switch node {
        case .leaf(let id):
            guard let newID = mapping[id] else {
                Log.general.warning("Layout template: unmapped pane ID \(id), using fallback")
                return .leaf(id)
            }
            return .leaf(newID)
        case .split(let dir, let ratio, let first, let second):
            return .split(
                direction: dir,
                ratio: ratio,
                first: remapSplitNode(first, mapping: mapping),
                second: remapSplitNode(second, mapping: mapping)
            )
        }
    }
}
