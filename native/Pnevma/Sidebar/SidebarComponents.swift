import SwiftUI

// MARK: - NotificationBadge

struct NotificationBadge: View {
    let count: Int

    var body: some View {
        Text(count > 99 ? "99+" : "\(count)")
            .font(.caption2)
            .bold()
            .foregroundStyle(.white)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(Capsule().fill(Color.red))
    }
}

// MARK: - AddButton

struct AddButton: View {
    let action: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: "plus")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(isHovering ? Color.green : Color.secondary)
                .frame(width: 28, height: 28)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .accessibilityLabel("Add workspace")
        .help("Add workspace")
        .accessibilityIdentifier("sidebar.addWorkspace")
    }
}

// MARK: - CloseButton

struct CloseButton: View {
    let action: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: "xmark")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(isHovering ? Color.red : Color.secondary)
                .frame(width: 28, height: 28)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .accessibilityLabel("Close workspace")
        .help("Close workspace")
    }
}

// MARK: - ToolsSectionHeader

struct ToolsSectionHeader: View {
    @Binding var isExpanded: Bool
    @State private var isHovering = false

    var body: some View {
        Button(action: {
            withAnimation(ChromeMotion.animation(for: .disclosure)) {
                isExpanded.toggle()
            }
        }) {
            HStack {
                Text("TOOLS")
                    .font(.system(size: 11))
                    .fontWeight(.semibold)
                    .foregroundStyle(.secondary)
                Spacer()
                Image(systemName: "chevron.up")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(isHovering ? Color.accentColor : .secondary)
                    .rotationEffect(.degrees(isExpanded ? 0 : 180))
                    .frame(width: 22, height: 22)
                    .contentShape(Rectangle())
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .accessibilityLabel(isExpanded ? "Collapse tools section" : "Expand tools section")
        .accessibilityIdentifier("sidebar.tools.toggle")
    }
}

// MARK: - SidebarMode

enum SidebarMode: String, Codable, CaseIterable {
    case expanded, collapsed, hidden

    var next: SidebarMode {
        switch self {
        case .expanded: return .collapsed
        case .collapsed: return .hidden
        case .hidden: return .expanded
        }
    }
}

// MARK: - SidebarPreferences

// MARK: - Background tint constants

enum BackgroundTint {
    static let defaultOffset: Double = 0.05
    static let range: ClosedRange<Double> = 0.0...0.3
    static func clamped(_ value: Double) -> Double { max(range.lowerBound, min(range.upperBound, value)) }
}

enum SidebarPreferences {
    private nonisolated(unsafe) static let defaults = UserDefaults.standard

    /// How much to lighten the sidebar background relative to the terminal.
    /// 0.0 = exact terminal color, 0.05 = slight lightening (default).
    static var backgroundOffset: Double {
        get {
            let raw = defaults.object(forKey: "sidebarBackgroundOffset") as? Double ?? BackgroundTint.defaultOffset
            return BackgroundTint.clamped(raw)
        }
        set { defaults.set(newValue, forKey: "sidebarBackgroundOffset") }
    }

    /// Current sidebar display mode.
    static var sidebarMode: SidebarMode {
        get {
            defaults.string(forKey: "sidebarMode")
                .flatMap(SidebarMode.init(rawValue:)) ?? .expanded
        }
        set { defaults.set(newValue.rawValue, forKey: "sidebarMode") }
    }

    /// User-dragged sidebar width (clamped to design token bounds).
    static var sidebarWidth: CGFloat {
        get {
            let raw = defaults.object(forKey: "sidebarCustomWidth") as? CGFloat
                ?? DesignTokens.Layout.sidebarWidth
            return min(max(raw, DesignTokens.Layout.sidebarMinWidth), DesignTokens.Layout.sidebarMaxWidth)
        }
        set {
            let clamped = min(max(newValue, DesignTokens.Layout.sidebarMinWidth), DesignTokens.Layout.sidebarMaxWidth)
            defaults.set(clamped, forKey: "sidebarCustomWidth")
        }
    }
}

enum SidebarCollapsedWorkspaceIndicator: Equatable {
    case icon(String)
    case text(String)
}

enum SidebarWorkspacePresentation {
    @MainActor
    static func shouldShowTerminalSectionHeader(for workspaces: [Workspace]) -> Bool {
        workspaces.count > 1
    }

    @MainActor
    static func collapsedIndicator(for workspace: Workspace) -> SidebarCollapsedWorkspaceIndicator {
        switch workspace.kind {
        case .terminal:
            return .icon("terminal")
        case .project:
            return .text(String(workspace.name.prefix(1)).uppercased())
        }
    }
}

// MARK: - ToolDockPreferences

enum ToolDockPreferences {
    private nonisolated(unsafe) static let defaults = UserDefaults.standard

    /// How much to lighten the tool dock background relative to the terminal.
    /// Uses the same scale as the sidebar. Default matches sidebar default.
    static var backgroundOffset: Double {
        get {
            let raw = defaults.object(forKey: "toolDockBackgroundOffset") as? Double ?? BackgroundTint.defaultOffset
            return BackgroundTint.clamped(raw)
        }
        set { defaults.set(newValue, forKey: "toolDockBackgroundOffset") }
    }
}

// MARK: - RightInspectorPreferences

enum RightInspectorPreferences {
    private nonisolated(unsafe) static let defaults = UserDefaults.standard

    /// How much to lighten the right inspector background relative to the terminal.
    /// Default is 0.0 (exact terminal color, no tinting).
    static var backgroundOffset: Double {
        get {
            let raw = defaults.object(forKey: "rightInspectorBackgroundOffset") as? Double ?? 0.0
            return BackgroundTint.clamped(raw)
        }
        set { defaults.set(newValue, forKey: "rightInspectorBackgroundOffset") }
    }
}

extension Notification.Name {
    static let backgroundTintDidChange = Notification.Name("backgroundTintDidChange")
}
