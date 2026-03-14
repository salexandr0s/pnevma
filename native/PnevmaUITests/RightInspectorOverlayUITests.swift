import XCTest

final class RightInspectorOverlayUITests: PnevmaUITestCase {
    private var projectURL: URL?

    override var expectedLaunchReadinessState: String { "project-ready" }

    override func configureApp(_ app: XCUIApplication) throws {
        let projectURL = try makeFixtureRepository()
        self.projectURL = projectURL
        app.launchEnvironment["PNEVMA_UI_TEST_PROJECT_PATH"] = projectURL.path
    }

    override func tearDownWithError() throws {
        try super.tearDownWithError()
        if let projectURL {
            try? FileManager.default.removeItem(at: projectURL)
        }
        projectURL = nil
    }

    func testRightInspectorAllowsTabAndChangeSwitchingWhileOverlayIsOpen() throws {
        var changesTab = app.descendants(matching: .any)["right-inspector-tab-changes"]
        if !changesTab.waitForExistence(timeout: 1) {
            app.typeKey("B", modifierFlags: [.command, .shift])
            changesTab = identifiedElement("right-inspector-tab-changes")
        } else {
            changesTab = identifiedElement("right-inspector-tab-changes")
        }
        changesTab.click()

        let alphaChange = identifiedElement("right-inspector-change-row-alpha_txt")
        alphaChange.click()

        let overlayTitle = identifiedStaticText("right-inspector-overlay-title")
        XCTAssertTrue(
            overlayTitle.waitForExistence(timeout: defaultTimeout),
            "Expected the change overlay to appear after selecting alpha.txt."
        )

        let betaChange = identifiedElement("right-inspector-change-row-beta_txt")
        betaChange.click()

        XCTAssertTrue(
            overlayTitle.waitForExistence(timeout: defaultTimeout),
            "Expected overlay title to remain visible after selecting a second change."
        )

        let reviewTab = identifiedElement("right-inspector-tab-review")
        reviewTab.click()
        let filesTab = identifiedElement("right-inspector-tab-files")
        filesTab.click()

        let notesFile = identifiedElement("right-inspector-file-row-notes_md")
        notesFile.click()

        XCTAssertTrue(
            overlayTitle.waitForExistence(timeout: defaultTimeout),
            "Expected file overlay title to appear after selecting notes.md."
        )

        changesTab.click()
        betaChange.click()

        XCTAssertTrue(
            overlayTitle.waitForExistence(timeout: defaultTimeout),
            "Expected diff overlay title to remain accessible after switching back to Changes."
        )
    }
}
