import SwiftUI
import Observation
import Cocoa

// MARK: - Data Models

struct HarnessConfigEntry: Identifiable, Decodable {
    var id: String { key }
    let key: String
    let display_name: String
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

// MARK: - HarnessConfigView

struct HarnessConfigView: View {
    @State private var viewModel = HarnessConfigViewModel()

    var body: some View {
        HSplitView {
            // Sidebar: categories and entries
            VStack(spacing: 0) {
                Text("Harness Config")
                    .font(.headline)
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)

                Divider()

                List(selection: $viewModel.selectedKey) {
                    ForEach(viewModel.activeCategories, id: \.self) { category in
                        Section(header: Label(category.displayName, systemImage: category.icon)) {
                            ForEach(viewModel.entries(for: category)) { entry in
                                HarnessConfigRow(entry: entry)
                                    .tag(entry.key)
                            }
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
            viewModel.didSelectKey(newKey)
        }
        .onChange(of: viewModel.editorContent) { _, newContent in
            viewModel.hasUnsavedChanges = newContent != viewModel.originalContent
        }
    }
}

// MARK: - HarnessConfigRow

struct HarnessConfigRow: View {
    let entry: HarnessConfigEntry

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(entry.exists ? Color.green : Color.gray)
                .frame(width: 6, height: 6)

            VStack(alignment: .leading, spacing: 1) {
                Text(entry.display_name)
                    .font(.body)
                    .lineLimit(1)
                Text(entry.format)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
        .accessibilityAddTraits(.isButton)
    }
}

// MARK: - Editor Header

struct HarnessConfigEditorHeader: View {
    let entry: HarnessConfigEntry
    let isSaving: Bool
    let hasChanges: Bool
    let onSave: () -> Void

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.display_name)
                    .font(.headline)
                Text(entry.path)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer()

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
    let shouldPersist = false
    var title: String { "Harness Config" }

    override init(frame: NSRect) {
        super.init(frame: frame)
        _ = addSwiftUISubview(HarnessConfigView())
    }

    required init?(coder: NSCoder) { fatalError() }
}
