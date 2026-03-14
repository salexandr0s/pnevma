import XCTest

final class PnevmaSidebarSmokeTests: PnevmaUITestCase {
    func testLaunchShowsWelcomeSurface() {
        requireExists(identifiedElement("sidebar.addWorkspace"))
        requireExists(button("Collapse tools section"))

        XCTAssertFalse(app.buttons["Task Board"].exists)
    }

    func testSidebarToolsOpenStableTerminalWorkspaceSurfaces() {
        let toggle = requireExists(button("Collapse tools section"))
        XCTAssertEqual(toggle.label, "Collapse tools section")
        toggle.click()
        XCTAssertEqual(toggle.label, "Expand tools section")
        toggle.click()
        XCTAssertEqual(toggle.label, "Collapse tools section")
    }

    func testToolsSectionToggleIsVisible() {
        requireExists(button("Collapse tools section"))
    }

    func testSettingsWindowOpensFromSidebar() {
        app.typeKey(",", modifierFlags: .command)

        let settingsWindow = app.windows["Settings"]
        requireExists(settingsWindow)
        requireExists(settingsWindow.staticTexts["Auto-save workspace on quit"])
    }

    func testOpenWorkspaceDialogShowsVisibleActionsImmediately() {
        identifiedElement("sidebar.addWorkspace").click()

        requireExists(app.staticTexts["Open Workspace"])
        requireExists(app.buttons["Local Folder"])
        requireExists(app.buttons["Remote SSH"])
        requireExists(app.buttons["Cancel"])
    }
}
