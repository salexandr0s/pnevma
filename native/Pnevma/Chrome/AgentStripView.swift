import SwiftUI

/// Horizontal strip of agent chips above content area.
struct AgentStripView: View {
    var state: AgentStripState
    var selectedSessionID: String?
    var onSelectSession: (String) -> Void

    @Environment(GhosttyThemeProvider.self) private var theme

    private var stripBackground: Color {
        Color(nsColor: theme.backgroundColor)
    }

    var body: some View {
        if state.hasEntries {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 4) {
                    ForEach(state.entries) { entry in
                        AgentStripChip(
                            entry: entry,
                            isSelected: entry.id == selectedSessionID,
                            onSelect: { onSelectSession(entry.id) }
                        )
                    }
                }
                .padding(.horizontal, 8)
            }
            .frame(height: DesignTokens.Layout.agentStripHeight)
            .background(stripBackground.opacity(0.95))
            .overlay(alignment: .bottom) {
                Divider()
            }
            .accessibilityIdentifier("agentStrip")
        }
    }
}
