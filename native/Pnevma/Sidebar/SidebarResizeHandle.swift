import SwiftUI

/// Drag handle on the right edge of the sidebar for resize.
struct SidebarResizeHandle: View {
    @Binding var width: CGFloat
    let minWidth: CGFloat
    let maxWidth: CGFloat

    @State private var isHovering = false
    @State private var isDragging = false

    var body: some View {
        Rectangle()
            .fill(isDragging || isHovering ? Color.accentColor.opacity(0.3) : Color.clear)
            .frame(width: DesignTokens.Layout.dividerHoverWidth > 0 ? DesignTokens.Layout.dividerHoverWidth : 5)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 1)
                    .onChanged { value in
                        isDragging = true
                        let newWidth = width + value.translation.width
                        width = min(max(newWidth, minWidth), maxWidth)
                    }
                    .onEnded { _ in
                        isDragging = false
                    }
            )
            .onHover { hovering in
                isHovering = hovering
                if hovering || isDragging {
                    NSCursor.resizeLeftRight.push()
                } else {
                    NSCursor.pop()
                }
            }
            .accessibilityLabel("Resize sidebar")
    }
}
