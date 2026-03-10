import SwiftUI

// MARK: - SidebarToolButton

struct SidebarToolButton: View {
    let tool: SidebarToolItem
    var isActive: Bool = false
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Label(tool.title, systemImage: tool.icon)
                    .font(.callout)
                    .labelStyle(.titleAndIcon)
                    .foregroundStyle(tool.isStub ? .tertiary : .primary)
                Spacer()
                if tool.isStub {
                    Text("Soon")
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(Capsule().fill(Color.secondary.opacity(DesignTokens.Opacity.subtle)))
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(
                RoundedRectangle(cornerRadius: 5)
                    .fill(isActive ? Color.primary.opacity(DesignTokens.Opacity.light) :
                          isHovering ? Color.primary.opacity(DesignTokens.Opacity.subtle) : Color.clear)
            )
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .accessibilityLabel(tool.title + (tool.isStub ? ", coming soon" : ""))
        .accessibilityIdentifier("sidebar.tool.\(tool.id)")
    }
}
