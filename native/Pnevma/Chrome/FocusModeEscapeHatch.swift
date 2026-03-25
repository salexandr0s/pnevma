import SwiftUI

/// Minimal floating overlay visible only in focus mode.
/// Invisible at rest, appears on mouse proximity in top-right corner.
struct FocusModeEscapeHatch: View {
    let onExitFocusMode: () -> Void

    @State private var isHovering = false

    var body: some View {
        VStack {
            HStack {
                Spacer()
                Button(action: onExitFocusMode) {
                    HStack(spacing: 4) {
                        Image(systemName: "arrow.up.left.and.arrow.down.right")
                            .font(.system(size: 10, weight: .medium))
                        if isHovering {
                            Text("Exit Focus")
                                .font(.caption)
                                .fontWeight(.medium)
                        }
                    }
                    .padding(.horizontal, isHovering ? 10 : 6)
                    .padding(.vertical, 6)
                    .background(
                        Capsule()
                            .fill(AccessibilityCheck.prefersReducedTransparency
                                ? AnyShapeStyle(ChromeSurfaceStyle.window.color)
                                : AnyShapeStyle(.ultraThinMaterial))
                            .shadow(color: .black.opacity(0.15), radius: 4, y: 2)
                    )
                    .opacity(isHovering ? 1.0 : 0.3)
                }
                .buttonStyle(.plain)
                .onHover { isHovering = $0 }
                .animation(ChromeMotion.animation(for: .hover), value: isHovering)
                .padding(12)
            }
            Spacer()
        }
        .allowsHitTesting(true)
        .accessibilityLabel("Exit focus mode")
        .accessibilityIdentifier("focusModeEscapeHatch")
    }
}
