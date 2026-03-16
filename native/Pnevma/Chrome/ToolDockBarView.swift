import AppKit
import Observation
import SwiftUI

@Observable
@MainActor
final class ToolDockState {
    var activeToolID: String?
    var notificationBadgeCount: Int = 0
}

struct ToolDockBarView: View {
    var workspaceManager: WorkspaceManager
    @Bindable var dockState: ToolDockState
    @Environment(GhosttyThemeProvider.self) private var theme
    @AppStorage("toolDockBackgroundOffset") private var toolDockOffset: Double = BackgroundTint.defaultOffset

    var onOpenTool: ((String) -> Void)?
    var onOpenToolAsTab: ((String) -> Void)?
    var onOpenToolAsPane: ((String) -> Void)?
    var onHoverChanged: ((Bool) -> Void)?

    private var backgroundColor: Color {
        let base = theme.backgroundColor
        let offset = BackgroundTint.clamped(toolDockOffset)
        if offset == 0 {
            return Color(nsColor: base)
        }
        let tinted = base.blended(withFraction: offset, of: .white) ?? base
        return Color(nsColor: tinted)
    }

    private var borderColor: Color {
        Color(nsColor: theme.splitDividerColor ?? .separatorColor)
    }

    private var tools: [SidebarToolItem] {
        sidebarTools(for: workspaceManager.activeWorkspace)
    }

    var body: some View {
        VStack(spacing: 0) {
            Rectangle()
                .fill(borderColor)
                .frame(height: DesignTokens.Layout.dividerWidth)

            GeometryReader { geometry in
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 0) {
                        Spacer(minLength: 0)
                        HStack(spacing: 6) {
                            ForEach(tools) { tool in
                                ToolDockItemButton(
                                    tool: tool,
                                    isActive: dockState.activeToolID == tool.id,
                                    badgeCount: badgeCount(for: tool),
                                    onOpenAsTab: { onOpenToolAsTab?(tool.id) },
                                    onOpenAsPane: { onOpenToolAsPane?(tool.id) }
                                ) {
                                    onOpenTool?(tool.id)
                                }
                            }
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(.vertical, 6)
                    .frame(minWidth: geometry.size.width)
                }
                .scrollIndicators(.hidden)
            }
            .frame(height: DesignTokens.Layout.toolDockHeight)
        }
        .background(backgroundColor)
        .contentShape(Rectangle())
        .onHover { isHovering in
            onHoverChanged?(isHovering)
        }
        .accessibilityIdentifier("tool-dock.view")
    }

    private func badgeCount(for tool: SidebarToolItem) -> Int {
        guard tool.id == "notifications" else { return 0 }
        return dockState.notificationBadgeCount
    }
}

private struct ToolDockItemButton: View {
    let tool: SidebarToolItem
    let isActive: Bool
    let badgeCount: Int
    var onOpenAsTab: (() -> Void)?
    var onOpenAsPane: (() -> Void)?
    let action: () -> Void

    @State private var isHovering = false
    @State private var showTooltip = false
    @State private var hoverTask: Task<Void, Never>?

    private var iconColor: Color {
        if tool.isStub { return Color.gray.opacity(DesignTokens.TextOpacity.tertiary) }
        if isActive || isHovering { return .primary }
        return .secondary
    }

    private var backgroundFill: Color {
        if isActive {
            return Color.primary.opacity(DesignTokens.Opacity.light)
        }
        if isHovering {
            return Color.primary.opacity(DesignTokens.Opacity.subtle)
        }
        return .clear
    }

    private var borderColor: Color {
        if isActive {
            return Color.primary.opacity(DesignTokens.Opacity.medium)
        }
        if isHovering {
            return Color.primary.opacity(DesignTokens.Opacity.subtle)
        }
        return .clear
    }

    var body: some View {
        Button(action: action) {
            VStack(spacing: 3) {
                ZStack(alignment: .topTrailing) {
                    Image(systemName: tool.icon)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(iconColor)
                        .frame(width: 20, height: 20)

                    if badgeCount > 0 {
                        Text(badgeText)
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, badgeCount > 9 ? 5 : 4)
                            .padding(.vertical, 1)
                            .background(Capsule().fill(Color.red))
                            .offset(x: 10, y: -6)
                            .accessibilityLabel("\(badgeCount) unread")
                    }
                }
                .frame(height: 20)

                Capsule(style: .continuous)
                    .fill(Color.primary.opacity(isActive ? DesignTokens.Opacity.medium : 0))
                    .frame(width: 16, height: 2.5)
                    .opacity(isActive ? 1 : 0)
            }
            .frame(width: 36)
            .padding(.horizontal, 4)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(backgroundFill)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(borderColor, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .onHover { hovering in
            isHovering = hovering
            hoverTask?.cancel()
            if hovering {
                hoverTask = Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(400))
                    guard !Task.isCancelled else { return }
                    showTooltip = true
                }
            } else {
                showTooltip = false
                hoverTask = nil
            }
        }
        .overlay(alignment: .top) {
            if showTooltip {
                Text(tool.title)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(
                        Capsule(style: .continuous)
                            .fill(Color.black.opacity(0.85))
                    )
                    .offset(y: -30)
                    .allowsHitTesting(false)
                    .transition(.opacity.combined(with: .scale(scale: 0.9, anchor: .bottom)))
            }
        }
        .animation(.easeOut(duration: DesignTokens.Motion.fast), value: showTooltip)
        .animation(.easeInOut(duration: DesignTokens.Motion.fast), value: isHovering)
        .animation(.easeInOut(duration: DesignTokens.Motion.fast), value: isActive)
        .contextMenu {
            if !tool.isStub && tool.id != "settings" {
                Button {
                    onOpenAsTab?()
                } label: {
                    Label("Open as Tab", systemImage: "plus.square")
                }

                Button {
                    onOpenAsPane?()
                } label: {
                    Label("Pin as Pane", systemImage: "rectangle.split.2x1")
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityValue(isActive ? "Selected" : "")
        .accessibilityIdentifier("tool-dock.item.\(tool.id)")
    }

    private var badgeText: String {
        badgeCount > 99 ? "99+" : "\(badgeCount)"
    }

    private var accessibilityLabel: String {
        if badgeCount > 0 {
            return "\(tool.title), \(badgeCount) unread"
        }
        return tool.title
    }
}
