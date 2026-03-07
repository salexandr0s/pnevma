import SwiftUI
import Cocoa
import Combine

// MARK: - Toast Model

struct ToastMessage: Identifiable {
    let id = UUID()
    let text: String
    let icon: String?
    let style: ToastStyle

    enum ToastStyle {
        case success, error, info
    }
}

// MARK: - Toast Manager

@MainActor
final class ToastManager: ObservableObject {
    static let shared = ToastManager()

    @Published private(set) var currentToast: ToastMessage?
    private var dismissTask: Task<Void, Never>?
    private var lastShownText: String?
    private var lastShownTime: Date?

    func show(_ text: String, icon: String? = nil, style: ToastMessage.ToastStyle = .info) {
        if text == lastShownText, let lastTime = lastShownTime, Date().timeIntervalSince(lastTime) < 1.0 {
            return
        }
        dismissTask?.cancel()
        currentToast = ToastMessage(text: text, icon: icon, style: style)
        lastShownText = text
        lastShownTime = Date()
        dismissTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 2_500_000_000)
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
    @ObservedObject var manager: ToastManager

    var body: some View {
        VStack {
            Spacer()
            if let toast = manager.currentToast {
                HStack(spacing: 8) {
                    if let icon = toast.icon {
                        Image(systemName: icon)
                            .foregroundStyle(iconColor(toast.style))
                    }
                    Text(toast.text)
                        .font(.system(size: 13, weight: .medium))
                        .lineLimit(2)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(.ultraThinMaterial)
                        .shadow(color: .black.opacity(0.2), radius: 8, y: 4)
                )
                .transition(.move(edge: .bottom).combined(with: .opacity))
                .padding(.bottom, 40)
                .onTapGesture { manager.dismiss() }
            }
        }
        .animation(.easeInOut(duration: DesignTokens.Motion.normal), value: manager.currentToast?.id)
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
    private var cancellables = Set<AnyCancellable>()
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
        overlay.contentView = NSHostingView(rootView: ToastOverlayView(manager: manager))
        overlay.contentView?.wantsLayer = true
        overlay.contentView?.layer?.backgroundColor = .clear

        parentWindow.addChildWindow(overlay, ordered: .above)
        overlayWindow = overlay

        // Toggle mouse event passthrough based on toast visibility
        manager.$currentToast
            .receive(on: RunLoop.main)
            .sink { [weak overlay] toast in
                overlay?.ignoresMouseEvents = (toast == nil)
            }
            .store(in: &cancellables)

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
