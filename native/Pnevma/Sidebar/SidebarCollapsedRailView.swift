import SwiftUI

/// Icon-only sidebar shown when sidebar is in collapsed mode.
struct SidebarCollapsedRailView: View {
    var workspaceManager: WorkspaceManager
    var onSelectWorkspace: (UUID) -> Void
    var onNavigateBack: (() -> Void)?
    var onNavigateForward: (() -> Void)?
    var canNavigateBack: Bool = false
    var canNavigateForward: Bool = false

    @Environment(GhosttyThemeProvider.self) private var theme

    private var railBackground: Color {
        Color(nsColor: theme.backgroundColor)
    }

    var body: some View {
        VStack(spacing: 4) {
            // Workspace indicators
            ScrollView(.vertical, showsIndicators: true) {
                VStack(spacing: 4) {
                    ForEach(workspaceManager.workspaces) { workspace in
                        collapsedWorkspaceIndicator(workspace)
                    }
                }
                .padding(.vertical, 8)
            }
            .scrollIndicators(.hidden)

            Spacer()

            // Navigation arrows
            if canNavigateBack || canNavigateForward {
                VStack(spacing: 2) {
                    Button { onNavigateBack?() } label: {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 11, weight: .medium))
                            .frame(width: 28, height: 28)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(!canNavigateBack)
                    .foregroundStyle(canNavigateBack ? .secondary : .quaternary)

                    Button { onNavigateForward?() } label: {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 11, weight: .medium))
                            .frame(width: 28, height: 28)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(!canNavigateForward)
                    .foregroundStyle(canNavigateForward ? .secondary : .quaternary)
                }
                .padding(.bottom, 8)
            }
        }
        .frame(width: DesignTokens.Layout.sidebarCollapsedWidth)
        .background(railBackground)
        .accessibilityIdentifier("sidebar.collapsedRail")
    }

    private func collapsedWorkspaceIndicator(_ workspace: Workspace) -> some View {
        let isActive = workspace.id == workspaceManager.activeWorkspaceID
        let indicatorColor: Color = {
            if let hex = workspace.customColor, let nsColor = NSColor(hexString: hex) {
                return Color(nsColor: nsColor)
            }
            return isActive ? Color(nsColor: GhosttyThemeProvider.shared.foregroundColor) : .secondary.opacity(0.3)
        }()
        let initial = workspace.name.prefix(1).uppercased()

        return Button { onSelectWorkspace(workspace.id) } label: {
            ZStack {
                Circle()
                    .fill(indicatorColor.opacity(isActive ? 0.2 : 0.1))
                    .frame(width: 32, height: 32)
                Text(initial)
                    .font(.system(size: 13, weight: isActive ? .semibold : .regular))
                    .foregroundStyle(isActive ? Color(nsColor: GhosttyThemeProvider.shared.foregroundColor) : .secondary)
            }
        }
        .buttonStyle(.plain)
        .help(workspace.name)
        .accessibilityLabel("Workspace: \(workspace.name)")
    }
}
