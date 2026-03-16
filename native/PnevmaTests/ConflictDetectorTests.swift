import XCTest
@testable import Pnevma

@MainActor
final class ConflictDetectorTests: XCTestCase {

    // MARK: - Normalization

    func testNormalizeShortcutCmdShiftD() {
        XCTAssertEqual(ConflictDetector.normalizeShortcut("Cmd+Shift+D"), "cmd+shift+d")
    }

    func testNormalizeShortcutOptModifier() {
        XCTAssertEqual(ConflictDetector.normalizeShortcut("Cmd+Opt+Left"), "cmd+opt+left")
    }

    func testNormalizeGhosttyTriggerSuperShiftD() {
        XCTAssertEqual(ConflictDetector.normalizeGhosttyTrigger("super+shift+d"), "cmd+shift+d")
    }

    func testNormalizeGhosttyTriggerAltMapsToOpt() {
        XCTAssertEqual(ConflictDetector.normalizeGhosttyTrigger("alt+d"), "opt+d")
    }

    func testNormalizationProducesSameResultForEquivalentShortcuts() {
        let pnevma = ConflictDetector.normalizeShortcut("Cmd+Shift+D")
        let ghostty = ConflictDetector.normalizeGhosttyTrigger("super+shift+d")
        XCTAssertEqual(pnevma, ghostty)
    }

    // MARK: - Cross-Layer Detection

    func testDetectsConflictBetweenLayers() {
        let pnevma = [
            KeybindingEntry(action: "menu.split_right", shortcut: "Cmd+D"),
        ]
        let ghostty = [
            GhosttyManagedKeybind(trigger: "super+d", action: "new_split", parameter: "right"),
        ]

        let conflicts = ConflictDetector.detect(pnevmaBindings: pnevma, ghosttyBindings: ghostty)
        XCTAssertEqual(conflicts.count, 1)
        XCTAssertEqual(conflicts.first?.claimants.count, 2)
    }

    func testNoConflictWhenShortcutsDiffer() {
        let pnevma = [
            KeybindingEntry(action: "menu.split_right", shortcut: "Cmd+D"),
        ]
        let ghostty = [
            GhosttyManagedKeybind(trigger: "super+e", action: "new_split", parameter: "right"),
        ]

        let conflicts = ConflictDetector.detect(pnevmaBindings: pnevma, ghosttyBindings: ghostty)
        XCTAssertTrue(conflicts.isEmpty)
    }

    func testDoesNotReportIntraLayerConflicts() {
        // Two Pnevma bindings on the same shortcut — not a cross-layer conflict
        let pnevma = [
            KeybindingEntry(action: "menu.split_right", shortcut: "Cmd+D"),
            KeybindingEntry(action: "menu.something_else", shortcut: "Cmd+D"),
        ]
        let ghostty: [GhosttyManagedKeybind] = []

        let conflicts = ConflictDetector.detect(pnevmaBindings: pnevma, ghosttyBindings: ghostty)
        XCTAssertTrue(conflicts.isEmpty)
    }

    func testEmptyInputsProduceNoConflicts() {
        let conflicts = ConflictDetector.detect(pnevmaBindings: [], ghosttyBindings: [])
        XCTAssertTrue(conflicts.isEmpty)
    }
}
