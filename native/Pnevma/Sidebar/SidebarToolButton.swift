import SwiftUI

// MARK: - SidebarToolButton

struct SidebarToolButton: View {
    let tool: SidebarToolItem
    var isActive: Bool = false
    var accessibilityID: String?
    var onOpenAsTab: (() -> Void)?
    var onOpenAsPane: (() -> Void)?
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: tool.icon)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(tool.isStub ? .tertiary : .secondary)
                    .frame(width: 18, alignment: .center)

                Text(tool.title)
                    .font(.callout)
                    .foregroundStyle(tool.isStub ? .tertiary : .primary)
                    .frame(maxWidth: .infinity, alignment: .leading)

                if tool.isStub {
                    Text("Soon")
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(Capsule().fill(Color.secondary.opacity(DesignTokens.Opacity.subtle)))
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(
                RoundedRectangle(cornerRadius: 5)
                    .fill(isActive ? Color.primary.opacity(DesignTokens.Opacity.light) :
                          isHovering ? Color.primary.opacity(DesignTokens.Opacity.subtle) : Color.clear)
            )
        }
        .buttonStyle(.plain)
        .contentShape(RoundedRectangle(cornerRadius: 5))
        .onHover { isHovering = $0 }
        .accessibilityElement(children: .ignore)
        .contextMenu {
            if !tool.isStub {
                Button {
                    onOpenAsTab?()
                } label: {
                    Label("Show in Tab", systemImage: "plus.square")
                }
                Button {
                    onOpenAsPane?()
                } label: {
                    Label("Show in Split Pane", systemImage: "rectangle.split.2x1")
                }
            }
        }
        .accessibilityLabel(tool.title + (tool.isStub ? ", coming soon" : ""))
        .accessibilityIdentifier(accessibilityID ?? "sidebar.tool.\(tool.id)")
    }
}
