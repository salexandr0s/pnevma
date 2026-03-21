import SwiftUI

// MARK: - Role Helpers

func roleIcon(for role: String) -> String {
    switch role.lowercased() {
    case "build": "hammer.fill"
    case "plan": "map.fill"
    case "review": "checkmark.shield.fill"
    case "ops": "gearshape.2.fill"
    case "research": "magnifyingglass"
    case "test": "testtube.2"
    default: "person.fill"
    }
}

func roleColor(for role: String) -> Color {
    switch role.lowercased() {
    case "build": Color(nsColor: .systemBlue)
    case "plan": Color(nsColor: .systemPurple)
    case "review": Color(nsColor: .systemOrange)
    case "ops": Color(nsColor: .systemGreen)
    case "research": Color(nsColor: .systemCyan)
    case "test": Color(nsColor: .systemYellow)
    default: Color(nsColor: .systemGray)
    }
}

// MARK: - StatusBadge

struct StatusBadge: View {
    let status: String

    var body: some View {
        Text(status)
            .font(.caption2.weight(.medium))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Capsule().fill(color.opacity(0.15)))
            .foregroundStyle(color)
    }

    private var color: Color {
        switch status.lowercased() {
        case "running": Color(nsColor: .systemBlue)
        case "completed": Color(nsColor: .systemGreen)
        case "failed": Color(nsColor: .systemRed)
        default: .secondary
        }
    }
}

// MARK: - RoleBadge

struct RoleBadge: View {
    let role: String

    var body: some View {
        Text(role)
            .font(.caption2.weight(.medium))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(roleColor(for: role).opacity(0.15))
            .foregroundStyle(roleColor(for: role))
            .clipShape(RoundedRectangle(cornerRadius: 4))
    }
}

// MARK: - SourceBadge

struct SourceBadge: View {
    let source: String

    private var logoAsset: String? {
        switch source.lowercased() {
        case "claude-code": "anthropic-logo"
        case "codex": "openai-logo"
        default: nil
        }
    }

    private var label: String {
        switch source.lowercased() {
        case "claude-code": "Claude"
        case "codex": "Codex"
        default: source
        }
    }

    private var color: Color {
        switch source.lowercased() {
        case "claude-code": Color(red: 0.85, green: 0.55, blue: 0.35)
        case "codex": Color(red: 0.3, green: 0.75, blue: 0.45)
        default: .secondary
        }
    }

    var body: some View {
        HStack(spacing: 3) {
            if let logoAsset {
                Image(logoAsset)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 10, height: 10)
                    .foregroundStyle(color)
            }
            Text(label)
        }
        .font(.caption2.weight(.medium))
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(color.opacity(0.12))
        .foregroundStyle(color)
        .clipShape(RoundedRectangle(cornerRadius: 4))
    }
}
