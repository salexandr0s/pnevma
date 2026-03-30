import SwiftUI
import Observation
import Cocoa

// MARK: - Data Models

struct HarnessInstall: Decodable, Equatable {
    let path: String
    let rootPath: String
    let tool: String
    let scope: String
    let format: String
    let exists: Bool
    let backingMode: String
    let status: String
    let removalPolicy: String
}

struct HarnessSupportFile: Decodable, Equatable, Identifiable {
    var id: String { path }
    let relPath: String
    let path: String
    let format: String
    let sizeBytes: UInt64

}

struct HarnessCatalogItem: Decodable, Equatable, Identifiable {
    var id: String { sourceKey }
    let sourceKey: String
    let displayName: String
    let summary: String?
    let kind: String
    let sourceMode: String
    let primaryTool: String
    let primaryScope: String
    let tools: [String]
    let scopes: [String]
    let format: String
    let primaryPath: String
    let primaryRootPath: String
    let canonicalPath: String
    let exists: Bool
    let folderBacked: Bool
    let sizeBytes: UInt64
    let installCount: Int
    let supportFileCount: Int
    var isFavorite: Bool
    let collections: [String]
    let isHeavy: Bool
    let installs: [HarnessInstall]
    let supportFiles: [HarnessSupportFile]

}

struct HarnessCatalogReadContent: Decodable {
    let sourceKey: String
    let content: String
    let format: String
    let path: String

}

struct HarnessCollection: Decodable, Equatable, Identifiable {
    let id: String
    let name: String
    let itemCount: Int
}

struct HarnessScanRoot: Decodable, Equatable, Identifiable {
    let id: String
    let path: String
    let label: String?
    let enabled: Bool
}

struct HarnessCount: Decodable, Equatable, Identifiable {
    var id: String { key }
    let key: String
    let count: Int
}

struct HarnessCatalogAnalytics: Decodable, Equatable {
    let totalItems: Int
    let favoriteCount: Int
    let collectionCount: Int
    let folderBackedCount: Int
    let heavyCount: Int
    let byKind: [HarnessCount]
    let byTool: [HarnessCount]
    let byScope: [HarnessCount]
}

struct HarnessTargetOption: Decodable, Equatable, Identifiable {
    var id: String { "\(tool)-\(scope)" }
    let tool: String
    let scope: String
    let enabled: Bool
    let reasonDisabled: String?
}

struct HarnessCreatableKind: Decodable, Equatable, Identifiable {
    var id: String { kind }
    let kind: String
    let defaultPrimaryFile: String
    let defaultFormat: String
    let allowedTargets: [HarnessTargetOption]
}

struct HarnessCatalogCapabilities: Decodable, Equatable {
    let libraryRootPath: String
    let creatableKinds: [HarnessCreatableKind]
}

struct HarnessCatalogSnapshot: Decodable, Equatable {
    let items: [HarnessCatalogItem]
    let collections: [HarnessCollection]
    let scanRoots: [HarnessScanRoot]
    let analytics: HarnessCatalogAnalytics
    let capabilities: HarnessCatalogCapabilities
}

struct HarnessPlannedOperation: Decodable, Equatable, Identifiable {
    var id: String { "\(action)|\(path)" }
    let action: String
    let path: String
    let tool: String
    let scope: String
    let backingMode: String
    let conflict: String?
    let note: String?
}

struct HarnessCreatePlan: Decodable, Equatable {
    let sourceMode: String
    let sourcePath: String
    let sourceRootPath: String
    let slug: String
    let templateContent: String
    let operations: [HarnessPlannedOperation]
    let warnings: [String]
}

struct HarnessInstallPlan: Decodable, Equatable {
    let sourceMode: String
    let sourcePath: String
    let sourceRootPath: String
    let sourceKey: String?
    let slug: String
    let requiresPromotion: Bool
    let operations: [HarnessPlannedOperation]
    let warnings: [String]
}

struct HarnessMutationResult: Decodable, Equatable {
    let sourceKey: String
    let sourcePath: String
    let sourceRootPath: String
    let warnings: [String]
}

// MARK: - Backend Param Types

private struct ReadHarnessCatalogParams: Encodable {
    let sourceKey: String

}

private struct WriteHarnessCatalogParams: Encodable {
    let sourceKey: String
    let content: String

}

private struct ToggleHarnessFavoriteParams: Encodable {
    let sourceKey: String
    let favorite: Bool

}

private struct CreateHarnessCollectionParams: Encodable {
    let name: String
}

private struct DeleteHarnessCollectionParams: Encodable {
    let id: String
}

private struct RenameHarnessCollectionParams: Encodable {
    let id: String
    let name: String
}

private struct SetHarnessCollectionMembershipParams: Encodable {
    let collectionID: String
    let sourceKey: String
    let present: Bool
}

private struct UpsertHarnessScanRootParams: Encodable {
    let path: String
    let label: String?
    let enabled: Bool?
}

private struct SetHarnessScanRootEnabledParams: Encodable {
    let id: String
    let enabled: Bool
}

private struct DeleteHarnessScanRootParams: Encodable {
    let id: String
}

struct HarnessTargetParams: Encodable, Hashable {
    let tool: String
    let scope: String
}

private struct PlanCreateHarnessParams: Encodable {
    let kind: String
    let name: String
    let targets: [HarnessTargetParams]
    let replaceExisting: Bool?
}

private struct ApplyCreateHarnessParams: Encodable {
    let kind: String
    let name: String
    let slug: String?
    let content: String
    let targets: [HarnessTargetParams]
    let replaceExisting: Bool?
    let allowCopyFallback: Bool?
}

private struct PlanInstallHarnessParams: Encodable {
    let sourceKey: String
    let targets: [HarnessTargetParams]
    let replaceExisting: Bool?
}

private struct ApplyInstallHarnessParams: Encodable {
    let sourceKey: String
    let targets: [HarnessTargetParams]
    let replaceExisting: Bool?
    let allowCopyFallback: Bool?
}

private struct RemoveHarnessInstallParams: Encodable {
    let sourceKey: String
    let targetPath: String
}

// MARK: - UI helpers

private enum HarnessFilter: String, CaseIterable, Identifiable {
    case all
    case favorites
    case claude
    case codex
    case global
    case library
    case custom

    var id: String { rawValue }

    var label: String {
        switch self {
        case .all: "All"
        case .favorites: "Favorites"
        case .claude: "Claude"
        case .codex: "Codex"
        case .global: "Global"
        case .library: "Library"
        case .custom: "Custom"
        }
    }
}

private func harnessKindLabel(_ kind: String) -> String {
    switch kind {
    case "skill": return "Skill"
    case "agent": return "Agent"
    case "command": return "Command"
    case "rule": return "Rule"
    case "settings": return "Settings"
    case "mcp": return "MCP"
    case "hook": return "Hook"
    case "memory": return "Memory"
    case "instructions": return "Instructions"
    default: return kind.capitalized
    }
}

private func harnessKindIcon(_ kind: String) -> String {
    switch kind {
    case "skill": return "hammer"
    case "agent": return "person.crop.circle"
    case "command": return "terminal"
    case "rule": return "list.bullet.clipboard"
    case "settings": return "gearshape"
    case "mcp": return "server.rack"
    case "hook": return "arrow.triangle.branch"
    case "memory": return "brain"
    case "instructions": return "doc.text"
    default: return "doc"
    }
}

private func harnessToolLabel(_ tool: String) -> String {
    switch tool {
    case "claude": return "Claude"
    case "codex": return "Codex"
    case "global": return "Global"
    case "pnevma": return "Library"
    case "custom": return "Custom"
    default: return tool.capitalized
    }
}

private func harnessStatusTone(_ status: String) -> Color {
    switch status {
    case "ok": return .green
    case "missing": return .orange
    case "drifted": return .red
    case "external": return .secondary
    default: return .secondary
    }
}

private func harnessBackingModeLabel(_ mode: String) -> String {
    switch mode {
    case "source": return "Source"
    case "symlink": return "Symlink"
    case "copy": return "Copy"
    default: return mode.capitalized
    }
}

private func harnessScopeLabel(_ scope: String) -> String {
    switch scope {
    case "user": return "User"
    case "project": return "Project"
    case "global": return "Global"
    case "library": return "Library"
    default: return scope.capitalized
    }
}

private func formatIcon(for format: String) -> String {
    switch format {
    case "json": "curlybraces"
    case "toml": "gearshape.2"
    case "markdown": "doc.richtext"
    case "yaml": "list.bullet"
    default: "doc"
    }
}

private struct HarnessBadge: View {
    let text: String
    let tone: Color

    var body: some View {
        Text(text)
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(tone)
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(tone.opacity(0.12))
            .clipShape(Capsule())
    }
}

private struct HarnessSearchField: View {
    @Binding var text: String

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)

            TextField("Search harness items", text: $text)
                .textFieldStyle(.plain)
                .font(.system(size: 13))

            if !text.isEmpty {
                Button("Clear", systemImage: "xmark.circle.fill") {
                    text = ""
                }
                .labelStyle(.iconOnly)
                .buttonStyle(.plain)
                .foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(Color.primary.opacity(0.05), lineWidth: 1)
        )
    }
}

private struct HarnessRow: View {
    let item: HarnessCatalogItem
    let isSelected: Bool
    let action: () -> Void

    @State private var isHovering = false

    private var toolColor: Color {
        switch item.primaryTool {
        case "claude": return Color(red: 0.85, green: 0.55, blue: 0.35)
        case "codex": return Color(red: 0.3, green: 0.75, blue: 0.45)
        case "global": return Color(nsColor: .systemMint)
        case "pnevma": return .purple
        default: return .secondary
        }
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                RoundedRectangle(cornerRadius: 7)
                    .fill(isSelected ? Color.white.opacity(0.18) : toolColor.opacity(0.14))
                    .frame(width: 28, height: 28)
                    .overlay {
                        Image(systemName: harnessKindIcon(item.kind))
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(isSelected ? Color.white : toolColor)
                    }

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(item.displayName)
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(isSelected ? .white : .primary)
                            .lineLimit(1)
                        if item.isFavorite {
                            Image(systemName: "star.fill")
                                .font(.system(size: 9))
                                .foregroundStyle(isSelected ? .white.opacity(0.8) : .yellow)
                        }
                    }

                    HStack(spacing: 4) {
                        Text(harnessToolLabel(item.primaryTool))
                        Text("·")
                        Text(harnessKindLabel(item.kind))
                        if item.installCount > 1 {
                            Text("·")
                            Text("\(item.installCount)x")
                        }
                        if item.supportFileCount > 0 {
                            Text("·")
                            Text("+\(item.supportFileCount)")
                        }
                    }
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(isSelected ? .white.opacity(0.75) : .secondary)
                }

                Spacer(minLength: 0)

                if item.isHeavy {
                    Text("HEAVY")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(isSelected ? .white.opacity(0.85) : .orange)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 9)
                    .fill(rowBackground)
            )
        }
        .buttonStyle(.plain)
        .contentShape(RoundedRectangle(cornerRadius: 9))
        .onHover { isHovering = $0 }
    }

    private var rowBackground: Color {
        if isSelected { return Color.accentColor }
        if isHovering { return Color.primary.opacity(0.06) }
        return .clear
    }
}

private struct HarnessFilterBar: View {
    @Binding var filter: HarnessFilter

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(HarnessFilter.allCases) { option in
                    Button {
                        filter = option
                    } label: {
                        Text(option.label)
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(filter == option ? .white : .primary)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(
                                Capsule()
                                    .fill(filter == option ? Color.accentColor : Color.primary.opacity(0.06))
                            )
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
        }
    }
}

private struct HarnessCollectionBar: View {
    let collections: [HarnessCollection]
    @Binding var selectedCollectionID: String?

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                Button {
                    selectedCollectionID = nil
                } label: {
                    Text("All Collections")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(selectedCollectionID == nil ? .white : .primary)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(
                            Capsule()
                                .fill(selectedCollectionID == nil ? Color.accentColor : Color.primary.opacity(0.06))
                        )
                }
                .buttonStyle(.plain)

                ForEach(collections) { collection in
                    Button {
                        selectedCollectionID = collection.id
                    } label: {
                        Text("\(collection.name) · \(collection.itemCount)")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(selectedCollectionID == collection.id ? .white : .primary)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(
                                Capsule()
                                    .fill(selectedCollectionID == collection.id ? Color.accentColor : Color.primary.opacity(0.06))
                            )
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 10)
        }
    }
}

private struct HarnessAnalyticsStrip: View {
    let analytics: HarnessCatalogAnalytics

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                HarnessBadge(text: "\(analytics.totalItems) items", tone: .secondary)

                if analytics.favoriteCount > 0 {
                    HarnessBadge(text: "\(analytics.favoriteCount) favorites", tone: .yellow)
                }

                if analytics.collectionCount > 0 {
                    HarnessBadge(text: "\(analytics.collectionCount) collections", tone: .pink)
                }

                if analytics.folderBackedCount > 0 {
                    HarnessBadge(text: "\(analytics.folderBackedCount) folders", tone: .purple)
                }

                if analytics.heavyCount > 0 {
                    HarnessBadge(text: "\(analytics.heavyCount) heavy", tone: .orange)
                }

                ForEach(Array(analytics.byTool.prefix(3))) { entry in
                    HarnessBadge(
                        text: "\(harnessToolLabel(entry.key)) \(entry.count)",
                        tone: .blue
                    )
                }
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 10)
        }
    }
}

private struct HarnessDetailHeader: View {
    let item: HarnessCatalogItem
    let collections: [HarnessCollection]
    let isSaving: Bool
    let hasChanges: Bool
    let isReaderMode: Bool
    let onToggleReader: () -> Void
    let onSave: () -> Void
    let onRefresh: () -> Void
    let onToggleFavorite: () -> Void
    let onToggleCollection: (HarnessCollection) -> Void
    let onPresentManager: () -> Void
    let onPresentCreate: () -> Void
    let onPresentInstall: () -> Void
    let canInstall: Bool

    private var toolTone: Color {
        switch item.primaryTool {
        case "claude": return Color(red: 0.85, green: 0.55, blue: 0.35)
        case "codex": return Color(red: 0.3, green: 0.75, blue: 0.45)
        case "global": return Color(nsColor: .systemMint)
        case "pnevma": return .purple
        default: return .secondary
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                RoundedRectangle(cornerRadius: 9)
                    .fill(toolTone.opacity(0.14))
                    .frame(width: 34, height: 34)
                    .overlay {
                        Image(systemName: harnessKindIcon(item.kind))
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(toolTone)
                    }

                VStack(alignment: .leading, spacing: 3) {
                    Text(item.displayName)
                        .font(.system(size: 14, weight: .semibold))
                    if let summary = item.summary, !summary.isEmpty {
                        Text(summary)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Text(item.primaryPath)
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }

                Spacer()

                Button {
                    onToggleFavorite()
                } label: {
                    Image(systemName: item.isFavorite ? "star.fill" : "star")
                }
                .buttonStyle(.borderless)
                .foregroundStyle(item.isFavorite ? .yellow : .secondary)
                .help(item.isFavorite ? "Remove favorite" : "Add favorite")

                Button("Refresh", systemImage: "arrow.clockwise") {
                    onRefresh()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)

                Button("New Item", systemImage: "plus") {
                    onPresentCreate()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)

                Button("Install…", systemImage: "square.and.arrow.down") {
                    onPresentInstall()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(!canInstall)

                Menu {
                    if collections.isEmpty {
                        Text("Create a collection to organize harness items.")
                    } else {
                        ForEach(collections) { collection in
                            Button {
                                onToggleCollection(collection)
                            } label: {
                                Label(
                                    collection.name,
                                    systemImage: item.collections.contains(collection.name) ? "checkmark.circle.fill" : "circle"
                                )
                            }
                        }
                    }

                    Divider()

                    Button("Manage Collections…") {
                        onPresentManager()
                    }
                } label: {
                    Label("Collections", systemImage: "square.stack.3d.up")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)

                Button("Sources", systemImage: "folder.badge.gearshape") {
                    onPresentManager()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)

                if item.format == "markdown" {
                    Button(isReaderMode ? "Source" : "Reader") {
                        onToggleReader()
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }

                if isSaving {
                    ProgressView()
                        .controlSize(.small)
                }

                Button("Save") { onSave() }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .disabled(!hasChanges || isSaving)
                    .keyboardShortcut("s", modifiers: .command)
            }

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    HarnessBadge(text: harnessToolLabel(item.primaryTool), tone: toolTone)
                    HarnessBadge(text: harnessScopeLabel(item.primaryScope), tone: .secondary)
                    HarnessBadge(text: harnessKindLabel(item.kind), tone: .blue)
                    HarnessBadge(text: item.format.uppercased(), tone: .secondary)
                    if item.installCount > 1 {
                        HarnessBadge(text: "\(item.installCount) installs", tone: .green)
                    }
                    if item.supportFileCount > 0 {
                        HarnessBadge(text: "\(item.supportFileCount) support files", tone: .purple)
                    }
                    if item.isHeavy {
                        HarnessBadge(text: "Heavy", tone: .orange)
                    }
                }
            }
        }
        .padding(.horizontal, DesignTokens.Spacing.md)
        .padding(.vertical, 10)
        .background(ChromeSurfaceStyle.toolbar.color)
    }
}

private struct HarnessMetadataSection: View {
    let item: HarnessCatalogItem
    let onRevealInstall: (HarnessInstall) -> Void
    let onReinstallInstall: (HarnessInstall) -> Void
    let onRemoveInstall: (HarnessInstall) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if !item.collections.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Collections")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)
                    FlowLayout(item.collections, spacing: 6) { name in
                        HarnessBadge(text: name, tone: .pink)
                    }
                }
            }

            if !item.installs.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Install paths")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)
                    ForEach(item.installs.indices, id: \.self) { index in
                        let install = item.installs[index]
                        VStack(alignment: .leading, spacing: 6) {
                            HStack(alignment: .top, spacing: 8) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(install.path)
                                        .font(.system(size: 11, design: .monospaced))
                                        .foregroundStyle(.primary)
                                        .lineLimit(2)
                                        .truncationMode(.middle)
                                    HStack(spacing: 4) {
                                        Text(harnessToolLabel(install.tool))
                                        Text("·")
                                        Text(harnessScopeLabel(install.scope))
                                        Text("·")
                                        Text(install.format.uppercased())
                                    }
                                    .font(.system(size: 10))
                                    .foregroundStyle(.secondary)
                                }

                                Spacer(minLength: 0)

                                VStack(alignment: .trailing, spacing: 6) {
                                    HStack(spacing: 4) {
                                        HarnessBadge(
                                            text: harnessBackingModeLabel(install.backingMode),
                                            tone: .blue
                                        )
                                        HarnessBadge(
                                            text: install.status.capitalized,
                                            tone: harnessStatusTone(install.status)
                                        )
                                    }
                                    HStack(spacing: 6) {
                                        Button("Reveal") {
                                            onRevealInstall(install)
                                        }
                                        .buttonStyle(.borderless)
                                        .font(.system(size: 11, weight: .medium))

                                        if install.removalPolicy == "delete_target" {
                                            Button("Reinstall") {
                                                onReinstallInstall(install)
                                            }
                                            .buttonStyle(.borderless)
                                            .font(.system(size: 11, weight: .medium))
                                        }

                                        if install.removalPolicy != "source" {
                                            Button(install.removalPolicy == "forget_only" ? "Forget" : "Remove") {
                                                onRemoveInstall(install)
                                            }
                                            .buttonStyle(.borderless)
                                            .font(.system(size: 11, weight: .medium))
                                            .foregroundStyle(.red)
                                        }
                                    }
                                }
                            }
                        }
                        .padding(.vertical, 2)
                    }
                }
            }

            if !item.supportFiles.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Support files")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)
                    ForEach(item.supportFiles) { file in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(file.relPath)
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(.primary)
                                .lineLimit(1)
                            HStack(spacing: 4) {
                                Text(file.format.uppercased())
                                Text("·")
                                Text(ByteCountFormatter.string(fromByteCount: Int64(file.sizeBytes), countStyle: .file))
                            }
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 2)
                    }
                }
            }
        }
    }
}

private struct FlowLayout<Data: RandomAccessCollection, Content: View>: View where Data.Element: Hashable {
    let data: Data
    let spacing: CGFloat
    let content: (Data.Element) -> Content

    init(_ data: Data, spacing: CGFloat = 8, @ViewBuilder content: @escaping (Data.Element) -> Content) {
        self.data = data
        self.spacing = spacing
        self.content = content
    }

    var body: some View {
        HStack(spacing: spacing) {
            ForEach(Array(data), id: \.self) { item in
                content(item)
            }
        }
    }
}

private struct HarnessEditor: View {
    @Binding var content: String

    var body: some View {
        TextEditor(text: $content)
            .font(.system(.body, design: .monospaced))
            .scrollContentBackground(.hidden)
    }
}

private struct HarnessCreateDraft {
    var kind: String = ""
    var name: String = ""
    var selectedTargetIDs: Set<String> = []
    var content: String = ""
    var replaceExisting = false
    var allowCopyFallback = true
}

private struct HarnessInstallDraft {
    var selectedTargetIDs: Set<String> = []
    var replaceExisting = false
    var allowCopyFallback = true
}

private struct HarnessPlanOperationsView: View {
    let operations: [HarnessPlannedOperation]
    let warnings: [String]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if !operations.isEmpty {
                Text("Planned Operations")
                    .font(.headline)
                ForEach(operations) { operation in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 6) {
                            Text(operation.action.replacingOccurrences(of: "_", with: " ").capitalized)
                                .font(.system(size: 12, weight: .semibold))
                            HarnessBadge(text: harnessToolLabel(operation.tool), tone: .blue)
                            HarnessBadge(text: harnessScopeLabel(operation.scope), tone: .secondary)
                            HarnessBadge(text: harnessBackingModeLabel(operation.backingMode), tone: .purple)
                            if let conflict = operation.conflict {
                                HarnessBadge(text: conflict.replacingOccurrences(of: "_", with: " ").capitalized, tone: .orange)
                            }
                        }
                        Text(operation.path)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                            .textSelection(.enabled)
                        if let note = operation.note, !note.isEmpty {
                            Text(note)
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(10)
                    .background(
                        RoundedRectangle(cornerRadius: 10)
                            .fill(Color.primary.opacity(0.04))
                    )
                }
            }

            if !warnings.isEmpty {
                Text("Warnings")
                    .font(.headline)
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(warnings.indices, id: \.self) { index in
                        let warning = warnings[index]
                        Text("• \(warning)")
                            .font(.system(size: 11))
                            .foregroundStyle(.orange)
                    }
                }
            }
        }
    }
}

private struct HarnessTargetSelectionView: View {
    let options: [HarnessTargetOption]
    @Binding var selectedIDs: Set<String>

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(options) { option in
                Toggle(isOn: selectionBinding(for: option)) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(harnessToolLabel(option.tool)) · \(harnessScopeLabel(option.scope))")
                            .font(.system(size: 12, weight: .medium))
                        if let reasonDisabled = option.reasonDisabled, !option.enabled {
                            Text(reasonDisabled)
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .disabled(!option.enabled)
            }
        }
    }

    private func selectionBinding(for option: HarnessTargetOption) -> Binding<Bool> {
        Binding(
            get: { selectedIDs.contains(option.id) },
            set: { enabled in
                if enabled {
                    selectedIDs.insert(option.id)
                } else {
                    selectedIDs.remove(option.id)
                }
            }
        )
    }
}

private struct HarnessCreateSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Bindable var viewModel: HarnessConfigViewModel
    @State private var draft = HarnessCreateDraft()
    @State private var plan: HarnessCreatePlan?
    @State private var isSubmitting = false

    private var kinds: [HarnessCreatableKind] {
        viewModel.capabilities?.creatableKinds ?? []
    }

    private var selectedKind: HarnessCreatableKind? {
        kinds.first(where: { $0.kind == draft.kind }) ?? kinds.first
    }

    private var selectedTargets: [HarnessTargetParams] {
        selectedKind?.allowedTargets.compactMap { option in
            guard draft.selectedTargetIDs.contains(option.id), option.enabled else { return nil }
            return HarnessTargetParams(tool: option.tool, scope: option.scope)
        } ?? []
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("New Harness Item")
                    .font(.title3.weight(.semibold))

                Picker("Kind", selection: $draft.kind) {
                    ForEach(kinds) { kind in
                        Text(harnessKindLabel(kind.kind)).tag(kind.kind)
                    }
                }
                .pickerStyle(.segmented)

                TextField("Name", text: $draft.name)
                    .textFieldStyle(.roundedBorder)

                if let selectedKind {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Targets")
                            .font(.headline)
                        HarnessTargetSelectionView(
                            options: selectedKind.allowedTargets,
                            selectedIDs: $draft.selectedTargetIDs
                        )
                    }
                }

                Toggle("Replace existing targets when needed", isOn: $draft.replaceExisting)
                Toggle("Allow copy fallback if symlink creation fails", isOn: $draft.allowCopyFallback)

                if let plan, !draft.content.isEmpty {
                    Text("Source")
                        .font(.headline)
                    Text(plan.sourcePath)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }

                Text("Content")
                    .font(.headline)
                HarnessEditor(content: $draft.content)
                    .frame(minHeight: 220)
                    .background(Color.primary.opacity(0.03))
                    .clipShape(RoundedRectangle(cornerRadius: 10))

                if let plan {
                    HarnessPlanOperationsView(operations: plan.operations, warnings: plan.warnings)
                }

                HStack {
                    Spacer()
                    Button("Cancel") { dismiss() }
                    Button(isSubmitting ? "Creating…" : "Create") {
                        Task { await submit() }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(isSubmitting || draft.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || selectedTargets.isEmpty)
                }
            }
            .padding(20)
        }
        .frame(minWidth: 620, minHeight: 620)
        .task { await bootstrapIfNeeded() }
        .onChange(of: draft.kind) { _, _ in Task { await refreshPlan() } }
        .onChange(of: draft.name) { _, _ in Task { await refreshPlan() } }
        .onChange(of: draft.selectedTargetIDs) { _, _ in Task { await refreshPlan() } }
        .onChange(of: draft.replaceExisting) { _, _ in Task { await refreshPlan() } }
    }

    private func bootstrapIfNeeded() async {
        guard draft.kind.isEmpty else { return }
        guard let firstKind = kinds.first else { return }
        draft.kind = firstKind.kind
        draft.selectedTargetIDs = Set(firstKind.allowedTargets.filter(\.enabled).prefix(1).map(\.id))
        await refreshPlan()
    }

    private func refreshPlan() async {
        guard !draft.kind.isEmpty else { return }
        let plan = await viewModel.planCreateItem(
            kind: draft.kind,
            name: draft.name,
            targets: selectedTargets,
            replaceExisting: draft.replaceExisting
        )
        self.plan = plan
        if draft.content.isEmpty, let template = plan?.templateContent {
            draft.content = template
        }
    }

    private func submit() async {
        isSubmitting = true
        defer { isSubmitting = false }
        let result = await viewModel.createItem(
            kind: draft.kind,
            name: draft.name,
            slug: plan?.slug,
            content: draft.content,
            targets: selectedTargets,
            replaceExisting: draft.replaceExisting,
            allowCopyFallback: draft.allowCopyFallback
        )
        if result != nil {
            dismiss()
        }
    }
}

private struct HarnessInstallSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Bindable var viewModel: HarnessConfigViewModel
    let item: HarnessCatalogItem
    @State private var draft = HarnessInstallDraft()
    @State private var plan: HarnessInstallPlan?
    @State private var isSubmitting = false

    private var options: [HarnessTargetOption] {
        viewModel.installOptions(for: item)
    }

    private var selectedTargets: [HarnessTargetParams] {
        options.compactMap { option in
            guard draft.selectedTargetIDs.contains(option.id), option.enabled else { return nil }
            return HarnessTargetParams(tool: option.tool, scope: option.scope)
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Install \(item.displayName)")
                    .font(.title3.weight(.semibold))

                HarnessTargetSelectionView(options: options, selectedIDs: $draft.selectedTargetIDs)
                Toggle("Replace existing targets when needed", isOn: $draft.replaceExisting)
                Toggle("Allow copy fallback if symlink creation fails", isOn: $draft.allowCopyFallback)

                if let plan {
                    if plan.requiresPromotion {
                        HarnessBadge(text: "Promotes to Library", tone: .purple)
                    }
                    Text(plan.sourcePath)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                    HarnessPlanOperationsView(operations: plan.operations, warnings: plan.warnings)
                }

                HStack {
                    Spacer()
                    Button("Cancel") { dismiss() }
                    Button(isSubmitting ? "Installing…" : "Install") {
                        Task { await submit() }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(isSubmitting || selectedTargets.isEmpty)
                }
            }
            .padding(20)
        }
        .frame(minWidth: 560, minHeight: 520)
        .task { await bootstrapIfNeeded() }
        .onChange(of: draft.selectedTargetIDs) { _, _ in Task { await refreshPlan() } }
        .onChange(of: draft.replaceExisting) { _, _ in Task { await refreshPlan() } }
    }

    private func bootstrapIfNeeded() async {
        guard draft.selectedTargetIDs.isEmpty else { return }
        draft.selectedTargetIDs = Set(options.filter(\.enabled).prefix(1).map(\.id))
        await refreshPlan()
    }

    private func refreshPlan() async {
        plan = await viewModel.planInstallItem(
            sourceKey: item.sourceKey,
            targets: selectedTargets,
            replaceExisting: draft.replaceExisting
        )
    }

    private func submit() async {
        isSubmitting = true
        defer { isSubmitting = false }
        let result = await viewModel.installItem(
            sourceKey: item.sourceKey,
            targets: selectedTargets,
            replaceExisting: draft.replaceExisting,
            allowCopyFallback: draft.allowCopyFallback
        )
        if result != nil {
            dismiss()
        }
    }
}

private struct HarnessStudioManagerSheet: View {
    @Bindable var viewModel: HarnessConfigViewModel

    @State private var newCollectionName = ""
    @State private var newScanRootPath = ""
    @State private var newScanRootLabel = ""

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Collections")
                        .font(.headline)

                    HStack(spacing: 10) {
                        TextField("New collection name", text: $newCollectionName)
                            .textFieldStyle(.roundedBorder)

                        Button("Create") {
                            let name = newCollectionName.trimmingCharacters(in: .whitespacesAndNewlines)
                            guard !name.isEmpty else { return }
                            viewModel.createCollection(named: name)
                            newCollectionName = ""
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(newCollectionName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }

                    if viewModel.collections.isEmpty {
                        Text("No collections yet.")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    } else {
                        VStack(spacing: 10) {
                            ForEach(viewModel.collections) { collection in
                                HarnessCollectionRow(collection: collection, viewModel: viewModel)
                            }
                        }
                    }
                }

                Divider()

                VStack(alignment: .leading, spacing: 12) {
                    Text("Custom Scan Roots")
                        .font(.headline)

                    VStack(spacing: 10) {
                        TextField("Path", text: $newScanRootPath)
                            .textFieldStyle(.roundedBorder)

                        TextField("Label (optional)", text: $newScanRootLabel)
                            .textFieldStyle(.roundedBorder)

                        HStack {
                            Spacer()

                            Button("Add Scan Root") {
                                let path = newScanRootPath.trimmingCharacters(in: .whitespacesAndNewlines)
                                guard !path.isEmpty else { return }
                                let label = newScanRootLabel.trimmingCharacters(in: .whitespacesAndNewlines)
                                viewModel.upsertScanRoot(
                                    path: path,
                                    label: label.isEmpty ? nil : label
                                )
                                newScanRootPath = ""
                                newScanRootLabel = ""
                            }
                            .buttonStyle(.borderedProminent)
                            .disabled(newScanRootPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        }
                    }

                    if viewModel.scanRoots.isEmpty {
                        Text("No custom scan roots configured.")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    } else {
                        VStack(spacing: 12) {
                            ForEach(viewModel.scanRoots) { root in
                                HarnessScanRootRow(root: root, viewModel: viewModel)
                            }
                        }
                    }
                }
            }
            .padding(20)
        }
        .frame(minWidth: 560, minHeight: 440)
    }
}

private struct HarnessCollectionRow: View {
    let collection: HarnessCollection
    var viewModel: HarnessConfigViewModel
    @State private var nameDraft: String

    init(collection: HarnessCollection, viewModel: HarnessConfigViewModel) {
        self.collection = collection
        self.viewModel = viewModel
        _nameDraft = State(initialValue: collection.name)
    }

    var body: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                TextField("Collection name", text: $nameDraft)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 13, weight: .medium))
                Text("\(collection.itemCount) items")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Button("Save") {
                viewModel.renameCollection(collection, name: trimmedName)
            }
            .buttonStyle(.borderless)
            .disabled(trimmedName.isEmpty || trimmedName == collection.name)

            Button(role: .destructive) {
                viewModel.deleteCollection(collection)
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
        }
        .padding(.vertical, 4)
        .task(id: collection.name) {
            guard nameDraft != collection.name else { return }
            nameDraft = collection.name
        }
    }

    private var trimmedName: String {
        nameDraft.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

private struct HarnessScanRootRow: View {
    let root: HarnessScanRoot
    var viewModel: HarnessConfigViewModel
    @State private var isEnabled: Bool
    @State private var isSyncingFromModel = false

    init(root: HarnessScanRoot, viewModel: HarnessConfigViewModel) {
        self.root = root
        self.viewModel = viewModel
        _isEnabled = State(initialValue: root.enabled)
    }

    var body: some View {
        HStack(spacing: 12) {
            Toggle(isOn: $isEnabled) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(root.label?.isEmpty == false ? root.label! : root.path)
                        .font(.system(size: 13, weight: .medium))
                    if root.label?.isEmpty == false {
                        Text(root.path)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                }
            }

            Spacer()

            Button(role: .destructive) {
                viewModel.deleteScanRoot(root)
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
        }
        .task(id: root.enabled) {
            isSyncingFromModel = true
            isEnabled = root.enabled
            isSyncingFromModel = false
        }
        .onChange(of: isEnabled) { oldValue, newValue in
            guard !isSyncingFromModel, oldValue != newValue else { return }
            viewModel.setScanRootEnabled(root, enabled: newValue)
        }
    }
}

// MARK: - Main View

struct HarnessConfigView: View {
    @State private var viewModel = HarnessConfigViewModel()
    @State private var searchText = ""
    @State private var selectedFilter: HarnessFilter = .all
    @State private var isReaderMode = false
    @State private var isManagingStudio = false
    @State private var isCreatingItem = false
    @State private var isInstallingItem = false

    private var filteredItems: [HarnessCatalogItem] {
        viewModel.filteredItems(
            searchText: searchText,
            filter: selectedFilter,
            collectionName: selectedCollectionName
        )
    }

    private var selectedItem: HarnessCatalogItem? {
        guard let sourceKey = viewModel.selectedSourceKey else { return nil }
        return viewModel.items.first(where: { $0.sourceKey == sourceKey })
    }

    private var selectedCollectionName: String? {
        guard let selectedCollectionID = viewModel.selectedCollectionID else { return nil }
        return viewModel.collections.first(where: { $0.id == selectedCollectionID })?.name
    }

    var body: some View {
        NativePaneScaffold(
            title: "Harness Config",
            subtitle: "Harness Studio — discover and edit skills, agents, commands, MCP, and config files",
            systemImage: "slider.horizontal.3",
            role: .document,
            inlineHeaderIdentifier: "pane.harnessConfig.inlineHeader",
            inlineHeaderLabel: "Harness Config inline header"
        ) {
            EmptyView()
        } content: {
            NativeSplitScaffold(
                sidebarMinWidth: 300,
                sidebarIdealWidth: 340,
                sidebarMaxWidth: 380,
                sidebarSurface: .sidebar
            ) {
                VStack(spacing: 0) {
                    HarnessSearchField(text: $searchText)
                        .padding(.horizontal, 12)
                        .padding(.top, 12)
                        .padding(.bottom, 8)

                    HStack {
                        Button("New Item", systemImage: "plus") {
                            isCreatingItem = true
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)

                        Spacer()
                    }
                    .padding(.horizontal, 12)
                    .padding(.bottom, 8)

                    HarnessFilterBar(filter: $selectedFilter)

                    if !viewModel.collections.isEmpty {
                        HarnessCollectionBar(
                            collections: viewModel.collections,
                            selectedCollectionID: $viewModel.selectedCollectionID
                        )
                    }

                    if let analytics = viewModel.analytics {
                        HarnessAnalyticsStrip(analytics: analytics)
                    }

                    Divider()

                    if viewModel.isRefreshing && viewModel.items.isEmpty {
                        ProgressView("Loading harness catalog…")
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else if filteredItems.isEmpty {
                        EmptyStateView(
                            icon: "slider.horizontal.3",
                            title: "No harness items",
                            message: searchText.isEmpty
                                ? "No supported harness files were discovered for the current filters."
                                : "Try a different search query."
                        )
                    } else {
                        ScrollView {
                            LazyVStack(alignment: .leading, spacing: 4) {
                                ForEach(filteredItems) { item in
                                    HarnessRow(
                                        item: item,
                                        isSelected: viewModel.selectedSourceKey == item.sourceKey
                                    ) {
                                        viewModel.selectedSourceKey = item.sourceKey
                                    }
                                }
                            }
                            .padding(8)
                        }
                    }
                }
            } detail: {
                VStack(spacing: 0) {
                    if let item = selectedItem {
                        HarnessDetailHeader(
                            item: item,
                            collections: viewModel.collections,
                            isSaving: viewModel.isSaving,
                            hasChanges: viewModel.hasUnsavedChanges,
                            isReaderMode: isReaderMode,
                            onToggleReader: { isReaderMode.toggle() },
                            onSave: { viewModel.saveSelectedItem() },
                            onRefresh: { viewModel.reloadSelectedItem() },
                            onToggleFavorite: { viewModel.toggleFavorite(for: item) },
                            onToggleCollection: { collection in
                                viewModel.toggleCollectionMembership(collection, for: item)
                            },
                            onPresentManager: { isManagingStudio = true },
                            onPresentCreate: { isCreatingItem = true },
                            onPresentInstall: { isInstallingItem = true },
                            canInstall: viewModel.canInstall(item: item)
                        )

                        Divider()

                        if viewModel.isLoadingContent {
                            ProgressView("Loading content…")
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                        } else {
                            NativeSplitScaffold(
                                sidebarMinWidth: 220,
                                sidebarIdealWidth: 260,
                                sidebarMaxWidth: 320,
                                sidebarSurface: .inspector
                            ) {
                                ScrollView {
                                    HarnessMetadataSection(
                                        item: item,
                                        onRevealInstall: { install in
                                            viewModel.revealInstall(install)
                                        },
                                        onReinstallInstall: { install in
                                            viewModel.reinstallInstall(install, from: item)
                                        },
                                        onRemoveInstall: { install in
                                            viewModel.removeInstall(install, from: item)
                                        }
                                    )
                                        .padding(16)
                                }
                            } detail: {
                                if isReaderMode && item.format == "markdown" {
                                    MarkdownReaderView(content: viewModel.editorContent)
                                        .padding(.horizontal, 16)
                                        .padding(.vertical, 12)
                                } else {
                                    HarnessEditor(content: $viewModel.editorContent)
                                        .padding(.horizontal, 8)
                                        .padding(.vertical, 8)
                                }
                            }
                        }
                    } else {
                        EmptyStateView(
                            icon: "slider.horizontal.3",
                            title: "Harness Catalog",
                            message: "Select a harness item to inspect its source, installs, and supporting files."
                        )
                    }
                }
            }
        }
        .overlay(alignment: .bottom) {
            VStack(spacing: 8) {
                ErrorBanner(message: viewModel.diskChangeMessage)
                ErrorBanner(message: viewModel.actionError)
            }
        }
        .sheet(isPresented: $isManagingStudio) {
            HarnessStudioManagerSheet(viewModel: viewModel)
        }
        .sheet(isPresented: $isCreatingItem) {
            HarnessCreateSheet(viewModel: viewModel)
        }
        .sheet(isPresented: $isInstallingItem) {
            if let selectedItem {
                HarnessInstallSheet(viewModel: viewModel, item: selectedItem)
            }
        }
        .accessibilityIdentifier("pane.harnessConfig")
        .task { await viewModel.activate() }
        .onChange(of: viewModel.selectedSourceKey) { _, _ in
            isReaderMode = false
            viewModel.loadSelectedItem()
        }
        .onChange(of: viewModel.editorContent) { _, newValue in
            viewModel.hasUnsavedChanges = newValue != viewModel.originalContent
        }
    }
}

// MARK: - ViewModel

@Observable @MainActor
final class HarnessConfigViewModel {
    var items: [HarnessCatalogItem] = []
    var collections: [HarnessCollection] = []
    var scanRoots: [HarnessScanRoot] = []
    var analytics: HarnessCatalogAnalytics?
    var capabilities: HarnessCatalogCapabilities?
    var selectedSourceKey: String?
    var selectedCollectionID: String?
    var editorContent: String = ""
    var originalContent: String = ""
    var isRefreshing = false
    var isLoadingContent = false
    var isSaving = false
    var hasUnsavedChanges = false
    var actionError: String?
    var diskChangeMessage: String?

    @ObservationIgnored
    private let commandBus: (any CommandCalling)?
    @ObservationIgnored
    private let bridgeEventHub: BridgeEventHub
    @ObservationIgnored
    private var bridgeObserverID: UUID?
    @ObservationIgnored
    private var readRequestToken: UUID?

    init(
        commandBus: (any CommandCalling)? = CommandBus.shared,
        bridgeEventHub: BridgeEventHub = .shared
    ) {
        self.commandBus = commandBus
        self.bridgeEventHub = bridgeEventHub
        bridgeObserverID = bridgeEventHub.addObserver { [weak self] event in
            guard event.name == "harness_catalog_updated" else { return }
            Task { @MainActor [weak self] in
                await self?.handleCatalogUpdatedEvent()
            }
        }
    }

    deinit {
        if let bridgeObserverID {
            bridgeEventHub.removeObserver(bridgeObserverID)
        }
    }

    func activate() async {
        await refresh()
    }

    func refresh(select sourceKey: String? = nil) async {
        guard let commandBus else {
            actionError = "Backend connection unavailable"
            scheduleDismissActionError()
            return
        }

        isRefreshing = true
        do {
            let snapshot: HarnessCatalogSnapshot = try await commandBus.call(
                method: "harness.catalog.snapshot",
                params: nil as String?
            )
            self.items = snapshot.items
            self.collections = snapshot.collections
            self.scanRoots = snapshot.scanRoots
            self.analytics = snapshot.analytics
            self.capabilities = snapshot.capabilities

            if let selectedCollectionID,
               !snapshot.collections.contains(where: { $0.id == selectedCollectionID }) {
                self.selectedCollectionID = nil
            }

            if let sourceKey, snapshot.items.contains(where: { $0.sourceKey == sourceKey }) {
                selectedSourceKey = sourceKey
            } else if selectedSourceKey == nil {
                selectedSourceKey = snapshot.items.first?.sourceKey
            } else if !snapshot.items.contains(where: { $0.sourceKey == selectedSourceKey }) {
                selectedSourceKey = snapshot.items.first?.sourceKey
            }
        } catch {
            actionError = error.localizedDescription
            scheduleDismissActionError()
        }
        isRefreshing = false
    }

    fileprivate func filteredItems(
        searchText: String,
        filter: HarnessFilter,
        collectionName: String?
    ) -> [HarnessCatalogItem] {
        items.filter { item in
            let matchesFilter: Bool
            switch filter {
            case .all:
                matchesFilter = true
            case .favorites:
                matchesFilter = item.isFavorite
            case .claude, .codex, .global, .custom, .library:
                let tool = filter == .library ? "pnevma" : filter.rawValue
                matchesFilter = item.tools.contains(tool) || item.primaryTool == tool
            }

            guard matchesFilter else { return false }
            if let collectionName, !item.collections.contains(collectionName) {
                return false
            }
            guard !searchText.isEmpty else { return true }

            let query = searchText.localizedLowercase
            return item.displayName.localizedLowercase.contains(query)
                || (item.summary?.localizedLowercase.contains(query) ?? false)
                || item.kind.localizedLowercase.contains(query)
                || item.primaryPath.localizedLowercase.contains(query)
                || item.collections.contains(where: { $0.localizedLowercase.contains(query) })
        }
    }

    func loadSelectedItem() {
        guard let selectedSourceKey, let commandBus else {
            editorContent = ""
            originalContent = ""
            hasUnsavedChanges = false
            return
        }

        let token = UUID()
        readRequestToken = token
        isLoadingContent = true
        Task { [weak self] in
            guard let self else { return }
            do {
                let result: HarnessCatalogReadContent = try await commandBus.call(
                    method: "harness.catalog.read",
                    params: ReadHarnessCatalogParams(sourceKey: selectedSourceKey)
                )
                guard self.readRequestToken == token, self.selectedSourceKey == selectedSourceKey else {
                    return
                }
                self.editorContent = result.content
                self.originalContent = result.content
                self.hasUnsavedChanges = false
                self.diskChangeMessage = nil
            } catch {
                self.actionError = error.localizedDescription
                self.scheduleDismissActionError()
            }
            self.isLoadingContent = false
        }
    }

    func reloadSelectedItem() {
        let currentSelection = selectedSourceKey
        Task { [weak self] in
            await self?.refresh(select: currentSelection)
            self?.loadSelectedItem()
        }
    }

    func saveSelectedItem() {
        guard let selectedSourceKey, let commandBus else { return }
        isSaving = true
        Task { [weak self] in
            guard let self else { return }
            do {
                let _: OkResponse = try await commandBus.call(
                    method: "harness.catalog.write",
                    params: WriteHarnessCatalogParams(
                        sourceKey: selectedSourceKey,
                        content: self.editorContent
                    )
                )
                self.originalContent = self.editorContent
                self.hasUnsavedChanges = false
                await self.refresh(select: selectedSourceKey)
            } catch {
                self.actionError = error.localizedDescription
                self.scheduleDismissActionError()
            }
            self.isSaving = false
        }
    }

    func toggleFavorite(for item: HarnessCatalogItem) {
        guard let commandBus else { return }
        Task { [weak self] in
            guard let self else { return }
            do {
                let _: OkResponse = try await commandBus.call(
                    method: "harness.catalog.favorite",
                    params: ToggleHarnessFavoriteParams(
                        sourceKey: item.sourceKey,
                        favorite: !item.isFavorite
                    )
                )
                await self.refresh(select: item.sourceKey)
            } catch {
                self.actionError = error.localizedDescription
                self.scheduleDismissActionError()
            }
        }
    }

    func toggleCollectionMembership(_ collection: HarnessCollection, for item: HarnessCatalogItem) {
        guard let commandBus else { return }
        Task { [weak self] in
            guard let self else { return }
            do {
                let _: OkResponse = try await commandBus.call(
                    method: "harness.catalog.collections.set_membership",
                    params: SetHarnessCollectionMembershipParams(
                        collectionID: collection.id,
                        sourceKey: item.sourceKey,
                        present: !item.collections.contains(collection.name)
                    )
                )
                await self.refresh(select: item.sourceKey)
            } catch {
                self.actionError = error.localizedDescription
                self.scheduleDismissActionError()
            }
        }
    }

    func createCollection(named name: String) {
        guard let commandBus else { return }
        Task { [weak self] in
            guard let self else { return }
            do {
                let _: HarnessCollection = try await commandBus.call(
                    method: "harness.catalog.collections.create",
                    params: CreateHarnessCollectionParams(name: name)
                )
                await self.refresh(select: self.selectedSourceKey)
            } catch {
                self.actionError = error.localizedDescription
                self.scheduleDismissActionError()
            }
        }
    }

    func renameCollection(_ collection: HarnessCollection, name: String) {
        guard let commandBus else { return }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        Task { [weak self] in
            guard let self else { return }
            do {
                let _: OkResponse = try await commandBus.call(
                    method: "harness.catalog.collections.rename",
                    params: RenameHarnessCollectionParams(id: collection.id, name: trimmed)
                )
                await self.refresh(select: self.selectedSourceKey)
            } catch {
                self.actionError = error.localizedDescription
                self.scheduleDismissActionError()
            }
        }
    }

    func deleteCollection(_ collection: HarnessCollection) {
        guard let commandBus else { return }
        Task { [weak self] in
            guard let self else { return }
            do {
                let _: OkResponse = try await commandBus.call(
                    method: "harness.catalog.collections.delete",
                    params: DeleteHarnessCollectionParams(id: collection.id)
                )
                if self.selectedCollectionID == collection.id {
                    self.selectedCollectionID = nil
                }
                await self.refresh(select: self.selectedSourceKey)
            } catch {
                self.actionError = error.localizedDescription
                self.scheduleDismissActionError()
            }
        }
    }

    func upsertScanRoot(path: String, label: String?) {
        guard let commandBus else { return }
        Task { [weak self] in
            guard let self else { return }
            do {
                let _: HarnessScanRoot = try await commandBus.call(
                    method: "harness.catalog.scan_roots.upsert",
                    params: UpsertHarnessScanRootParams(
                        path: path,
                        label: label,
                        enabled: true
                    )
                )
                await self.refresh(select: self.selectedSourceKey)
            } catch {
                self.actionError = error.localizedDescription
                self.scheduleDismissActionError()
            }
        }
    }

    func setScanRootEnabled(_ root: HarnessScanRoot, enabled: Bool) {
        guard let commandBus else { return }
        Task { [weak self] in
            guard let self else { return }
            do {
                let _: OkResponse = try await commandBus.call(
                    method: "harness.catalog.scan_roots.set_enabled",
                    params: SetHarnessScanRootEnabledParams(id: root.id, enabled: enabled)
                )
                await self.refresh(select: self.selectedSourceKey)
            } catch {
                self.actionError = error.localizedDescription
                self.scheduleDismissActionError()
            }
        }
    }

    func deleteScanRoot(_ root: HarnessScanRoot) {
        guard let commandBus else { return }
        Task { [weak self] in
            guard let self else { return }
            do {
                let _: OkResponse = try await commandBus.call(
                    method: "harness.catalog.scan_roots.delete",
                    params: DeleteHarnessScanRootParams(id: root.id)
                )
                await self.refresh(select: self.selectedSourceKey)
            } catch {
                self.actionError = error.localizedDescription
                self.scheduleDismissActionError()
            }
        }
    }

    func planCreateItem(
        kind: String,
        name: String,
        targets: [HarnessTargetParams],
        replaceExisting: Bool
    ) async -> HarnessCreatePlan? {
        guard let commandBus, !kind.isEmpty else { return nil }
        do {
            return try await commandBus.call(
                method: "harness.catalog.create.plan",
                params: PlanCreateHarnessParams(
                    kind: kind,
                    name: name,
                    targets: targets,
                    replaceExisting: replaceExisting
                )
            )
        } catch {
            return nil
        }
    }

    func createItem(
        kind: String,
        name: String,
        slug: String?,
        content: String,
        targets: [HarnessTargetParams],
        replaceExisting: Bool,
        allowCopyFallback: Bool
    ) async -> HarnessMutationResult? {
        guard let commandBus else { return nil }
        do {
            let result: HarnessMutationResult = try await commandBus.call(
                method: "harness.catalog.create.apply",
                params: ApplyCreateHarnessParams(
                    kind: kind,
                    name: name,
                    slug: slug,
                    content: content,
                    targets: targets,
                    replaceExisting: replaceExisting,
                    allowCopyFallback: allowCopyFallback
                )
            )
            await refresh(select: result.sourceKey)
            loadSelectedItem()
            return result
        } catch {
            actionError = error.localizedDescription
            scheduleDismissActionError()
            return nil
        }
    }

    func installOptions(for item: HarnessCatalogItem) -> [HarnessTargetOption] {
        guard let kind = capabilities?.creatableKinds.first(where: { $0.kind == item.kind }) else {
            return []
        }
        return kind.allowedTargets.filter { option in
            !item.installs.contains(where: { $0.tool == option.tool && $0.scope == option.scope })
        }
    }

    func canInstall(item: HarnessCatalogItem) -> Bool {
        !installOptions(for: item).isEmpty
    }

    func planInstallItem(
        sourceKey: String,
        targets: [HarnessTargetParams],
        replaceExisting: Bool
    ) async -> HarnessInstallPlan? {
        guard let commandBus else { return nil }
        do {
            return try await commandBus.call(
                method: "harness.catalog.install.plan",
                params: PlanInstallHarnessParams(
                    sourceKey: sourceKey,
                    targets: targets,
                    replaceExisting: replaceExisting
                )
            )
        } catch {
            return nil
        }
    }

    func installItem(
        sourceKey: String,
        targets: [HarnessTargetParams],
        replaceExisting: Bool,
        allowCopyFallback: Bool
    ) async -> HarnessMutationResult? {
        guard let commandBus else { return nil }
        do {
            let result: HarnessMutationResult = try await commandBus.call(
                method: "harness.catalog.install.apply",
                params: ApplyInstallHarnessParams(
                    sourceKey: sourceKey,
                    targets: targets,
                    replaceExisting: replaceExisting,
                    allowCopyFallback: allowCopyFallback
                )
            )
            await refresh(select: result.sourceKey)
            loadSelectedItem()
            return result
        } catch {
            actionError = error.localizedDescription
            scheduleDismissActionError()
            return nil
        }
    }

    func revealInstall(_ install: HarnessInstall) {
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: install.rootPath)])
    }

    func reinstallInstall(_ install: HarnessInstall, from item: HarnessCatalogItem) {
        guard install.removalPolicy == "delete_target" else { return }
        Task { [weak self] in
            _ = await self?.installItem(
                sourceKey: item.sourceKey,
                targets: [HarnessTargetParams(tool: install.tool, scope: install.scope)],
                replaceExisting: true,
                allowCopyFallback: true
            )
        }
    }

    func removeInstall(_ install: HarnessInstall, from item: HarnessCatalogItem) {
        guard install.removalPolicy != "source", let commandBus else { return }
        Task { [weak self] in
            guard let self else { return }
            do {
                let _: OkResponse = try await commandBus.call(
                    method: "harness.catalog.install.remove",
                    params: RemoveHarnessInstallParams(
                        sourceKey: item.sourceKey,
                        targetPath: install.path
                    )
                )
                await self.refresh(select: item.sourceKey)
            } catch {
                self.actionError = error.localizedDescription
                self.scheduleDismissActionError()
            }
        }
    }

    private func scheduleDismissActionError() {
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(5))
            self?.actionError = nil
        }
    }

    private func handleCatalogUpdatedEvent() async {
        let selection = selectedSourceKey
        await refresh(select: selection)
        if hasUnsavedChanges {
            diskChangeMessage = "Harness source changed on disk. Refresh after saving or discarding edits."
        } else if selection != nil {
            loadSelectedItem()
        }
    }
}

// MARK: - NSView wrapper

final class HarnessConfigPaneView: NSView, PaneContent {
    let paneID = PaneID()
    let paneType = "harness_config"
    let shouldPersist = true
    var title: String { "Harness Config" }

    init(frame: NSRect, chromeContext: PaneChromeContext = .standard) {
        super.init(frame: frame)
        _ = addSwiftUISubview(HarnessConfigView(), chromeContext: chromeContext)
    }

    required init?(coder: NSCoder) { fatalError() }
}
