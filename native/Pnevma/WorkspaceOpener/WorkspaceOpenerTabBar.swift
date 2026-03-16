import SwiftUI

struct WorkspaceOpenerTabBar: View {
    @Binding var selectedTab: WorkspaceOpenerTab

    var body: some View {
        HStack(spacing: 2) {
            ForEach(WorkspaceOpenerTab.allCases) { tab in
                OpenerTabButton(
                    tab: tab,
                    isActive: selectedTab == tab,
                    action: { selectedTab = tab }
                )
            }
        }
    }
}

private struct OpenerTabButton: View {
    let tab: WorkspaceOpenerTab
    let isActive: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: tab.icon)
                    .font(.system(size: 11))
                Text(tab.rawValue)
                    .font(.system(size: 12, weight: .medium))
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .foregroundStyle(isActive ? .primary : .secondary)
            .background(
                Capsule().fill(isActive ? Color.primary.opacity(0.10) : Color.clear)
            )
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("opener.tab.\(tab.rawValue)")
    }
}
