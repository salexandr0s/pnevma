import SwiftUI
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
    @StateObject private var viewModel = RulesManagerViewModel()

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Rules & Conventions")
                    .font(.headline)
                Spacer()
                Button("Add Rule") { viewModel.showAddSheet = true }
                    .buttonStyle(.bordered)
                    .disabled(!viewModel.isProjectOpen)
            }
            .padding(12)

            Divider()

            if !viewModel.isProjectOpen {
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
                List {
                    ForEach(viewModel.rules) { rule in
                        RuleRow(
                            rule: rule,
                            onToggle: { viewModel.toggleRule(rule: rule) },
                            onDelete: { viewModel.deleteRule(id: rule.id) }
                        )
                    }
                }
                .listStyle(.plain)
            }
        }
        .sheet(isPresented: $viewModel.showAddSheet) {
            AddRuleSheet(onAdd: { name, content, scope in
                viewModel.addRule(name: name, description: content, type: scope)
            })
        }
        .onAppear { viewModel.activate() }
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

@MainActor
final class RulesManagerViewModel: ObservableObject {
    @Published var rules: [ProjectRule] = []
    @Published var showAddSheet = false
    @Published private(set) var isProjectOpen = false

    private let commandBus: (any CommandCalling)?
    private let bridgeEventHub: BridgeEventHub
    private let activationHub: ActiveWorkspaceActivationHub
    private var bridgeObserverID: UUID?
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

    func activate() {
        handleActivationState(activationHub.currentState)
    }

    func load() {
        guard let bus = commandBus else { return }
        Task { [weak self] in
            guard let self else { return }
            do {
                let fetched: [ProjectRule] = try await bus.call(method: "rules.list", params: nil)
                self.rules = fetched
            } catch {
                // Leave existing rules in place on failure.
            }
        }
    }

    func addRule(name: String, description: String, type: String) {
        guard let bus = commandBus else { return }
        let params = UpsertRuleParams(name: name, content: description, scope: type)
        Task { [weak self] in
            guard let self else { return }
            do {
                let created: ProjectRule = try await bus.call(method: "rules.upsert", params: params)
                self.rules.append(created)
            } catch {
                // Ignore — no optimistic insert.
            }
        }
    }

    func deleteRule(id: String) {
        guard let bus = commandBus else { return }
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
                // Re-insert on failure; find the closest valid position.
                let insertAt = min(index, self.rules.count)
                self.rules.insert(rule, at: insertAt)
            }
        }
    }

    private var togglingRuleIDs = Set<String>()

    func toggleRule(rule: ProjectRule) {
        guard let bus = commandBus else { return }
        guard togglingRuleIDs.insert(rule.id).inserted else { return }
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
                if let idx = self.rules.firstIndex(where: { $0.id == updated.id }) {
                    self.rules[idx] = updated
                }
            } catch {
                // Roll back the optimistic flip.
                if let idx = self.rules.firstIndex(where: { $0.id == rule.id }) {
                    self.rules[idx].active = rule.active
                }
            }
        }
    }

    // MARK: - Private

    private func handleActivationState(_ state: ActiveWorkspaceActivationState) {
        switch state {
        case .idle, .opening, .closed:
            isProjectOpen = false
            rules = []
        case .open:
            isProjectOpen = true
            load()
        case .failed:
            isProjectOpen = false
            rules = []
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
    let shouldPersist = false
    var title: String { "Rules" }

    override init(frame: NSRect) {
        super.init(frame: frame)
        _ = addSwiftUISubview(RulesManagerView())
    }

    required init?(coder: NSCoder) { fatalError() }
}
