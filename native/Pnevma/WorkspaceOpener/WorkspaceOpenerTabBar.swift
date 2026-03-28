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
        .padding(4)
        .accessibilityElement(children: .contain)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color.primary.opacity(0.04))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(Color.primary.opacity(0.06), lineWidth: 1)
        )
    }
}

private struct OpenerTabButton: View {
    let tab: WorkspaceOpenerTab
    let isActive: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: tab.icon)
                    .font(.system(size: 11, weight: .medium))
                Text(tab.rawValue)
                    .font(.system(size: 12, weight: .medium))
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .foregroundStyle(isActive ? .primary : .secondary)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(isActive ? Color.primary.opacity(0.10) : Color.clear)
            )
            .overlay {
                if isActive {
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(Color.primary.opacity(0.08), lineWidth: 1)
                }
            }
            .contentShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isActive ? .isSelected : [])
        .accessibilityIdentifier("opener.tab.\(tab.accessibilityID)")
    }
}
