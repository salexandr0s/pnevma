import AppKit
import XCTest
@testable import Pnevma

@MainActor
final class AppKeybindingManagerTests: XCTestCase {
    override func setUp() {
        super.setUp()
        _ = NSApplication.shared
        // Reset to empty state
        AppKeybindingManager.shared.update(from: [])
    }

    // MARK: - Shortcut Parser

    func testParseCmdD() {
        let parsed = AppKeybindingManager.parse("Cmd+D")
        XCTAssertNotNil(parsed)
        XCTAssertEqual(parsed?.key, "d")
        XCTAssertEqual(parsed?.modifiers, .command)
    }

    func testParseCmdShiftD() {
        let parsed = AppKeybindingManager.parse("Cmd+Shift+D")
        XCTAssertNotNil(parsed)
        XCTAssertEqual(parsed?.key, "d")
        XCTAssertEqual(parsed?.modifiers, [.command, .shift])
    }

    func testParseCmdOptLeft() {
        let parsed = AppKeybindingManager.parse("Cmd+Opt+Left")
        XCTAssertNotNil(parsed)
        XCTAssertEqual(parsed?.key, String(Character(UnicodeScalar(NSLeftArrowFunctionKey)!)))
        XCTAssertEqual(parsed?.modifiers, [.command, .option])
    }

    func testParseCmdEnter() {
        let parsed = AppKeybindingManager.parse("Cmd+Enter")
        XCTAssertNotNil(parsed)
        XCTAssertEqual(parsed?.key, "\r")
        XCTAssertEqual(parsed?.modifiers, .command)
    }

    func testParseCmdCtrlEquals() {
        let parsed = AppKeybindingManager.parse("Cmd+Ctrl+=")
        XCTAssertNotNil(parsed)
        XCTAssertEqual(parsed?.key, "=")
        XCTAssertEqual(parsed?.modifiers, [.command, .control])
    }

    func testParseEmptyStringReturnsNil() {
        let parsed = AppKeybindingManager.parse("")
        XCTAssertNil(parsed)
    }

    // MARK: - Event Matching

    func testIsAppKeyEquivalentMatchesRegisteredBinding() throws {
        AppKeybindingManager.shared.update(from: [
            KeybindingEntry(action: "menu.close_pane", shortcut: "Cmd+W"),
            KeybindingEntry(action: "menu.split_right", shortcut: "Cmd+D"),
        ])

        let cmdW = try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [.command],
            timestamp: 0, windowNumber: 0, context: nil,
            characters: "w", charactersIgnoringModifiers: "w",
            isARepeat: false, keyCode: 13
        ))
        XCTAssertTrue(AppKeybindingManager.shared.isAppKeyEquivalent(cmdW))

        let cmdD = try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [.command],
            timestamp: 0, windowNumber: 0, context: nil,
            characters: "d", charactersIgnoringModifiers: "d",
            isARepeat: false, keyCode: 2
        ))
        XCTAssertTrue(AppKeybindingManager.shared.isAppKeyEquivalent(cmdD))
    }

    func testIsAppKeyEquivalentRejectsUnregisteredBinding() throws {
        AppKeybindingManager.shared.update(from: [
            KeybindingEntry(action: "menu.close_pane", shortcut: "Cmd+W"),
        ])

        let cmdX = try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [.command],
            timestamp: 0, windowNumber: 0, context: nil,
            characters: "x", charactersIgnoringModifiers: "x",
            isARepeat: false, keyCode: 7
        ))
        XCTAssertFalse(AppKeybindingManager.shared.isAppKeyEquivalent(cmdX))
    }

    func testKeyUpDoesNotMatchBinding() throws {
        AppKeybindingManager.shared.update(from: [
            KeybindingEntry(action: "menu.close_pane", shortcut: "Cmd+W"),
        ])

        let event = try XCTUnwrap(NSEvent.keyEvent(
            with: .keyUp, location: .zero, modifierFlags: [.command],
            timestamp: 0, windowNumber: 0, context: nil,
            characters: "w", charactersIgnoringModifiers: "w",
            isARepeat: false, keyCode: 13
        ))
        XCTAssertFalse(AppKeybindingManager.shared.isAppKeyEquivalent(event))
    }

    // MARK: - Update

    func testUpdatePopulatesBindingsAndKeyEquivalents() {
        let entries = [
            KeybindingEntry(action: "menu.new_tab", shortcut: "Cmd+T"),
            KeybindingEntry(action: "menu.split_right", shortcut: "Cmd+D"),
        ]
        AppKeybindingManager.shared.update(from: entries)

        XCTAssertEqual(AppKeybindingManager.shared.bindings["menu.new_tab"], "Cmd+T")
        XCTAssertEqual(AppKeybindingManager.shared.bindings["menu.split_right"], "Cmd+D")
        XCTAssertEqual(AppKeybindingManager.shared.activeKeyEquivalents.count, 2)
    }

    func testUpdateClearsPreviousBindings() {
        AppKeybindingManager.shared.update(from: [
            KeybindingEntry(action: "menu.new_tab", shortcut: "Cmd+T"),
        ])
        XCTAssertEqual(AppKeybindingManager.shared.bindings.count, 1)

        AppKeybindingManager.shared.update(from: [
            KeybindingEntry(action: "menu.close_pane", shortcut: "Cmd+W"),
        ])
        XCTAssertEqual(AppKeybindingManager.shared.bindings.count, 1)
        XCTAssertNil(AppKeybindingManager.shared.bindings["menu.new_tab"])
        XCTAssertEqual(AppKeybindingManager.shared.bindings["menu.close_pane"], "Cmd+W")
    }
}
