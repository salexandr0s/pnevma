import SwiftUI

enum ErrorBannerStyle {
    case warning
    case error

    var iconColor: Color {
        switch self {
        case .warning: return .orange
        case .error: return .red
        }
    }

    var backgroundTint: Color {
        switch self {
        case .warning: return .orange.opacity(0.06)
        case .error: return .red.opacity(0.06)
        }
    }

    var icon: String {
        switch self {
        case .warning: return "exclamationmark.triangle.fill"
        case .error: return "xmark.circle.fill"
        }
    }
}

/// Reusable error banner for pane overlays.
/// Replaces the duplicated inline error pattern across 8+ panes.
struct ErrorBanner: View {
    let message: String?
    let style: ErrorBannerStyle

    init(_ message: String?, style: ErrorBannerStyle = .warning) {
        self.message = message
        self.style = style
    }

    /// Legacy initializer for backward compatibility.
    init(message: String?) {
        self.message = message
        self.style = .warning
    }

    var body: some View {
        if let message {
            HStack(spacing: DesignTokens.Spacing.sm) {
                Image(systemName: style.icon)
                    .foregroundStyle(style.iconColor)
                    .accessibilityHidden(true)
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, DesignTokens.Spacing.md)
            .padding(.vertical, DesignTokens.Spacing.sm)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(style.backgroundTint)
            .background(ChromeSurfaceStyle.toolbar.color)
            .overlay(alignment: .top) {
                Divider()
            }
        }
    }
}
