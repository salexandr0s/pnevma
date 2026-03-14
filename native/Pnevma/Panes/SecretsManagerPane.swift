import SwiftUI
import Observation
import AppKit

struct ProjectSecret: Identifiable, Decodable {
    let id: String
    let projectID: String?
    var scope: String
    var name: String
    var backend: String
    var locationDisplay: String
    var status: String
    var statusMessage: String?
    let createdAt: String
    let updatedAt: String
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

struct SecretsManagerView: View {
    @State private var viewModel = SecretsManagerViewModel()
    @State private var showingDeleteAlert = false
    @State private var pendingDeleteSecret: ProjectSecret?

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Secrets")
                    .font(.headline)
                Spacer()
                Button("Import .env") { viewModel.importSecretsFromPanel() }
                    .buttonStyle(.bordered)
                    .disabled(!viewModel.isProjectOpen || viewModel.isLoading)
                Button("Export Template") { viewModel.exportTemplate() }
                    .buttonStyle(.bordered)
                    .disabled(!viewModel.isProjectOpen || viewModel.isLoading)
                Button("Add Secret") { viewModel.presentAddSheet() }
                    .buttonStyle(.borderedProminent)
                    .disabled(!viewModel.isProjectOpen)
            }
            .padding(12)

            Divider()

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
                    message: "Open a project to manage project-scoped secrets"
                )
            } else if viewModel.secrets.isEmpty {
                EmptyStateView(
                    icon: "key",
                    title: "No secrets configured",
                    message: "Add keychain-backed or .env.local-backed secrets for this project"
                )
            } else {
                List {
                    ForEach(viewModel.secrets) { secret in
                        SecretRow(
                            secret: secret,
                            onEdit: { viewModel.presentEditSheet(secret) },
                            onDelete: {
                                pendingDeleteSecret = secret
                                showingDeleteAlert = true
                            }
                        )
                    }
                }
                .listStyle(.plain)
            }
        }
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
    }
}

private struct SecretRow: View {
    let secret: ProjectSecret
    let onEdit: () -> Void
    let onDelete: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(secret.name)
                        .font(.body.weight(.medium))
                    SecretTag(text: secret.scope.uppercased())
                    SecretTag(text: secret.backend == "keychain" ? "KEYCHAIN" : ".ENV.LOCAL")
                    SecretStatusPill(status: secret.status)
                }
                Text(secret.locationDisplay)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let statusMessage = secret.statusMessage, !statusMessage.isEmpty {
                    Text(statusMessage)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
            Spacer()
            Button("Edit", action: onEdit)
                .buttonStyle(.plain)
            Button(role: .destructive, action: onDelete) {
                Image(systemName: "trash")
            }
            .buttonStyle(.plain)
        }
        .padding(.vertical, 4)
    }
}

private struct SecretTag: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.caption2)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Capsule().fill(Color.secondary.opacity(0.15)))
    }
}

private struct SecretStatusPill: View {
    let status: String

    private var color: Color {
        switch status {
        case "configured": return .green
        case "missing": return .orange
        default: return .red
        }
    }

    var body: some View {
        Text(status.capitalized)
            .font(.caption2)
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

private struct SecretEditorSheet: View {
    @State var draft: SecretEditorDraft
    let isSaving: Bool
    let onCancel: () -> Void
    let onSave: (SecretEditorDraft) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(draft.isEditing ? "Edit Secret" : "Add Secret")
                .font(.headline)

            TextField("Name", text: $draft.name)

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
            .disabled(draft.scope == "global")
            .onChange(of: draft.scope) { _, newScope in
                if newScope == "global" {
                    draft.backend = "keychain"
                }
            }

            SecureField(
                draft.isEditing ? "Replacement value (leave blank to keep current value)" : "Value",
                text: $draft.replacementValue
            )

            if draft.backend == "env_file" {
                Text("File-backed secrets are stored in a Pnevma-managed .env.local block.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            HStack {
                Button("Cancel", action: onCancel)
                Spacer()
                Button(draft.isEditing ? "Save" : "Add") {
                    onSave(draft)
                }
                .buttonStyle(.borderedProminent)
                .disabled(draft.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || (!draft.isEditing && draft.replacementValue.isEmpty))
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
                self.secrets.removeAll { $0.id == secret.id }
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
                self.showActionError(
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
                self.showActionError("Wrote template for \(result.count) secrets to \(result.path).")
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

    override init(frame: NSRect) {
        super.init(frame: frame)
        _ = addSwiftUISubview(SecretsManagerView())
    }

    required init?(coder: NSCoder) { fatalError() }
}
