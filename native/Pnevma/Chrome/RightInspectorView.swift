import AppKit
import SwiftUI
import Observation

private enum RightInspectorLayout {
    static let railMinWidth: CGFloat = DesignTokens.Layout.rightInspectorMinWidth
    static let railContentInset: CGFloat = DesignTokens.Spacing.sm
    static let overlayAbsoluteMaxWidth: CGFloat = 920
    static let overlayAbsoluteMaxHeight: CGFloat = 760
    static let overlayPadding: CGFloat = 32

    /// Cap overlay at 70% of window dimensions for smaller screens.
    static func overlayMaxWidth(for windowWidth: CGFloat) -> CGFloat {
        min(overlayAbsoluteMaxWidth, windowWidth * 0.7)
    }

    static func overlayMaxHeight(for windowHeight: CGFloat) -> CGFloat {
        min(overlayAbsoluteMaxHeight, windowHeight * 0.7)
    }
}

private func inspectorIdentifierComponent(_ value: String) -> String {
    let lowered = value.lowercased()
    let mapped = lowered.map { character -> Character in
        character.isLetter || character.isNumber ? character : "_"
    }
    return String(mapped)
}

@Observable
@MainActor
final class RightInspectorChromeState {
    var isVisible = true
    var overlayHitRect: CGRect = .zero
}

private struct RightInspectorOverlayFramePreferenceKey: PreferenceKey {
    nonisolated(unsafe) static var defaultValue: CGRect = .zero

    static func reduce(value: inout CGRect, nextValue: () -> CGRect) {
        value = nextValue()
    }
}

struct RenderedDiffDocument {
    let text: NSAttributedString
    let lineBackgroundColors: [NSColor?]
}

enum RightInspectorDiffRenderer {
    static let overlayPrimaryTextColor = NSColor.labelColor.withAlphaComponent(DesignTokens.TextOpacity.primary)
    static let overlaySecondaryTextColor = NSColor.labelColor.withAlphaComponent(DesignTokens.TextOpacity.secondary)
    static let overlayHeaderBackgroundColor = NSColor.labelColor.withAlphaComponent(0.12)

    static func render(diffFile: DiffFile) -> RenderedDiffDocument {
        let attributed = NSMutableAttributedString()
        let bodyFont = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        let headerFont = NSFont.monospacedSystemFont(ofSize: 12, weight: .medium)
        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.lineHeightMultiple = 1.05
        var lineBackgroundColors: [NSColor?] = []

        let headerAttributes: [NSAttributedString.Key: Any] = [
            .font: headerFont,
            .foregroundColor: overlaySecondaryTextColor,
            .paragraphStyle: paragraphStyle,
        ]

        for (hunkIndex, hunk) in diffFile.hunks.enumerated() {
            attributed.append(NSAttributedString(string: hunk.header + "\n", attributes: headerAttributes))
            lineBackgroundColors.append(overlayHeaderBackgroundColor)

            for line in hunk.lines {
                attributed.append(
                    NSAttributedString(
                        string: prefix(for: line) + line.content + "\n",
                        attributes: lineAttributes(for: line, font: bodyFont, paragraphStyle: paragraphStyle)
                    )
                )
                lineBackgroundColors.append(backgroundColor(for: line))
            }

            if hunkIndex < diffFile.hunks.count - 1 {
                attributed.append(
                    NSAttributedString(
                        string: "\n",
                        attributes: [
                            .font: bodyFont,
                            .foregroundColor: overlayPrimaryTextColor,
                            .paragraphStyle: paragraphStyle,
                        ]
                    )
                )
                lineBackgroundColors.append(nil)
            }
        }

        return RenderedDiffDocument(text: attributed, lineBackgroundColors: lineBackgroundColors)
    }

    private static func prefix(for line: DiffLine) -> String {
        switch line.type {
        case .addition:
            return "+"
        case .deletion:
            return "-"
        case .context:
            return " "
        }
    }

    private static func lineAttributes(
        for line: DiffLine,
        font: NSFont,
        paragraphStyle: NSParagraphStyle
    ) -> [NSAttributedString.Key: Any] {
        return [
            .font: font,
            .foregroundColor: overlayPrimaryTextColor,
            .paragraphStyle: paragraphStyle,
        ]
    }

    private static func backgroundColor(for line: DiffLine) -> NSColor? {
        switch line.type {
        case .addition:
            return NSColor.systemGreen.withAlphaComponent(0.12)
        case .deletion:
            return NSColor.systemRed.withAlphaComponent(0.12)
        case .context:
            return nil
        }
    }
}

struct RightInspectorView: View {
    @Bindable var workspaceManager: WorkspaceManager
    let onStateChanged: () -> Void
    let onClose: () -> Void
    let fileBrowserViewModel: FileBrowserViewModel
    let workspaceChangesViewModel: WorkspaceChangesViewModel
    let reviewViewModel: ReviewViewModel
    let mergeQueueViewModel: MergeQueueViewModel

    init(
        workspaceManager: WorkspaceManager,
        onStateChanged: @escaping () -> Void,
        onClose: @escaping () -> Void,
        fileBrowserViewModel: FileBrowserViewModel,
        workspaceChangesViewModel: WorkspaceChangesViewModel,
        reviewViewModel: ReviewViewModel,
        mergeQueueViewModel: MergeQueueViewModel
    ) {
        self.workspaceManager = workspaceManager
        self.onStateChanged = onStateChanged
        self.onClose = onClose
        self.fileBrowserViewModel = fileBrowserViewModel
        self.workspaceChangesViewModel = workspaceChangesViewModel
        self.reviewViewModel = reviewViewModel
        self.mergeQueueViewModel = mergeQueueViewModel
    }

    private var sectionBinding: Binding<RightInspectorSection> {
        Binding(
            get: { workspaceManager.activeWorkspace?.rightInspectorSection ?? .files },
            set: { newValue in
                workspaceManager.activeWorkspace?.rightInspectorSection = newValue
                onStateChanged()
            }
        )
    }

    private var supportsProjectTools: Bool {
        workspaceManager.activeWorkspace?.showsProjectToolsInUI == true
    }

    var body: some View {
        VStack(spacing: 0) {
            if supportsProjectTools {
                inspectorSectionTabs
                Divider()
                sectionContent
            } else {
                EmptyStateView(
                    icon: "sidebar.right",
                    title: "No project open",
                    message: "Open a project workspace to browse files, changes, and review tasks."
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private var sectionContent: some View {
        switch sectionBinding.wrappedValue {
        case .files:
            InspectorFilesSection(viewModel: fileBrowserViewModel)
        case .changes:
            InspectorChangesSection(viewModel: workspaceChangesViewModel)
        case .review, .mergeQueue:
            // Fallback: persisted .review/.mergeQueue sections gracefully redirect to files
            InspectorFilesSection(viewModel: fileBrowserViewModel)
        }
    }

    private var inspectorSectionTabs: some View {
        HStack(spacing: DesignTokens.Spacing.xs) {
            ForEach(RightInspectorSection.tabBarCases, id: \.self) { section in
                Button {
                    sectionBinding.wrappedValue = section
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: section.icon)
                            .font(.system(size: 10, weight: .semibold))
                        Text(section.title)
                            .font(.system(size: 11, weight: .medium))
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(
                        Capsule(style: .continuous)
                            .fill(sectionBinding.wrappedValue == section ? ChromeSurfaceStyle.pane.selectionColor : Color.clear)
                    )
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("right-inspector-tab-\(section.rawValue)")
            }

            Spacer(minLength: 0)

            Button {
                onClose()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(width: 24, height: 24)
            }
            .contentShape(Rectangle())
            .buttonStyle(.plain)
            .help("Close inspector")
            .padding(.trailing, 4)
        }
        .padding(.horizontal, DesignTokens.Spacing.sm)
        .padding(.vertical, DesignTokens.Spacing.xs)
        .background(ChromeSurfaceStyle.toolbar.color)
    }
}

struct RightInspectorOverlayView: View {
    @Environment(GhosttyThemeProvider.self) private var theme
    @Bindable var workspaceManager: WorkspaceManager
    @Bindable var chromeState: RightInspectorChromeState
    let fileBrowserViewModel: FileBrowserViewModel
    let workspaceChangesViewModel: WorkspaceChangesViewModel
    let reviewViewModel: ReviewViewModel
    let mergeQueueViewModel: MergeQueueViewModel
    let onVisibilityChanged: (Bool) -> Void
    let onHitRectChanged: (CGRect) -> Void

    private var supportsProjectTools: Bool {
        workspaceManager.activeWorkspace?.showsProjectToolsInUI == true
    }

    private var activeSection: RightInspectorSection {
        workspaceManager.activeWorkspace?.rightInspectorSection ?? .files
    }

    private var showsOverlay: Bool {
        guard chromeState.isVisible, supportsProjectTools else { return false }
        return switch activeSection {
        case .files:
            fileBrowserViewModel.selectedFilePath != nil || fileBrowserViewModel.isLoadingPreview
        case .changes:
            workspaceChangesViewModel.isShowingPreview
        case .review:
            reviewViewModel.selectedTaskID != nil || reviewViewModel.isLoadingPack || reviewViewModel.isLoadingDiff
        case .mergeQueue:
            false
        }
    }

    var body: some View {
        GeometryReader { geometry in
            if showsOverlay {
                ZStack {
                    Color.black.opacity(0.18)
                        .ignoresSafeArea()
                        .allowsHitTesting(false)

                    overlayCard(in: geometry.size)
                        .background(
                            GeometryReader { proxy in
                                Color.clear.preference(
                                    key: RightInspectorOverlayFramePreferenceKey.self,
                                    value: proxy.frame(in: .named("rightInspectorOverlaySpace"))
                                )
                            }
                        )
                }
                .transition(.opacity)
            }
        }
        .coordinateSpace(name: "rightInspectorOverlaySpace")
        .allowsHitTesting(showsOverlay)
        .animation(ChromeMotion.animation(for: .overlay), value: showsOverlay)
        .onAppear {
            onVisibilityChanged(showsOverlay)
            let hitRect = showsOverlay ? chromeState.overlayHitRect : .zero
            onHitRectChanged(hitRect)
        }
        .onChange(of: showsOverlay) { _, newValue in
            if !newValue {
                chromeState.overlayHitRect = .zero
            }
            onVisibilityChanged(newValue)
            onHitRectChanged(newValue ? chromeState.overlayHitRect : .zero)
        }
        .onPreferenceChange(RightInspectorOverlayFramePreferenceKey.self) { newValue in
            let hitRect = showsOverlay ? newValue : .zero
            chromeState.overlayHitRect = hitRect
            onHitRectChanged(hitRect)
        }
    }

    @ViewBuilder
    private func overlayCard(in size: CGSize) -> some View {
        let width = max(520, min(RightInspectorLayout.overlayMaxWidth(for: size.width), size.width - RightInspectorLayout.overlayPadding * 2))
        let height = max(420, min(RightInspectorLayout.overlayMaxHeight(for: size.height), size.height - RightInspectorLayout.overlayPadding * 2))
        let cardBackgroundOpacity = min(1.0, max(0.96, theme.backgroundOpacity))
        let cardBackgroundColor = Color(nsColor: theme.backgroundColor).opacity(cardBackgroundOpacity)

        Group {
            switch activeSection {
            case .files:
                InspectorFilePreviewOverlay(viewModel: fileBrowserViewModel)
            case .changes:
                InspectorChangePreviewOverlay(viewModel: workspaceChangesViewModel)
            case .review:
                InspectorReviewOverlay(viewModel: reviewViewModel)
            case .mergeQueue:
                EmptyView()
            }
        }
        .frame(width: width, height: height)
        .contentShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(cardBackgroundColor)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08))
        )
        .shadow(color: Color.black.opacity(0.18), radius: 28, y: 18)
    }
}

@MainActor @ViewBuilder
private func overlayCloseButton(action: @escaping () -> Void) -> some View {
    _OverlayCloseButton(action: action)
}

private struct _OverlayCloseButton: View {
    let action: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: "xmark")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(isHovering ? Color.red : Color.secondary)
                .frame(width: 28, height: 28)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
    }
}

private struct InspectorFilesSection: View {
    @Bindable var viewModel: FileBrowserViewModel
    @State private var isReaderMode = false
    @State private var showDiscardAlert = false
    @State private var pendingAction: PendingFileAction?

    private enum PendingFileAction {
        case select(FileNode)
        case dismiss
    }

    private var isMarkdownFile: Bool {
        guard let path = viewModel.selectedFilePath else { return false }
        return (path as NSString).pathExtension.lowercased() == "md"
    }

    private var isReadOnly: Bool {
        viewModel.isBinary || viewModel.isTruncated
    }

    private var fileCountLabel: String {
        viewModel.hasActiveSearch
            ? "\(viewModel.visibleRootNodes.count) matches"
            : "\(viewModel.visibleRootNodes.count) items"
    }

    var body: some View {
        VStack(spacing: 0) {
            inspectorFileSearchBar
            Divider()

            Group {
                if let waitingMessage = viewModel.projectStatusMessage {
                    progressState(waitingMessage)
                } else if viewModel.isLoadingRoot {
                    progressState("Loading files...")
                } else if viewModel.isSearching && viewModel.visibleRootNodes.isEmpty {
                    progressState("Searching files...")
                } else if viewModel.hasActiveSearch && viewModel.visibleRootNodes.isEmpty {
                    EmptyStateView(
                        icon: "magnifyingglass",
                        title: "No matching files",
                        message: "Try a different file name or path."
                    )
                } else if viewModel.visibleRootNodes.isEmpty {
                    EmptyStateView(
                        icon: "folder",
                        title: "No files found",
                        message: "This project has no visible files yet."
                    )
                } else {
                    InspectorFileTreeList(viewModel: viewModel) { node in
                        handleFileSelect(node)
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(minWidth: RightInspectorLayout.railMinWidth, maxWidth: .infinity, maxHeight: .infinity)
        .overlay(alignment: .bottom) { ErrorBanner(message: viewModel.actionError) }
        .alert("Unsaved Changes", isPresented: $showDiscardAlert) {
            Button("Discard", role: .destructive) {
                viewModel.discardChanges()
                performPendingAction()
            }
            Button("Save") {
                viewModel.saveFile {
                    performPendingAction()
                }
            }
            Button("Cancel", role: .cancel) {
                pendingAction = nil
            }
        } message: {
            Text("You have unsaved changes. What would you like to do?")
        }
        .task { await viewModel.activate() }
    }

    private var inspectorFileSearchBar: some View {
        HStack(spacing: DesignTokens.Spacing.sm) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)

            TextField("Search files...", text: $viewModel.searchQuery)
                .textFieldStyle(.plain)
                .onChange(of: viewModel.searchQuery) {
                    viewModel.searchQueryDidChange()
                }
                .onSubmit {
                    viewModel.searchQueryDidChange(immediate: true)
                }

            if viewModel.isSearching {
                ProgressView()
                    .controlSize(.small)
            }

            if viewModel.hasActiveSearch {
                Button {
                    viewModel.clearSearch()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear file search")
                .help("Clear file search")
            }

            Spacer(minLength: DesignTokens.Spacing.sm)

            Text(fileCountLabel)
                .font(.caption)
                .foregroundStyle(.secondary)

            Button(action: viewModel.refresh) {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.plain)
            .help("Refresh files")
        }
        .padding(.horizontal, DesignTokens.Spacing.md)
        .padding(.vertical, DesignTokens.Spacing.sm)
    }

    private var filePreviewFlyout: some View {
        VStack(spacing: 0) {
            filePreviewToolbar
            Divider()

            if isReaderMode && isMarkdownFile {
                MarkdownReaderView(content: viewModel.editableContent)
            } else if viewModel.isBinary {
                ScrollView {
                    Text(viewModel.previewContent ?? "")
                        .font(.system(.body, design: .monospaced))
                        .textSelection(.enabled)
                        .padding(DesignTokens.Spacing.md)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            } else if viewModel.isTruncated {
                ScrollView {
                    Text(viewModel.previewContent ?? "")
                        .font(.system(.body, design: .monospaced))
                        .textSelection(.enabled)
                        .padding(DesignTokens.Spacing.md)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            } else if viewModel.previewContent != nil {
                TextEditor(text: $viewModel.editableContent)
                    .font(.system(.body, design: .monospaced))
                    .scrollContentBackground(.hidden)
                    .padding(.horizontal, 4)
            } else if viewModel.isLoadingPreview {
                progressState("Loading preview...")
            } else if viewModel.selectedFilePath != nil {
                EmptyStateView(icon: "doc", title: "Preview unavailable")
            } else {
                EmptyStateView(icon: "doc.text", title: "Select a file", message: "Choose a file to inspect it here.")
            }
        }
        .onChange(of: viewModel.selectedFilePath) {
            isReaderMode = false
        }
    }

    private var filePreviewToolbar: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.sm) {
            HStack(spacing: DesignTokens.Spacing.sm) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(viewModel.selectedFilePath ?? "File Preview")
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)

                    if viewModel.isDirty {
                        HStack(spacing: 6) {
                            Circle()
                                .fill(Color.orange)
                                .frame(width: 6, height: 6)
                            Text("Modified")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    } else if viewModel.isTruncated {
                        Label("Truncated", systemImage: "exclamationmark.triangle.fill")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Spacer()

                if isMarkdownFile {
                    Button(isReaderMode ? "Source" : "Reader") {
                        isReaderMode.toggle()
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }

                if viewModel.isDirty {
                    Button("Discard") {
                        viewModel.discardChanges()
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }

                Button {
                    viewModel.saveFile()
                } label: {
                    if viewModel.isSaving {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Text("Save")
                    }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .disabled(!viewModel.isDirty || viewModel.isSaving || isReadOnly)

                Button(action: requestDismissPreview) {
                    Image(systemName: "xmark")
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Close file preview")
                .help("Close preview")
            }
        }
        .padding(.horizontal, DesignTokens.Spacing.md)
        .padding(.vertical, DesignTokens.Spacing.sm)
    }

    private func progressState(_ message: String) -> some View {
        VStack(spacing: DesignTokens.Spacing.sm) {
            ProgressView()
            Text(message)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func handleFileSelect(_ node: FileNode) {
        guard !node.isDirectory else { return }
        if viewModel.isDirty {
            pendingAction = .select(node)
            showDiscardAlert = true
        } else {
            viewModel.select(node)
        }
    }

    private func requestDismissPreview() {
        if viewModel.isDirty {
            pendingAction = .dismiss
            showDiscardAlert = true
        } else {
            viewModel.clearSelection()
            isReaderMode = false
        }
    }

    private func performPendingAction() {
        guard let pendingAction else { return }
        self.pendingAction = nil

        switch pendingAction {
        case .select(let node):
            viewModel.select(node)
        case .dismiss:
            viewModel.clearSelection()
            isReaderMode = false
        }
    }
}

private struct InspectorFileTreeList: View {
    let viewModel: FileBrowserViewModel
    let onSelect: (FileNode) -> Void

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(viewModel.visibleRootNodes) { node in
                    InspectorFileTreeRow(node: node, depth: 0, viewModel: viewModel, onSelect: onSelect)
                }
            }
            .padding(.vertical, 4)
        }
        .padding(.horizontal, RightInspectorLayout.railContentInset)
        .padding(.vertical, DesignTokens.Spacing.xs)
    }
}

private struct InspectorFileTreeRow: View {
    let node: FileNode
    let depth: Int
    let viewModel: FileBrowserViewModel
    let onSelect: (FileNode) -> Void

    private var isSelected: Bool {
        viewModel.selectedPath == node.path
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                if node.isDirectory && !viewModel.hasActiveSearch {
                    Button {
                        viewModel.toggleDirectory(node)
                    } label: {
                        Image(systemName: viewModel.isExpanded(node.path) ? "chevron.down" : "chevron.right")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .frame(width: 12, height: 12)
                    }
                    .buttonStyle(.plain)
                } else {
                    Image(systemName: node.isDirectory ? "chevron.down" : "circle.fill")
                        .font(.system(size: node.isDirectory ? 10 : 3, weight: .semibold))
                        .foregroundStyle(.tertiary)
                        .frame(width: 12, height: 12)
                        .accessibilityHidden(true)
                }

                Image(systemName: fileTypeIcon(for: node))
                    .foregroundStyle(node.isDirectory ? Color.accentColor : fileTypeColor(for: node))
                    .frame(width: 16)

                Text(node.name)
                    .font(.system(.body, design: .monospaced))
                    .lineLimit(1)

                Spacer(minLength: 8)
            }
            .padding(.leading, CGFloat(depth) * DesignTokens.Layout.treeIndent + DesignTokens.Spacing.sm)
            .padding(.trailing, DesignTokens.Spacing.sm)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(isSelected ? Color.accentColor.opacity(0.12) : .clear)
            )
            .contentShape(Rectangle())
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("right-inspector-file-row-\(inspectorIdentifierComponent(node.path))")
            .onTapGesture {
                if node.isDirectory && !viewModel.hasActiveSearch {
                    viewModel.toggleDirectory(node)
                } else {
                    onSelect(node)
                }
            }

            if node.isDirectory && viewModel.shouldShowChildren(for: node), let children = node.children {
                ForEach(children) { child in
                    InspectorFileTreeRow(node: child, depth: depth + 1, viewModel: viewModel, onSelect: onSelect)
                }
            }
        }
    }

    private func fileTypeIcon(for node: FileNode) -> String {
        if node.isDirectory { return "folder.fill" }
        let ext = (node.name as NSString).pathExtension.lowercased()
        switch ext {
        case "swift": return "swift"
        case "rs": return "gearshape.2"
        case "ts", "tsx", "js", "jsx": return "chevron.left.forwardslash.chevron.right"
        case "json": return "curlybraces"
        case "md": return "doc.richtext"
        case "toml", "yaml", "yml": return "gearshape"
        case "png", "jpg", "jpeg", "gif", "svg": return "photo"
        case "lock": return "lock"
        default: return "doc"
        }
    }

    private func fileTypeColor(for node: FileNode) -> Color {
        let ext = (node.name as NSString).pathExtension.lowercased()
        switch ext {
        case "swift": return .orange
        case "rs": return Color(nsColor: .systemBrown)
        case "ts", "tsx": return .blue
        case "js", "jsx": return .yellow
        case "json": return .purple
        case "md": return .cyan
        case "png", "jpg", "jpeg", "gif", "svg": return .green
        default: return .secondary
        }
    }
}

private struct InspectorChangesSection: View {
    @Bindable var viewModel: WorkspaceChangesViewModel
    @State private var commitMessage = ""
    @State private var isCommitting = false

    var body: some View {
        VStack(spacing: 0) {
            sectionToolbar(
                subtitle: viewModel.summaryLabel,
                onRefresh: { viewModel.refresh() }
            )

            Divider()

            Group {
                if let statusMessage = viewModel.statusMessage {
                    EmptyStateView(icon: "point.3.connected.trianglepath.dotted", title: statusMessage)
                } else if viewModel.isLoadingChanges {
                    loadingPane("Loading changes...")
                } else if viewModel.changes.isEmpty {
                    EmptyStateView(
                        icon: "checkmark.circle",
                        title: "Working tree is clean",
                        message: "No local changes were found for this project."
                    )
                } else {
                    InspectorChangesList(
                        changes: viewModel.changes,
                        selectedPath: viewModel.selectedPath,
                        onSelect: { path in
                            viewModel.selectPath(path, presentPreview: true)
                        }
                    )
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(minWidth: RightInspectorLayout.railMinWidth, maxWidth: .infinity, maxHeight: .infinity)
        .overlay(alignment: .bottom) { ErrorBanner(message: viewModel.actionError) }
        .task { await viewModel.activate() }
    }

    private var changePreviewFlyout: some View {
        VStack(spacing: 0) {
            HStack(spacing: DesignTokens.Spacing.sm) {
                Text(viewModel.selectedPath ?? "Change Preview")
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)

                Spacer()

                Button(action: viewModel.clearSelection) {
                    Image(systemName: "xmark")
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Close diff preview")
                .help("Close diff")
            }
            .padding(.horizontal, DesignTokens.Spacing.md)
            .padding(.vertical, DesignTokens.Spacing.sm)

            Divider()

            if viewModel.isLoadingDiff {
                loadingPane("Loading diff...")
            } else if let diffFile = viewModel.selectedDiffFile {
                SelectableDiffDocumentView(diffFile: diffFile)
            } else if let diffError = viewModel.diffError {
                EmptyStateView(
                    icon: "exclamationmark.triangle",
                    title: "Diff load failed",
                    message: diffError
                )
            } else if viewModel.selectedPath != nil {
                EmptyStateView(
                    icon: "doc.text.magnifyingglass",
                    title: "Diff unavailable",
                    message: "No diff output is available for the selected path."
                )
            } else {
                EmptyStateView(
                    icon: "doc.text.magnifyingglass",
                    title: "Select a change",
                    message: "Choose a changed path to inspect the patch."
                )
            }
        }
    }

    private func loadingPane(_ message: String) -> some View {
        VStack(spacing: DesignTokens.Spacing.sm) {
            ProgressView()
            Text(message)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct InspectorChangesList: View {
    let changes: [WorkspaceChangeItem]
    let selectedPath: String?
    let onSelect: (String) -> Void

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(Array(changes.enumerated()), id: \.element.id) { index, change in
                    InspectorChangeRow(
                        change: change,
                        isSelected: selectedPath == change.path,
                        onSelect: { onSelect(change.path) }
                    )
                    .padding(.horizontal, RightInspectorLayout.railContentInset)

                    if index < changes.count - 1 {
                        Divider()
                            .padding(.leading, RightInspectorLayout.railContentInset + 42)
                    }
                }
            }
            .padding(.vertical, DesignTokens.Spacing.xs)
        }
        .scrollIndicators(.hidden)
    }
}

private struct InspectorChangeRow: View {
    let change: WorkspaceChangeItem
    let isSelected: Bool
    let onSelect: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: 10) {
                InspectorChangeStatusBadge(
                    symbolName: statusSymbolName,
                    tintColor: statusColor
                )

                VStack(alignment: .leading, spacing: 2) {
                    Text(fileName)
                        .font(.system(size: 13, weight: isSelected ? .semibold : .regular))
                        .lineLimit(1)

                    Text(secondaryLabel)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer(minLength: DesignTokens.Spacing.sm)

                if hasDiffStats {
                    DiffStatsChip(
                        insertions: Int(clamping: change.additions ?? 0),
                        deletions: Int(clamping: change.deletions ?? 0)
                    )
                } else {
                    Text(statusLabel.uppercased())
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(statusColor)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(rowBackground)
            .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.plain)
        .help(change.path)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityIdentifier("right-inspector-change-row-\(inspectorIdentifierComponent(change.path))")
        .onHover { isHovering = $0 }
    }

    private var fileName: String {
        (change.path as NSString).lastPathComponent
    }

    private var directoryPath: String? {
        let directory = (change.path as NSString).deletingLastPathComponent
        return directory.isEmpty || directory == "." ? nil : directory
    }

    private var hasDiffStats: Bool {
        (change.additions ?? 0) > 0 || (change.deletions ?? 0) > 0
    }

    private var secondaryLabel: String {
        guard let directoryPath else { return statusLabel }
        return "\(directoryPath) · \(statusLabel)"
    }

    private var statusLabel: String {
        let normalized = change.status.replacingOccurrences(of: " ", with: "")
        if change.conflicted { return "Conflict" }
        if normalized.contains("R") { return "Renamed" }
        if normalized.contains("D") { return "Deleted" }
        if change.untracked || normalized == "??" { return "New file" }
        if change.staged && change.modified { return "Partially staged" }
        if normalized.contains("A") { return "Added" }
        if change.staged { return "Staged" }
        return "Modified"
    }

    private var statusSymbolName: String {
        let normalized = change.status.replacingOccurrences(of: " ", with: "")
        if change.conflicted { return "exclamationmark.triangle.fill" }
        if normalized.contains("R") { return "arrow.left.arrow.right.circle.fill" }
        if normalized.contains("D") { return "minus.circle.fill" }
        if change.untracked || normalized == "??" { return "plus.circle.fill" }
        if change.staged && change.modified { return "circle.lefthalf.filled" }
        if normalized.contains("A") { return "plus.circle.fill" }
        if change.staged { return "checkmark.circle.fill" }
        return "pencil.circle.fill"
    }

    private var statusColor: Color {
        let normalized = change.status.replacingOccurrences(of: " ", with: "")
        if change.conflicted || normalized.contains("D") { return .red }
        if change.untracked || normalized == "??" || normalized.contains("A") { return .green }
        if change.staged { return .blue }
        return .orange
    }

    @ViewBuilder
    private var rowBackground: some View {
        RoundedRectangle(cornerRadius: 8, style: .continuous)
            .fill(
                isSelected
                    ? ChromeSurfaceStyle.pane.selectionColor
                    : Color.primary.opacity(isHovering ? 0.06 : 0)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(Color.primary.opacity(isSelected ? 0.08 : 0))
            )
    }
}

private struct InspectorChangeStatusBadge: View {
    let symbolName: String
    let tintColor: Color

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(tintColor.opacity(0.16))

            Image(systemName: symbolName)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(tintColor)
        }
        .frame(width: 24, height: 24)
        .accessibilityHidden(true)
    }
}

private struct InspectorReviewSection: View {
    @Bindable var viewModel: ReviewViewModel

    private var summaryLabel: String {
        "\(viewModel.reviewTasks.count) pending"
    }

    var body: some View {
        VStack(spacing: 0) {
            sectionToolbar(
                subtitle: summaryLabel,
                onRefresh: { viewModel.refresh() }
            )

            Divider()

            Group {
                if let statusMessage = viewModel.statusMessage {
                    EmptyStateView(icon: "checklist", title: statusMessage)
                } else if viewModel.reviewTasks.isEmpty {
                    EmptyStateView(
                        icon: "checkmark.circle",
                        title: "No review tasks",
                        message: "Tasks that need approval will appear here."
                    )
                } else {
                    List(viewModel.reviewTasks, selection: $viewModel.selectedTaskID) { task in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(task.title)
                                .lineLimit(2)
                            if let cost = task.costUsd {
                                Text(cost, format: .currency(code: "USD"))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .padding(.vertical, 4)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .tag(task.id)
                        .accessibilityAddTraits(.isButton)
                    }
                    .listStyle(.plain)
                    .listRowInsets(
                        EdgeInsets(
                            top: DesignTokens.Spacing.sm,
                            leading: DesignTokens.Spacing.md,
                            bottom: DesignTokens.Spacing.sm,
                            trailing: DesignTokens.Spacing.md
                        )
                    )
                    .padding(.horizontal, RightInspectorLayout.railContentInset)
                    .padding(.vertical, DesignTokens.Spacing.xs)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(minWidth: RightInspectorLayout.railMinWidth, maxWidth: .infinity, maxHeight: .infinity)
        .overlay(alignment: .bottom) { ErrorBanner(message: viewModel.actionError) }
        .task { await viewModel.activate() }
    }

    @ViewBuilder
    private var reviewFlyout: some View {
        if viewModel.isLoadingPack {
            VStack(spacing: 0) {
                reviewToolbar(title: viewModel.selectedTaskTitle ?? "Review")
                Divider()
                VStack(spacing: DesignTokens.Spacing.sm) {
                    ProgressView("Loading review pack...")
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        } else if let pack = viewModel.reviewPack {
            VStack(spacing: 0) {
                reviewToolbar(title: viewModel.selectedTaskTitle ?? pack.taskId)
                Divider()

                ScrollView {
                    VStack(alignment: .leading, spacing: DesignTokens.Spacing.md) {
                        VStack(alignment: .leading, spacing: DesignTokens.Spacing.xs) {
                            Text(pack.status)
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(.secondary)
                            Text(pack.reviewPackPath)
                                .font(.system(.caption, design: .monospaced))
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                                .lineLimit(2)
                        }

                        GroupBox("Review Pack") {
                            VStack(alignment: .leading, spacing: DesignTokens.Spacing.sm) {
                                LabeledContent("Path", value: pack.reviewPackPath)
                                if let approvedAt = pack.approvedAt {
                                    LabeledContent("Approved At", value: approvedAt)
                                }
                            }
                            .font(.system(.body, design: .monospaced))
                            .textSelection(.enabled)
                        }

                        if !viewModel.criteria.isEmpty {
                            GroupBox("Acceptance Criteria") {
                                VStack(alignment: .leading, spacing: DesignTokens.Spacing.sm) {
                                    ForEach(viewModel.criteria.indices, id: \.self) { index in
                                        Toggle(viewModel.criteria[index].description, isOn: $viewModel.criteria[index].met)
                                            .toggleStyle(.checkbox)
                                    }
                                }
                                .padding(.vertical, 4)
                            }
                        }

                        GroupBox("Changed Files") {
                            VStack(alignment: .leading, spacing: DesignTokens.Spacing.sm) {
                                if !viewModel.diffFiles.isEmpty {
                                    ScrollView(.horizontal) {
                                        HStack(spacing: DesignTokens.Spacing.sm) {
                                            ForEach(viewModel.diffFiles) { file in
                                                Button(file.path) {
                                                    viewModel.selectedDiffFilePath = file.path
                                                }
                                                .buttonStyle(.bordered)
                                                .controlSize(.small)
                                                .tint(viewModel.selectedDiffFilePath == file.path ? .accentColor : .secondary)
                                            }
                                        }
                                    }
                                    .scrollIndicators(.hidden)
                                }

                                if let diffFile = viewModel.selectedDiffFile {
                                    SelectableDiffDocumentView(diffFile: diffFile)
                                        .frame(minHeight: 220)
                                        .background(
                                            RoundedRectangle(cornerRadius: 8)
                                                .fill(Color.primary.opacity(0.02))
                                        )
                                } else if viewModel.isLoadingDiff {
                                    ProgressView("Loading diff...")
                                } else if let diffError = viewModel.diffError {
                                    Text(diffError)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                } else {
                                    Text("No changed files were included in this review diff.")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            .padding(.vertical, 4)
                        }

                        GroupBox("Notes") {
                            TextField("Add notes...", text: $viewModel.notes, axis: .vertical)
                                .font(.body)
                                .lineLimit(3...6)
                        }

                        HStack {
                            Button("Reject") { viewModel.reject() }
                                .buttonStyle(.bordered)
                                .disabled(viewModel.isActing)

                            Spacer()

                            Button("Approve") { viewModel.approve() }
                                .buttonStyle(.borderedProminent)
                                .disabled(viewModel.isActing || !viewModel.allCriteriaMet)
                        }
                    }
                    .padding(DesignTokens.Spacing.md)
                }
            }
        } else if viewModel.selectedTaskID != nil {
            VStack(spacing: 0) {
                reviewToolbar(title: viewModel.selectedTaskTitle ?? "Review")
                Divider()
                EmptyStateView(
                    icon: "checklist",
                    title: "Review unavailable",
                    message: viewModel.actionError ?? "The selected review pack could not be loaded."
                )
            }
        } else {
            EmptyStateView(
                icon: "checklist",
                title: "Select a task",
                message: "Choose a review task above to inspect its pack and changes."
            )
        }
    }

    private func reviewToolbar(title: String) -> some View {
        HStack(spacing: DesignTokens.Spacing.sm) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.headline)
                    .lineLimit(1)
                if let taskID = viewModel.selectedTaskID {
                    Text(taskID)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            Spacer()

            Button(action: viewModel.clearSelection) {
                Image(systemName: "xmark")
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Close review details")
            .help("Close review details")
        }
        .padding(.horizontal, DesignTokens.Spacing.md)
        .padding(.vertical, DesignTokens.Spacing.sm)
    }
}

private struct InspectorMergeQueueSection: View {
    @Bindable var viewModel: MergeQueueViewModel
    @State private var showMergeAlert = false
    @State private var itemToMerge: MergeQueueItem? = nil

    var body: some View {
        VStack(spacing: 0) {
            sectionToolbar(
                subtitle: "\(viewModel.items.count) queued",
                onRefresh: { viewModel.load() }
            )
            Divider()
            Group {
                if let statusMessage = viewModel.statusMessage {
                    EmptyStateView(icon: "arrow.triangle.merge", title: statusMessage)
                } else if viewModel.isLoadingState {
                    loadingPane("Loading merge queue...")
                } else if viewModel.items.isEmpty {
                    EmptyStateView(
                        icon: "arrow.triangle.merge",
                        title: "Merge Queue Empty",
                        message: "No branches queued for merge"
                    )
                } else {
                    List {
                        ForEach(viewModel.items) { item in
                            MergeQueueRow(
                                item: item,
                                onMerge: { itemToMerge = item; showMergeAlert = true },
                                onMoveUp: { viewModel.reorder(taskId: item.taskId, direction: "up") },
                                onMoveDown: { viewModel.reorder(taskId: item.taskId, direction: "down") }
                            )
                        }
                    }
                    .listStyle(.plain)
                    .padding(.horizontal, RightInspectorLayout.railContentInset)
                    .padding(.vertical, DesignTokens.Spacing.xs)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(minWidth: RightInspectorLayout.railMinWidth, maxWidth: .infinity, maxHeight: .infinity)
        .overlay(alignment: .bottom) { ErrorBanner(message: viewModel.actionError) }
        .alert("Merge Branch", isPresented: $showMergeAlert, presenting: itemToMerge) { item in
            Button("Cancel", role: .cancel) {}
            Button("Merge", role: .destructive) { viewModel.merge(item) }
        } message: { item in
            Text("Merge \"\(item.taskTitle)\" into the target branch?")
        }
        .task { await viewModel.activate() }
    }

    private func loadingPane(_ message: String) -> some View {
        VStack(spacing: DesignTokens.Spacing.sm) {
            ProgressView()
            Text(message)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct InspectorFilePreviewOverlay: View {
    @Bindable var viewModel: FileBrowserViewModel
    @State private var isReaderMode = false
    @State private var showDiscardAlert = false

    private var isMarkdownFile: Bool {
        guard let path = viewModel.selectedFilePath else { return false }
        return (path as NSString).pathExtension.lowercased() == "md"
    }

    private var isReadOnly: Bool {
        viewModel.isBinary || viewModel.isTruncated
    }

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: DesignTokens.Spacing.sm) {
                HStack(spacing: DesignTokens.Spacing.sm) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(viewModel.selectedFilePath ?? "File Preview")
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .accessibilityLabel(viewModel.selectedFilePath ?? "File Preview")
                            .accessibilityIdentifier("right-inspector-overlay-title")

                        if viewModel.isDirty {
                            HStack(spacing: 6) {
                                Circle()
                                    .fill(Color.orange)
                                    .frame(width: 6, height: 6)
                                Text("Modified")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        } else if viewModel.isTruncated {
                            Label("Truncated", systemImage: "exclamationmark.triangle.fill")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }

                    Spacer()

                    if isMarkdownFile {
                        Button(isReaderMode ? "Source" : "Reader") {
                            isReaderMode.toggle()
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }

                    if viewModel.isDirty {
                        Button("Discard") {
                            viewModel.discardChanges()
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }

                    Button {
                        viewModel.saveFile()
                    } label: {
                        if viewModel.isSaving {
                            ProgressView()
                                .controlSize(.small)
                        } else {
                            Text("Save")
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .disabled(!viewModel.isDirty || viewModel.isSaving || isReadOnly)

                    overlayCloseButton(action: requestDismissPreview)
                        .accessibilityLabel("Close file preview")
                        .help("Close file preview")
                }
            }
            .padding(.horizontal, DesignTokens.Spacing.md)
            .padding(.vertical, DesignTokens.Spacing.sm)

            Divider()

            Group {
                if isReaderMode && isMarkdownFile {
                    MarkdownReaderView(content: viewModel.editableContent)
                } else if viewModel.isBinary || viewModel.isTruncated {
                    ScrollView {
                        Text(viewModel.previewContent ?? "")
                            .font(.system(.body, design: .monospaced))
                            .textSelection(.enabled)
                            .padding(DesignTokens.Spacing.md)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                } else if viewModel.previewContent != nil {
                    TextEditor(text: $viewModel.editableContent)
                        .font(.system(.body, design: .monospaced))
                        .scrollContentBackground(.hidden)
                        .padding(.horizontal, 4)
                } else if viewModel.isLoadingPreview {
                    overlayProgressState("Loading preview...")
                } else {
                    EmptyStateView(icon: "doc", title: "Preview unavailable")
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .overlay(alignment: .bottom) { ErrorBanner(message: viewModel.actionError) }
        .onChange(of: viewModel.selectedFilePath) {
            isReaderMode = false
        }
        .alert("Unsaved Changes", isPresented: $showDiscardAlert) {
            Button("Discard", role: .destructive) {
                viewModel.discardChanges()
                viewModel.clearSelection()
            }
            Button("Save") {
                viewModel.saveFile {
                    viewModel.clearSelection()
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("You have unsaved changes. What would you like to do?")
        }
    }

    private func overlayProgressState(_ message: String) -> some View {
        VStack(spacing: DesignTokens.Spacing.sm) {
            ProgressView()
            Text(message)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func requestDismissPreview() {
        if viewModel.isDirty {
            showDiscardAlert = true
        } else {
            viewModel.clearSelection()
            isReaderMode = false
        }
    }
}

private struct InspectorChangePreviewOverlay: View {
    @Bindable var viewModel: WorkspaceChangesViewModel

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: DesignTokens.Spacing.sm) {
                Text(viewModel.selectedPath ?? "Change Preview")
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .accessibilityLabel(viewModel.selectedPath ?? "Change Preview")
                    .accessibilityIdentifier("right-inspector-overlay-title")

                Spacer()

                overlayCloseButton(action: viewModel.clearSelection)
                    .accessibilityLabel("Close diff preview")
                    .help("Close diff preview")
            }
            .padding(.horizontal, DesignTokens.Spacing.md)
            .padding(.vertical, DesignTokens.Spacing.sm)

            Divider()

            Group {
                if viewModel.isLoadingDiff {
                    overlayProgressState("Loading diff...")
                } else if let diffFile = viewModel.selectedDiffFile {
                    SelectableDiffDocumentView(diffFile: diffFile)
                } else if let diffError = viewModel.diffError {
                    EmptyStateView(
                        icon: "exclamationmark.triangle",
                        title: "Diff load failed",
                        message: diffError
                    )
                } else {
                    EmptyStateView(
                        icon: "doc.text.magnifyingglass",
                        title: "Diff unavailable",
                        message: "No diff output is available for the selected path."
                    )
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func overlayProgressState(_ message: String) -> some View {
        VStack(spacing: DesignTokens.Spacing.sm) {
            ProgressView()
            Text(message)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct InspectorReviewOverlay: View {
    @Bindable var viewModel: ReviewViewModel

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: DesignTokens.Spacing.sm) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(viewModel.selectedTaskTitle ?? "Review")
                        .font(.headline)
                        .lineLimit(1)
                        .accessibilityLabel(viewModel.selectedTaskTitle ?? "Review")
                        .accessibilityIdentifier("right-inspector-overlay-title")
                    if let taskID = viewModel.selectedTaskID {
                        Text(taskID)
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }

                Spacer()

                overlayCloseButton(action: viewModel.clearSelection)
                    .accessibilityLabel("Close review details")
                    .help("Close review details")
            }
            .padding(.horizontal, DesignTokens.Spacing.md)
            .padding(.vertical, DesignTokens.Spacing.sm)

            Divider()

            reviewContent
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .overlay(alignment: .bottom) { ErrorBanner(message: viewModel.actionError) }
    }

    @ViewBuilder
    private var reviewContent: some View {
        if viewModel.isLoadingPack {
            overlayProgressState("Loading review pack...")
        } else if let pack = viewModel.reviewPack {
            ScrollView {
                VStack(alignment: .leading, spacing: DesignTokens.Spacing.md) {
                    VStack(alignment: .leading, spacing: DesignTokens.Spacing.xs) {
                        Text(pack.status)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.secondary)
                        Text(pack.reviewPackPath)
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                            .lineLimit(2)
                    }

                    GroupBox("Review Pack") {
                        VStack(alignment: .leading, spacing: DesignTokens.Spacing.sm) {
                            LabeledContent("Path", value: pack.reviewPackPath)
                            if let approvedAt = pack.approvedAt {
                                LabeledContent("Approved At", value: approvedAt)
                            }
                        }
                        .font(.system(.body, design: .monospaced))
                        .textSelection(.enabled)
                    }

                    if !viewModel.criteria.isEmpty {
                        GroupBox("Acceptance Criteria") {
                            VStack(alignment: .leading, spacing: DesignTokens.Spacing.sm) {
                                ForEach(viewModel.criteria.indices, id: \.self) { index in
                                    Toggle(viewModel.criteria[index].description, isOn: $viewModel.criteria[index].met)
                                        .toggleStyle(.checkbox)
                                }
                            }
                            .padding(.vertical, 4)
                        }
                    }

                    GroupBox("Changed Files") {
                        VStack(alignment: .leading, spacing: DesignTokens.Spacing.sm) {
                            if !viewModel.diffFiles.isEmpty {
                                ScrollView(.horizontal) {
                                    HStack(spacing: DesignTokens.Spacing.sm) {
                                        ForEach(viewModel.diffFiles) { file in
                                            Button(file.path) {
                                                viewModel.selectedDiffFilePath = file.path
                                            }
                                            .buttonStyle(.bordered)
                                            .controlSize(.small)
                                            .tint(viewModel.selectedDiffFilePath == file.path ? .accentColor : .secondary)
                                        }
                                    }
                                }
                                .scrollIndicators(.hidden)
                            }

                            if let diffFile = viewModel.selectedDiffFile {
                                SelectableDiffDocumentView(diffFile: diffFile)
                                    .frame(minHeight: 260)
                                    .background(
                                        RoundedRectangle(cornerRadius: 8)
                                            .fill(Color.primary.opacity(0.02))
                                    )
                            } else if viewModel.isLoadingDiff {
                                ProgressView("Loading diff...")
                            } else if let diffError = viewModel.diffError {
                                Text(diffError)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            } else {
                                Text("No changed files were included in this review diff.")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .padding(.vertical, 4)
                    }

                    GroupBox("Notes") {
                        TextField("Add notes...", text: $viewModel.notes, axis: .vertical)
                            .font(.body)
                            .lineLimit(3...6)
                    }

                    HStack {
                        Button("Reject") { viewModel.reject() }
                            .buttonStyle(.bordered)
                            .disabled(viewModel.isActing)

                        Spacer()

                        Button("Approve") { viewModel.approve() }
                            .buttonStyle(.borderedProminent)
                            .disabled(viewModel.isActing || !viewModel.allCriteriaMet)
                    }
                }
                .padding(DesignTokens.Spacing.md)
            }
        } else {
            EmptyStateView(
                icon: "checklist",
                title: "Review unavailable",
                message: viewModel.actionError ?? "The selected review pack could not be loaded."
            )
        }
    }

    private func overlayProgressState(_ message: String) -> some View {
        VStack(spacing: DesignTokens.Spacing.sm) {
            ProgressView(message)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct WorkspaceChangeDiffParams: Encodable {
    let path: String
}

struct WorkspaceChangeItem: Identifiable, Decodable, Hashable {
    var id: String { path }
    let path: String
    let status: String
    let modified: Bool
    let staged: Bool
    let conflicted: Bool
    let untracked: Bool
    let additions: Int64?
    let deletions: Int64?
}

private struct SelectableDiffDocumentView: NSViewRepresentable {
    let diffFile: DiffFile

    final class Coordinator {
        var lastRenderedSignature: String?
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true

        let textView = DiffDocumentTextView()
        textView.drawsBackground = false
        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = true
        textView.importsGraphics = false
        textView.usesFindBar = true
        textView.allowsUndo = false
        textView.minSize = .zero
        textView.maxSize = NSSize(
            width: CGFloat.greatestFiniteMagnitude,
            height: CGFloat.greatestFiniteMagnitude
        )
        textView.textContainerInset = NSSize(width: 14, height: 14)
        textView.isHorizontallyResizable = true
        textView.isVerticallyResizable = true
        textView.autoresizingMask = []

        if let textContainer = textView.textContainer {
            textContainer.lineFragmentPadding = 0
            textContainer.containerSize = NSSize(
                width: CGFloat.greatestFiniteMagnitude,
                height: CGFloat.greatestFiniteMagnitude
            )
            textContainer.widthTracksTextView = false
        }

        scrollView.documentView = textView
        updateTextView(textView, inside: scrollView, coordinator: context.coordinator)
        return scrollView
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
        guard let textView = nsView.documentView as? NSTextView else { return }
        updateTextView(textView, inside: nsView, coordinator: context.coordinator)
    }

    private func updateTextView(
        _ textView: NSTextView,
        inside scrollView: NSScrollView,
        coordinator: Coordinator
    ) {
        let renderedDiff = RightInspectorDiffRenderer.render(diffFile: diffFile)
        textView.textStorage?.setAttributedString(renderedDiff.text)
        (textView as? DiffDocumentTextView)?.lineBackgroundColors = renderedDiff.lineBackgroundColors
        guard let textContainer = textView.textContainer,
              let layoutManager = textView.layoutManager else { return }

        layoutManager.ensureLayout(for: textContainer)
        let usedRect = layoutManager.usedRect(for: textContainer)
        let inset = textView.textContainerInset
        let contentWidth = ceil(usedRect.width + inset.width * 2)
        let contentHeight = ceil(usedRect.height + inset.height * 2)
        let targetWidth = max(scrollView.contentSize.width, contentWidth)
        let targetHeight = max(scrollView.contentSize.height, contentHeight)
        textView.frame = NSRect(origin: .zero, size: NSSize(width: targetWidth, height: targetHeight))

        let signature = diffSignature
        if coordinator.lastRenderedSignature != signature {
            scrollView.contentView.scroll(to: .zero)
            scrollView.reflectScrolledClipView(scrollView.contentView)
            coordinator.lastRenderedSignature = signature
        }
    }

    private var diffSignature: String {
        let serializedHunks = diffFile.hunks.map { hunk in
            let serializedLines = hunk.lines.map { line in
                "\(line.type.rawValue):\(line.content)"
            }
            return ([hunk.header] + serializedLines).joined(separator: "\u{1F}")
        }
        return ([diffFile.path] + serializedHunks).joined(separator: "\u{1E}")
    }
}

private final class DiffDocumentTextView: NSTextView {
    var lineBackgroundColors: [NSColor?] = [] {
        didSet { needsDisplay = true }
    }

    override func drawBackground(in rect: NSRect) {
        guard let layoutManager, let textContainer else {
            super.drawBackground(in: rect)
            return
        }

        let glyphRange = layoutManager.glyphRange(for: textContainer)
        var lineIndex = 0

        layoutManager.enumerateLineFragments(forGlyphRange: glyphRange) { lineRect, _, _, _, _ in
            guard lineIndex < self.lineBackgroundColors.count else {
                lineIndex += 1
                return
            }

            defer { lineIndex += 1 }

            guard let fillColor = self.lineBackgroundColors[lineIndex] else { return }

            let textOrigin = self.textContainerOrigin
            var fillRect = lineRect.offsetBy(dx: textOrigin.x, dy: textOrigin.y)
            fillRect.origin.x = 0
            fillRect.size.width = self.bounds.width

            guard fillRect.intersects(rect) else { return }
            fillColor.setFill()
            fillRect.fill()
        }
    }
}

@Observable @MainActor
final class WorkspaceChangesViewModel {
    private enum ViewState: Equatable {
        case waiting(String)
        case loading(String)
        case ready
        case failed(String)
    }

    var changes: [WorkspaceChangeItem] = []
    var selectedPath: String? {
        didSet {
            guard selectedPath != oldValue else { return }
            selectedDiffFile = nil
            diffError = nil
            if let selectedPath {
                loadDiff(path: selectedPath)
            }
        }
    }
    var selectedDiffFile: DiffFile?
    var isShowingPreview = false
    var isLoadingChanges = false
    var isLoadingDiff = false
    var diffError: String?
    var actionError: String?

    private var viewState: ViewState = .waiting("Open a project to load changes.")

    var statusMessage: String? {
        switch viewState {
        case .waiting(let message), .loading(let message), .failed(let message):
            return message
        case .ready:
            return nil
        }
    }

    var summaryLabel: String {
        guard !changes.isEmpty else { return "No local changes" }
        let stagedCount = changes.count(where: \.staged)
        let modifiedCount = changes.count(where: \.modified)
        let untrackedCount = changes.count(where: \.untracked)
        var segments: [String] = ["\(changes.count) paths"]
        if stagedCount > 0 { segments.append("\(stagedCount) staged") }
        if modifiedCount > 0 { segments.append("\(modifiedCount) modified") }
        if untrackedCount > 0 { segments.append("\(untrackedCount) new") }
        return segments.joined(separator: " · ")
    }

    @ObservationIgnored
    private let commandBus: (any CommandCalling)?
    @ObservationIgnored
    private let activationHub: ActiveWorkspaceActivationHub
    @ObservationIgnored
    private var activationObserverID: UUID?
    @ObservationIgnored
    private var loadTask: Task<Void, Never>?
    @ObservationIgnored
    private var diffTask: Task<Void, Never>?
    @ObservationIgnored
    private var activationGeneration: UInt64 = 0
    @ObservationIgnored
    private var changesLoadToken: UInt64 = 0
    @ObservationIgnored
    private var diffLoadToken: UInt64 = 0

    init(
        commandBus: (any CommandCalling)? = CommandBus.shared,
        activationHub: ActiveWorkspaceActivationHub = .shared
    ) {
        self.commandBus = commandBus
        self.activationHub = activationHub
        activationObserverID = activationHub.addObserver { [weak self] state in
            Task { @MainActor [weak self] in
                self?.handleActivationState(state)
            }
        }
    }

    deinit {
        if let activationObserverID {
            activationHub.removeObserver(activationObserverID)
        }
    }

    func activate() async {
        handleActivationState(activationHub.currentState)
    }

    func refresh() {
        loadChanges(showLoadingState: true)
    }

    func selectPath(_ path: String?, presentPreview: Bool) {
        isShowingPreview = presentPreview && path != nil
        selectedPath = path
    }

    func clearSelection() {
        diffTask?.cancel()
        diffTask = nil
        diffLoadToken &+= 1
        isShowingPreview = false
        selectedPath = nil
        selectedDiffFile = nil
        diffError = nil
        isLoadingDiff = false
    }

    private func handleActivationState(_ state: ActiveWorkspaceActivationState) {
        invalidatePendingLoads()

        switch state {
        case .idle, .opening:
            clearContentState()
            viewState = .waiting("Waiting for project activation...")
        case .open:
            clearContentState()
            loadChanges(showLoadingState: changes.isEmpty)
        case .failed(_, _, let message):
            clearContentState()
            viewState = .failed(message)
        case .closed:
            clearContentState()
            viewState = .waiting("Open a project to load changes.")
        }
    }

    private func loadChanges(showLoadingState: Bool) {
        guard let bus = commandBus else {
            viewState = .failed("Change loading is unavailable because the command bus is not configured.")
            return
        }
        loadTask?.cancel()
        changesLoadToken &+= 1
        let loadToken = changesLoadToken
        let generation = activationGeneration
        isLoadingChanges = showLoadingState
        if showLoadingState, changes.isEmpty {
            viewState = .loading("Loading changes...")
        }
        loadTask = Task { [weak self] in
            guard let self else { return }
            do {
                let items: [WorkspaceChangeItem] = try await bus.call(method: "workspace.changes", params: nil)
                guard !Task.isCancelled,
                      self.activationGeneration == generation,
                      self.changesLoadToken == loadToken else { return }
                self.isLoadingChanges = false
                self.changes = items
                if let selectedPath, self.changes.contains(where: { $0.path == selectedPath }) {
                    self.selectPath(selectedPath, presentPreview: self.isShowingPreview)
                    if self.isShowingPreview {
                        self.loadDiff(path: selectedPath)
                    }
                } else {
                    self.selectPath(self.changes.first?.path, presentPreview: false)
                }
                self.viewState = .ready
            } catch {
                guard !Task.isCancelled,
                      self.activationGeneration == generation,
                      self.changesLoadToken == loadToken else { return }
                self.isLoadingChanges = false
                self.handleLoadFailure(error)
            }
        }
    }

    private func loadDiff(path: String) {
        guard let bus = commandBus else {
            diffError = "Backend connection unavailable"
            return
        }
        diffTask?.cancel()
        diffLoadToken &+= 1
        let loadToken = diffLoadToken
        let generation = activationGeneration
        isLoadingDiff = true
        diffError = nil
        diffTask = Task { [weak self] in
            guard let self else { return }
            do {
                let diffFile: DiffFile? = try await bus.call(
                    method: "workspace.change.diff",
                    params: WorkspaceChangeDiffParams(path: path)
                )
                guard !Task.isCancelled,
                      self.activationGeneration == generation,
                      self.diffLoadToken == loadToken,
                      self.selectedPath == path else { return }
                self.selectedDiffFile = diffFile
                self.isLoadingDiff = false
            } catch {
                guard !Task.isCancelled,
                      self.activationGeneration == generation,
                      self.diffLoadToken == loadToken,
                      self.selectedPath == path else { return }
                self.selectedDiffFile = nil
                self.diffError = error.localizedDescription
                self.isLoadingDiff = false
            }
        }
    }

    private func handleLoadFailure(_ error: Error) {
        if PnevmaError.isProjectNotReady(error) {
            viewState = .waiting("Waiting for project activation...")
            return
        }
        viewState = .failed(error.localizedDescription)
    }

    private func invalidatePendingLoads() {
        activationGeneration &+= 1
        changesLoadToken &+= 1
        diffLoadToken &+= 1
        loadTask?.cancel()
        loadTask = nil
        diffTask?.cancel()
        diffTask = nil
        isLoadingChanges = false
        isLoadingDiff = false
    }

    private func clearContentState() {
        isShowingPreview = false
        changes = []
        selectedPath = nil
        selectedDiffFile = nil
        diffError = nil
        actionError = nil
    }
}

@MainActor @ViewBuilder
private func sectionToolbar(
    subtitle: String,
    onRefresh: @escaping () -> Void
) -> some View {
    HStack(spacing: DesignTokens.Spacing.sm) {
        Text(subtitle)
            .font(.caption)
            .foregroundStyle(.secondary)

        Spacer()

        Button(action: onRefresh) {
            Image(systemName: "arrow.clockwise")
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Refresh section")
        .help("Refresh")
    }
    .padding(.horizontal, DesignTokens.Spacing.md)
    .padding(.vertical, DesignTokens.Spacing.sm)
}
