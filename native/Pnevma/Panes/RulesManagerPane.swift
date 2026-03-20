import SwiftUI
import Observation
import Cocoa

// MARK: - Data Models

struct ProjectRule: Identifiable, Decodable {
    let id: String
    var name: String
    var path: String
    var scope: String  // "rule" or "convention"
    var active: Bool
    var content: String
}

// MARK: - Backend Param Types

private struct UpsertRuleParams: Encodable {
    let name: String
    let content: String
    let scope: String
}

private struct DeleteRuleParams: Encodable {
    let id: String
}

private struct ToggleRuleParams: Encodable {
    let id: String
    let active: Bool
}

// MARK: - RulesManagerView

struct RulesManagerView: View {
    @State private var viewModel = RulesManagerViewModel()
    @State private var showDeleteAlert = false
    @State private var ruleToDelete: String? = nil

    var body: some View {
        NativePaneScaffold(
            title: "Rules & Conventions",
            subtitle: "Shared project guidance for agents and automation",
            systemImage: "list.bullet.clipboard",
            role: .manager,
            inlineHeaderIdentifier: "pane.rules.inlineHeader",
            inlineHeaderLabel: "Rules inline header"
        ) {
            Button("Add Rule") { viewModel.showAddSheet = true }
                .buttonStyle(.bordered)
                .disabled(!viewModel.isProjectOpen)
                .keyboardShortcut("n", modifiers: .command)
        } content: {
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
                    icon: "folder.badge.questionmark",
                    title: "No project open",
                    message: "Open a project to manage rules and conventions"
                )
            } else if viewModel.rules.isEmpty {
                EmptyStateView(
                    icon: "list.bullet.clipboard",
                    title: "No rules configured",
                    message: "Add rules to guide agent behavior"
                )
            } else {
                NativeCollectionShell {
                    List {
                        ForEach(viewModel.rules) { rule in
                            RuleRow(
                                rule: rule,
                                onToggle: { viewModel.toggleRule(rule: rule) },
                                onDelete: {
                                    ruleToDelete = rule.id
                                    showDeleteAlert = true
                                }
                            )
                            .accessibilityElement(children: .combine)
                        }
                    }
                    .listStyle(.inset)
                    .scrollContentBackground(.hidden)
                }
            }
        }
        .overlay(alignment: .bottom) {
            ErrorBanner(message: viewModel.actionError)
        }
        .alert("Delete Rule?", isPresented: $showDeleteAlert) {
            Button("Cancel", role: .cancel) {}
            Button("Delete", role: .destructive) {
                if let id = ruleToDelete {
                    viewModel.deleteRule(id: id)
                }
            }
        } message: {
            Text("This rule will be permanently removed.")
        }
        // sheet(isPresented:) is intentional: the sheet creates a new rule from scratch
        // with no pre-existing item, so sheet(item:) does not apply here.
        .sheet(isPresented: $viewModel.showAddSheet) {
            AddRuleSheet(onAdd: { name, content, scope in
                viewModel.addRule(name: name, description: content, type: scope)
            })
        }
        .accessibilityIdentifier("pane.rules")
        .task { await viewModel.activate() }
    }
}

// MARK: - RuleRow

struct RuleRow: View {
    let rule: ProjectRule
    let onToggle: () -> Void
    let onDelete: () -> Void

    var body: some View {
        HStack {
            Toggle("", isOn: Binding(
                get: { rule.active },
                set: { _ in onToggle() }
            ))
            .toggleStyle(.switch)
            .labelsHidden()

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(rule.name)
                        .font(.body)
                        .fontWeight(.medium)
                    Text(rule.scope)
                        .font(.caption2)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(Capsule().fill(Color.secondary.opacity(0.15)))
                }
                Text(rule.content)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }

            Spacer()

            Button(action: onDelete) {
                Image(systemName: "trash")
                    .foregroundStyle(.red)
            }
            .buttonStyle(.plain)
        }
        .padding(.vertical, 4)
    }
}

// MARK: - AddRuleSheet

struct AddRuleSheet: View {
    let onAdd: (String, String, String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var content = ""
    @State private var scope = "rule"

    var body: some View {
        VStack(spacing: 16) {
            Text("Add Rule")
                .font(.headline)

            TextField("Name", text: $name)
            TextField("Content", text: $content)

            Picker("Type", selection: $scope) {
                Text("Rule").tag("rule")
                Text("Convention").tag("convention")
            }
            .pickerStyle(.segmented)

            HStack {
                Button("Cancel") { dismiss() }
                Spacer()
                Button("Add") {
                    onAdd(name, content, scope)
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .disabled(name.isEmpty || content.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 400)
    }
}

// MARK: - ViewModel

@Observable @MainActor
final class RulesManagerViewModel {
    var rules: [ProjectRule] = []
    var showAddSheet = false
    var actionError: String?
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
            guard event.name == "project_refreshed" else { return }
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

    func load() {
        rulesGeneration &+= 1
        let generation = rulesGeneration
        guard let bus = commandBus else {
            actionError = "Backend connection unavailable"
            scheduleDismissActionError()
            return
        }
        Task { [weak self] in
            guard let self else { return }
            do {
                let fetched: [ProjectRule] = try await bus.call(method: "rules.list", params: nil)
                guard self.rulesGeneration == generation else { return }
                self.rules = fetched
                self.projectStatusMessage = nil
            } catch {
                guard self.rulesGeneration == generation else { return }
                self.handleLoadFailure(error)
            }
        }
    }

    func addRule(name: String, description: String, type: String) {
        guard let bus = commandBus else {
            actionError = "Backend connection unavailable"
            scheduleDismissActionError()
            return
        }
        let params = UpsertRuleParams(name: name, content: description, scope: type)
        Task { [weak self] in
            guard let self else { return }
            do {
                let created: ProjectRule = try await bus.call(method: "rules.upsert", params: params)
                self.rules.append(created)
            } catch {
                self.actionError = error.localizedDescription
                self.scheduleDismissActionError()
            }
        }
    }

    func deleteRule(id: String) {
        guard let bus = commandBus else {
            actionError = "Backend connection unavailable"
            scheduleDismissActionError()
            return
        }
        guard let index = rules.firstIndex(where: { $0.id == id }) else { return }
        let rule = rules.remove(at: index)
        Task { [weak self] in
            guard let self else { return }
            do {
                let _: OkResponse = try await bus.call(
                    method: "rules.delete",
                    params: DeleteRuleParams(id: rule.id)
                )
            } catch {
                self.actionError = error.localizedDescription
                self.scheduleDismissActionError()
                // Re-insert on failure; find the closest valid position.
                let insertAt = min(index, self.rules.count)
                self.rules.insert(rule, at: insertAt)
            }
        }
    }

    private var togglingRuleIDs = Set<String>()
    private var rulesGeneration: UInt64 = 0

    func toggleRule(rule: ProjectRule) {
        guard let bus = commandBus else {
            actionError = "Backend connection unavailable"
            scheduleDismissActionError()
            return
        }
        guard togglingRuleIDs.insert(rule.id).inserted else { return }
        let generation = rulesGeneration
        // Optimistically flip the active state locally.
        if let idx = rules.firstIndex(where: { $0.id == rule.id }) {
            rules[idx].active.toggle()
        }
        let newActive = !rule.active
        Task { [weak self] in
            guard let self else { return }
            defer { self.togglingRuleIDs.remove(rule.id) }
            do {
                let updated: ProjectRule = try await bus.call(
                    method: "rules.toggle",
                    params: ToggleRuleParams(id: rule.id, active: newActive)
                )
                guard self.rulesGeneration == generation else { return }
                if let idx = self.rules.firstIndex(where: { $0.id == updated.id }) {
                    self.rules[idx] = updated
                }
            } catch {
                self.actionError = error.localizedDescription
                self.scheduleDismissActionError()
                guard self.rulesGeneration == generation else { return }
                // Roll back the optimistic flip.
                if let idx = self.rules.firstIndex(where: { $0.id == rule.id }) {
                    self.rules[idx].active = rule.active
                }
            }
        }
    }

    // MARK: - Private

    private func handleActivationState(_ state: ActiveWorkspaceActivationState) {
        rulesGeneration &+= 1
        switch state {
        case .idle, .opening:
            isProjectOpen = false
            projectStatusMessage = "Waiting for project activation..."
            rules = []
        case .closed:
            isProjectOpen = false
            projectStatusMessage = nil
            rules = []
        case .open:
            isProjectOpen = true
            projectStatusMessage = nil
            load()
        case .failed(_, _, let message):
            isProjectOpen = false
            projectStatusMessage = nil
            rules = []
            actionError = message
            scheduleDismissActionError()
        }
    }

    private func handleLoadFailure(_ error: Error) {
        if PnevmaError.isProjectNotReady(error) {
            isProjectOpen = false
            projectStatusMessage = "Waiting for project activation..."
            rules = []
            actionError = nil
            return
        }

        actionError = error.localizedDescription
        scheduleDismissActionError()
    }

    private func scheduleDismissActionError() {
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(5))
            self?.actionError = nil
        }
    }

    private func refreshIfActive() {
        guard activationHub.currentState.isOpen else { return }
        load()
    }
}

// MARK: - NSView Wrapper

final class RulesManagerPaneView: NSView, PaneContent {
    let paneID = PaneID()
    let paneType = "rules"
    let shouldPersist = true
    var title: String { "Rules" }

    init(frame: NSRect, chromeContext: PaneChromeContext = .standard) {
        super.init(frame: frame)
        _ = addSwiftUISubview(RulesManagerView(), chromeContext: chromeContext)
    }

    required init?(coder: NSCoder) { fatalError() }
}
