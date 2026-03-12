import XCTest

class PnevmaUITestCase: XCTestCase {
    let defaultTimeout: TimeInterval = 10
    var app: XCUIApplication!

    func configureApp(_ app: XCUIApplication) throws {}

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchEnvironment["PNEVMA_UI_TESTING"] = "1"
        try configureApp(app)
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
    func requireHittable(
        _ element: XCUIElement,
        timeout: TimeInterval? = nil,
        file: StaticString = #filePath,
        line: UInt = #line
    ) -> XCUIElement {
        let deadline = Date().addingTimeInterval(timeout ?? defaultTimeout)
        repeat {
            if element.exists && element.isHittable {
                return element
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        } while Date() < deadline

        XCTFail("Expected element to be hittable: \(element)", file: file, line: line)
        return element
    }

    func waitForCount(
        _ query: XCUIElementQuery,
        count: Int,
        timeout: TimeInterval? = nil,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let deadline = Date().addingTimeInterval(timeout ?? defaultTimeout)
        repeat {
            if query.count == count {
                return
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        } while Date() < deadline

        XCTFail(
            "Expected query count \(count), got \(query.count)",
            file: file,
            line: line
        )
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

    @discardableResult
    func identifiedElement(
        _ identifier: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) -> XCUIElement {
        let element = app.descendants(matching: .any)[identifier]
        return requireExists(element, file: file, line: line)
    }
}
