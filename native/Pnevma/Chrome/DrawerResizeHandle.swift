import SwiftUI

struct DrawerResizeHandle: View {
    let currentHeight: CGFloat
    let availableHeight: CGFloat
    let onHeightChanged: (CGFloat) -> Void

    @State private var dragStartHeight: CGFloat?

    var body: some View {
        ZStack {
            Color.clear
                .frame(height: 18)

            Capsule(style: .continuous)
                .fill(Color.secondary.opacity(0.55))
                .frame(width: 46, height: 5)
        }
        .contentShape(Rectangle())
        .onHover { hovering in
            if hovering {
                NSCursor.openHand.push()
            } else {
                NSCursor.pop()
            }
        }
        .gesture(
            DragGesture(minimumDistance: 0, coordinateSpace: .global)
                .onChanged { value in
                    if dragStartHeight == nil {
                        NSCursor.pop()
                        NSCursor.closedHand.push()
                        dragStartHeight = currentHeight
                    }
                    guard let startHeight = dragStartHeight else { return }
                    var t = Transaction()
                    t.disablesAnimations = true
                    withTransaction(t) {
                        onHeightChanged(
                            DrawerSizing.clamp(
                                startHeight - value.translation.height,
                                availableHeight: availableHeight
                            )
                        )
                    }
                }
                .onEnded { _ in
                    NSCursor.pop()
                    NSCursor.openHand.push()
                    dragStartHeight = nil
                }
        )
        .help("Drag to resize")
        .accessibilityLabel("Resize drawer")
    }
}
