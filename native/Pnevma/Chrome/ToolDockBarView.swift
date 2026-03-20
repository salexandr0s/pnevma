import AppKit
import Observation
import SwiftUI

@Observable
@MainActor
final class ToolDockState {
    var activeToolID: String?
    var notificationBadgeCount: Int = 0
}

// MARK: - Dock Tooltip Preference

private struct DockTooltipPreferenceKey: PreferenceKey {
    static let defaultValue: DockTooltipAnchor? = nil
    static func reduce(value: inout DockTooltipAnchor?, nextValue: () -> DockTooltipAnchor?) {
        value = nextValue() ?? value
    }
}

private struct DockTooltipAnchor: Equatable {
    let title: String
    let anchor: Anchor<CGRect>

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.title == rhs.title
    }
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
        let offset = min(
            BackgroundTint.clamped(toolDockOffset) + 0.025,
            BackgroundTint.range.upperBound
        )
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

    private let dividerHeight = DesignTokens.Layout.dividerWidth
    private let dockHeight = DesignTokens.Layout.toolDockHeight
    private let dockButtonWidth: CGFloat = 50
    private let dockButtonSpacing: CGFloat = 8
    private let innerHorizontalPadding: CGFloat = 8
    private let outerHorizontalPadding: CGFloat = 18

    var body: some View {
        VStack(spacing: 0) {
            Rectangle()
                .fill(borderColor)
                .frame(height: dividerHeight)

            GeometryReader { geometry in
                if geometry.size.width >= minimumDockContentWidth {
                    centeredDockContent(minWidth: geometry.size.width)
                } else {
                    ScrollView(.horizontal) {
                        centeredDockContent(minWidth: geometry.size.width)
                    }
                    .scrollIndicators(.hidden)
                }
            }
            .frame(height: dockHeight - dividerHeight)
        }
        .frame(height: dockHeight)
        .background(
            ZStack {
                backgroundColor
                Color.white.opacity(0.016)
            }
        )
        .overlayPreferenceValue(DockTooltipPreferenceKey.self) { anchor in
            if let anchor {
                GeometryReader { proxy in
                    let rect = proxy[anchor.anchor]
                    DockTooltipLabel(text: anchor.title)
                        .fixedSize()
                        .position(x: rect.midX, y: rect.minY - 22)
                }
                .allowsHitTesting(false)
            }
        }
        .contentShape(Rectangle())
        .onHover { isHovering in
            onHoverChanged?(isHovering)
        }
    }

    private func badgeCount(for tool: SidebarToolItem) -> Int {
        guard tool.id == "notifications" else { return 0 }
        return dockState.notificationBadgeCount
    }

    private var minimumDockContentWidth: CGFloat {
        let buttonCount = CGFloat(tools.count)
        let totalButtonWidth = buttonCount * dockButtonWidth
        let totalSpacing = CGFloat(max(tools.count - 1, 0)) * dockButtonSpacing
        return outerHorizontalPadding * 2
            + innerHorizontalPadding * 2
            + totalButtonWidth
            + totalSpacing
    }

    @ViewBuilder
    private func centeredDockContent(minWidth: CGFloat) -> some View {
        HStack(spacing: 0) {
            Spacer(minLength: 0)
            HStack(spacing: dockButtonSpacing) {
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
            .padding(.horizontal, innerHorizontalPadding)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, outerHorizontalPadding)
        .frame(minWidth: minWidth, maxHeight: .infinity, alignment: .center)
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

    private var iconColor: Color {
        if tool.isStub { return Color.gray.opacity(DesignTokens.TextOpacity.tertiary) }
        if isActive || isHovering { return .primary }
        return .secondary
    }

    private var backgroundFill: Color {
        if isActive {
            return Color.primary.opacity(0.135)
        }
        if isHovering {
            return Color.primary.opacity(0.075)
        }
        return .clear
    }

    private var borderColor: Color {
        if isActive {
            return Color.primary.opacity(0.16)
        }
        if isHovering {
            return Color.primary.opacity(0.09)
        }
        return .clear
    }

    private var buttonShadowOpacity: CGFloat {
        isActive ? 0.12 : 0
    }

    private var highlightStrokeColor: Color {
        if isActive {
            return .white.opacity(0.09)
        }
        if isHovering {
            return .white.opacity(0.045)
        }
        return .clear
    }

    private var symbolPointSize: CGFloat {
        switch tool.id {
        case "resource_monitor", "ports":
            return 14
        case "analytics", "browser", "ssh", "rules":
            return 15
        case "workflow", "tasks", "replay", "brief":
            return 16
        default:
            return 17
        }
    }

    private var symbolWeight: Font.Weight {
        switch tool.id {
        case "terminal", "tasks", "workflow":
            return .semibold
        default:
            return .medium
        }
    }

    var body: some View {
        Button(action: action) {
            ZStack(alignment: .topTrailing) {
                Image(systemName: tool.icon)
                    .font(.system(size: symbolPointSize, weight: symbolWeight))
                    .foregroundStyle(iconColor)
                    .frame(width: 24, height: 24)

                ZStack(alignment: .topTrailing) {
                    if badgeCount > 0 {
                        Text(badgeText)
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, badgeCount > 9 ? 5 : 4)
                            .padding(.vertical, 1)
                            .background(Capsule().fill(Color.red))
                            .offset(x: 12, y: -7)
                            .accessibilityLabel("\(badgeCount) unread")
                    }
                }
            }
            .frame(width: 50, height: 40)
            .background(
                RoundedRectangle(cornerRadius: 13)
                    .fill(backgroundFill)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 13)
                    .stroke(borderColor, lineWidth: 1)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(highlightStrokeColor, lineWidth: 1)
                    .padding(1)
            )
            .shadow(color: .black.opacity(buttonShadowOpacity), radius: 6, y: 1)
        }
        .buttonStyle(.plain)
        .contentShape(RoundedRectangle(cornerRadius: 13))
        .anchorPreference(key: DockTooltipPreferenceKey.self, value: .bounds) { anchor in
            isHovering ? DockTooltipAnchor(title: tool.title, anchor: anchor) : nil
        }
        .onHover { hovering in
            isHovering = hovering
        }
        .animation(ChromeMotion.animation(for: .hover), value: isHovering)
        .animation(ChromeMotion.animation(for: .hover), value: isActive)
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

private struct DockTooltipLabel: View {
    let text: String
    private let cornerRadius: CGFloat = 9
    private let arrowHeight: CGFloat = 7
    private let arrowWidth: CGFloat = 14

    var body: some View {
        VStack(spacing: 0) {
            Text(text)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.white.opacity(0.95))
                .padding(.horizontal, 12)
                .padding(.vertical, 5)
            Color.clear
                .frame(height: arrowHeight)
        }
        .background(
            TooltipBubbleShape(cornerRadius: cornerRadius, arrowHeight: arrowHeight, arrowWidth: arrowWidth)
                .fill(Color(nsColor: NSColor(white: 0.24, alpha: 0.85)))
        )
        .transition(.opacity)
        .animation(ChromeMotion.animation(for: .tooltip), value: text)
    }
}

private struct TooltipBubbleShape: Shape {
    let cornerRadius: CGFloat
    let arrowHeight: CGFloat
    let arrowWidth: CGFloat

    func path(in rect: CGRect) -> Path {
        let bodyRect = CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: rect.height - arrowHeight)
        var path = Path(roundedRect: bodyRect, cornerRadius: cornerRadius)
        let midX = bodyRect.midX
        let arrowTop = bodyRect.maxY
        path.move(to: CGPoint(x: midX - arrowWidth / 2, y: arrowTop))
        path.addLine(to: CGPoint(x: midX, y: arrowTop + arrowHeight))
        path.addLine(to: CGPoint(x: midX + arrowWidth / 2, y: arrowTop))
        path.closeSubpath()
        return path
    }
}
