import XCTest

class PnevmaUITestCase: XCTestCase {
    let defaultTimeout: TimeInterval = 10
    var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchEnvironment["PNEVMA_UI_TESTING"] = "1"
        app.launch()
    }

    override func tearDownWithError() throws {
        app?.terminate()
        app = nil
    }

    @discardableResult
    func requireExists(
        _ element: XCUIElement,
        timeout: TimeInterval? = nil,
        file: StaticString = #filePath,
        line: UInt = #line
    ) -> XCUIElement {
        XCTAssertTrue(
            element.waitForExistence(timeout: timeout ?? defaultTimeout),
            "Expected element to exist: \(element)",
            file: file,
            line: line
        )
        return element
    }

    @discardableResult
    func button(
        _ label: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) -> XCUIElement {
        requireExists(app.buttons[label], file: file, line: line)
    }

    func clickButton(_ label: String) {
        button(label).click()
    }

    @discardableResult
    func sidebarButton(
        _ label: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) -> XCUIElement {
        let predicate = NSPredicate(
            format: "label == %@ AND identifier == %@",
            label,
            "sidebar.view"
        )
        let scopedButton = app.buttons.matching(predicate).firstMatch
        if scopedButton.waitForExistence(timeout: defaultTimeout) {
            return scopedButton
        }
        return button(label, file: file, line: line)
    }

    func clickSidebarButton(_ label: String) {
        sidebarButton(label).click()
    }
}
