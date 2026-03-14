import XCTest

final class PnevmaSidebarSmokeTests: PnevmaUITestCase {
    func testLaunchShowsWorkspaceSidebarAndToolDock() {
        requireExists(identifiedElement("sidebar.addWorkspace"))
        requireExists(identifiedElement("tool-dock.view"))
        requireExists(toolDockItem("terminal"))
        XCTAssertFalse(app.buttons["Task Board"].exists)
    }

    func testTerminalWorkspaceKeepsProjectOnlyToolsOutOfDock() {
        requireExists(identifiedElement("sidebar.addWorkspace"))
        requireExists(identifiedElement("tool-dock.view"))
        XCTAssertFalse(app.buttons["Task Board"].exists)
        XCTAssertFalse(app.buttons["tool-dock.item.tasks"].exists)
    }

    func testSettingsWindowOpensFromTitlebarButton() {
        identifiedElement("titlebar.settings").click()

        let settingsWindow = app.windows["Settings"]
        requireExists(settingsWindow)
        requireExists(settingsWindow.staticTexts["Auto-save workspace on quit"])
        requireExists(settingsWindow.staticTexts["Auto-hide bottom tool bar"])
    }

    func testOpenWorkspaceDialogShowsVisibleActionsImmediately() {
        identifiedElement("sidebar.addWorkspace").click()

        requireExists(app.staticTexts["Open Workspace"])
        requireExists(app.buttons["Local Folder"])
        requireExists(app.buttons["Remote SSH"])
        requireExists(app.buttons["Cancel"])
    }
}
