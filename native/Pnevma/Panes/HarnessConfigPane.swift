import SwiftUI
import Observation
import Cocoa

// MARK: - Data Models

struct HarnessConfigEntry: Identifiable, Decodable {
    var id: String { key }
    let key: String
    let displayName: String
    let path: String
    let format: String
    let exists: Bool
    let category: String
}

struct HarnessConfigContent: Decodable {
    let key: String
    let content: String
    let format: String
    let path: String
}

// MARK: - Backend Param Types

private struct ReadConfigParams: Encodable {
    let key: String
}

private struct WriteConfigParams: Encodable {
    let key: String
    let content: String
}

// MARK: - Category Definitions

enum ConfigCategory: String, CaseIterable, Identifiable {
    case settings
    case mcp
    case hooks
    case agents
    case skills
    case memory
    case design
    case rules

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .settings: "Settings"
        case .mcp: "MCP"
        case .hooks: "Hooks"
        case .agents: "Agents"
        case .skills: "Skills"
        case .memory: "Memory"
        case .design: "Design"
        case .rules: "Rules"
        }
    }

    var icon: String {
        switch self {
        case .settings: "gearshape"
        case .mcp: "server.rack"
        case .hooks: "arrow.triangle.branch"
        case .agents: "person.crop.circle"
        case .skills: "hammer"
        case .memory: "brain"
        case .design: "paintbrush"
        case .rules: "list.bullet.clipboard"
        }
    }

    var iconTintColor: Color {
        switch self {
        case .settings: Color(nsColor: .systemGray)
        case .mcp: Color(nsColor: .systemPurple)
        case .hooks: Color(nsColor: .systemOrange)
        case .agents: Color(nsColor: .systemBlue)
        case .skills: Color(nsColor: .systemIndigo)
        case .memory: Color(nsColor: .systemPink)
        case .design: Color(nsColor: .systemTeal)
        case .rules: Color(nsColor: .systemBrown)
        }
    }

    var iconFillColor: Color {
        switch self {
        case .settings: Color(nsColor: .quaternaryLabelColor)
        case .mcp: Color(nsColor: .systemPurple)
        case .hooks: Color(nsColor: .systemOrange)
        case .agents: Color(nsColor: .systemBlue)
        case .skills: Color(nsColor: .systemIndigo)
        case .memory: Color(nsColor: .systemPink)
        case .design: Color(nsColor: .systemTeal)
        case .rules: Color(nsColor: .systemBrown)
        }
    }
}

// MARK: - Format Helpers

private func formatIcon(for format: String) -> String {
    switch format {
    case "json": "curlybraces"
    case "toml": "gearshape.2"
    case "markdown": "doc.richtext"
    case "yaml": "list.bullet"
    default: "doc"
    }
}

// MARK: - Brand

enum HarnessBrand {
    case anthropic, codex, generic

    var label: String {
        switch self {
        case .anthropic: "Claude"
        case .codex: "Codex"
        case .generic: ""
        }
    }

    var color: Color {
        switch self {
        case .anthropic: Color(red: 0.85, green: 0.55, blue: 0.35)
        case .codex: Color(red: 0.3, green: 0.75, blue: 0.45)
        case .generic: .secondary
        }
    }

    var logoAsset: String? {
        switch self {
        case .anthropic: "anthropic-logo"
        case .codex: "openai-logo"
        case .generic: nil
        }
    }

    static func from(key: String) -> HarnessBrand {
        if key.hasPrefix("claude.") { return .anthropic }
        if key.hasPrefix("codex.") { return .codex }
        return .generic
    }
}

// MARK: - Brand Pill

struct HarnessBrandPill: View {
    let brand: HarnessBrand
    var large: Bool = false

    var body: some View {
        if brand != .generic {
            Text(brand.label)
                .font(large ? .caption : .system(size: 9, weight: .semibold))
                .foregroundStyle(brand.color)
                .padding(.horizontal, large ? 7 : 5)
                .padding(.vertical, large ? 3 : 2)
                .background(brand.color.opacity(0.12))
                .clipShape(Capsule())
        }
    }
}

// MARK: - Search Field

private struct HarnessConfigSearchField: View {
    @Binding var text: String

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)

            TextField("Filter", text: $text)
                .textFieldStyle(.plain)
                .font(.system(size: 13))

            if !text.isEmpty {
                Button("Clear filter", systemImage: "xmark.circle.fill") {
                    text = ""
                }
                .labelStyle(.iconOnly)
                .foregroundStyle(.tertiary)
                .buttonStyle(.plain)
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

// MARK: - HarnessConfigView

struct HarnessConfigView: View {
    @State private var viewModel = HarnessConfigViewModel()
    @State private var isReaderMode = false
    @State private var searchText = ""

    private func filteredEntries(for category: ConfigCategory) -> [HarnessConfigEntry] {
        let entries = viewModel.entries(for: category)
        guard !searchText.isEmpty else { return entries }
        return entries.filter {
            $0.displayName.localizedStandardContains(searchText) ||
            $0.format.localizedStandardContains(searchText) ||
            $0.key.localizedStandardContains(searchText)
        }
    }

    private var filteredCategories: [ConfigCategory] {
        viewModel.activeCategories.filter { !filteredEntries(for: $0).isEmpty }
    }

    var body: some View {
        NativePaneScaffold(
            title: "Harness Config",
            subtitle: "Agent, hook, MCP, and workspace configuration files",
            systemImage: "slider.horizontal.3",
            role: .document,
            inlineHeaderIdentifier: "pane.harnessConfig.inlineHeader",
            inlineHeaderLabel: "Harness Config inline header"
        ) {
            NativeSplitScaffold(
                sidebarMinWidth: 240,
                sidebarIdealWidth: 280,
                sidebarMaxWidth: 340,
                sidebarSurface: .sidebar
            ) {
                VStack(alignment: .leading, spacing: 0) {
                    HarnessConfigSearchField(text: $searchText)
                        .padding(.horizontal, 12)
                        .padding(.top, 12)
                        .padding(.bottom, 8)

                    Divider()

                    if filteredCategories.isEmpty && !searchText.isEmpty {
                        VStack(spacing: DesignTokens.Spacing.sm) {
                            Text("No matching configs")
                                .font(.subheadline.weight(.semibold))
                            Text("Try a different search term.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else {
                        ScrollView {
                            LazyVStack(alignment: .leading, spacing: 2) {
                                ForEach(Array(filteredCategories.enumerated()), id: \.element) { index, category in
                                    let entries = filteredEntries(for: category)

                                    HarnessCategoryHeader(
                                        category: category,
                                        count: entries.count
                                    )
                                    .padding(.top, index == 0 ? 4 : 14)

                                    ForEach(entries) { entry in
                                        HarnessConfigRow(
                                            entry: entry,
                                            category: category,
                                            isSelected: viewModel.selectedKey == entry.key
                                        ) {
                                            viewModel.selectedKey = entry.key
                                        }
                                    }
                                }
                            }
                            .padding(.horizontal, 8)
                            .padding(.bottom, 8)
                        }
                    }
                }
            } detail: {
                VStack(spacing: 0) {
                    if let selectedKey = viewModel.selectedKey,
                       let entry = viewModel.allEntries.first(where: { $0.key == selectedKey }) {
                        HarnessConfigEditorHeader(
                            entry: entry,
                            isSaving: viewModel.isSaving,
                            hasChanges: viewModel.hasUnsavedChanges,
                            isReaderMode: $isReaderMode,
                            onSave: { viewModel.save() }
                        )

                        Divider()

                        if viewModel.isLoading {
                            ProgressView("Loading...")
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                        } else if !entry.exists {
                            EmptyStateView(
                                icon: "doc.badge.plus",
                                title: "File does not exist",
                                message: entry.path
                            )
                        } else if isReaderMode && entry.format == "markdown" {
                            MarkdownReaderView(content: viewModel.editorContent)
                        } else {
                            HarnessConfigEditor(
                                content: $viewModel.editorContent,
                                format: entry.format,
                                validationError: viewModel.validationError
                            )
                        }
                    } else {
                        EmptyStateView(
                            icon: "slider.horizontal.3",
                            title: "Harness Config",
                            message: "Select a configuration file from the sidebar to view or edit it"
                        )
                    }
                }
            }
        }
        .overlay(alignment: .bottom) {
            ErrorBanner(message: viewModel.actionError)
        }
        .accessibilityIdentifier("pane.harnessConfig")
        .task { await viewModel.activate() }
        .onChange(of: viewModel.selectedKey) { _, newKey in
            isReaderMode = false
            viewModel.didSelectKey(newKey)
        }
        .onChange(of: viewModel.editorContent) { _, newContent in
            viewModel.hasUnsavedChanges = newContent != viewModel.originalContent
        }
    }
}

// MARK: - Category Section Header

struct HarnessCategoryHeader: View {
    let category: ConfigCategory
    let count: Int

    var body: some View {
        HStack(spacing: 6) {
            Text(category.displayName.uppercased())
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.tertiary)
                .textCase(nil)
            Spacer()
            Text("\(count)")
                .font(.system(size: 10, weight: .medium, design: .rounded))
                .foregroundStyle(.quaternary)
        }
        .padding(.horizontal, 10)
        .padding(.bottom, 4)
    }
}

// MARK: - HarnessConfigRow

struct HarnessConfigRow: View {
    let entry: HarnessConfigEntry
    let category: ConfigCategory
    let isSelected: Bool
    let action: () -> Void

    @State private var isHovering = false

    private var brand: HarnessBrand {
        HarnessBrand.from(key: entry.key)
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                if let logoAsset = brand.logoAsset {
                    RoundedRectangle(cornerRadius: 6)
                        .fill(isSelected ? Color.white.opacity(0.18) : brand.color.opacity(0.12))
                        .frame(width: 24, height: 24)
                        .overlay {
                            Image(logoAsset)
                                .resizable()
                                .scaledToFit()
                                .frame(width: 14, height: 14)
                                .foregroundStyle(isSelected ? Color.white : brand.color)
                        }
                } else {
                    RoundedRectangle(cornerRadius: 6)
                        .fill(iconBackground)
                        .frame(width: 24, height: 24)
                        .overlay {
                            Image(systemName: formatIcon(for: entry.format))
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(iconForeground)
                        }
                }

                VStack(alignment: .leading, spacing: 1) {
                    Text(entry.displayName)
                        .font(.system(size: 13, weight: isSelected ? .semibold : .regular))
                        .foregroundStyle(rowForeground)
                        .lineLimit(1)

                    HStack(spacing: 3) {
                        Text(entry.format)
                            .font(.system(size: 10, weight: .medium))
                        if brand != .generic {
                            Text("\u{00B7}")
                            Text(brand.label)
                        }
                    }
                    .font(.system(size: 10))
                    .foregroundStyle(isSelected ? .white.opacity(0.7) : .secondary)
                }

                Spacer(minLength: 0)

                if !entry.exists {
                    Image(systemName: "exclamationmark.circle")
                        .font(.system(size: 11))
                        .foregroundStyle(isSelected ? Color.white.opacity(0.6) : Color.secondary)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(rowBackground)
            )
        }
        .buttonStyle(.plain)
        .contentShape(RoundedRectangle(cornerRadius: 8))
        .onHover { isHovering = $0 }
        .opacity(entry.exists ? 1.0 : 0.5)
        .accessibilityAddTraits(.isButton)
    }

    private var rowBackground: Color {
        if isSelected { return Color.accentColor }
        if isHovering { return Color.primary.opacity(0.06) }
        return .clear
    }

    private var rowForeground: Color {
        isSelected ? .white : .primary
    }

    private var iconBackground: Color {
        if isSelected { return .white.opacity(0.18) }
        return category.iconFillColor.opacity(category == .settings ? 0.65 : 0.92)
    }

    private var iconForeground: Color {
        if isSelected { return .white }
        return category == .settings ? .primary : .white
    }
}

// MARK: - Editor Header

struct HarnessConfigEditorHeader: View {
    let entry: HarnessConfigEntry
    let isSaving: Bool
    let hasChanges: Bool
    @Binding var isReaderMode: Bool
    let onSave: () -> Void

    private var brand: HarnessBrand {
        HarnessBrand.from(key: entry.key)
    }

    private var category: ConfigCategory {
        ConfigCategory(rawValue: entry.category) ?? .settings
    }

    var body: some View {
        HStack(spacing: 12) {
            if let logoAsset = brand.logoAsset {
                RoundedRectangle(cornerRadius: 8)
                    .fill(brand.color.opacity(0.12))
                    .frame(width: 32, height: 32)
                    .overlay {
                        Image(logoAsset)
                            .resizable()
                            .scaledToFit()
                            .frame(width: 18, height: 18)
                            .foregroundStyle(brand.color)
                    }
            } else {
                RoundedRectangle(cornerRadius: 8)
                    .fill(category.iconFillColor.opacity(category == .settings ? 0.65 : 0.92))
                    .frame(width: 32, height: 32)
                    .overlay {
                        Image(systemName: formatIcon(for: entry.format))
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(category == .settings ? Color.primary : Color.white)
                    }
            }

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(entry.displayName)
                        .font(.system(size: 13, weight: .semibold))
                    HarnessBrandPill(brand: brand, large: true)
                }
                Text(entry.path)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer()

            if entry.format == "markdown" {
                Button {
                    isReaderMode.toggle()
                } label: {
                    Label(
                        isReaderMode ? "Source" : "Reader",
                        systemImage: isReaderMode
                            ? "chevron.left.forwardslash.chevron.right"
                            : "doc.richtext"
                    )
                    .font(.caption)
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
        .padding(.horizontal, DesignTokens.Spacing.md)
        .padding(.vertical, 10)
        .background(ChromeSurfaceStyle.toolbar.color)
    }
}

// MARK: - Editor

struct HarnessConfigEditor: View {
    @Binding var content: String
    let format: String
    let validationError: String?

    var body: some View {
        VStack(spacing: 0) {
            TextEditor(text: $content)
                .font(.system(.body, design: .monospaced))
                .scrollContentBackground(.hidden)

            if let error = validationError {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.yellow)
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                .padding(.horizontal, DesignTokens.Spacing.md)
                .padding(.vertical, DesignTokens.Spacing.sm)
                .background(Color.red.opacity(0.08))
                .overlay(alignment: .top) { Divider() }
            }
        }
    }
}

// MARK: - ViewModel

@Observable @MainActor
final class HarnessConfigViewModel {
    var allEntries: [HarnessConfigEntry] = []
    var selectedKey: String?
    var editorContent: String = ""
    var isLoading = false
    var isSaving = false
    var actionError: String?
    var validationError: String?
    var hasUnsavedChanges = false

    var activeCategories: [ConfigCategory] {
        let presentCategories = Set(allEntries.map(\.category))
        return ConfigCategory.allCases.filter { presentCategories.contains($0.rawValue) }
    }

    @ObservationIgnored
    var originalContent: String = ""
    @ObservationIgnored
    private let commandBus: (any CommandCalling)?

    init(commandBus: (any CommandCalling)? = CommandBus.shared) {
        self.commandBus = commandBus
    }

    func entries(for category: ConfigCategory) -> [HarnessConfigEntry] {
        allEntries.filter { $0.category == category.rawValue }
    }

    func activate() async {
        await loadEntries()
    }

    func loadEntries() async {
        guard let bus = commandBus else {
            actionError = "Backend connection unavailable"
            scheduleDismissActionError()
            return
        }
        do {
            let entries: [HarnessConfigEntry] = try await bus.call(
                method: "harness.config.list",
                params: nil as String?
            )
            self.allEntries = entries
        } catch {
            actionError = error.localizedDescription
            scheduleDismissActionError()
        }
    }

    func loadContent(for key: String) {
        guard let bus = commandBus else {
            actionError = "Backend connection unavailable"
            scheduleDismissActionError()
            return
        }
        isLoading = true
        validationError = nil
        Task { [weak self] in
            guard let self else { return }
            do {
                let result: HarnessConfigContent = try await bus.call(
                    method: "harness.config.read",
                    params: ReadConfigParams(key: key)
                )
                self.editorContent = result.content
                self.originalContent = result.content
                self.hasUnsavedChanges = false
                self.isLoading = false
            } catch {
                self.isLoading = false
                self.actionError = error.localizedDescription
                self.scheduleDismissActionError()
            }
        }
    }

    func save() {
        guard let key = selectedKey, let bus = commandBus else { return }
        isSaving = true
        Task { [weak self] in
            guard let self else { return }
            do {
                let _: OkResponse = try await bus.call(
                    method: "harness.config.write",
                    params: WriteConfigParams(key: key, content: self.editorContent)
                )
                self.originalContent = self.editorContent
                self.hasUnsavedChanges = false
                self.isSaving = false
            } catch {
                self.isSaving = false
                self.actionError = error.localizedDescription
                self.scheduleDismissActionError()
            }
        }
    }

    // MARK: - Private

    private func scheduleDismissActionError() {
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(5))
            self?.actionError = nil
        }
    }
}

// Observe selectedKey changes to load content
extension HarnessConfigViewModel {
    func didSelectKey(_ key: String?) {
        guard let key, allEntries.first(where: { $0.key == key })?.exists == true else {
            editorContent = ""
            originalContent = ""
            hasUnsavedChanges = false
            return
        }
        loadContent(for: key)
    }
}

// MARK: - NSView Wrapper

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
