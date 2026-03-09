import SwiftUI

// MARK: - NotificationBadge

struct NotificationBadge: View {
    let count: Int

    var body: some View {
        Text(count > 99 ? "99+" : "\(count)")
            .font(.caption2)
            .bold()
            .foregroundStyle(.white)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(Capsule().fill(Color.red))
    }
}

// MARK: - AddButton

struct AddButton: View {
    let action: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: "plus")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(isHovering ? Color.green : Color.secondary)
                .frame(width: 22, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .accessibilityLabel("Add workspace")
    }
}

// MARK: - CloseButton

struct CloseButton: View {
    let action: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: "xmark")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(isHovering ? Color.red : Color.secondary)
                .frame(width: 20, height: 20)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .accessibilityLabel("Close workspace")
    }
}

// MARK: - ToolsSectionHeader

struct ToolsSectionHeader: View {
    @Binding var isExpanded: Bool
    @State private var isHovering = false

    var body: some View {
        Button(action: {
            withAnimation(.easeInOut(duration: 0.15)) { isExpanded.toggle() }
        }) {
            HStack {
                Text("TOOLS")
                    .font(.system(size: 11))
                    .fontWeight(.semibold)
                    .foregroundStyle(.secondary)
                Spacer()
                Image(systemName: "chevron.up")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(isHovering ? Color.accentColor : .secondary)
                    .rotationEffect(.degrees(isExpanded ? 0 : 180))
                    .frame(width: 22, height: 22)
                    .contentShape(Rectangle())
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .accessibilityLabel(isExpanded ? "Collapse tools section" : "Expand tools section")
    }
}

// MARK: - SidebarPreferences

enum SidebarPreferences {
    private static let defaults = UserDefaults.standard

    /// How much to lighten the sidebar background relative to the terminal.
    /// 0.0 = exact terminal color, 0.05 = slight lightening (default).
    static var backgroundOffset: Double {
        get {
            let raw = defaults.object(forKey: "sidebarBackgroundOffset") as? Double ?? 0.05
            return max(0.0, min(0.3, raw))
        }
        set { defaults.set(newValue, forKey: "sidebarBackgroundOffset") }
    }
}
