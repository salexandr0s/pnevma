import AppKit
import SwiftUI
import XCTest
@testable import Pnevma

private actor NotificationsPaneCommandBus: CommandCalling {
    private var notificationListCallCountValue = 0

    func call<T: Decodable & Sendable>(method: String, params: (any Encodable & Sendable)?) async throws -> T {
        switch method {
        case "notification.list":
            notificationListCallCountValue += 1
            return try decode(
                #"[{"id":"note-1","level":"info","title":"Heads up","body":"hello","unread":true,"created_at":"2026-03-06T08:00:00Z","task_id":null,"session_id":null}]"#
            )
        default:
            throw NSError(domain: "NotificationsPaneCommandBus", code: 1)
        }
    }

    func notificationListCallCount() -> Int {
        notificationListCallCountValue
    }

    private func decode<T: Decodable>(_ json: String) throws -> T {
        let decoder = PnevmaJSON.decoder()
        return try decoder.decode(T.self, from: Data(json.utf8))
    }
}

@MainActor
final class NotificationsPaneTests: XCTestCase {
    override func setUp() {
        super.setUp()
        MainActor.assumeIsolated {
            _ = NSApplication.shared
        }
    }

    private func waitUntil(
        timeoutNanos: UInt64 = 1_000_000_000,
        pollIntervalNanos: UInt64 = 10_000_000,
        file: StaticString = #filePath,
        line: UInt = #line,
        _ condition: @escaping () async -> Bool
    ) async throws {
        let deadline = DispatchTime.now().uptimeNanoseconds + timeoutNanos
        while DispatchTime.now().uptimeNanoseconds < deadline {
            if await condition() {
                return
            }
            try await Task.sleep(nanoseconds: pollIntervalNanos)
        }
        XCTFail("Timed out waiting for notifications-pane condition", file: file, line: line)
    }

    func testNotificationsPaneActivatesWhenOpenedAfterProjectIsAlreadyActive() async throws {
        let bus = NotificationsPaneCommandBus()
        let activationHub = ActiveWorkspaceActivationHub()
        let bridgeHub = BridgeEventHub()
        activationHub.update(.open(workspaceID: UUID(), projectID: "project-1"))

        let viewModel = NotificationsViewModel(
            commandBus: bus,
            bridgeEventHub: bridgeHub,
            activationHub: activationHub
        )

        let host = NSHostingView(
            rootView: NotificationsView(viewModel: viewModel)
                .environment(GhosttyThemeProvider.shared)
        )
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 500, height: 400),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        defer {
            window.orderOut(nil)
        }

        try await waitUntil {
            await bus.notificationListCallCount() == 1
                && viewModel.statusMessage == nil
                && viewModel.notifications.count == 1
        }
    }
}
