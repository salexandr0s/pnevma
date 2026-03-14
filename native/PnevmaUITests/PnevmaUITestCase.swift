import AppKit
import XCTest

class PnevmaUITestCase: XCTestCase {
    let defaultTimeout: TimeInterval = 10
    var app: XCUIApplication!
    private let appBundleIdentifier = "com.pnevma.app"

    var expectedLaunchReadinessState: String { "terminal-ready" }

    func configureApp(_ app: XCUIApplication) throws {}

    override func setUpWithError() throws {
        continueAfterFailure = false
        terminateRunningPnevmaApps()
        app = XCUIApplication()
        app.launchEnvironment["PNEVMA_UI_TESTING"] = "1"
        app.launchEnvironment["PNEVMA_UI_TEST_LIGHTWEIGHT_MODE"] = "1"
        try configureApp(app)
        app.launch()
        waitForReadinessState(expectedLaunchReadinessState)
        app.activate()
        dismissOpenWorkspaceDialogIfNeeded()
    }

    override func tearDownWithError() throws {
        app?.terminate()
        app = nil
    }

    private func terminateRunningPnevmaApps() {
        let runningApps = NSRunningApplication.runningApplications(
            withBundleIdentifier: appBundleIdentifier
        )
        for runningApp in runningApps {
            guard !runningApp.isTerminated else { continue }
            _ = runningApp.forceTerminate()
        }

        let deadline = Date().addingTimeInterval(3)
        repeat {
            let hasLiveApp = NSRunningApplication.runningApplications(
                withBundleIdentifier: appBundleIdentifier
            )
            .contains { !$0.isTerminated }

            if !hasLiveApp {
                return
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        } while Date() < deadline
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


    func waitForSelection(
        _ element: XCUIElement,
        selected: Bool = true,
        timeout: TimeInterval? = nil,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let deadline = Date().addingTimeInterval(timeout ?? defaultTimeout)
        repeat {
            if element.exists && element.isSelected == selected {
                return
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        } while Date() < deadline

        XCTFail(
            "Expected element \(element) selected=\(selected), got \(element.isSelected)",
            file: file,
            line: line
        )
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

    func waitForLabel(
        _ element: XCUIElement,
        toContain expectedSubstring: String,
        timeout: TimeInterval? = nil,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let deadline = Date().addingTimeInterval(timeout ?? defaultTimeout)
        repeat {
            if element.exists && element.label.contains(expectedSubstring) {
                return
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        } while Date() < deadline

        XCTFail(
            "Expected element label to contain \(expectedSubstring), got \(element.label)",
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
        return button(label, file: file, line: line)
    }

    func sidebarToolLabel(for toolID: String) -> String {
        switch toolID {
        case "terminal": return "Terminal"
        case "tasks": return "Task Board"
        case "workflow": return "Agents"
        case "notifications": return "Notifications"
        case "ssh": return "SSH Manager"
        case "harness": return "Harness Config"
        case "replay": return "Session Replay"
        case "browser": return "Browser"
        case "analytics": return "Usage"
        case "brief": return "Daily Brief"
        case "rules": return "Rules Manager"
        case "secrets": return "Secrets"
        case "settings": return "Settings"
        default: return toolID
        }
    }

    @discardableResult
    func sidebarTool(
        _ toolID: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) -> XCUIElement {
        let identifiedButton = app.buttons["sidebar.tool.\(toolID)"]
        if identifiedButton.waitForExistence(timeout: defaultTimeout) {
            return identifiedButton
        }
        let identified = app.descendants(matching: .any)["sidebar.tool.\(toolID)"]
        if identified.waitForExistence(timeout: defaultTimeout) {
            return identified
        }
        return sidebarButton(sidebarToolLabel(for: toolID), file: file, line: line)
    }

    func clickSidebarTool(_ toolID: String) {
        app.activate()
        sidebarTool(toolID).click()
    }

    @discardableResult
    func toolDockItem(
        _ toolID: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) -> XCUIElement {
        let identifiedButton = app.buttons["tool-dock.item.\(toolID)"]
        if identifiedButton.waitForExistence(timeout: defaultTimeout) {
            return identifiedButton
        }
        let identified = app.descendants(matching: .any)["tool-dock.item.\(toolID)"]
        if identified.waitForExistence(timeout: defaultTimeout) {
            return identified
        }
        return button(sidebarToolLabel(for: toolID), file: file, line: line)
    }

    func dismissOpenWorkspaceDialogIfNeeded() {
        let cancelButton = app.descendants(matching: .any)["openWorkspace.cancel"]
        guard cancelButton.waitForExistence(timeout: 1) else { return }
        cancelButton.click()
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


    @discardableResult
    func identifiedStaticText(
        _ identifier: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) -> XCUIElement {
        requireExists(app.staticTexts[identifier], file: file, line: line)
    }

    @discardableResult
    func waitForReadinessState(
        _ expectedState: String,
        timeout: TimeInterval? = nil,
        file: StaticString = #filePath,
        line: UInt = #line
    ) -> XCUIElement {
        let readiness = requireExists(
            app.descendants(matching: .any)["ui-test.readiness"],
            timeout: timeout,
            file: file,
            line: line
        )
        let deadline = Date().addingTimeInterval(timeout ?? defaultTimeout)
        repeat {
            if readiness.label == expectedState {
                return readiness
            }
            if readiness.label == "project-open-failed" {
                let detail = String(describing: readiness.value ?? "unknown")
                XCTFail(
                    "UI test bootstrap failed before reaching \(expectedState): \(detail)",
                    file: file,
                    line: line
                )
                return readiness
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        } while Date() < deadline

        XCTFail(
            "Expected readiness state \(expectedState), got \(readiness.label)",
            file: file,
            line: line
        )
        return readiness
    }

    func makeFixtureRepository() throws -> URL {
        let baseURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("pui-\(UUID().uuidString.prefix(6))", isDirectory: true)
        try FileManager.default.createDirectory(at: baseURL, withIntermediateDirectories: true)

        try "alpha\n".write(to: baseURL.appendingPathComponent("alpha.txt"), atomically: true, encoding: .utf8)
        try "beta\n".write(to: baseURL.appendingPathComponent("beta.txt"), atomically: true, encoding: .utf8)
        try "# Notes\n\nFixture repo.\n".write(
            to: baseURL.appendingPathComponent("notes.md"),
            atomically: true,
            encoding: .utf8
        )
        try """
        [project]
        name = "UITest Fixture"
        brief = "UI automation fixture"

        [agents]
        default_provider = "claude-code"
        max_concurrent = 4

        [branches]
        target = "main"
        naming = "task/{id}-{slug}"

        [automation]
        socket_enabled = true
        socket_path = ".pnevma/run/control.sock"
        socket_auth = "same-user"

        [rules]
        paths = [".pnevma/rules/*.md"]

        [conventions]
        paths = [".pnevma/conventions/*.md"]
        """.write(
            to: baseURL.appendingPathComponent("pnevma.toml"),
            atomically: true,
            encoding: .utf8
        )
        for (relativePath, content) in [
            (".pnevma/rules/project-rules.md", "# Project Rules\n\n- Keep changes scoped.\n"),
            (".pnevma/conventions/conventions.md", "# Conventions\n\n- Prefer deterministic checks.\n"),
        ] {
            let fileURL = baseURL.appendingPathComponent(relativePath)
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try content.write(to: fileURL, atomically: true, encoding: .utf8)
        }

        try runGit(["init", "-q"], in: baseURL)
        try runGit(["config", "user.email", "uitest@example.com"], in: baseURL)
        try runGit(["config", "user.name", "UI Test"], in: baseURL)
        try runGit(["add", "."], in: baseURL)
        try runGit(["commit", "-q", "-m", "Initial commit"], in: baseURL)

        for relativePath in [".pnevma", ".pnevma/data", ".pnevma/rules", ".pnevma/conventions"] {
            try FileManager.default.createDirectory(
                at: baseURL.appendingPathComponent(relativePath, isDirectory: true),
                withIntermediateDirectories: true
            )
        }

        try "alpha changed\n".write(to: baseURL.appendingPathComponent("alpha.txt"), atomically: true, encoding: .utf8)
        try "beta changed\n".write(to: baseURL.appendingPathComponent("beta.txt"), atomically: true, encoding: .utf8)

        return baseURL
    }

    func runGit(_ arguments: [String], in directory: URL) throws {
        let process = Process()
        process.executableURL = gitExecutableURL()
        process.arguments = arguments
        process.currentDirectoryURL = directory

        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr

        try process.run()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            let errorData = stderr.fileHandleForReading.readDataToEndOfFile()
            let output = String(data: errorData, encoding: .utf8) ?? "unknown git error"
            XCTFail("git \(arguments.joined(separator: " ")) failed: \(output)")
            throw NSError(domain: "PnevmaUITestCase", code: Int(process.terminationStatus))
        }
    }

    func gitExecutableURL() -> URL {
        let candidates = [
            "/Applications/Xcode.app/Contents/Developer/usr/bin/git",
            "/Library/Developer/CommandLineTools/usr/bin/git",
            "/opt/homebrew/bin/git",
            "/usr/local/bin/git",
            "/usr/bin/git",
        ]

        for path in candidates where FileManager.default.isExecutableFile(atPath: path) {
            return URL(fileURLWithPath: path)
        }

        return URL(fileURLWithPath: "/usr/bin/git")
    }
}
