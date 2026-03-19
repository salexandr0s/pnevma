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

    func testSettingsWindowOpensFromSidebarFooterButton() {
        identifiedElement("sidebar.settings").click()

        requireExists(identifiedElement("settings.root"))
        requireExists(app.staticTexts["Auto-save workspace on quit"])
        requireExists(app.staticTexts["Auto-hide bottom tool bar"])
    }

    func testGhosttySettingsDoesNotResizeSettingsWindow() {
        identifiedElement("sidebar.settings").click()

        requireExists(identifiedElement("settings.root"))
        let initialWindow = requireExists(app.windows.element(boundBy: max(0, app.windows.count - 1)))
        let initialFrame = initialWindow.frame

        identifiedElement("settings.sidebar.ghostty").click()

        requireExists(app.staticTexts["Embedded terminal rendering, config-backed Ghostty options, and terminal keybindings."])

        let updatedWindow = requireExists(app.windows.element(boundBy: max(0, app.windows.count - 1)))
        let updatedFrame = updatedWindow.frame

        XCTAssertEqual(initialFrame.width, updatedFrame.width, accuracy: 1)
        XCTAssertEqual(initialFrame.height, updatedFrame.height, accuracy: 1)
    }

    func testOpenWorkspaceDialogShowsVisibleActionsImmediately() {
        identifiedElement("sidebar.addWorkspace").click()

        requireExists(app.staticTexts["Open Workspace"])
        requireExists(app.buttons["Local Folder"])
        requireExists(app.buttons["Remote SSH"])
        requireExists(app.buttons["Cancel"])
    }

    func testWorkspaceTabBarButtonsRemainClickable() {
        app.typeKey("t", modifierFlags: .command)

        let tabBar = requireExists(app.tabGroups["Tab bar"])
        let addButton = requireHittable(app.buttons["New tab"])
        let closeButtons = app.buttons.matching(identifier: "Close tab")

        XCTAssertGreaterThanOrEqual(closeButtons.count, 2)

        addButton.click()
        waitForCount(closeButtons, count: 3)

        let closeButton = requireHittable(closeButtons.element(boundBy: 0))
        closeButton.click()
        waitForCount(closeButtons, count: 2)

        XCTAssertTrue(tabBar.exists)
    }
}
