import SwiftUI

// MARK: - StatusBadge

struct StatusBadge: View {
    let status: String
    var body: some View {
        Text(status)
            .font(.caption2)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Capsule().fill(color.opacity(0.15)))
            .foregroundStyle(color)
    }
    private var color: Color {
        switch status.lowercased() {
        case "running": return .blue
        case "completed": return .green
        case "failed": return .red
        default: return .secondary
        }
    }
}

// MARK: - RoleBadge

struct RoleBadge: View {
    let role: String

    var color: Color {
        switch role.lowercased() {
        case "build": return .blue
        case "plan": return .purple
        case "review": return .orange
        case "ops": return .green
        case "research": return .cyan
        case "test": return .yellow
        default: return .gray
        }
    }

    var body: some View {
        Text(role)
            .font(.caption2)
            .fontWeight(.medium)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(color.opacity(0.2))
            .foregroundStyle(color)
            .clipShape(.rect(cornerRadius: 4))
    }
}

// MARK: - SourceBadge

struct SourceBadge: View {
    let source: String

    var color: Color {
        switch source.lowercased() {
        case "claude-code": return .indigo
        case "codex": return .teal
        default: return .gray
        }
    }

    var label: String {
        switch source.lowercased() {
        case "claude-code": return "Claude"
        case "codex": return "Codex"
        default: return source
        }
    }

    var body: some View {
        Text(label)
            .font(.caption2)
            .fontWeight(.medium)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(color.opacity(0.2))
            .foregroundStyle(color)
            .clipShape(.rect(cornerRadius: 4))
    }
}
