import SwiftUI

enum StatusChipStyle {
    case `default`, success, warning, error

    var tint: Color {
        switch self {
        case .default: return .secondary
        case .success: return .green
        case .warning: return .orange
        case .error: return .red
        }
    }
}

struct StatusChipView: View {
    let icon: String?
    let label: String
    let style: StatusChipStyle

    init(_ label: String, icon: String? = nil, style: StatusChipStyle = .default) {
        self.label = label
        self.icon = icon
        self.style = style
    }

    var body: some View {
        HStack(spacing: 3) {
            if let icon {
                Image(systemName: icon)
                    .font(.system(size: 9, weight: .semibold))
            }
            Text(label)
                .font(.caption)
                .fontWeight(.medium)
        }
        .foregroundStyle(style.tint)
        .padding(.horizontal, 5)
        .padding(.vertical, 2)
        .background(
            Capsule().fill(style.tint.opacity(0.12))
        )
        .fixedSize()
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(label) status")
    }
}
