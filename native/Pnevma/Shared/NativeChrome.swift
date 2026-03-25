import AppKit
import SwiftUI

enum ChromeSurfaceStyle {
    case window
    case toolbar
    case sidebar
    case pane
    case inspector
    case sourceList
    case utilityShelf
    case utilityShelfToolbar
    case groupedCard

    var baseColor: NSColor {
        switch self {
        case .window, .pane, .utilityShelf:
            return .windowBackgroundColor
        case .toolbar, .sourceList, .utilityShelfToolbar, .groupedCard:
            return .controlBackgroundColor
        case .sidebar, .inspector:
            return .underPageBackgroundColor
        }
    }

    var color: Color {
        Color(nsColor: baseColor)
    }

    var separatorColor: NSColor {
        .separatorColor
    }

    var selectionColor: Color {
        Color(nsColor: .selectedContentBackgroundColor).opacity(0.32)
    }

    func resolvedColor(themeColor: NSColor? = nil, tintAmount: Double = 0) -> NSColor {
        let base = baseColor
        guard let themeColor, tintAmount > 0 else {
            return base
        }

        let clampedAmount = max(0, min(tintAmount, 1)) * 0.18
        return base.blended(withFraction: clampedAmount, of: themeColor) ?? base
    }
}

// MARK: - Accessibility Checks

enum AccessibilityCheck {
    static var prefersReducedTransparency: Bool {
        NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency
    }

    static var prefersHighContrast: Bool {
        NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
    }

    static var prefersBoldText: Bool {
        // Bold Text preference is exposed via UIAccessibility on iOS;
        // on macOS we use the NSWorkspace font-smoothing threshold as a proxy,
        // or check the user default directly.
        UserDefaults.standard.bool(forKey: "com.apple.accessibility.BoldTextEnabled")
    }
}

enum PanePresentationRole: Equatable {
    case document
    case manager
    case monitor
    case utility
    case inspectorDriven

    init(paneType: String) {
        switch paneType {
        case "terminal", "file_browser", "harness_config", "diff":
            self = .document
        case "analytics", "daily_brief", "resource_monitor", "taskboard":
            self = .monitor
        case "review":
            self = .inspectorDriven
        case "notifications", "ssh", "rules", "secrets", "workflow":
            self = .manager
        case "ports", "replay", "settings", "restore_error", "welcome":
            self = .utility
        default:
            self = .manager
        }
    }

    var defaultSystemImage: String {
        switch self {
        case .document:
            return "doc.text"
        case .manager:
            return "sidebar.left"
        case .monitor:
            return "chart.bar"
        case .utility:
            return "slider.horizontal.3"
        case .inspectorDriven:
            return "sidebar.right"
        }
    }
}

enum NativePaneHeaderVisibility {
    case automatic
    case always
    case hidden
}

private struct NativePaneTitleBlock: View {
    let title: String
    let subtitle: String?
    let systemImage: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: DesignTokens.Spacing.sm) {
            Image(systemName: systemImage)
                .font(.system(size: 13, weight: DesignTokens.AccessibleFont.weight(SwiftUI.Font.Weight.semibold)))
                .foregroundStyle(.secondary)
                .frame(width: 16)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 13, weight: DesignTokens.AccessibleFont.weight(SwiftUI.Font.Weight.semibold)))

                if let subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
}

struct NativePaneScaffold<HeaderContent: View, Content: View>: View {
    @Environment(\.paneChromeContext) private var paneChromeContext

    private let title: String?
    private let subtitle: String?
    private let systemImage: String?
    private let role: PanePresentationRole
    private let titleVisibility: NativePaneHeaderVisibility
    private let inlineHeaderIdentifier: String?
    private let inlineHeaderLabel: String?
    private let showsToolbar: Bool
    private let headerContent: HeaderContent
    private let content: Content

    init(
        title: String?,
        subtitle: String? = nil,
        systemImage: String? = nil,
        role: PanePresentationRole = .manager,
        titleVisibility: NativePaneHeaderVisibility = .automatic,
        inlineHeaderIdentifier: String? = nil,
        inlineHeaderLabel: String? = nil,
        @ViewBuilder headerContent: () -> HeaderContent,
        @ViewBuilder content: () -> Content
    ) {
        self.title = title
        self.subtitle = subtitle
        self.systemImage = systemImage
        self.role = role
        self.titleVisibility = titleVisibility
        self.inlineHeaderIdentifier = inlineHeaderIdentifier
        self.inlineHeaderLabel = inlineHeaderLabel
        self.showsToolbar = true
        self.headerContent = headerContent()
        self.content = content()
    }

    init(
        title: String?,
        subtitle: String? = nil,
        systemImage: String? = nil,
        role: PanePresentationRole = .manager,
        titleVisibility: NativePaneHeaderVisibility = .automatic,
        inlineHeaderIdentifier: String? = nil,
        inlineHeaderLabel: String? = nil,
        @ViewBuilder content: () -> Content
    ) where HeaderContent == EmptyView {
        self.title = title
        self.subtitle = subtitle
        self.systemImage = systemImage
        self.role = role
        self.titleVisibility = titleVisibility
        self.inlineHeaderIdentifier = inlineHeaderIdentifier
        self.inlineHeaderLabel = inlineHeaderLabel
        self.showsToolbar = false
        self.headerContent = EmptyView()
        self.content = content()
    }

    var body: some View {
        VStack(spacing: 0) {
            if showsHeaderBar {
                HStack(alignment: .center, spacing: DesignTokens.Spacing.md) {
                    if showsTitleBlock, let title {
                        NativePaneTitleBlock(
                            title: title,
                            subtitle: subtitle,
                            systemImage: systemImage ?? role.defaultSystemImage
                        )

                        if let inlineHeaderIdentifier, let inlineHeaderLabel {
                            AccessibilityMarker(
                                identifier: inlineHeaderIdentifier,
                                label: inlineHeaderLabel
                            )
                            .frame(width: 1, height: 1)
                            .allowsHitTesting(false)
                        }
                    }

                    Spacer(minLength: DesignTokens.Spacing.sm)

                    if showsToolbar {
                        headerContent
                    }
                }
                .padding(.horizontal, DesignTokens.Spacing.md)
                .padding(.vertical, 10)
                .background(ChromeSurfaceStyle.toolbar.color)

                Divider()
            }

            content
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .background(ChromeSurfaceStyle.pane.color)
        }
        .background(ChromeSurfaceStyle.pane.color)
    }

    private var showsTitleBlock: Bool {
        switch titleVisibility {
        case .automatic:
            return paneChromeContext.showsInlinePaneHeader && title != nil
        case .always:
            return title != nil
        case .hidden:
            return false
        }
    }

    private var showsHeaderBar: Bool {
        showsToolbar || showsTitleBlock
    }
}

struct NativeSplitScaffold<Sidebar: View, Detail: View>: View {
    private let sidebarMinWidth: CGFloat?
    private let sidebarIdealWidth: CGFloat?
    private let sidebarMaxWidth: CGFloat?
    private let sidebarSurface: ChromeSurfaceStyle
    private let detailSurface: ChromeSurfaceStyle
    private let sidebar: Sidebar
    private let detail: Detail

    init(
        sidebarMinWidth: CGFloat? = nil,
        sidebarIdealWidth: CGFloat? = nil,
        sidebarMaxWidth: CGFloat? = nil,
        sidebarSurface: ChromeSurfaceStyle = .sourceList,
        detailSurface: ChromeSurfaceStyle = .pane,
        @ViewBuilder sidebar: () -> Sidebar,
        @ViewBuilder detail: () -> Detail
    ) {
        self.sidebarMinWidth = sidebarMinWidth
        self.sidebarIdealWidth = sidebarIdealWidth
        self.sidebarMaxWidth = sidebarMaxWidth
        self.sidebarSurface = sidebarSurface
        self.detailSurface = detailSurface
        self.sidebar = sidebar()
        self.detail = detail()
    }

    var body: some View {
        HSplitView {
            sidebar
                .frame(
                    minWidth: sidebarMinWidth,
                    idealWidth: sidebarIdealWidth,
                    maxWidth: sidebarMaxWidth,
                    maxHeight: .infinity,
                    alignment: .topLeading
                )
                .background(sidebarSurface.color)

            detail
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .background(detailSurface.color)
        }
    }
}

struct NativeCollectionShell<Content: View>: View {
    private let surface: ChromeSurfaceStyle
    private let content: Content

    init(
        surface: ChromeSurfaceStyle = .sourceList,
        @ViewBuilder content: () -> Content
    ) {
        self.surface = surface
        self.content = content()
    }

    var body: some View {
        content
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(surface.color)
    }
}
