import SwiftUI

/// Collapsible section header for sidebar project groups.
struct SidebarSectionHeader: View {
    let title: String
    var count: Int?
    var isCollapsible: Bool = true
    var isCollapsed: Bool = false
    var onToggle: (() -> Void)?
    var onAdd: (() -> Void)?

    @State private var isHoveringAdd = false

    private var projectColor: Color {
        ProjectColorPalette.color(for: title)
    }

    var body: some View {
        HStack(spacing: 8) {
            // Project initial circle — colored per project
            let initial = title.prefix(1).uppercased()
            ZStack {
                Circle()
                    .fill(projectColor.opacity(0.20))
                    .frame(width: 24, height: 24)
                Text(initial)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(projectColor.opacity(0.85))
            }

            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.primary)

            if let count {
                Text("(\(count))")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                    .monospacedDigit()
            }

            Spacer()

            if let onAdd {
                Button(action: onAdd) {
                    Image(systemName: "plus")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(isHoveringAdd ? Color.green : Color.secondary)
                        .frame(width: 20, height: 20)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .onHover { isHoveringAdd = $0 }
                .help("Add workspace to \(title)")
            }

            if isCollapsible {
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.tertiary)
                    .rotationEffect(.degrees(isCollapsed ? 0 : 90))
                    .frame(width: 12)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .onTapGesture { if isCollapsible { onToggle?() } }
        .accessibilityAddTraits(isCollapsible ? .isButton : [])
        .accessibilityLabel("\(title) section\(isCollapsed ? ", collapsed" : "")")
        .accessibilityIdentifier("sidebar.section.\(title.lowercased())")
    }
}

