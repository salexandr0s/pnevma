import SwiftUI
import Cocoa
import Observation

// MARK: - Toast Action

struct ToastAction {
    let title: String
    let callback: @MainActor () -> Void
}

// MARK: - Toast Model

struct ToastMessage: Identifiable {
    let id = UUID()
    let text: String
    let icon: String?
    let style: ToastStyle
    let action: ToastAction?

    enum ToastStyle {
        case success, error, info
    }

    init(text: String, icon: String? = nil, style: ToastStyle = .info, action: ToastAction? = nil) {
        self.text = text
        self.icon = icon
        self.style = style
        self.action = action
    }
}

// MARK: - Toast Manager

@Observable
@MainActor
final class ToastManager {
    static let shared = ToastManager()

    private(set) var currentToast: ToastMessage? {
        didSet { onToastChange?(currentToast) }
    }

    /// Callback invoked whenever `currentToast` changes (used by ToastWindowController).
    @ObservationIgnored
    var onToastChange: ((ToastMessage?) -> Void)?

    @ObservationIgnored
    private var dismissTask: Task<Void, Never>?
    @ObservationIgnored
    private var lastShownText: String?
    @ObservationIgnored
    private var lastShownTime: Date?

    func show(_ text: String, icon: String? = nil, style: ToastMessage.ToastStyle = .info) {
        show(text, icon: icon, style: style, action: nil)
    }

    func show(_ text: String, icon: String? = nil, style: ToastMessage.ToastStyle = .info, action: ToastAction?) {
        if text == lastShownText, let lastTime = lastShownTime, Date.now.timeIntervalSince(lastTime) < 1.0 {
            return
        }
        dismissTask?.cancel()
        currentToast = ToastMessage(text: text, icon: icon, style: style, action: action)
        lastShownText = text
        lastShownTime = Date.now

        // VoiceOver: announce toast content
        if NSWorkspace.shared.isVoiceOverEnabled {
            NSAccessibility.post(
                element: NSApp.mainWindow as Any,
                notification: .announcementRequested,
                userInfo: [.announcement: text, .priority: NSAccessibilityPriorityLevel.medium.rawValue]
            )
        }

        let duration = action != nil
            ? DesignTokens.Motion.toastActionDuration
            : 2.5

        dismissTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(duration))
            guard !Task.isCancelled else { return }
            withAnimation(DesignTokens.Motion.resolved(.easeOut(duration: DesignTokens.Motion.normal))) {
                self.currentToast = nil
            }
        }
    }

    func dismiss() {
        dismissTask?.cancel()
        currentToast = nil
        lastShownText = nil
        lastShownTime = nil
    }
}

// MARK: - Toast Overlay View

struct ToastOverlayView: View {
    var manager: ToastManager

    var body: some View {
        ZStack(alignment: .bottom) {
            if let toast = manager.currentToast {
                toastCard(for: toast)
                .transition(.move(edge: .bottom).combined(with: .opacity))
                .padding(.horizontal, DesignTokens.Spacing.lg)
                .padding(.bottom, DesignTokens.Layout.toolDockHeight + 12)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        .animation(.easeInOut(duration: DesignTokens.Motion.normal), value: manager.currentToast?.id)
        .transaction { $0.disablesAnimations = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }
    }

    @ViewBuilder
    private func toastCard(for toast: ToastMessage) -> some View {
        if toast.action == nil {
            Button(action: { manager.dismiss() }) {
                toastCardContent(for: toast, showsDismissButton: false)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Dismiss notification")
            .accessibilityValue(toast.text)
        } else {
            toastCardContent(for: toast, showsDismissButton: true)
                .accessibilityElement(children: .contain)
        }
    }

    private func toastCardContent(for toast: ToastMessage, showsDismissButton: Bool) -> some View {
        HStack(spacing: 10) {
            if let icon = toast.icon {
                Image(systemName: icon)
                    .foregroundStyle(iconColor(toast.style))
            }

            Text(toast.text)
                .font(.body.weight(DesignTokens.AccessibleFont.weight(SwiftUI.Font.Weight.medium)))
                .foregroundStyle(.primary)
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)

            if let action = toast.action {
                Divider()
                    .frame(height: 18)

                HStack(spacing: 10) {
                    Button(action.title) {
                        action.callback()
                        manager.dismiss()
                    }
                    .buttonStyle(.plain)
                    .font(.body.weight(.semibold))
                    .foregroundStyle(Color.accentColor)

                    if showsDismissButton {
                        Button("Dismiss notification", systemImage: "xmark") {
                            manager.dismiss()
                        }
                        .labelStyle(.iconOnly)
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                        .accessibilityLabel("Dismiss notification")
                    }
                }
            }
        }
        .frame(maxWidth: 520, alignment: .leading)
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(AccessibilityCheck.prefersReducedTransparency
                    ? AnyShapeStyle(ChromeSurfaceStyle.window.color)
                    : AnyShapeStyle(.regularMaterial))
                .overlay {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(borderColor(toast.style), lineWidth: 1)
                }
                .shadow(color: .black.opacity(0.18), radius: 12, y: 6)
        )
    }

    private func iconColor(_ style: ToastMessage.ToastStyle) -> Color {
        switch style {
        case .success: return .green
        case .error: return .red
        case .info: return .accentColor
        }
    }

    private func borderColor(_ style: ToastMessage.ToastStyle) -> Color {
        switch style {
        case .success: return .green.opacity(0.28)
        case .error: return .red.opacity(0.28)
        case .info: return Color.accentColor.opacity(0.28)
        }
    }
}

// MARK: - Toast Window Controller

/// Manages a transparent overlay window for displaying toast notifications.
@MainActor
final class ToastWindowController {
    private var overlayWindow: NSWindow?
    private let manager: ToastManager
    nonisolated(unsafe) private var resizeObserver: NSObjectProtocol?
    nonisolated(unsafe) private var moveObserver: NSObjectProtocol?

    init(manager: ToastManager? = nil) {
        self.manager = manager ?? .shared
    }

    deinit {
        if let resizeObserver {
            NotificationCenter.default.removeObserver(resizeObserver)
        }
        if let moveObserver {
            NotificationCenter.default.removeObserver(moveObserver)
        }
    }

    func attach(to parentWindow: NSWindow) {
        let overlay = NSPanel(
            contentRect: parentWindow.frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )
        overlay.isOpaque = false
        overlay.backgroundColor = .clear
        overlay.hasShadow = false
        overlay.level = .floating
        overlay.ignoresMouseEvents = true
        overlay.contentView = NSHostingView(rootView: ToastOverlayView(manager: manager).environment(GhosttyThemeProvider.shared))
        overlay.contentView?.wantsLayer = true
        overlay.contentView?.layer?.backgroundColor = .clear

        parentWindow.addChildWindow(overlay, ordered: .above)
        overlayWindow = overlay

        // Toggle mouse event passthrough based on toast visibility
        manager.onToastChange = { [weak overlay] toast in
            overlay?.ignoresMouseEvents = (toast == nil)
        }

        // Keep overlay sized to parent
        resizeObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didResizeNotification,
            object: parentWindow,
            queue: .main
        ) { [weak overlay, weak parentWindow] _ in
            MainActor.assumeIsolated {
                guard let parentWindow, let overlay else { return }
                overlay.setFrame(parentWindow.frame, display: true)
            }
        }

        moveObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didMoveNotification,
            object: parentWindow,
            queue: .main
        ) { [weak overlay, weak parentWindow] _ in
            MainActor.assumeIsolated {
                guard let parentWindow, let overlay else { return }
                overlay.setFrame(parentWindow.frame, display: true)
            }
        }

        overlay.setFrame(parentWindow.frame, display: true)
    }
}
