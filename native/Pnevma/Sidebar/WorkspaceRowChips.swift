import SwiftUI

/// Diff stats chip showing +N -M.
struct DiffStatsChip: View {
    let insertions: Int
    let deletions: Int

    var body: some View {
        HStack(spacing: 2) {
            if insertions > 0 {
                Text("+\(insertions)")
                    .foregroundStyle(.green)
            }
            if deletions > 0 {
                Text("-\(deletions)")
                    .foregroundStyle(.red)
            }
        }
        .font(.caption.weight(.medium).monospaced())
        .fixedSize()
        .accessibilityLabel("\(insertions) insertions, \(deletions) deletions")
    }
}

/// PR link chip showing #1234.
struct PRChip: View {
    let number: UInt64
    var url: String?

    @State private var isHovering = false

    private var destinationURL: URL? {
        guard let url else { return nil }
        return URL(string: url)
    }

    var body: some View {
        Group {
            if let destinationURL {
                Link(destination: destinationURL) {
                    chipLabel
                }
            } else {
                chipLabel
            }
        }
        .onHover { isHovering = $0 }
        .help(url ?? "PR #\(number)")
        .fixedSize()
        .accessibilityLabel("Pull request \(number)")
    }

    private var chipLabel: some View {
        Text("#\(number)")
            .font(.caption.weight(.medium))
            .foregroundStyle(isHovering ? Color.accentColor : Color.secondary)
            .padding(.horizontal, 4)
            .padding(.vertical, 1)
            .background(
                Capsule().fill(Color.accentColor.opacity(isHovering ? 0.15 : 0.08))
            )
    }
}

/// CI status chip.
struct CIChip: View {
    let status: String  // "pass", "failed", "running", "none"

    private var icon: String {
        switch status {
        case "pass": return "checkmark.circle.fill"
        case "failed": return "xmark.circle.fill"
        case "running": return "arrow.triangle.2.circlepath"
        default: return "questionmark.circle"
        }
    }

    private var chipColor: Color {
        switch status {
        case "pass": return .green
        case "failed": return .red
        case "running": return .orange
        default: return .secondary
        }
    }

    var body: some View {
        Image(systemName: icon)
            .font(.system(size: 10))
            .foregroundStyle(chipColor)
            .help("CI: \(status)")
            .accessibilityLabel("CI status: \(status)")
    }
}

/// Attention indicator chip.
struct AttentionChip: View {
    let reason: String

    var body: some View {
        HStack(spacing: 2) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 9))
            Text("Attention")
                .font(.caption.weight(.medium))
        }
        .foregroundStyle(.orange)
        .help(reason)
        .fixedSize()
        .accessibilityLabel("Needs attention: \(reason)")
    }
}
