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
        ToolbarAttachmentScaffold(title: "Layout Templates") {
            Group {
                if !templates.isEmpty {
                    ScrollView {
                        VStack(spacing: DesignTokens.Spacing.xs) {
                            ForEach(templates) { template in
                                Button(action: { onSelect(template) }) {
                                    HStack(spacing: DesignTokens.Spacing.sm) {
                                        VStack(alignment: .leading, spacing: DesignTokens.Spacing.xs) {
                                            Text(template.name)
                                                .lineLimit(1)
                                            Text(panesSummary(template))
                                                .font(.subheadline)
                                                .foregroundStyle(.secondary)
                                                .lineLimit(2)
                                        }

                                        Spacer()

                                        if hoveredID == template.id {
                                            Button(role: .destructive) {
                                                onDelete(template)
                                            } label: {
                                                Label("Delete Template", systemImage: "trash")
                                                    .labelStyle(.iconOnly)
                                            }
                                            .buttonStyle(.plain)
                                            .foregroundStyle(.secondary)
                                        }
                                    }
                                    .padding(.horizontal, DesignTokens.Spacing.sm + DesignTokens.Spacing.xs)
                                    .padding(.vertical, DesignTokens.Spacing.sm)
                                    .background(
                                        RoundedRectangle(cornerRadius: 10)
                                            .fill(hoveredID == template.id ? ChromeSurfaceStyle.groupedCard.selectionColor : Color.clear)
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
                        .padding(DesignTokens.Spacing.md)
                    }
                } else if !isSaving {
                    EmptyStateView(
                        icon: "square.3.layers.3d",
                        title: "No Saved Templates",
                        message: "Save the current layout to reuse it later."
                    )
                }
            }
        } footer: {
            if isSaving {
                VStack(alignment: .leading, spacing: DesignTokens.Spacing.sm) {
                    TextField("Template name", text: $templateName)
                        .textFieldStyle(.plain)
                        .padding(DesignTokens.Spacing.sm + DesignTokens.Spacing.xs)
                        .background(
                            RoundedRectangle(cornerRadius: 10)
                                .fill(ChromeSurfaceStyle.groupedCard.color)
                        )
                        .focused($nameFocused)
                        .onSubmit {
                            saveIfPossible()
                        }

                    HStack(spacing: DesignTokens.Spacing.sm) {
                        Spacer()

                        Button("Cancel") {
                            isSaving = false
                            templateName = ""
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)

                        Button("Save") {
                            saveIfPossible()
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(trimmedTemplateName.isEmpty)
                    }
                }
            } else {
                HStack {
                    Button {
                        isSaving = true
                        Task { @MainActor in nameFocused = true }
                    } label: {
                        Label("Save Current Layout", systemImage: "plus.circle")
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(Color.accentColor)
                    Spacer()
                }
            }
        }
        .frame(width: 320)
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

    private var trimmedTemplateName: String {
        templateName.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func saveIfPossible() {
        guard trimmedTemplateName.isEmpty == false else { return }
        onSave(trimmedTemplateName)
    }
}
