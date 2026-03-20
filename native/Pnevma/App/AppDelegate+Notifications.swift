import Cocoa
import SwiftUI
import UserNotifications

// MARK: - Native macOS Notification Support

/// Manages native macOS notifications with focus suppression.
@MainActor
final class NativeNotificationManager: NSObject, UNUserNotificationCenterDelegate {
    static let shared = NativeNotificationManager()

    private override init() {
        super.init()
    }

    func setup() {
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        center.requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in }
    }

    /// Post a native notification. Suppressed when app is active (frontmost).
    func postNotification(title: String, body: String, identifier: String? = nil) {
        guard !NSApplication.shared.isActive else { return }

        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default

        let request = UNNotificationRequest(
            identifier: identifier ?? UUID().uuidString,
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request)
    }

    // UNUserNotificationCenterDelegate — handle notification actions
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        Task { @MainActor in
            NSApplication.shared.activate(ignoringOtherApps: true)
        }
        completionHandler()
    }

    // Show notifications even when app is in foreground (only if explicitly requested)
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        // Suppress in-app banner — we use our own toast system
        completionHandler([])
    }
}

// MARK: - Notifications Popover

struct NotificationsPopoverView: View {
    @State private var viewModel = NotificationsViewModel.shared
    var onViewAll: (() -> Void)?

    var body: some View {
        ToolbarAttachmentScaffold(title: "Notifications") {
            Button("Mark All Read") { viewModel.markAllRead() }
                .buttonStyle(.plain)
                .foregroundStyle(Color.accentColor)
        } content: {
            Group {
                if let statusMessage = viewModel.statusMessage {
                    EmptyStateView(icon: "bell.badge", title: statusMessage)
                } else if viewModel.filteredNotifications.isEmpty {
                    EmptyStateView(
                        icon: "bell.slash",
                        title: "No Notifications Yet",
                        message: "Desktop notifications will appear here."
                    )
                } else {
                    NativeCollectionShell(surface: .pane) {
                        List(viewModel.filteredNotifications.prefix(10)) { notification in
                            Button {
                                viewModel.markRead(notification.id)
                            } label: {
                                NotificationRow(notification: notification)
                            }
                            .buttonStyle(.plain)
                        }
                        .listStyle(.plain)
                        .scrollContentBackground(.hidden)
                    }
                }
            }
        } footer: {
            HStack {
                Button("View All") { onViewAll?() }
                    .buttonStyle(.plain)
                    .foregroundStyle(Color.accentColor)
                Spacer()
            }
        }
        .frame(width: 400, height: 400)
    }
}

final class BadgeOverlayView: NSView {
    var count: Int = 0 {
        didSet {
            isHidden = count <= 0
            needsDisplay = true
        }
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        isHidden = true
    }

    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ dirtyRect: NSRect) {
        guard count > 0 else { return }

        let text = count > 99 ? "99+" : "\(count)"
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 8, weight: .bold),
            .foregroundColor: NSColor.white
        ]
        let textSize = (text as NSString).size(withAttributes: attributes)

        let capsuleWidth = max(textSize.width + 6, 14)
        let capsuleHeight: CGFloat = 12
        let capsuleRect = NSRect(
            x: bounds.width - capsuleWidth,
            y: 0,
            width: capsuleWidth,
            height: capsuleHeight
        )
        let capsulePath = NSBezierPath(roundedRect: capsuleRect, xRadius: capsuleHeight / 2, yRadius: capsuleHeight / 2)
        NSColor.systemRed.setFill()
        capsulePath.fill()

        let textRect = NSRect(
            x: capsuleRect.midX - textSize.width / 2,
            y: capsuleRect.midY - textSize.height / 2,
            width: textSize.width,
            height: textSize.height
        )
        (text as NSString).draw(in: textRect, withAttributes: attributes)
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

final class StatusDotOverlayView: NSView {
    enum Status {
        case hidden
        case ok
        case warning
        case error
    }

    var status: Status = .hidden {
        didSet {
            isHidden = status == .hidden
            needsDisplay = true
        }
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        isHidden = true
    }

    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ dirtyRect: NSRect) {
        guard status != .hidden else { return }
        let color: NSColor = switch status {
        case .hidden:
            .clear
        case .ok:
            .systemGreen
        case .warning:
            .systemOrange
        case .error:
            .systemRed
        }
        let circle = NSBezierPath(ovalIn: bounds.insetBy(dx: 1, dy: 1))
        color.setFill()
        circle.fill()
        NSColor.black.withAlphaComponent(0.35).setStroke()
        circle.lineWidth = 0.5
        circle.stroke()
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

final class RightInspectorOverlayBlockerView: NSView {
    override var isFlipped: Bool { true }
    var capturesPointerEvents = false
    var overlayHitRect: CGRect = .zero

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard capturesPointerEvents else { return nil }
        let localPoint = convert(point, from: superview)
        guard bounds.contains(localPoint) else { return nil }
        return self
    }
}

final class RightInspectorOverlayHostingView<Content: View>: NSHostingView<Content> {
    var capturesPointerEvents = false
    var overlayHitRect: CGRect = .zero

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard capturesPointerEvents else { return nil }
        return super.hitTest(point)
    }
}
