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

        let duration = action != nil
            ? DesignTokens.Motion.toastActionDuration
            : 2.5

        dismissTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(duration))
            guard !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: DesignTokens.Motion.normal)) {
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
        VStack {
            Spacer()
            if let toast = manager.currentToast {
                Button(action: { manager.dismiss() }) {
                    HStack(spacing: 8) {
                        if let icon = toast.icon {
                            Image(systemName: icon)
                                .foregroundStyle(iconColor(toast.style))
                        }
                        Text(toast.text)
                            .font(.body.weight(.medium))
                            .lineLimit(2)

                        if let action = toast.action {
                            Divider()
                                .frame(height: 16)
                            Button(action.title) {
                                action.callback()
                                manager.dismiss()
                            }
                            .buttonStyle(.plain)
                            .font(.body.weight(.semibold))
                            .foregroundStyle(Color.accentColor)
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(
                        RoundedRectangle(cornerRadius: 8)
                            .fill(.ultraThinMaterial)
                            .shadow(color: .black.opacity(0.2), radius: 8, y: 4)
                    )
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Dismiss notification")
                .transition(.move(edge: .bottom).combined(with: .opacity))
                .padding(.bottom, DesignTokens.Layout.toolDockHeight + 12)
            }
        }
        .animation(.easeInOut(duration: DesignTokens.Motion.normal), value: manager.currentToast?.id)
        .transaction { $0.disablesAnimations = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }
    }

    private func iconColor(_ style: ToastMessage.ToastStyle) -> Color {
        switch style {
        case .success: return .green
        case .error: return .red
        case .info: return .accentColor
        }
    }
}

// MARK: - Toast Window Controller

/// Manages a transparent overlay window for displaying toast notifications.
@MainActor
final class ToastWindowController {
    private var overlayWindow: NSWindow?
    private let manager: ToastManager
    private var resizeObserver: NSObjectProtocol?
    private var moveObserver: NSObjectProtocol?

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
            guard let parentWindow, let overlay else { return }
            overlay.setFrame(parentWindow.frame, display: true)
        }

        moveObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didMoveNotification,
            object: parentWindow,
            queue: .main
        ) { [weak overlay, weak parentWindow] _ in
            guard let parentWindow, let overlay else { return }
            overlay.setFrame(parentWindow.frame, display: true)
        }

        overlay.setFrame(parentWindow.frame, display: true)
    }
}
