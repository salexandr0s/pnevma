import XCTest

final class PnevmaSidebarSmokeTests: PnevmaUITestCase {
    func testLaunchShowsWelcomeSurface() {
        requireExists(app.staticTexts["Pnevma"])
        requireExists(app.staticTexts["Terminal-first workspace for AI-agent-driven delivery"])
        requireExists(sidebarButton("Task Board"))
        requireExists(sidebarButton("Settings"))
        requireExists(app.buttons["Collapse tools section"])
    }

    func testSidebarToolsOpenStableProjectlessPanes() {
        clickSidebarButton("Task Board")
        requireExists(app.staticTexts["Open a project to load tasks."])

        clickSidebarButton("Notifications")
        requireExists(app.staticTexts["Open a project to load notifications."])

        clickSidebarButton("File Browser")
        requireExists(app.staticTexts["Select a file to preview"])

        clickSidebarButton("Session Replay")
        requireExists(app.staticTexts["No session selected for replay"])

        clickSidebarButton("Search")
        requireExists(app.staticTexts["Open a project to search."])
    }

    func testToolsSectionCanCollapseAndExpand() {
        let toolsToggle = button("Collapse tools section")

        toolsToggle.click()
        requireExists(app.buttons["Expand tools section"])
        XCTAssertFalse(app.buttons["Task Board"].exists)

        clickButton("Expand tools section")
        requireExists(app.buttons["Task Board"])
    }

    func testSettingsWindowOpensFromSidebar() {
        clickSidebarButton("Settings")

        let settingsWindow = app.windows["Settings"]
        requireExists(settingsWindow)
        requireExists(settingsWindow.staticTexts["Auto-save workspace on quit"])
    }
}
