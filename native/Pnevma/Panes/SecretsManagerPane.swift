import SwiftUI
import Observation
import AppKit

struct ProjectSecret: Identifiable, Codable {
    let id: String
    let projectID: String?
    var scope: String
    var name: String
    var backend: String
    var locationDisplay: String
    var status: String
    var statusMessage: String?
    let createdAt: Date
    let updatedAt: Date
}

private extension ProjectSecret {
    var scopeLabel: String {
        scope == "global" ? "GLOBAL" : "PROJECT"
    }

    var backendLabel: String {
        backend == "keychain" ? "KEYCHAIN" : ".ENV.LOCAL"
    }

    var updatedLabel: String {
        updatedAt.formatted(date: .abbreviated, time: .shortened)
    }

    var statusTone: SecretStatusPill.Tone {
        switch status {
        case "configured":
            return .configured
        case "missing":
            return .missing
        default:
            return .error
        }
    }
}

enum SecretsSectionKind: String, CaseIterable {
    case project
    case global

    var title: String {
        switch self {
        case .project: return "Project"
        case .global: return "Global"
        }
    }

    var accessibilityIdentifier: String {
        "secrets.section.\(rawValue)"
    }
}

struct SecretsListPresentation {
    let projectSecrets: [ProjectSecret]
    let globalSecrets: [ProjectSecret]

    init(secrets: [ProjectSecret]) {
        projectSecrets = secrets
            .filter { $0.scope != "global" }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        globalSecrets = secrets
            .filter { $0.scope == "global" }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    var hasShadowedGlobals: Bool {
        let projectNames = Set(projectSecrets.map(\.name))
        return globalSecrets.contains { projectNames.contains($0.name) }
    }

    var orderedSections: [SecretsSectionKind] {
        var sections: [SecretsSectionKind] = []
        if !projectSecrets.isEmpty {
            sections.append(.project)
        }
        if !globalSecrets.isEmpty {
            sections.append(.global)
        }
        return sections
    }
}

private struct ProjectSecretsListParams: Encodable {
    let scope: String?
}

private struct ProjectSecretUpsertParams: Encodable {
    let id: String?
    let name: String
    let scope: String
    let backend: String
    let value: String?
    let envFilePath: String?
}

private struct ProjectSecretDeleteParams: Encodable {
    let id: String
}

private struct ProjectSecretImportParams: Encodable {
    let path: String
    let scope: String
    let destinationBackend: String
    let onConflict: String?
}

private struct ProjectSecretExportParams: Encodable {
    let path: String?
}

private struct ProjectSecretImportResult: Decodable {
    let importedNames: [String]
    let skippedNames: [String]
    let errorNames: [String]
}

private struct ProjectSecretExportResult: Decodable {
    let path: String
    let count: Int
}

private struct SecretsHeaderWidthPreferenceKey: PreferenceKey {
    static let defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

enum SecretsHeaderActionLayout: Equatable {
    case expanded
    case compact

    static func from(width: CGFloat) -> Self {
        width < 760 ? .compact : .expanded
    }
}

private struct SecretsHeaderActions: View {
    let layout: SecretsHeaderActionLayout
    let isProjectOpen: Bool
    let isLoading: Bool
    let onImport: () -> Void
    let onExport: () -> Void
    let onAdd: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            if isLoading {
                ProgressView()
                    .controlSize(.small)
            }

            if layout == .expanded {
                Button {
                    onImport()
                } label: {
                    Label("Import .env", systemImage: "square.and.arrow.down")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(!isProjectOpen || isLoading)
                .help("Import secrets from an existing .env-style file")
                .accessibilityIdentifier("secrets.header.import")

                Button {
                    onExport()
                } label: {
                    Label("Export Template", systemImage: "square.and.arrow.up")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(!isProjectOpen || isLoading)
                .help("Create a blank .env.local template using known secret names")
                .accessibilityIdentifier("secrets.header.export")
            } else {
                Menu {
                    Button("Import .env", action: onImport)
                        .disabled(!isProjectOpen || isLoading)
                    Button("Export Template", action: onExport)
                        .disabled(!isProjectOpen || isLoading)
                } label: {
                    Label("More", systemImage: "ellipsis.circle")
                }
                .menuStyle(.borderlessButton)
                .controlSize(.small)
                .disabled(!isProjectOpen || isLoading)
                .accessibilityIdentifier("secrets.header.more")
            }

            Button {
                onAdd()
            } label: {
                Label("Add Secret", systemImage: "plus")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(!isProjectOpen || isLoading)
            .keyboardShortcut("n", modifiers: .command)
            .accessibilityIdentifier("secrets.header.add")
        }
    }
}

@MainActor
struct SecretsManagerView: View {
    @State private var viewModel = SecretsManagerViewModel()
    @State private var showingDeleteAlert = false
    @State private var pendingDeleteSecret: ProjectSecret?
    @State private var headerLayout: SecretsHeaderActionLayout = .expanded

    init() {}

    init(viewModel: SecretsManagerViewModel) {
        _viewModel = State(initialValue: viewModel)
    }

    var body: some View {
        let presentation = SecretsListPresentation(secrets: viewModel.secrets)

        NativePaneScaffold(
            title: "Secrets",
            subtitle: "Project and global environment values for tools and agents",
            systemImage: "key",
            role: .manager,
            inlineHeaderIdentifier: "pane.secrets.inlineHeader",
            inlineHeaderLabel: "Secrets inline header"
        ) {
            SecretsHeaderActions(
                layout: headerLayout,
                isProjectOpen: viewModel.isProjectOpen,
                isLoading: viewModel.isLoading,
                onImport: { viewModel.importSecretsFromPanel() },
                onExport: { viewModel.exportTemplate() },
                onAdd: { viewModel.presentAddSheet() }
            )
        } content: {
            Group {
                if let waitingMessage = viewModel.projectStatusMessage {
                    VStack(spacing: 8) {
                        ProgressView()
                        Text(waitingMessage)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if !viewModel.isProjectOpen {
                    EmptyStateView(
                        icon: "key.slash",
                        title: "No project open",
                        message: "Open a project to manage project and global secrets"
                    )
                } else if viewModel.secrets.isEmpty {
                    EmptyStateView(
                        icon: "key",
                        title: "No secrets configured",
                        message: "Add keychain-backed or .env.local-backed secrets for this project or across projects",
                        actionTitle: "Add Secret",
                        action: { viewModel.presentAddSheet() }
                    )
                } else {
                    NativeCollectionShell {
                        List {
                            if presentation.hasShadowedGlobals {
                                Section {
                                    Text("Project secrets override global secrets with the same name.")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .padding(.vertical, 2)
                                }
                            }

                            if !presentation.projectSecrets.isEmpty {
                                Section {
                                    ForEach(presentation.projectSecrets) { secret in
                                        SecretRow(
                                            secret: secret,
                                            onEdit: { viewModel.presentEditSheet(secret) },
                                            onDelete: {
                                                pendingDeleteSecret = secret
                                                showingDeleteAlert = true
                                            }
                                        )
                                        .accessibilityElement(children: .contain)
                                    }
                                } header: {
                                    Text(SecretsSectionKind.project.title)
                                        .accessibilityIdentifier(SecretsSectionKind.project.accessibilityIdentifier)
                                }
                            }

                            if !presentation.globalSecrets.isEmpty {
                                Section {
                                    ForEach(presentation.globalSecrets) { secret in
                                        SecretRow(
                                            secret: secret,
                                            onEdit: { viewModel.presentEditSheet(secret) },
                                            onDelete: {
                                                pendingDeleteSecret = secret
                                                showingDeleteAlert = true
                                            }
                                        )
                                        .accessibilityElement(children: .contain)
                                    }
                                } header: {
                                    Text(SecretsSectionKind.global.title)
                                        .accessibilityIdentifier(SecretsSectionKind.global.accessibilityIdentifier)
                                }
                            }
                        }
                        .listStyle(.inset)
                        .scrollContentBackground(.hidden)
                    }
                }
            }
        }
        .background(
            GeometryReader { proxy in
                Color.clear
                    .preference(key: SecretsHeaderWidthPreferenceKey.self, value: proxy.size.width)
            }
        )
        .overlay(alignment: .bottom) {
            ErrorBanner(message: viewModel.actionError)
        }
        .sheet(isPresented: $viewModel.isEditorPresented) {
            SecretEditorSheet(
                draft: viewModel.editorDraft,
                isSaving: viewModel.isLoading,
                onCancel: { viewModel.dismissEditor() },
                onSave: { draft in viewModel.saveSecret(draft: draft) }
            )
        }
        .alert("Delete Secret?", isPresented: $showingDeleteAlert, presenting: pendingDeleteSecret) { secret in
            Button("Cancel", role: .cancel) {}
            Button("Delete", role: .destructive) {
                viewModel.deleteSecret(secret)
            }
        } message: { secret in
            Text(
                secret.scope == "global"
                    ? "\(secret.name) is a global secret and will be removed for all projects."
                    : "\(secret.name) will be removed from this project."
            )
        }
        .accessibilityIdentifier("pane.secrets")
        .task { await viewModel.activate() }
        .onPreferenceChange(SecretsHeaderWidthPreferenceKey.self) { width in
            headerLayout = SecretsHeaderActionLayout.from(width: width)
        }
    }
}

private struct SecretRow: View {
    let secret: ProjectSecret
    let onEdit: () -> Void
    let onDelete: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Text(secret.name)
                        .font(.system(.body, design: .monospaced))
                        .bold()
                    SecretTag(text: secret.scopeLabel)
                    SecretTag(text: secret.backendLabel)
                    SecretStatusPill(tone: secret.statusTone)
                }
                Text("\(secret.locationDisplay) • Updated \(secret.updatedLabel)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let statusMessage = secret.statusMessage, !statusMessage.isEmpty {
                    Text(statusMessage)
                        .font(.caption)
                        .foregroundStyle(secret.status == "error" ? .red : .secondary)
                        .lineLimit(2)
                }
            }
            Spacer()
            HStack(spacing: 8) {
                Button("Edit", action: onEdit)
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                Button("Delete", role: .destructive, action: onDelete)
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .accessibilityLabel("Delete \(secret.name)")
            }
        }
        .padding(.vertical, 4)
    }
}

private struct SecretTag: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.caption)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Capsule().fill(Color.secondary.opacity(0.15)))
    }
}

private struct SecretStatusPill: View {
    enum Tone {
        case configured
        case missing
        case error
    }

    let tone: Tone

    private var title: String {
        switch tone {
        case .configured: return "Configured"
        case .missing: return "Missing"
        case .error: return "Error"
        }
    }

    private var icon: String {
        switch tone {
        case .configured: return "checkmark.circle.fill"
        case .missing: return "exclamationmark.triangle.fill"
        case .error: return "xmark.octagon.fill"
        }
    }

    private var color: Color {
        switch tone {
        case .configured: return .green
        case .missing: return .orange
        case .error: return .red
        }
    }

    var body: some View {
        Label(title, systemImage: icon)
            .font(.caption)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Capsule().fill(color.opacity(0.18)))
            .foregroundStyle(color)
    }
}

struct SecretEditorDraft {
    var id: String?
    var name = ""
    var scope = "project"
    var backend = "keychain"
    var replacementValue = ""
    var isEditing = false
}

extension SecretEditorDraft {
    var storageSelectionDisabled: Bool {
        scope == "global"
    }

    var storageHelperText: String? {
        storageSelectionDisabled ? "Global secrets are always stored in Keychain." : nil
    }

    var valueHelperText: String? {
        isEditing
            ? "Existing secret values are never shown again. Leave the field blank to keep the current value."
            : nil
    }

    var backendHelperText: String {
        backend == "env_file"
            ? "File-backed secrets are stored in a Pnevma-managed .env.local block."
            : "Keychain-backed secrets stay out of the project working tree."
    }
}

struct SecretEditorSheet: View {
    @State var draft: SecretEditorDraft
    let isSaving: Bool
    let onCancel: () -> Void
    let onSave: (SecretEditorDraft) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(draft.isEditing ? "Edit Secret" : "Add Secret")
                .font(.headline)

            TextField("Name", text: $draft.name)
                .textFieldStyle(.roundedBorder)
                .autocorrectionDisabled()

            Picker("Scope", selection: $draft.scope) {
                Text("Project").tag("project")
                Text("Global").tag("global")
            }
            .pickerStyle(.segmented)

            Picker("Storage", selection: $draft.backend) {
                Text("Keychain").tag("keychain")
                Text(".env.local").tag("env_file")
            }
            .pickerStyle(.segmented)
            .disabled(draft.storageSelectionDisabled)
            .onChange(of: draft.scope) { _, newScope in
                if newScope == "global" {
                    draft.backend = "keychain"
                }
            }
            .accessibilityIdentifier("secrets.editor.storage")

            if let storageHelperText = draft.storageHelperText {
                Text(storageHelperText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("secrets.editor.storageHelper")
            }

            SecureField(
                draft.isEditing ? "Replacement value (leave blank to keep current value)" : "Value",
                text: $draft.replacementValue
            )
            .textFieldStyle(.roundedBorder)
            .autocorrectionDisabled()

            if let valueHelperText = draft.valueHelperText {
                Text(valueHelperText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("secrets.editor.valueHelper")
            }

            Text(draft.backendHelperText)
                .font(.caption)
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("secrets.editor.backendHelper")

            HStack {
                Button("Cancel", action: onCancel)
                    .disabled(isSaving)
                Spacer()
                Button(draft.isEditing ? "Save" : "Add") {
                    onSave(draft)
                }
                .buttonStyle(.borderedProminent)
                .disabled(
                    isSaving
                        || draft.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        || (!draft.isEditing && draft.replacementValue.isEmpty)
                )
            }
        }
        .padding(20)
        .frame(width: 460)
    }
}

@Observable @MainActor
final class SecretsManagerViewModel {
    var secrets: [ProjectSecret] = []
    var isLoading = false
    var actionError: String?
    var isEditorPresented = false
    var editorDraft = SecretEditorDraft()
    private(set) var isProjectOpen = false
    private(set) var projectStatusMessage: String?

    @ObservationIgnored
    private let commandBus: (any CommandCalling)?
    @ObservationIgnored
    private let bridgeEventHub: BridgeEventHub
    @ObservationIgnored
    private let activationHub: ActiveWorkspaceActivationHub
    @ObservationIgnored
    private var bridgeObserverID: UUID?
    @ObservationIgnored
    private var activationObserverID: UUID?

    init(
        commandBus: (any CommandCalling)? = CommandBus.shared,
        bridgeEventHub: BridgeEventHub = .shared,
        activationHub: ActiveWorkspaceActivationHub = .shared
    ) {
        self.commandBus = commandBus
        self.bridgeEventHub = bridgeEventHub
        self.activationHub = activationHub

        bridgeObserverID = bridgeEventHub.addObserver { [weak self] event in
            guard event.name == "project_secrets_updated" else { return }
            Task { @MainActor [weak self] in
                self?.refreshIfActive()
            }
        }
        activationObserverID = activationHub.addObserver { [weak self] state in
            Task { @MainActor [weak self] in
                self?.handleActivationState(state)
            }
        }
    }

    deinit {
        if let bridgeObserverID {
            bridgeEventHub.removeObserver(bridgeObserverID)
        }
        if let activationObserverID {
            activationHub.removeObserver(activationObserverID)
        }
    }

    func activate() async {
        handleActivationState(activationHub.currentState)
    }

    func presentAddSheet() {
        editorDraft = SecretEditorDraft()
        isEditorPresented = true
    }

    func presentEditSheet(_ secret: ProjectSecret) {
        editorDraft = SecretEditorDraft(
            id: secret.id,
            name: secret.name,
            scope: secret.scope,
            backend: secret.backend,
            replacementValue: "",
            isEditing: true
        )
        isEditorPresented = true
    }

    func dismissEditor() {
        isEditorPresented = false
    }

    func saveSecret(draft: SecretEditorDraft) {
        guard let bus = commandBus else {
            showActionError("Backend connection unavailable")
            return
        }
        isLoading = true
        Task { [weak self] in
            guard let self else { return }
            defer { self.isLoading = false }
            do {
                let params = ProjectSecretUpsertParams(
                    id: draft.id,
                    name: draft.name,
                    scope: draft.scope,
                    backend: draft.scope == "global" ? "keychain" : draft.backend,
                    value: draft.replacementValue.isEmpty ? nil : draft.replacementValue,
                    envFilePath: draft.backend == "env_file" ? ".env.local" : nil
                )
                let _: ProjectSecret = try await bus.call(method: "project.secrets.upsert", params: params)
                self.isEditorPresented = false
                await self.load()
                self.showToast(
                    draft.isEditing ? "Saved secret." : "Added secret.",
                    icon: "key.fill",
                    style: .success
                )
            } catch {
                self.showActionError(error.localizedDescription)
            }
        }
    }

    func deleteSecret(_ secret: ProjectSecret) {
        guard let bus = commandBus else {
            showActionError("Backend connection unavailable")
            return
        }
        isLoading = true
        Task { [weak self] in
            guard let self else { return }
            defer { self.isLoading = false }
            do {
                let _: OkResponse = try await bus.call(
                    method: "project.secrets.delete",
                    params: ProjectSecretDeleteParams(id: secret.id)
                )
                await self.load()
                self.showToast("Deleted \(secret.name).", icon: "trash", style: .success)
            } catch {
                self.showActionError(error.localizedDescription)
            }
        }
    }

    func importSecretsFromPanel() {
        guard let path = Self.pickOpenPath(
            title: "Import .env Secrets",
            message: "Choose a .env-style file to import into this project."
        ) else { return }
        guard let bus = commandBus else {
            showActionError("Backend connection unavailable")
            return
        }
        isLoading = true
        Task { [weak self] in
            guard let self else { return }
            defer { self.isLoading = false }
            do {
                let result: ProjectSecretImportResult = try await bus.call(
                    method: "project.secrets.import_env",
                    params: ProjectSecretImportParams(
                        path: path,
                        scope: "project",
                        destinationBackend: "keychain",
                        onConflict: "skip"
                    )
                )
                await self.load()
                self.showToast(
                    "Imported \(result.importedNames.count), skipped \(result.skippedNames.count), errors \(result.errorNames.count)."
                )
            } catch {
                self.showActionError(error.localizedDescription)
            }
        }
    }

    func exportTemplate() {
        guard let bus = commandBus else {
            showActionError("Backend connection unavailable")
            return
        }
        isLoading = true
        Task { [weak self] in
            guard let self else { return }
            defer { self.isLoading = false }
            do {
                let result: ProjectSecretExportResult = try await bus.call(
                    method: "project.secrets.export_env_template",
                    params: ProjectSecretExportParams(path: nil)
                )
                self.showToast(
                    "Wrote template for \(result.count) secrets to \(result.path).",
                    icon: "doc.badge.plus",
                    style: .success
                )
            } catch {
                self.showActionError(error.localizedDescription)
            }
        }
    }

    private func load() async {
        guard let bus = commandBus else {
            showActionError("Backend connection unavailable")
            return
        }
        do {
            let rows: [ProjectSecret] = try await bus.call(
                method: "project.secrets.list",
                params: ProjectSecretsListParams(scope: nil)
            )
            secrets = rows
            projectStatusMessage = nil
        } catch {
            handleLoadFailure(error)
        }
    }

    private func handleActivationState(_ state: ActiveWorkspaceActivationState) {
        switch state {
        case .idle, .opening:
            isProjectOpen = false
            projectStatusMessage = "Waiting for project activation..."
            secrets = []
        case .closed:
            isProjectOpen = false
            projectStatusMessage = nil
            secrets = []
        case .open:
            isProjectOpen = true
            projectStatusMessage = nil
            Task { await load() }
        case .failed(_, _, let message):
            isProjectOpen = false
            projectStatusMessage = nil
            secrets = []
            showActionError(message)
        }
    }

    private func handleLoadFailure(_ error: Error) {
        if PnevmaError.isProjectNotReady(error) {
            isProjectOpen = false
            projectStatusMessage = "Waiting for project activation..."
            secrets = []
            actionError = nil
            return
        }
        showActionError(error.localizedDescription)
    }

    private func refreshIfActive() {
        guard activationHub.currentState.isOpen else { return }
        Task { await load() }
    }

    private func showActionError(_ message: String) {
        actionError = message
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(5))
            self?.actionError = nil
        }
    }

    private func showToast(
        _ message: String,
        icon: String? = nil,
        style: ToastMessage.ToastStyle = .info
    ) {
        ToastManager.shared.show(message, icon: icon, style: style)
    }

    private static func pickOpenPath(title: String, message: String) -> String? {
        let panel = NSOpenPanel()
        panel.title = title
        panel.message = message
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Import"
        return panel.runModal() == .OK ? panel.url?.path : nil
    }
}

final class SecretsManagerPaneView: NSView, PaneContent {
    let paneID = PaneID()
    let paneType = "secrets"
    let shouldPersist = true
    var title: String { "Secrets" }

    init(frame: NSRect, chromeContext: PaneChromeContext = .standard) {
        super.init(frame: frame)
        _ = addSwiftUISubview(SecretsManagerView(), chromeContext: chromeContext)
    }

    required init?(coder: NSCoder) { fatalError() }
}
