import AppKit
import Foundation
import XCTest

enum UIExerciseCoverageStatus: String, Codable {
    case exercised
    case humanReview = "human_review"
    case blocked
}

struct UIExerciseCoverageRecord: Codable {
    let surface: String
    let status: UIExerciseCoverageStatus
    let detail: String?
    let evidence: [String]
}

private final class XCTestLifecycleErrorBox: NSObject {
    var error: Error?
}

private final class XCTestRecordedIssueBox: NSObject {
    let issueType: String
    let compactDescription: String

    init(issueType: String, compactDescription: String) {
        self.issueType = issueType
        self.compactDescription = compactDescription
    }
}

private final class ProjectCleanupURLBox: NSObject {
    var url: URL?
}

@MainActor
class PnevmaUITestCase: XCTestCase {
    let defaultTimeout: TimeInterval = 10
    let shortTimeout: TimeInterval = 2
    var app: XCUIApplication!
    private let appBundleIdentifier = "com.pnevma.app"
    private(set) var harnessLog: [String] = []
    private(set) var coverageRecords: [UIExerciseCoverageRecord] = []
    private(set) var hardFailures: [String] = []
    private var evidenceCounter = 0
    private var isRecordingIssue = false
    private var isAttachingFailureDiagnostics = false

    var expectedLaunchReadinessState: String { "terminal-ready" }
    var shouldSeedUITestFixtures: Bool { true }

    func configureApp(_ app: XCUIApplication) throws {}

    override nonisolated func setUpWithError() throws {
        let errorBox = XCTestLifecycleErrorBox()
        perform(#selector(runSetUpOnMainThread(_:)), on: .main, with: errorBox, waitUntilDone: true)
        if let error = errorBox.error {
            throw error
        }
    }

    override nonisolated func tearDownWithError() throws {
        perform(#selector(runTearDownOnMainThread), on: .main, with: nil, waitUntilDone: true)
    }

    override nonisolated func record(_ issue: XCTIssue) {
        let issueBox = XCTestRecordedIssueBox(
            issueType: String(issue.type.rawValue),
            compactDescription: issue.compactDescriptionIfAvailable
        )
        perform(#selector(runRecordOnMainThread(_:)), on: .main, with: issueBox, waitUntilDone: true)
        super.record(issue)
    }

    @objc private func runSetUpOnMainThread(_ errorBox: XCTestLifecycleErrorBox) {
        do {
            try performSetUp()
        } catch {
            errorBox.error = error
        }
    }

    @objc private func runTearDownOnMainThread() {
        performTearDown()
    }

    @objc private func runRecordOnMainThread(_ issueBox: XCTestRecordedIssueBox) {
        performRecord(issueType: issueBox.issueType, compactDescription: issueBox.compactDescription)
    }
}

@MainActor
extension PnevmaUITestCase {
    func performSetUp() throws {
        continueAfterFailure = false
        harnessLog.removeAll()
        coverageRecords.removeAll()
        hardFailures.removeAll()
        evidenceCounter = 0

        terminateRunningPnevmaApps()

        let app = XCUIApplication()
        self.app = app
        app.launchEnvironment["PNEVMA_UI_TESTING"] = "1"
        app.launchEnvironment["PNEVMA_UI_TEST_LIGHTWEIGHT_MODE"] = "1"
        if shouldSeedUITestFixtures {
            app.launchEnvironment["PNEVMA_UI_TEST_SEED_FIXTURES"] = "1"
        }
        try configureApp(app)

        log("Launching app with expected readiness \(expectedLaunchReadinessState)")
        app.launch()
        waitForReadinessState(expectedLaunchReadinessState)
        dismissOpenWorkspaceDialogIfNeeded()
        _ = attachScreenshot(surface: "launch", phase: "ready")
    }

    func performTearDown() {
        attachHarnessArtifacts(prefix: makeEvidenceName(surface: "harness", phase: "summary"))
        app?.terminate()
        app = nil
    }

    func performRecord(issueType: String, compactDescription: String) {
        if isRecordingIssue {
            return
        }

        isRecordingIssue = true
        defer { isRecordingIssue = false }
        log("Failure recorded: \(issueType) — \(compactDescription)")
        attachFailureDiagnostics(prefix: makeEvidenceName(surface: "failure", phase: "diagnostics"))
    }

    func runStep(_ name: String, block: () throws -> Void) rethrows {
        log("STEP \(name)")
        try block()
    }

    func log(_ message: String) {
        let timestamp = ISO8601DateFormatter().string(from: Date())
        harnessLog.append("[\(timestamp)] \(message)")
    }

    func hasLiveTargetApp() -> Bool {
        NSRunningApplication.runningApplications(withBundleIdentifier: appBundleIdentifier)
            .contains { !$0.isTerminated }
    }

    @discardableResult
    func attachScreenshot(surface: String, phase: String) -> String {
        let name = makeEvidenceName(surface: surface, phase: phase)
        guard app != nil, hasLiveTargetApp() else {
            attachText("Skipped screenshot \(name): target application is not running.", named: "\(name).skipped.txt")
            log("Skipped screenshot \(name) because target app is not running")
            return name
        }
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        log("Attached screenshot \(name)")
        return name
    }

    func attachText(_ text: String, named name: String) {
        let attachment = XCTAttachment(string: text)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    func attachJSON<T: Encodable>(_ value: T, named name: String) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        do {
            let data = try encoder.encode(value)
            let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.json")
            attachment.name = name
            attachment.lifetime = .keepAlways
            add(attachment)
        } catch {
            attachText("Failed to encode JSON for \(name): \(error.localizedDescription)", named: "\(name).error")
        }
    }

    func attachHarnessArtifacts(prefix: String) {
        if !harnessLog.isEmpty {
            attachText(harnessLog.joined(separator: "\n"), named: "\(prefix).log")
        }
        if !coverageRecords.isEmpty {
            attachJSON(coverageRecords, named: "\(prefix).coverage.json")
            attachText(coverageSummaryMarkdown(), named: "\(prefix).coverage.md")
        }
    }

    func attachFailureDiagnostics(prefix: String) {
        guard !isAttachingFailureDiagnostics else {
            return
        }

        isAttachingFailureDiagnostics = true
        defer { isAttachingFailureDiagnostics = false }

        guard app != nil, hasLiveTargetApp() else {
            attachHarnessArtifacts(prefix: prefix)
            return
        }

        _ = attachScreenshot(surface: "failure", phase: prefix)
        attachText(app.debugDescription, named: "\(prefix).hierarchy.txt")
        let windowSummary = app.windows.allElementsBoundByIndex.enumerated().map { index, window in
            let frame = window.frame
            return "window[\(index)] exists=\(window.exists) frame=\(NSStringFromRect(frame)) title=\(window.label)"
        }.joined(separator: "\n")
        attachText(windowSummary, named: "\(prefix).windows.txt")
        attachHarnessArtifacts(prefix: prefix)
    }

    func makeEvidenceName(surface: String, phase: String) -> String {
        evidenceCounter += 1
        let suite = sanitizedIdentifier(String(describing: type(of: self)))
        let surfacePart = sanitizedIdentifier(surface)
        let phasePart = sanitizedIdentifier(phase)
        return String(format: "ui.%@.%02d.%@.%@", suite, evidenceCounter, surfacePart, phasePart)
    }

    func sanitizedIdentifier(_ value: String) -> String {
        let allowed = CharacterSet.alphanumerics
        let scalars = value.unicodeScalars.map { scalar -> String in
            allowed.contains(scalar) ? String(scalar).lowercased() : "_"
        }
        let collapsed = scalars.joined()
            .replacingOccurrences(of: "_+", with: "_", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "_"))
        return collapsed.isEmpty ? "item" : collapsed
    }

    func coverageSummaryMarkdown() -> String {
        let grouped = Dictionary(grouping: coverageRecords, by: \.status)
        let exercised = grouped[.exercised] ?? []
        let humanReview = grouped[.humanReview] ?? []
        let blocked = grouped[.blocked] ?? []

        func section(_ title: String, records: [UIExerciseCoverageRecord]) -> String {
            if records.isEmpty { return "- none" }
            return records.map { record in
                let detail = record.detail.map { " — \($0)" } ?? ""
                return "- \(record.surface)\(detail)"
            }.joined(separator: "\n")
        }

        return """
        # UI exercise coverage

        ## Exercised
        \(section("Exercised", records: exercised))

        ## Human review
        \(section("Human review", records: humanReview))

        ## Blocked
        \(section("Blocked", records: blocked))
        """
    }

    func recordCoverage(
        surface: String,
        status: UIExerciseCoverageStatus,
        detail: String? = nil,
        evidence: [String] = []
    ) {
        coverageRecords.append(
            UIExerciseCoverageRecord(
                surface: surface,
                status: status,
                detail: detail,
                evidence: evidence
            )
        )
        log("Coverage \(status.rawValue): \(surface)\(detail.map { " — \($0)" } ?? "")")
    }

    func markExercised(_ surface: String, detail: String? = nil, evidence: [String] = []) {
        recordCoverage(surface: surface, status: .exercised, detail: detail, evidence: evidence)
    }

    func markHumanReview(_ surface: String, detail: String? = nil, evidence: [String] = []) {
        recordCoverage(surface: surface, status: .humanReview, detail: detail, evidence: evidence)
    }

    func markBlocked(_ surface: String, detail: String? = nil, evidence: [String] = []) {
        recordCoverage(surface: surface, status: .blocked, detail: detail, evidence: evidence)
    }

    func recordHardFailure(_ message: String) {
        hardFailures.append(message)
        log("HARD FAILURE: \(message)")
    }

    func assertNoHardFailures(file: StaticString = #filePath, line: UInt = #line) {
        if hardFailures.isEmpty { return }
        XCTFail(hardFailures.joined(separator: "\n"), file: file, line: line)
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

    func elementExists(_ element: XCUIElement, timeout: TimeInterval? = nil) -> Bool {
        element.waitForExistence(timeout: timeout ?? defaultTimeout)
    }

    func element(_ identifier: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

    func staticText(_ identifier: String) -> XCUIElement {
        app.staticTexts.matching(identifier: identifier).firstMatch
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
    func ensureExists(
        _ element: XCUIElement,
        timeout: TimeInterval? = nil,
        failure: String
    ) -> Bool {
        let exists = element.waitForExistence(timeout: timeout ?? defaultTimeout)
        if !exists {
            recordHardFailure(failure)
        }
        return exists
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

    @discardableResult
    func ensureHittable(
        _ element: XCUIElement,
        timeout: TimeInterval? = nil,
        failure: String
    ) -> Bool {
        let deadline = Date().addingTimeInterval(timeout ?? defaultTimeout)
        repeat {
            if element.exists && element.isHittable {
                return true
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        } while Date() < deadline

        recordHardFailure(failure)
        return false
    }

    @discardableResult
    func clickIfExists(
        _ element: XCUIElement,
        timeout: TimeInterval? = nil,
        failure: String
    ) -> Bool {
        guard element.waitForExistence(timeout: timeout ?? defaultTimeout) else {
            recordHardFailure(failure)
            return false
        }

        guard ensureHittable(
            element,
            timeout: timeout,
            failure: "\(failure) (element was not hittable)"
        ) else {
            return false
        }

        element.click()
        return true
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

    func waitForLabelChange(
        _ element: XCUIElement,
        from previousValue: String,
        timeout: TimeInterval? = nil
    ) -> Bool {
        let deadline = Date().addingTimeInterval(timeout ?? defaultTimeout)
        repeat {
            if element.exists && element.label != previousValue {
                return true
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        } while Date() < deadline
        return false
    }

    func displayedText(of element: XCUIElement) -> String {
        let label = element.label.trimmingCharacters(in: .whitespacesAndNewlines)
        if !label.isEmpty {
            return label
        }
        if let value = element.value as? String {
            return value.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return ""
    }

    @discardableResult
    func waitForDisplayedText(
        _ element: XCUIElement,
        toEqual expectedValue: String,
        timeout: TimeInterval? = nil
    ) -> Bool {
        let deadline = Date().addingTimeInterval(timeout ?? defaultTimeout)
        repeat {
            if element.exists && displayedText(of: element) == expectedValue {
                return true
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        } while Date() < deadline

        return element.exists && displayedText(of: element) == expectedValue
    }

    func assertWindowFrameStable(
        _ window: XCUIElement,
        while description: String,
        accuracy: CGFloat = 1,
        action: () -> Void,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let initialFrame = requireExists(window, file: file, line: line).frame
        action()
        let updatedFrame = requireExists(window, file: file, line: line).frame
        XCTAssertEqual(initialFrame.width, updatedFrame.width, accuracy: accuracy, "Window width changed during \(description)", file: file, line: line)
        XCTAssertEqual(initialFrame.height, updatedFrame.height, accuracy: accuracy, "Window height changed during \(description)", file: file, line: line)
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

    func replaceText(
        in element: XCUIElement,
        with value: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let field = requireHittable(element, file: file, line: line)
        field.click()
        app.typeKey("a", modifierFlags: .command)
        field.typeText(XCUIKeyboardKey.delete.rawValue)
        if !value.isEmpty {
            field.typeText(value)
        }
    }

    @discardableResult
    func sidebarButton(
        _ label: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) -> XCUIElement {
        button(label, file: file, line: line)
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
        case "resource_monitor": return "Resources"
        case "brief": return "Daily Brief"
        case "rules": return "Rules Manager"
        case "secrets": return "Secrets"
        case "ports": return "Ports"
        case "files": return "File Browser"
        case "diff": return "Diff Viewer"
        case "review": return "Review"
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
        let identifier = "sidebar.tool.\(toolID)"
        let sidebarRoots = [
            app.otherElements["sidebar.view"],
            app.descendants(matching: .any)["sidebar.view"],
        ]

        for sidebarRoot in sidebarRoots where sidebarRoot.waitForExistence(timeout: shortTimeout) {
            let identifiedInSidebar = sidebarRoot.descendants(matching: .any).matching(identifier: identifier).firstMatch
            if identifiedInSidebar.waitForExistence(timeout: defaultTimeout) {
                return identifiedInSidebar
            }

            let labeledButton = sidebarRoot.buttons[sidebarToolLabel(for: toolID)]
            if labeledButton.waitForExistence(timeout: defaultTimeout) {
                return labeledButton
            }
        }

        func isSidebarFrame(_ frame: CGRect) -> Bool {
            frame.minX < 420 && frame.width >= 44 && frame.height >= 20
        }

        let identifiedButton = app.buttons[identifier]
        if identifiedButton.waitForExistence(timeout: defaultTimeout), isSidebarFrame(identifiedButton.frame) {
            return identifiedButton
        }
        let identified = app.descendants(matching: .any)[identifier]
        if identified.waitForExistence(timeout: defaultTimeout), isSidebarFrame(identified.frame) {
            return identified
        }

        let label = sidebarToolLabel(for: toolID)
        let sidebarMatches = app.buttons.allElementsBoundByIndex
            .filter { $0.label == label && $0.exists && isSidebarFrame($0.frame) }

        if let match = sidebarMatches.max(by: { lhs, rhs in
            (lhs.frame.width * lhs.frame.height) < (rhs.frame.width * rhs.frame.height)
        }) {
            return match
        }

        XCTFail("Expected sidebar tool in sidebar region: \(toolID)", file: file, line: line)
        return identifiedButton
    }

    func clickSidebarTool(_ toolID: String) {
        sidebarTool(toolID).click()
    }

    @discardableResult
    func openSettingsWindow() -> XCUIElement {
        identifiedElement("sidebar.settings").click()
        return identifiedElement("settings.root")
    }

    @discardableResult
    func openWorkspaceOpener() -> XCUIElement {
        identifiedElement("sidebar.newWorkspace").click()
        return identifiedElement("workspaceOpener")
    }

    @discardableResult
    func toolDockItem(
        _ toolID: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) -> XCUIElement {
        let identifier = "tool-dock.item.\(toolID)"

        let identifiedButton = app.buttons[identifier]
        if identifiedButton.waitForExistence(timeout: 1) {
            return identifiedButton
        }

        let dockRoots = [
            app.scrollViews["tool-dock.view"],
            app.otherElements["tool-dock.view"],
            app.descendants(matching: .any)["tool-dock.view"],
        ]
        for dockRoot in dockRoots where dockRoot.waitForExistence(timeout: defaultTimeout) {
            let dockOther = dockRoot.otherElements[identifier]
            if dockOther.waitForExistence(timeout: 1) {
                return dockOther
            }

            let dockAny = dockRoot.descendants(matching: .any)[identifier]
            if dockAny.waitForExistence(timeout: 1) {
                return dockAny
            }
        }

        let identifiedOther = app.otherElements[identifier]
        if identifiedOther.waitForExistence(timeout: 1) {
            return identifiedOther
        }

        let identified = app.descendants(matching: .any)[identifier]
        if identified.waitForExistence(timeout: 1) {
            return identified
        }

        XCTFail("Expected tool dock item: \(toolID)", file: file, line: line)
        return identifiedButton
    }

    func dismissOpenWorkspaceDialogIfNeeded() {
        let legacyCancel = element("openWorkspace.cancel")
        if legacyCancel.waitForExistence(timeout: 1) {
            legacyCancel.click()
            return
        }

        let openerCancel = element("workspaceOpener.action.cancel")
        if openerCancel.waitForExistence(timeout: 1) {
            openerCancel.click()
        }
    }

    func waitForAnyIdentifier(
        _ identifiers: [String],
        timeout: TimeInterval? = nil
    ) -> String? {
        let deadline = Date().addingTimeInterval(timeout ?? defaultTimeout)
        repeat {
            for identifier in identifiers where element(identifier).exists {
                return identifier
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        } while Date() < deadline

        for identifier in identifiers where element(identifier).exists {
            return identifier
        }
        return nil
    }

    @discardableResult
    func identifiedElement(
        _ identifier: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) -> XCUIElement {
        let resolved = app.descendants(matching: .any).matching(identifier: identifier).firstMatch
        return requireExists(resolved, file: file, line: line)
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
        var lastObserved: String?
        repeat {
            if readiness.label != lastObserved {
                lastObserved = readiness.label
                log("Readiness state changed to \(readiness.label)")
            }
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

        let files: [(String, String)] = [
            ("alpha.txt", "alpha\n"),
            ("beta.txt", "beta\n"),
            ("notes.md", "# Notes\n\nFixture repo.\n"),
            ("README.md", "# UI Fixture Repo\n\nUsed for deterministic native UI automation.\n"),
            ("src/demo.swift", "struct Demo { let value = 42 }\n"),
            ("docs/changelog.md", "# Changelog\n\n- Initial fixture state.\n"),
        ]
        for (relativePath, content) in files {
            let fileURL = baseURL.appendingPathComponent(relativePath)
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try content.write(to: fileURL, atomically: true, encoding: .utf8)
        }

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
            (".pnevma/secrets/example.env", "API_TOKEN=redacted\n"),
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
        try runGit(["branch", "-M", "main"], in: baseURL)
        try runGit(["add", "."], in: baseURL)
        try runGit(["commit", "-q", "-m", "Initial commit"], in: baseURL)

        try runGit(["checkout", "-q", "-b", "feature/ui-harness"], in: baseURL)
        try "feature branch\n".write(
            to: baseURL.appendingPathComponent("feature.txt"),
            atomically: true,
            encoding: .utf8
        )
        try runGit(["add", "feature.txt"], in: baseURL)
        try runGit(["commit", "-q", "-m", "Add feature branch file"], in: baseURL)
        try runGit(["checkout", "-q", "main"], in: baseURL)

        for relativePath in [".pnevma", ".pnevma/data", ".pnevma/rules", ".pnevma/conventions"] {
            try FileManager.default.createDirectory(
                at: baseURL.appendingPathComponent(relativePath, isDirectory: true),
                withIntermediateDirectories: true
            )
        }

        try "alpha changed\n".write(to: baseURL.appendingPathComponent("alpha.txt"), atomically: true, encoding: .utf8)
        try "beta changed\n".write(to: baseURL.appendingPathComponent("beta.txt"), atomically: true, encoding: .utf8)
        try "# Notes\n\nFixture repo updated for right inspector coverage.\n".write(
            to: baseURL.appendingPathComponent("notes.md"),
            atomically: true,
            encoding: .utf8
        )

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

class PnevmaProjectUITestCase: PnevmaUITestCase {
    private(set) var projectURL: URL?

    override var expectedLaunchReadinessState: String { "project-ready" }

    @MainActor
    override func configureApp(_ app: XCUIApplication) throws {
        let projectURL = try makeFixtureRepository()
        self.projectURL = projectURL
        app.launchEnvironment["PNEVMA_UI_TEST_PROJECT_PATH"] = projectURL.path
    }

    override nonisolated func tearDownWithError() throws {
        try super.tearDownWithError()
        let cleanupBox = ProjectCleanupURLBox()
        perform(#selector(captureProjectCleanupURLOnMainThread(_:)), on: .main, with: cleanupBox, waitUntilDone: true)
        let cleanupURL = cleanupBox.url
        if let cleanupURL {
            try? FileManager.default.removeItem(at: cleanupURL)
        }
    }

    @objc private func captureProjectCleanupURLOnMainThread(_ cleanupBox: ProjectCleanupURLBox) {
        cleanupBox.url = projectURL
        projectURL = nil
    }
}

private extension XCTIssue {
    var compactDescriptionIfAvailable: String {
        let mirror = Mirror(reflecting: self)
        if let compact = mirror.children.first(where: { $0.label == "compactDescription" })?.value as? String,
           !compact.isEmpty {
            return compact
        }
        return String(describing: self)
    }
}
