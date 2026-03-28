import XCTest

@MainActor
final class RightInspectorOverlayUITests: PnevmaProjectUITestCase {
    func testRightInspectorAllowsTabAndChangeSwitchingWhileOverlayIsOpen() throws {
        runStep("show right inspector") {
            var changesTab = element("right-inspector-tab-changes")
            if !changesTab.waitForExistence(timeout: 1) {
                app.typeKey("B", modifierFlags: [.command, .shift])
            }
            changesTab = identifiedElement("right-inspector-tab-changes")
            _ = identifiedElement("right-inspector-tab-files")
            _ = attachScreenshot(surface: "right-inspector", phase: "visible")
        }

        let changesTab = identifiedElement("right-inspector-tab-changes")
        let filesTab = identifiedElement("right-inspector-tab-files")
        let overlayTitle = staticText("right-inspector-overlay-title")

        runStep("open diff overlay") {
            changesTab.click()
            waitForSelection(changesTab)
            let alphaChange = identifiedElement("right-inspector-change-row-alpha_txt")
            alphaChange.click()
            XCTAssertTrue(waitForDisplayedText(overlayTitle, toEqual: "alpha.txt"))
            _ = attachScreenshot(surface: "right-inspector", phase: "change_alpha")
        }

        runStep("switch change row with overlay open") {
            let betaChange = identifiedElement("right-inspector-change-row-beta_txt")
            betaChange.click()
            XCTAssertTrue(waitForDisplayedText(overlayTitle, toEqual: "beta.txt"))
            _ = attachScreenshot(surface: "right-inspector", phase: "change_beta")
        }

        runStep("switch to files tab and keep overlay open") {
            filesTab.click()
            waitForSelection(filesTab)
            let notesFile = identifiedElement("right-inspector-file-row-notes_md")
            notesFile.click()
            XCTAssertTrue(waitForDisplayedText(overlayTitle, toEqual: "notes.md"))
            _ = attachScreenshot(surface: "right-inspector", phase: "file_notes")
        }

        runStep("switch back to changes tab") {
            changesTab.click()
            waitForSelection(changesTab)
            let betaChange = identifiedElement("right-inspector-change-row-beta_txt")
            betaChange.click()
            XCTAssertTrue(waitForDisplayedText(overlayTitle, toEqual: "beta.txt"))
            _ = attachScreenshot(surface: "right-inspector", phase: "return_to_changes")
        }

        markExercised(
            "right-inspector.overlay",
            detail: "Changes/files tabs and overlay transitions remained interactive.",
            evidence: []
        )
    }
}
