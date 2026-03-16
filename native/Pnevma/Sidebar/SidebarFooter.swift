import SwiftUI

struct SidebarFooter: View {
    var onAddRepository: (() -> Void)?
    @State private var isHovering = false

    var body: some View {
        VStack(spacing: 0) {
            Divider()
            Button(action: { onAddRepository?() }) {
                HStack(spacing: 8) {
                    Image(systemName: "plus.circle")
                        .font(.system(size: 13, weight: .medium))
                    Text("Add repository")
                        .font(.system(size: 12, weight: .medium))
                    Spacer()
                }
                .foregroundStyle(isHovering ? .primary : .secondary)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onHover { isHovering = $0 }
            .accessibilityLabel("Add repository")
            .accessibilityIdentifier("sidebar.addRepository")
        }
    }
}
