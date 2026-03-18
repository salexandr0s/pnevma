import AppKit
import XCTest
@testable import Pnevma

@MainActor
private final class CloseDecisionPane: NSView, PaneContent {
    let paneID = PaneID()
    let paneType = "test"
    let title = "Test"
    let hasActiveProcess: Bool

    init(hasActiveProcess: Bool = false) {
        self.hasActiveProcess = hasActiveProcess
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) not supported")
    }
}

@MainActor
private final class CloseDecisionTerminalPane: NSView, TerminalPaneControlling {
    let paneID = PaneID()
    let paneType = "terminal"
    let title = "Terminal"
    let hasActiveProcess: Bool
    let closeDecision: Bool

    init(hasActiveProcess: Bool, closeDecision: Bool) {
        self.hasActiveProcess = hasActiveProcess
        self.closeDecision = closeDecision
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) not supported")
    }

    func loadSession(sessionID _: String, workingDirectory _: String?) {}
    func launchAgent(_: AgentKind) {}

    func requestCloseDecision(_ completion: @escaping (Bool) -> Void) {
        completion(closeDecision)
    }
}

@MainActor
final class ContentAreaViewTests: XCTestCase {
    override func setUp() {
        super.setUp()
        MainActor.assumeIsolated {
            _ = NSApplication.shared
        }
    }

    func testActivePaneCloseConfirmationUsesExplicitTerminalDecision() {
        let pane = CloseDecisionTerminalPane(hasActiveProcess: true, closeDecision: false)
        let contentArea = ContentAreaView(frame: NSRect(x: 0, y: 0, width: 400, height: 300), rootPaneView: pane)
        let expectation = expectation(description: "close decision")
        var result: Bool?

        contentArea.activePaneRequiresCloseConfirmation {
            result = $0
            expectation.fulfill()
        }

        wait(for: [expectation], timeout: 1)
        XCTAssertEqual(result, false)
    }

    func testAnyPaneCloseConfirmationReturnsTrueWhenAnyPaneNeedsIt() {
        let rootPane = CloseDecisionPane()
        let contentArea = ContentAreaView(
            frame: NSRect(x: 0, y: 0, width: 400, height: 300),
            rootPaneView: rootPane
        )
        let terminalPane = CloseDecisionTerminalPane(hasActiveProcess: false, closeDecision: true)
        XCTAssertNotNil(contentArea.splitActivePane(direction: .horizontal, newPaneView: terminalPane))

        let expectation = expectation(description: "any pane close decision")
        var result: Bool?

        contentArea.anyPaneRequiresCloseConfirmation {
            result = $0
            expectation.fulfill()
        }

        wait(for: [expectation], timeout: 1)
        XCTAssertEqual(result, true)
    }
}
