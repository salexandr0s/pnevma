import XCTest

@MainActor
final class PnevmaSidebarSmokeTests: PnevmaUITestCase {
    func testLaunchShowsWorkspaceSidebarAndToolDock() {
        requireExists(identifiedElement("sidebar.newWorkspace"))
        requireExists(identifiedElement("tool-dock.view"))
        requireExists(toolDockItem("terminal"))
        XCTAssertFalse(app.buttons["Task Board"].exists)
    }

    func testTerminalWorkspaceKeepsProjectOnlyToolsOutOfDock() {
        requireExists(identifiedElement("sidebar.newWorkspace"))
        requireExists(identifiedElement("tool-dock.view"))
        XCTAssertFalse(app.buttons["Task Board"].exists)
        XCTAssertFalse(app.buttons["tool-dock.item.tasks"].exists)
    }

    func testSettingsWindowOpensFromSidebarFooterButton() {
        _ = openSettingsWindow()
        requireExists(app.staticTexts["Auto-save workspace on quit"])
        requireExists(app.staticTexts["Auto-hide bottom tool bar"])
    }

    func testGhosttySettingsDoesNotResizeSettingsWindow() {
        _ = openSettingsWindow()
        let initialWindow = requireExists(app.windows.element(boundBy: max(0, app.windows.count - 1)))
        let initialFrame = initialWindow.frame

        let ghosttyButton = requireHittable(requireExists(app.buttons.matching(identifier: "settings.sidebar.ghostty").firstMatch))
        ghosttyButton.click()

        requireExists(app.staticTexts["Embedded terminal rendering, config-backed Ghostty options, and terminal keybindings."])

        let updatedWindow = requireExists(app.windows.element(boundBy: max(0, app.windows.count - 1)))
        let updatedFrame = updatedWindow.frame

        XCTAssertEqual(initialFrame.width, updatedFrame.width, accuracy: 1)
        XCTAssertEqual(initialFrame.height, updatedFrame.height, accuracy: 1)
    }

    func testOpenWorkspaceDialogShowsVisibleActionsImmediately() {
        let opener = openWorkspaceOpener()

        requireExists(opener)
        requireExists(identifiedElement("opener.tab.prompt"))
        requireExists(identifiedElement("workspaceOpener.prompt.agent"))
        requireExists(identifiedElement("workspaceOpener.action.cancel"))
        requireExists(identifiedElement("workspaceOpener.action.submit"))
    }

    func testWorkspaceTabBarButtonsRemainClickable() {
        app.typeKey("t", modifierFlags: .command)

        let addButton = requireHittable(app.buttons["tabbar.add"])
        let closeButtons = app.buttons.matching(identifier: "tabbar.close")

        XCTAssertGreaterThanOrEqual(closeButtons.count, 2)

        addButton.click()
        waitForCount(closeButtons, count: 3)

        let closeButton = requireHittable(closeButtons.element(boundBy: 0))
        closeButton.click()
        waitForCount(closeButtons, count: 2)

        XCTAssertTrue(addButton.exists)
    }

    func testToolDockSwapReplacesDrawerContent() {
        toolDockItem("browser").click()

        requireExists(identifiedElement("bottom.drawer.content.browser"))
        requireExists(identifiedElement("bottom.drawer.close"))
        requireExists(identifiedElement("bottom.drawer.openAsTab"))
        let drawerState = requireExists(identifiedElement("bottom.drawer.state"))
        waitForLabel(drawerState, toContain: "browser")

        toolDockItem("analytics").click()
        waitForLabel(drawerState, toContain: "analytics")
        requireExists(identifiedElement("bottom.drawer.close"))

        toolDockItem("notifications").click()
        waitForLabel(drawerState, toContain: "notifications")
        requireExists(identifiedElement("bottom.drawer.close"))
        requireExists(identifiedElement("bottom.drawer.openAsTab"))
    }
}
