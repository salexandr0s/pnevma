import SwiftUI

/// Individual chip in the agent strip.
struct AgentStripChip: View {
    let entry: AgentStripEntry
    let isSelected: Bool
    let onSelect: () -> Void

    @State private var isHovering = false

    private var stateColor: Color {
        switch entry.state {
        case "running": return .green
        case "waiting": return .blue
        case "error": return .red
        case "stuck": return .orange
        default: return .secondary
        }
    }

    private var chipBackground: some View {
        RoundedRectangle(cornerRadius: DesignTokens.Layout.agentStripHeight / 2)
            .fill(isSelected
                  ? Color.accentColor.opacity(0.15)
                  : (isHovering ? Color.secondary.opacity(0.1) : Color.secondary.opacity(0.05)))
    }

    private var chipOverlay: some View {
        RoundedRectangle(cornerRadius: DesignTokens.Layout.agentStripHeight / 2)
            .strokeBorder(isSelected ? Color.accentColor.opacity(0.3) : Color.clear, lineWidth: 1)
    }

    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: 4) {
                // State dot
                Circle()
                    .fill(stateColor)
                    .frame(width: DesignTokens.Layout.statusDotSize,
                           height: DesignTokens.Layout.statusDotSize)

                // Title
                Text(entry.title)
                    .font(.caption)
                    .fontWeight(.medium)
                    .lineLimit(1)

                // Elapsed time
                Text(entry.elapsedFormatted)
                    .font(.caption2)
                    .foregroundStyle(.secondary)

                // Attention indicator
                if entry.isAttention {
                    Image(systemName: "exclamationmark.circle.fill")
                        .font(.system(size: 9))
                        .foregroundStyle(.orange)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(chipBackground)
            .overlay(chipOverlay)
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .help("\(entry.title) — \(entry.state)\nLast activity: \(entry.lastActivityAge)")
        .accessibilityLabel("Agent: \(entry.title), \(entry.state)")
        .accessibilityIdentifier("agentStrip.chip.\(entry.id)")
    }
}
