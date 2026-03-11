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
        case .settings: return "Settings"
        case .mcp: return "MCP"
        case .hooks: return "Hooks"
        case .agents: return "Agents"
        case .skills: return "Skills"
        case .memory: return "Memory"
        case .design: return "Design"
        case .rules: return "Rules"
        }
    }

    var icon: String {
        switch self {
        case .settings: return "gearshape"
        case .mcp: return "server.rack"
        case .hooks: return "arrow.triangle.branch"
        case .agents: return "person.crop.circle"
        case .skills: return "hammer"
        case .memory: return "brain"
        case .design: return "paintbrush"
        case .rules: return "list.bullet.clipboard"
        }
    }
}

// MARK: - Brand

enum HarnessBrand {
    case anthropic, codex, generic

    var label: String {
        switch self {
        case .anthropic: return "Claude"
        case .codex: return "Codex"
        case .generic: return ""
        }
    }

    var color: Color {
        switch self {
        case .anthropic: return Color(red: 0.85, green: 0.55, blue: 0.35)
        case .codex: return Color(red: 0.3, green: 0.75, blue: 0.45)
        case .generic: return .secondary
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

// MARK: - HarnessConfigView

struct HarnessConfigView: View {
    @State private var viewModel = HarnessConfigViewModel()
    @State private var isReaderMode = false

    var body: some View {
        HSplitView {
            // Sidebar
            VStack(spacing: 0) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Agent Harness")
                        .font(.headline)
                    Text("Configuration files for AI agents and tools")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .frame(maxWidth: .infinity, alignment: .leading)

                Divider()

                List(selection: $viewModel.selectedKey) {
                    ForEach(viewModel.activeCategories, id: \.self) { category in
                        let categoryEntries = viewModel.entries(for: category)
                        Section {
                            ForEach(categoryEntries) { entry in
                                HarnessConfigRow(entry: entry)
                                    .tag(entry.key)
                            }
                        } header: {
                            HarnessCategoryHeader(
                                category: category,
                                count: categoryEntries.count
                            )
                        }
                    }
                }
                .listStyle(.sidebar)
            }
            .frame(minWidth: 200, idealWidth: 250, maxWidth: 300)

            // Editor area
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
                        icon: "doc.text",
                        title: "Select a config file",
                        message: "Choose a harness configuration file from the sidebar to view or edit it"
                    )
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
            Image(systemName: category.icon)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
            Text(category.displayName)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
                .textCase(nil)
            Spacer()
            Text("\(count)")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.tertiary)
                .padding(.horizontal, 5)
                .padding(.vertical, 1)
                .background(Color.secondary.opacity(0.12))
                .clipShape(Capsule())
        }
        .padding(.top, 6)
        .padding(.bottom, 2)
    }
}

// MARK: - HarnessConfigRow

struct HarnessConfigRow: View {
    let entry: HarnessConfigEntry

    var body: some View {
        let brand = HarnessBrand.from(key: entry.key)
        HStack(spacing: 6) {
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.displayName)
                    .font(.body)
                    .lineLimit(1)
                HStack(spacing: 4) {
                    Text(entry.format)
                        .font(.system(size: 9, weight: .medium, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .background(Color.secondary.opacity(0.1))
                        .clipShape(RoundedRectangle(cornerRadius: 3))
                    HarnessBrandPill(brand: brand)
                }
            }
        }
        .padding(.vertical, 2)
        .opacity(entry.exists ? 1.0 : 0.45)
        .accessibilityAddTraits(.isButton)
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

    var body: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(entry.displayName)
                        .font(.headline)
                    HarnessBrandPill(brand: brand, large: true)
                    Text(entry.format)
                        .font(.system(size: 10, weight: .medium, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.secondary.opacity(0.1))
                        .clipShape(RoundedRectangle(cornerRadius: 4))
                }
                Text(entry.path)
                    .font(.caption)
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
                .disabled(!hasChanges || isSaving)
                .keyboardShortcut("s", modifiers: .command)
        }
        .padding(12)
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
                HStack {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.yellow)
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(Color.red.opacity(0.1))
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

    override init(frame: NSRect) {
        super.init(frame: frame)
        _ = addSwiftUISubview(HarnessConfigView())
    }

    required init?(coder: NSCoder) { fatalError() }
}
