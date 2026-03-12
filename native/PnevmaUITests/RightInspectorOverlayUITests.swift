import XCTest

final class RightInspectorOverlayUITests: PnevmaUITestCase {
    private var projectURL: URL?

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
        let changesTab = identifiedElement("right-inspector-tab-changes")
        changesTab.click()

        let alphaChange = identifiedElement("right-inspector-change-row-alpha_txt")
        alphaChange.click()

        let overlayTitle = identifiedElement("right-inspector-overlay-title")
        XCTAssertTrue(
            overlayTitle.label.contains("alpha.txt"),
            "Expected the change overlay to show alpha.txt, got: \(overlayTitle.label)"
        )

        let betaChange = identifiedElement("right-inspector-change-row-beta_txt")
        betaChange.click()

        XCTAssertTrue(
            overlayTitle.waitForExistence(timeout: defaultTimeout),
            "Expected overlay title to remain visible after selecting a second change."
        )
        XCTAssertTrue(
            overlayTitle.label.contains("beta.txt"),
            "Expected the change overlay to update to beta.txt, got: \(overlayTitle.label)"
        )

        let reviewTab = identifiedElement("right-inspector-tab-review")
        reviewTab.click()
        requireExists(app.staticTexts["No review tasks"])

        let filesTab = identifiedElement("right-inspector-tab-files")
        filesTab.click()

        let notesFile = identifiedElement("right-inspector-file-row-notes_md")
        notesFile.click()

        XCTAssertTrue(
            overlayTitle.waitForExistence(timeout: defaultTimeout),
            "Expected file overlay title to appear after selecting notes.md."
        )
        XCTAssertTrue(
            overlayTitle.label.contains("notes.md"),
            "Expected the file overlay to show notes.md, got: \(overlayTitle.label)"
        )

        changesTab.click()
        betaChange.click()

        XCTAssertTrue(
            overlayTitle.waitForExistence(timeout: defaultTimeout),
            "Expected diff overlay title to remain accessible after switching back to Changes."
        )
        XCTAssertTrue(
            overlayTitle.label.contains("beta.txt"),
            "Expected the diff overlay to reopen on beta.txt, got: \(overlayTitle.label)"
        )
    }

    private func makeFixtureRepository() throws -> URL {
        let baseURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: baseURL, withIntermediateDirectories: true)

        try "alpha\n".write(to: baseURL.appendingPathComponent("alpha.txt"), atomically: true, encoding: .utf8)
        try "beta\n".write(to: baseURL.appendingPathComponent("beta.txt"), atomically: true, encoding: .utf8)
        try "# Notes\n\nFixture repo.\n".write(
            to: baseURL.appendingPathComponent("notes.md"),
            atomically: true,
            encoding: .utf8
        )

        try runGit(["init", "-q"], in: baseURL)
        try runGit(["config", "user.email", "uitest@example.com"], in: baseURL)
        try runGit(["config", "user.name", "UI Test"], in: baseURL)
        try runGit(["add", "."], in: baseURL)
        try runGit(["commit", "-q", "-m", "Initial commit"], in: baseURL)

        try "alpha changed\n".write(to: baseURL.appendingPathComponent("alpha.txt"), atomically: true, encoding: .utf8)
        try "beta changed\n".write(to: baseURL.appendingPathComponent("beta.txt"), atomically: true, encoding: .utf8)

        return baseURL
    }

    private func runGit(_ arguments: [String], in directory: URL) throws {
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
            throw NSError(domain: "RightInspectorOverlayUITests", code: Int(process.terminationStatus))
        }
    }

    private func gitExecutableURL() -> URL {
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
