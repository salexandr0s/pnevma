import SwiftUI

/// Extracted run card for reuse in CommandCenterView and AgentStrip context menu.
struct CommandCenterRunCard: View {
    let runID: String
    let taskTitle: String?
    let provider: String?
    let model: String?
    let state: String
    let attentionReason: String?
    let costUSD: Double
    let startedAt: Date
    let lastActivityAt: Date

    private var stateStyle: StatusChipStyle {
        switch state {
        case "active", "running": return .success
        case "stuck", "retrying": return .warning
        case "failed", "error": return .error
        default: return .default
        }
    }

    private var elapsed: String {
        let interval = Date().timeIntervalSince(startedAt)
        if interval < 60 { return "\(Int(interval))s" }
        if interval < 3600 { return "\(Int(interval / 60))m" }
        return String(format: "%.1fh", interval / 3600)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            // Title + state
            HStack {
                Text(taskTitle ?? runID)
                    .font(.body.weight(.medium))
                    .lineLimit(1)
                Spacer()
                StatusChipView(state, style: stateStyle)
            }

            // Provider / model / cost / time
            HStack(spacing: 8) {
                if let provider {
                    Text(provider)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if let model {
                    Text(model)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
                Spacer()
                if costUSD > 0 {
                    Text(String(format: "$%.2f", costUSD))
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                }
                Text(elapsed)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }

            // Attention reason
            if let reason = attentionReason {
                HStack(spacing: 4) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                    Text(reason)
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }
        }
        .padding(8)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(Color.secondary.opacity(DesignTokens.Opacity.subtle))
        )
        .accessibilityIdentifier("commandCenter.runCard.\(runID)")
    }
}
