import Cocoa
import SwiftUI

// MARK: - CapsuleButton

/// A small capsule-shaped view with icon + text label, styled for titlebar use.
/// Handles its own click and hover — works in the titlebar because it's added
/// as a direct subview of windowContent (not nested in a container).
final class CapsuleButton: NSView {
    private var trackingArea: NSTrackingArea?
    private var isHovering = false
    private let label: String
    private let iconImage: NSImage?
    weak var target: AnyObject?
    var action: Selector?

    override var mouseDownCanMoveWindow: Bool { false }
    override var isFlipped: Bool { false }

    init(icon: String, label: String) {
        self.label = label
        self.iconImage = NSImage(
            systemSymbolName: icon,
            accessibilityDescription: label
        )?.withSymbolConfiguration(.init(pointSize: 10, weight: .semibold))
        super.init(frame: .zero)
        wantsLayer = true
        setAccessibilityLabel(label)
        toolTip = label
        NotificationCenter.default.addObserver(forName: GhosttyThemeProvider.didChangeNotification, object: nil, queue: .main) { [weak self] _ in
            self?.needsDisplay = true
        }
    }

    required init?(coder: NSCoder) { fatalError() }

    override var intrinsicContentSize: NSSize {
        let font = NSFont.systemFont(ofSize: 11, weight: .medium)
        let textSize = (label as NSString).size(withAttributes: [.font: font])
        let iconWidth: CGFloat = iconImage != nil ? 14 : 0
        return NSSize(width: textSize.width + iconWidth + 16, height: textSize.height + 2)
    }

    override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath(roundedRect: bounds, xRadius: bounds.height / 2, yRadius: bounds.height / 2)

        // Background
        GhosttyThemeProvider.shared.foregroundColor.withAlphaComponent(isHovering ? 0.12 : 0.06).setFill()
        path.fill()

        // Border
        GhosttyThemeProvider.shared.foregroundColor.withAlphaComponent(isHovering ? 0.2 : 0.1).setStroke()
        path.lineWidth = 0.5
        path.stroke()

        // Content
        let textColor: NSColor = isHovering ? .controlAccentColor : .secondaryLabelColor
        let font = NSFont.systemFont(ofSize: 11, weight: .medium)
        let textSize = (label as NSString).size(withAttributes: [.font: font])

        var x = (bounds.width - textSize.width - (iconImage != nil ? 14 : 0)) / 2

        if let img = iconImage {
            let tinted = img.copy() as! NSImage
            tinted.lockFocus()
            textColor.set()
            NSRect(origin: .zero, size: tinted.size).fill(using: .sourceAtop)
            tinted.unlockFocus()
            let imgY = (bounds.height - 12) / 2
            tinted.draw(in: NSRect(x: x, y: imgY, width: 12, height: 12))
            x += 14
        }

        let textY = (bounds.height - textSize.height) / 2
        (label as NSString).draw(
            at: NSPoint(x: x, y: textY),
            withAttributes: [.font: font, .foregroundColor: textColor]
        )
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        guard let action, let target else { return }
        NSApp.sendAction(action, to: target, from: self)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let existing = trackingArea { removeTrackingArea(existing) }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeAlways],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        isHovering = true
        needsDisplay = true
    }

    override func mouseExited(with event: NSEvent) {
        isHovering = false
        needsDisplay = true
    }
}

// MARK: - LayoutTemplatePopoverView

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

// MARK: - CommitPopoverView

struct CommitPopoverView: View {
    let branch: String?
    let onCommit: (String) -> Void
    let onCancel: () -> Void

    @State private var commitMessage = ""
    @FocusState private var isFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Commit Message")
                .font(.headline)

            if let branch {
                HStack(spacing: 4) {
                    Image(systemName: "arrow.triangle.branch")
                    Text(branch)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            TextField("Describe your changes…", text: $commitMessage, axis: .vertical)
                .textFieldStyle(.plain)
                .lineLimit(3...6)
                .padding(8)
                .background(RoundedRectangle(cornerRadius: 6).fill(.quaternary))
                .focused($isFocused)
                .onSubmit {
                    let msg = commitMessage.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !msg.isEmpty { onCommit(msg) }
                }

            HStack {
                Spacer()
                Button("Cancel") { onCancel() }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)

                Button("Commit") {
                    let msg = commitMessage.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !msg.isEmpty { onCommit(msg) }
                }
                .buttonStyle(.borderedProminent)
                .disabled(commitMessage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(12)
        .frame(width: 320)
        .onAppear { isFocused = true }
    }
}
