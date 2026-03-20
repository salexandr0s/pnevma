import SwiftUI

struct SidebarFooter: View {
    var onOpenSettings: (() -> Void)?
    @State private var isHovering = false
    private let footerHeight = DesignTokens.Layout.toolDockHeight

    var body: some View {
        VStack(spacing: 0) {
            Divider()

            Button(action: { onOpenSettings?() }) {
                HStack(spacing: 12) {
                    Image(systemName: "gearshape")
                        .font(.system(size: 18, weight: .medium))
                    Text("Settings")
                        .font(.system(size: 13, weight: .semibold))
                    Spacer(minLength: 0)
                }
                .foregroundStyle(isHovering ? .primary : .secondary)
                .padding(.horizontal, 16)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(Color.primary.opacity(isHovering ? 0.065 : 0.04))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .stroke(Color.primary.opacity(isHovering ? 0.08 : 0.04), lineWidth: 1)
                )
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .frame(height: footerHeight - DesignTokens.Layout.dividerWidth)
            .background(Color.primary.opacity(0.02))
            .onHover { isHovering = $0 }
            .accessibilityLabel("Settings")
            .accessibilityIdentifier("sidebar.settings")
            .help("Open Settings")
        }
        .frame(height: footerHeight)
    }
}
