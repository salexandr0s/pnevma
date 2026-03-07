import SwiftUI
import Cocoa

// MARK: - Data Models

struct ProjectRule: Identifiable, Codable {
    let id: String
    var name: String
    var description: String
    var isEnabled: Bool
    let ruleType: String  // "rule" or "convention"
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
            }
            .padding(12)

            Divider()

            if viewModel.rules.isEmpty {
                Spacer()
                VStack(spacing: 8) {
                    Image(systemName: "list.bullet.clipboard")
                        .font(.largeTitle)
                        .foregroundStyle(.secondary)
                    Text("No rules configured")
                        .foregroundStyle(.secondary)
                }
                Spacer()
            } else {
                List {
                    ForEach(viewModel.rules.indices, id: \.self) { idx in
                        RuleRow(rule: $viewModel.rules[idx],
                                onDelete: { viewModel.deleteRule(at: idx) })
                    }
                }
                .listStyle(.plain)
            }
        }
        .sheet(isPresented: $viewModel.showAddSheet) {
            AddRuleSheet(onAdd: { name, desc, type in
                viewModel.addRule(name: name, description: desc, type: type)
            })
        }
    }
}

// MARK: - RuleRow

struct RuleRow: View {
    @Binding var rule: ProjectRule
    let onDelete: () -> Void

    var body: some View {
        HStack {
            Toggle("", isOn: $rule.isEnabled)
                .toggleStyle(.switch)
                .labelsHidden()

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(rule.name)
                        .font(.body)
                        .fontWeight(.medium)
                    Text(rule.ruleType)
                        .font(.caption2)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(Capsule().fill(Color.secondary.opacity(0.15)))
                }
                Text(rule.description)
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
    @State private var description = ""
    @State private var ruleType = "rule"

    var body: some View {
        VStack(spacing: 16) {
            Text("Add Rule")
                .font(.headline)

            TextField("Name", text: $name)
            TextField("Description", text: $description)

            Picker("Type", selection: $ruleType) {
                Text("Rule").tag("rule")
                Text("Convention").tag("convention")
            }
            .pickerStyle(.segmented)

            HStack {
                Button("Cancel") { dismiss() }
                Spacer()
                Button("Add") {
                    onAdd(name, description, ruleType)
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .disabled(name.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 400)
    }
}

// MARK: - ViewModel

final class RulesManagerViewModel: ObservableObject {
    @Published var rules: [ProjectRule] = []
    @Published var showAddSheet = false

    func load() {
        // pnevma_call("rule.list", "{}")
    }

    func addRule(name: String, description: String, type: String) {
        let rule = ProjectRule(id: UUID().uuidString, name: name,
                               description: description, isEnabled: true, ruleType: type)
        rules.append(rule)
        // pnevma_call("rule.create", ...)
    }

    func deleteRule(at index: Int) {
        let rule = rules.remove(at: index)
        _ = rule // pnevma_call("rule.delete", ...)
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
