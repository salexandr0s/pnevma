import SwiftUI

/// Collapsible section header for sidebar project groups.
struct SidebarSectionHeader: View {
    let title: String
    var count: Int?
    var isCollapsible: Bool = true
    var isCollapsed: Bool = false
    var onToggle: (() -> Void)?
    var onAdd: (() -> Void)?

    @State private var isHovering = false

    var body: some View {
        Button(action: { if isCollapsible { onToggle?() } }) {
            HStack(spacing: 4) {
                if isCollapsible {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.tertiary)
                        .rotationEffect(.degrees(isCollapsed ? 0 : 90))
                        .frame(width: 12)
                }

                Text(title)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)

                if let count {
                    Text("\(count)")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .background(Capsule().fill(Color.secondary.opacity(0.1)))
                }

                Spacer()

                if let onAdd, isHovering {
                    Button(action: onAdd) {
                        Image(systemName: "plus")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(.secondary)
                            .frame(width: 20, height: 20)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("Add workspace to \(title)")
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .accessibilityLabel("\(title) section\(isCollapsed ? ", collapsed" : "")")
        .accessibilityIdentifier("sidebar.section.\(title.lowercased())")
    }
}

/// Small label for sub-groups within a project (Attention, Active, Review, Idle).
struct SmallSubgroupLabel: View {
    let text: String

    init(_ text: String) {
        self.text = text
    }

    var body: some View {
        Text(text)
            .font(.system(size: 10, weight: .medium))
            .foregroundStyle(.tertiary)
            .padding(.leading, 20)
            .padding(.top, 4)
            .padding(.bottom, 1)
    }
}
