import SwiftUI

/// Reusable error banner for pane overlays.
/// Replaces the duplicated inline error pattern across 8+ panes.
struct ErrorBanner: View {
    let message: String?

    var body: some View {
        if let message {
            HStack(spacing: DesignTokens.Spacing.sm) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .accessibilityHidden(true)
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, DesignTokens.Spacing.md)
            .padding(.vertical, DesignTokens.Spacing.sm)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(ChromeSurfaceStyle.toolbar.color)
            .overlay(alignment: .top) {
                Divider()
            }
        }
    }
}
