import SwiftUI

/// Reusable error banner for pane overlays.
/// Replaces the duplicated inline error pattern across 8+ panes.
struct ErrorBanner: View {
    let message: String?

    var body: some View {
        if let message {
            Text(message)
                .font(.caption)
                .foregroundStyle(.red)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color(nsColor: GhosttyThemeProvider.shared.backgroundColor))
        }
    }
}
