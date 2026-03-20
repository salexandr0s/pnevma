import SwiftUI

// MARK: - SidebarNavigationMode

enum SidebarNavigationMode: String, CaseIterable {
    case workspaces, tasks

    var title: String { rawValue.capitalized }

    var icon: String {
        switch self {
        case .workspaces: return "square.stack.3d.up"
        case .tasks: return "checklist"
        }
    }
}

// MARK: - SidebarNavigationHeader

struct SidebarNavigationHeader: View {
    @Binding var mode: SidebarNavigationMode
    var onAddWorkspace: ((WorkspaceOpenerLaunchContext) -> Void)?

    var body: some View {
        VStack(spacing: 8) {
            navigationToggles
            newWorkspaceButton
        }
        .padding(DesignTokens.Spacing.sm)
    }

    // MARK: - Navigation Toggles

    private var navigationToggles: some View {
        HStack(spacing: 4) {
            ForEach(SidebarNavigationMode.allCases, id: \.self) { navMode in
                NavigationToggleButton(
                    mode: navMode,
                    isActive: mode == navMode,
                    action: { mode = navMode }
                )
            }
            Spacer()
        }
    }

    // MARK: - New Workspace Button

    private var newWorkspaceButton: some View {
        NewWorkspaceButton(action: { onAddWorkspace?(.generic) })
    }
}

// MARK: - NavigationToggleButton

private struct NavigationToggleButton: View {
    let mode: SidebarNavigationMode
    let isActive: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: mode.icon)
                    .font(.system(size: 11))
                Text(mode.title)
                    .font(.system(size: 12, weight: .medium))
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .foregroundStyle(isActive ? .primary : .secondary)
            .background(
                Capsule()
                    .fill(isActive ? Color.primary.opacity(0.10) : Color.clear)
            )
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(mode.title) navigation")
        .accessibilityAddTraits(isActive ? .isSelected : [])
    }
}

// MARK: - NewWorkspaceButton

private struct NewWorkspaceButton: View {
    let action: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color.accentColor.opacity(0.14))
                    .frame(width: 20, height: 20)
                    .overlay(
                        Image(systemName: "plus")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(.secondary)
                    )

                Text("New Workspace")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)

                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(isHovering ? Color.accentColor.opacity(0.14) : Color.accentColor.opacity(0.08))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .accessibilityLabel("New workspace")
        .accessibilityIdentifier("sidebar.newWorkspace")
    }
}
