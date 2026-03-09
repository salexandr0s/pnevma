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
