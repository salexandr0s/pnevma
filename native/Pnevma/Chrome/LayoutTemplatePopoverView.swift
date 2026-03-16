import SwiftUI

struct LayoutTemplatePopoverView: View {
    let templates: [LayoutTemplate]
    let onSave: (String) -> Void
    let onSelect: (LayoutTemplate) -> Void
    let onDelete: (LayoutTemplate) -> Void
    let onDismiss: () -> Void

    @State private var isSaving = false
    @State private var templateName = ""
    @State private var hoveredID: UUID?
    @FocusState private var nameFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Layout Templates")
                .font(.headline)

            // Template list
            if !templates.isEmpty {
                ScrollView {
                    VStack(spacing: 2) {
                        ForEach(templates) { template in
                            Button(action: { onSelect(template) }) {
                                HStack {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(template.name)
                                            .font(.body)
                                        Text(panesSummary(template))
                                            .font(.caption2)
                                            .foregroundStyle(.tertiary)
                                    }

                                    Spacer()

                                    if hoveredID == template.id {
                                        Button(role: .destructive) {
                                            onDelete(template)
                                        } label: {
                                            Image(systemName: "trash")
                                                .font(.caption)
                                        }
                                        .buttonStyle(.plain)
                                        .foregroundStyle(.secondary)
                                    }
                                }
                                .padding(.horizontal, 8)
                                .padding(.vertical, 6)
                                .background(
                                    RoundedRectangle(cornerRadius: 6)
                                        .fill(hoveredID == template.id ? Color.accentColor.opacity(0.1) : Color.clear)
                                )
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("Select template: \(template.name)")
                            .onHover { isHovering in
                                hoveredID = isHovering ? template.id : nil
                            }
                        }
                    }
                }
                .frame(maxHeight: 200)
            } else if !isSaving {
                Text("No saved templates yet.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 8)
            }

            Divider()

            // Save section
            if isSaving {
                TextField("Template name", text: $templateName)
                    .textFieldStyle(.plain)
                    .padding(8)
                    .background(RoundedRectangle(cornerRadius: 6).fill(.quaternary))
                    .focused($nameFocused)
                    .onSubmit {
                        let name = templateName.trimmingCharacters(in: .whitespacesAndNewlines)
                        if !name.isEmpty { onSave(name) }
                    }

                HStack {
                    Spacer()
                    Button("Cancel") {
                        isSaving = false
                        templateName = ""
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)

                    Button("Save") {
                        let name = templateName.trimmingCharacters(in: .whitespacesAndNewlines)
                        if !name.isEmpty { onSave(name) }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(templateName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            } else {
                Button {
                    isSaving = true
                    Task { @MainActor in nameFocused = true }
                } label: {
                    Label("Save Current Layout", systemImage: "plus.circle")
                        .font(.subheadline)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 4)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .frame(width: 300)
    }

    private func panesSummary(_ template: LayoutTemplate) -> String {
        var counts: [String: Int] = [:]
        for pane in template.panes {
            counts[pane.type, default: 0] += 1
        }
        return counts
            .sorted { $0.key < $1.key }
            .map { "\($0.value)x \($0.key)" }
            .joined(separator: ", ")
    }
}
