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

    var body: some View {
        VStack(spacing: 0) {
            Rectangle()
                .fill(borderColor)
                .frame(height: dividerHeight)

            GeometryReader { geometry in
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 0) {
                        Spacer(minLength: 0)
                        HStack(spacing: 8) {
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
                        .padding(.horizontal, 8)
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 18)
                    .frame(minWidth: geometry.size.width, maxHeight: .infinity, alignment: .center)
                }
                .scrollIndicators(.hidden)
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
                RoundedRectangle(cornerRadius: 13, style: .continuous)
                    .fill(backgroundFill)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 13, style: .continuous)
                    .stroke(borderColor, lineWidth: 1)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(highlightStrokeColor, lineWidth: 1)
                    .padding(1)
            )
            .shadow(color: .black.opacity(buttonShadowOpacity), radius: 6, y: 1)
        }
        .buttonStyle(.plain)
        .contentShape(RoundedRectangle(cornerRadius: 13, style: .continuous))
        .background(ToolDockNativeTooltipBridge(text: tool.title))
        .onHover { hovering in
            isHovering = hovering
        }
        .help(tool.title)
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

private struct ToolDockNativeTooltipBridge: NSViewRepresentable {
    let text: String

    func makeNSView(context: Context) -> ToolDockNativeTooltipView {
        let view = ToolDockNativeTooltipView()
        view.toolTip = text
        return view
    }

    func updateNSView(_ nsView: ToolDockNativeTooltipView, context: Context) {
        nsView.toolTip = text
    }
}

private final class ToolDockNativeTooltipView: NSView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = false
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }
}
