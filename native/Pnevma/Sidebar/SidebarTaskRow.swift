import SwiftUI

/// Compact task row for the sidebar task list.
struct SidebarTaskRow: View {
    let task: TaskItem
    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 8) {
            // Status indicator dot
            Circle()
                .fill(task.status.tint)
                .frame(width: 6, height: 6)

            // Priority badge
            Text(task.priority.rawValue)
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(task.priority.color)
                .padding(.horizontal, 4)
                .padding(.vertical, 1)
                .background(
                    Capsule()
                        .fill(task.priority.color.opacity(0.12))
                )

            // Title
            Text(task.title)
                .font(.system(size: 12))
                .foregroundStyle(.primary)
                .lineLimit(1)
                .truncationMode(.tail)

            Spacer(minLength: 0)

            // Status icon
            Image(systemName: task.status.symbolName)
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(isHovering ? Color.primary.opacity(0.06) : Color.clear)
        )
        .contentShape(Rectangle())
        .onHover { isHovering = $0 }
        .accessibilityLabel("\(task.title), \(task.status.displayName), \(task.priority.rawValue)")
    }
}
