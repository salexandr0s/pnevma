import AppKit
import CoreGraphics
import XCTest
@testable import Pnevma

private final class FocusableTestView: NSView {
    override var acceptsFirstResponder: Bool { true }
}

@MainActor
final class TerminalHostViewTests: XCTestCase {
    override func setUp() {
        super.setUp()
        _ = NSApplication.shared
    }

    func testScreenRectFromGhosttyRectConvertsTopLeftCoordinatesToScreenSpace() {
        let window = NSWindow(
            contentRect: NSRect(x: 100, y: 200, width: 400, height: 300),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        let contentView = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        window.contentView = contentView

        let hostView = TerminalHostView(frame: NSRect(x: 20, y: 30, width: 200, height: 120))
        contentView.addSubview(hostView)

        let rect = hostView.screenRectFromGhosttyRect(x: 10, y: 15, width: 30, height: 8)
        let expectedViewRect = NSRect(x: 10, y: 105, width: 30, height: 8)
        let expectedWindowRect = hostView.convert(expectedViewRect, to: nil)
        let expectedScreenRect = window.convertToScreen(expectedWindowRect)

        XCTAssertEqual(rect.origin.x, expectedScreenRect.origin.x, accuracy: 0.01)
        XCTAssertEqual(rect.origin.y, expectedScreenRect.origin.y, accuracy: 0.01)
        XCTAssertEqual(rect.width, expectedScreenRect.width, accuracy: 0.01)
        XCTAssertEqual(rect.height, expectedScreenRect.height, accuracy: 0.01)
    }

    func testOnlyButtonTwoIsTreatedAsMiddleMouseButton() {
        XCTAssertFalse(TerminalHostView.shouldTreatAsMiddleMouseButton(1))
        XCTAssertTrue(TerminalHostView.shouldTreatAsMiddleMouseButton(2))
        XCTAssertFalse(TerminalHostView.shouldTreatAsMiddleMouseButton(3))
    }

    func testCommandWDefersToAppKitShortcutHandling() throws {
        // Seed the keybinding manager with default bindings that include Cmd+W
        AppKeybindingManager.shared.update(from: [
            KeybindingEntry(action: "menu.close_pane", shortcut: "Cmd+W")
        ])

        let event = try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [.command],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: "w",
            charactersIgnoringModifiers: "w",
            isARepeat: false,
            keyCode: 13
        ))

        XCTAssertTrue(TerminalHostView.shouldDeferKeyEquivalentToAppKit(event))
    }

    func testPlainWDoesNotDeferToAppKitShortcutHandling() throws {
        AppKeybindingManager.shared.update(from: [
            KeybindingEntry(action: "menu.close_pane", shortcut: "Cmd+W")
        ])

        let event = try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: "w",
            charactersIgnoringModifiers: "w",
            isARepeat: false,
            keyCode: 13
        ))

        XCTAssertFalse(TerminalHostView.shouldDeferKeyEquivalentToAppKit(event))
    }

    func testCustomBindingDefersToAppKit() throws {
        // Set a custom binding: Cmd+Shift+R should defer
        AppKeybindingManager.shared.update(from: [
            KeybindingEntry(action: "menu.split_right", shortcut: "Cmd+Shift+R")
        ])

        let event = try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [.command, .shift],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: "R",
            charactersIgnoringModifiers: "r",
            isARepeat: false,
            keyCode: 15
        ))

        XCTAssertTrue(TerminalHostView.shouldDeferKeyEquivalentToAppKit(event))
    }

    func testUnboundKeyDoesNotDeferToAppKit() throws {
        // Only Cmd+W is registered
        AppKeybindingManager.shared.update(from: [
            KeybindingEntry(action: "menu.close_pane", shortcut: "Cmd+W")
        ])

        let event = try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [.command],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: "x",
            charactersIgnoringModifiers: "x",
            isARepeat: false,
            keyCode: 7
        ))

        XCTAssertFalse(TerminalHostView.shouldDeferKeyEquivalentToAppKit(event))
    }

    func testFlagsChangedDoesNotReadCharactersFromModifierOnlyEvent() throws {
        let source = try XCTUnwrap(CGEventSource(stateID: .hidSystemState))
        let cgEvent = try XCTUnwrap(CGEvent(source: source))
        cgEvent.type = .flagsChanged
        cgEvent.flags = .maskCommand
        cgEvent.setIntegerValueField(.keyboardEventKeycode, value: 55)
        let event = try XCTUnwrap(NSEvent(cgEvent: cgEvent))
        let hostView = TerminalHostView(frame: NSRect(x: 0, y: 0, width: 120, height: 80))

        XCTAssertEqual(event.type, .flagsChanged)
        XCTAssertNoThrow(hostView.flagsChanged(with: event))
    }

    func testMouseDownClaimsFirstResponder() throws {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        let contentView = NSView(frame: window.contentLayoutRect)
        window.contentView = contentView

        let priorResponder = FocusableTestView(frame: NSRect(x: 20, y: 20, width: 120, height: 24))
        let hostView = TerminalHostView(frame: NSRect(x: 20, y: 60, width: 200, height: 120))
        contentView.addSubview(priorResponder)
        contentView.addSubview(hostView)
        window.makeKeyAndOrderFront(nil)

        XCTAssertTrue(window.makeFirstResponder(priorResponder))
        XCTAssertTrue(window.firstResponder === priorResponder)

        let location = hostView.convert(NSPoint(x: 10, y: 10), to: nil)
        let event = try XCTUnwrap(NSEvent.mouseEvent(
            with: .leftMouseDown,
            location: location,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: window.windowNumber,
            context: nil,
            eventNumber: 0,
            clickCount: 1,
            pressure: 1
        ))

        hostView.mouseDown(with: event)

        XCTAssertTrue(window.firstResponder === hostView)
    }

    func testCloseCoordinatorRoutesExplicitCloseDecisionWithoutClosingPane() {
        let coordinator = TerminalCloseCoordinator()
        var requestedClose = false
        var decision: Bool?
        var terminalCloseSignal: Bool?

        coordinator.requestClose(
            using: { requestedClose = true },
            completion: { decision = $0 }
        )
        coordinator.handleSurfaceClose(processAlive: false) { processAlive in
            terminalCloseSignal = processAlive
        }

        XCTAssertTrue(requestedClose)
        XCTAssertEqual(decision, false)
        XCTAssertNil(terminalCloseSignal)
    }

    func testCloseCoordinatorForwardsRealTerminalCloseWhenNoDecisionIsPending() {
        let coordinator = TerminalCloseCoordinator()
        var terminalCloseSignal: Bool?

        coordinator.handleSurfaceClose(processAlive: true) { processAlive in
            terminalCloseSignal = processAlive
        }

        XCTAssertEqual(terminalCloseSignal, true)
    }

    func testCloseCoordinatorSuppressesNextSurfaceCloseForSilentPaneDisposal() {
        let coordinator = TerminalCloseCoordinator()
        var terminalCloseSignal: Bool?

        coordinator.suppressNextSurfaceClose()
        coordinator.handleSurfaceClose(processAlive: true) { processAlive in
            terminalCloseSignal = processAlive
        }

        XCTAssertNil(terminalCloseSignal)

        coordinator.handleSurfaceClose(processAlive: false) { processAlive in
            terminalCloseSignal = processAlive
        }

        XCTAssertEqual(terminalCloseSignal, false)
    }

    func testChromeTransitionCoordinatorOnlyEmitsEndWhenLastReasonCompletes() {
        let center = NotificationCenter.default
        var endNotificationCount = 0
        let observer = center.addObserver(
            forName: .chromeTransitionDidEnd,
            object: nil,
            queue: .main
        ) { _ in
            endNotificationCount += 1
        }
        defer {
            center.removeObserver(observer)
            ChromeTransitionCoordinator.shared.reset()
        }

        ChromeTransitionCoordinator.shared.begin(.sidebar)
        ChromeTransitionCoordinator.shared.begin(.rightInspector)
        ChromeTransitionCoordinator.shared.end(.sidebar)
        XCTAssertEqual(endNotificationCount, 0)

        ChromeTransitionCoordinator.shared.end(.rightInspector)
        XCTAssertEqual(endNotificationCount, 1)
        XCTAssertFalse(ChromeTransitionCoordinator.shared.isActive)
    }

    func testChromeTransitionCoordinatorWaitsForOverlappingTransitionsOfSameReason() {
        let center = NotificationCenter.default
        var endNotificationCount = 0
        let observer = center.addObserver(
            forName: .chromeTransitionDidEnd,
            object: nil,
            queue: .main
        ) { _ in
            endNotificationCount += 1
        }
        defer {
            center.removeObserver(observer)
            ChromeTransitionCoordinator.shared.reset()
        }

        ChromeTransitionCoordinator.shared.begin(.sidebar)
        ChromeTransitionCoordinator.shared.begin(.sidebar)
        ChromeTransitionCoordinator.shared.end(.sidebar)
        XCTAssertEqual(endNotificationCount, 0)
        XCTAssertTrue(ChromeTransitionCoordinator.shared.isActive)

        ChromeTransitionCoordinator.shared.end(.sidebar)
        XCTAssertEqual(endNotificationCount, 1)
        XCTAssertFalse(ChromeTransitionCoordinator.shared.isActive)
    }
}
