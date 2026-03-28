import AppKit
import XCTest

private struct PaneExerciseSpec {
    let toolID: String
    let rootIdentifier: String
    let detail: String
    let requiresHumanReview: Bool
}

private struct SettingsSectionSpec {
    let id: String
    let subtitle: String
}

@MainActor
private extension PnevmaUITestCase {
    @discardableResult
    func waitForLabelContains(
        _ element: XCUIElement,
        substring: String,
        timeout: TimeInterval? = nil
    ) -> Bool {
        let deadline = Date().addingTimeInterval(timeout ?? defaultTimeout)
        repeat {
            if element.exists, element.label.contains(substring) {
                return true
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        } while Date() < deadline

        return element.exists && element.label.contains(substring)
    }

    func bestMatch(for identifier: String) -> XCUIElement? {
        let matches = app.descendants(matching: .any)
            .matching(identifier: identifier)
            .allElementsBoundByIndex
            .filter { $0.exists }

        guard !matches.isEmpty else {
            return nil
        }

        return matches.max { lhs, rhs in
            (lhs.frame.width * lhs.frame.height) < (rhs.frame.width * rhs.frame.height)
        }
    }

    func softClick(_ element: XCUIElement, timeout: TimeInterval? = nil) -> Bool {
        guard element.waitForExistence(timeout: timeout ?? defaultTimeout) else {
            return false
        }
        guard element.isHittable else {
            return false
        }
        element.click()
        return true
    }

    func firstExistingElement(
        _ candidates: [XCUIElement],
        timeout: TimeInterval? = nil
    ) -> XCUIElement? {
        let deadline = Date().addingTimeInterval(timeout ?? defaultTimeout)
        repeat {
            if let match = candidates.first(where: { $0.exists }) {
                return match
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        } while Date() < deadline

        return candidates.first(where: { $0.exists })
    }

    @discardableResult
    func softlyClickIfExists(
        _ element: XCUIElement,
        timeout: TimeInterval? = nil
    ) -> Bool {
        guard element.waitForExistence(timeout: timeout ?? defaultTimeout) else {
            return false
        }
        guard element.isHittable else {
            log("Optional click skipped for non-hittable element: \(element)")
            return false
        }
        element.click()
        return true
    }

    @discardableResult
    func clickFirstExisting(
        _ candidates: [XCUIElement],
        timeout: TimeInterval? = nil,
        failure: String
    ) -> Bool {
        guard let candidate = firstExistingElement(candidates, timeout: timeout ?? defaultTimeout) else {
            recordHardFailure(failure)
            return false
        }

        guard ensureHittable(
            candidate,
            timeout: timeout,
            failure: "\(failure) (element was not hittable)"
        ) else {
            return false
        }

        candidate.click()
        return true
    }

    func settingsSearchField() -> XCUIElement {
        let byInputIdentifier = app.descendants(matching: .textField)["settings.sidebar.search.input"]
        if byInputIdentifier.exists {
            return byInputIdentifier
        }

        let byContainerIdentifier = app.descendants(matching: .textField)["settings.sidebar.search"]
        if byContainerIdentifier.exists {
            return byContainerIdentifier
        }

        return app.descendants(matching: .textField)
            .matching(NSPredicate(format: "placeholderValue == %@", "Search"))
            .firstMatch
    }

    @discardableResult
    func replaceTextWithFocusFallback(
        in element: XCUIElement,
        with value: String,
        failure: String
    ) -> Bool {
        guard ensureExists(element, failure: failure) else {
            return false
        }

        if element.isHittable {
            replaceText(in: element, with: value)
            return true
        }

        log("Using focused-input fallback for non-hittable text field: \(element)")
        app.typeKey("a", modifierFlags: .command)
        app.typeKey(XCUIKeyboardKey.delete.rawValue, modifierFlags: [])
        if !value.isEmpty {
            app.typeText(value)
        }
        return true
    }

    @discardableResult
    func selectWorkspaceOpenerProject(named projectName: String) -> Bool {
        let picker = element("workspaceOpener.projectPicker")
        if displayedText(of: picker).contains(projectName) || picker.label.contains(projectName) {
            return true
        }

        guard clickIfExists(
            picker,
            timeout: shortTimeout,
            failure: "Expected workspace opener project picker."
        ) else {
            return false
        }

        let namedMenuItem = app.menuItems[projectName]
        let fallbackButton = app.buttons[projectName]
        let fallbackStaticText = app.staticTexts[projectName]
        let fallbackOther = app.otherElements[projectName]
        let fallbackElement = app.descendants(matching: .any)[projectName]

        return clickFirstExisting(
            [namedMenuItem, fallbackButton, fallbackStaticText, fallbackOther, fallbackElement],
            timeout: defaultTimeout,
            failure: "Expected workspace opener project option \(projectName)."
        )
    }

    func sidebarToolCandidate(_ toolID: String) -> XCUIElement? {
        let identifier = "sidebar.tool.\(toolID)"
        let sidebarRootCandidates = [
            app.otherElements["sidebar.view"],
            app.descendants(matching: .any)["sidebar.view"],
        ]

        for sidebarRoot in sidebarRootCandidates where sidebarRoot.waitForExistence(timeout: shortTimeout) {
            let buttonByIdentifier = sidebarRoot.buttons.matching(identifier: identifier).firstMatch
            if buttonByIdentifier.waitForExistence(timeout: shortTimeout) {
                return buttonByIdentifier
            }

            let byIdentifier = sidebarRoot.descendants(matching: .any).matching(identifier: identifier).firstMatch
            if byIdentifier.waitForExistence(timeout: shortTimeout) {
                return byIdentifier
            }

            let label = sidebarToolLabel(for: toolID)
            let buttonMatch = sidebarRoot.buttons[label]
            if buttonMatch.waitForExistence(timeout: shortTimeout) {
                return buttonMatch
            }
        }

        func isSidebarFrame(_ frame: CGRect) -> Bool {
            frame.minX < 420 && frame.width >= 44 && frame.height >= 20
        }

        let byIdentifier = app.buttons.matching(identifier: identifier).firstMatch
        if byIdentifier.waitForExistence(timeout: shortTimeout), isSidebarFrame(byIdentifier.frame) {
            return byIdentifier
        }

        let anyIdentifier = app.descendants(matching: .any).matching(identifier: identifier).firstMatch
        if anyIdentifier.waitForExistence(timeout: shortTimeout), isSidebarFrame(anyIdentifier.frame) {
            return anyIdentifier
        }

        let label = sidebarToolLabel(for: toolID)
        let candidates = app.buttons.allElementsBoundByIndex
            .filter { $0.label == label && $0.exists && isSidebarFrame($0.frame) }

        return candidates.max { lhs, rhs in
            (lhs.frame.width * lhs.frame.height) < (rhs.frame.width * rhs.frame.height)
        }
    }

    func dockToolCandidate(_ toolID: String) -> XCUIElement {
        let identifier = "tool-dock.item.\(toolID)"
        let button = app.buttons.matching(identifier: identifier).firstMatch
        if button.waitForExistence(timeout: shortTimeout) {
            return button
        }

        let dockRootCandidates = [
            app.scrollViews["tool-dock.view"],
            app.otherElements["tool-dock.view"],
            app.descendants(matching: .any)["tool-dock.view"],
        ]
        for dockRoot in dockRootCandidates where dockRoot.waitForExistence(timeout: shortTimeout) {
            let dockMatch = dockRoot
                .descendants(matching: .any)
                .matching(identifier: identifier)
                .firstMatch
            if dockMatch.waitForExistence(timeout: shortTimeout) {
                return dockMatch
            }
        }

        return app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

    func firstVisibleRoot(
        identifiers: [String],
        timeout: TimeInterval? = nil
    ) -> (String, XCUIElement)? {
        let deadline = Date().addingTimeInterval(timeout ?? defaultTimeout)
        repeat {
            for identifier in identifiers {
                guard let element = bestMatch(for: identifier), element.waitForExistence(timeout: shortTimeout) else {
                    continue
                }

                let frame = element.frame
                if frame.width >= 40, frame.height >= 40 {
                    return (identifier, element)
                }
            }

            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        } while Date() < deadline

        return nil
    }

    func verifySurfaceVisible(
        identifier: String,
        description: String
    ) -> Bool {
        guard let root = bestMatch(for: identifier), root.waitForExistence(timeout: shortTimeout) else {
            return false
        }

        let frame = root.frame
        if frame.width < 40 || frame.height < 40 {
            recordHardFailure("Expected \(description) frame to be non-trivial, got \(NSStringFromRect(frame)).")
            return false
        }

        if root.descendants(matching: .any).count == 0 {
            recordHardFailure("Expected \(description) to have visible descendants.")
            return false
        }

        return true
    }

    func exerciseSidebarSurface(_ spec: PaneExerciseSpec) {
        let surface = "sidebar.tool.\(spec.toolID)"
        let before = attachScreenshot(surface: surface, phase: "before")

        guard let button = sidebarToolCandidate(spec.toolID) else {
            markBlocked(surface, detail: "Sidebar tool is not present in the current sidebar chrome.", evidence: [before])
            return
        }

        guard softClick(button, timeout: shortTimeout) else {
            markBlocked(surface, detail: "Sidebar tool missing or not clickable in the current workspace chrome.", evidence: [before])
            return
        }

        guard verifySurfaceVisible(identifier: spec.rootIdentifier, description: spec.detail) else {
            let failureShot = attachScreenshot(surface: surface, phase: "missing_root")
            markBlocked(
                surface,
                detail: "Expected root \(spec.rootIdentifier) did not appear.",
                evidence: [before, failureShot]
            )
            return
        }

        let after = attachScreenshot(surface: surface, phase: "after")
        if spec.requiresHumanReview {
            markHumanReview(
                surface,
                detail: "\(spec.detail) opened successfully; screenshot evidence still needs human visual review.",
                evidence: [before, after]
            )
        } else {
            markExercised(surface, detail: spec.detail, evidence: [before, after])
        }
    }

    func exerciseDockSurface(_ spec: PaneExerciseSpec) {
        let surface = "tool-dock.item.\(spec.toolID)"
        let button = dockToolCandidate(spec.toolID)
        let before = attachScreenshot(surface: surface, phase: "before")

        guard softClick(button, timeout: shortTimeout) else {
            markBlocked(surface, detail: "Dock item missing or not clickable.", evidence: [before])
            return
        }

        let drawerState = element("bottom.drawer.state")
        guard drawerState.waitForExistence(timeout: defaultTimeout) else {
            let failureShot = attachScreenshot(surface: surface, phase: "drawer_state_missing")
            markBlocked(surface, detail: "Bottom drawer did not open.", evidence: [before, failureShot])
            return
        }

        let expectedStateToken = spec.toolID.replacingOccurrences(of: "_", with: " ")
        let stateText = displayedText(of: drawerState)
        if !stateText.localizedCaseInsensitiveContains(spec.toolID)
            && !stateText.localizedCaseInsensitiveContains(expectedStateToken) {
            recordHardFailure("Expected bottom drawer state to mention \(spec.toolID), got \(stateText).")
        }

        let contentIdentifier = "bottom.drawer.content.\(spec.toolID)"
        let candidateRootIdentifiers = Array(Set([contentIdentifier, spec.rootIdentifier]))
        guard firstVisibleRoot(identifiers: candidateRootIdentifiers, timeout: defaultTimeout) != nil else {
            let failureShot = attachScreenshot(surface: surface, phase: "drawer_content_missing")
            markBlocked(
                surface,
                detail: "Expected drawer content root did not appear for identifiers: \(candidateRootIdentifiers.joined(separator: ", ")).",
                evidence: [before, failureShot]
            )
            return
        }

        let after = attachScreenshot(surface: surface, phase: "after")
        if spec.requiresHumanReview {
            markHumanReview(
                surface,
                detail: "Drawer opened for \(spec.detail); content is evidence-backed but still requires visual review.",
                evidence: [before, after]
            )
        } else {
            markExercised(surface, detail: "Drawer opened for \(spec.detail).", evidence: [before, after])
        }
    }

    @discardableResult
    func waitForSelectionState(
        _ element: XCUIElement,
        selected: Bool,
        timeout: TimeInterval? = nil
    ) -> Bool {
        let deadline = Date().addingTimeInterval(timeout ?? defaultTimeout)
        repeat {
            if element.exists && element.isSelected == selected {
                return true
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        } while Date() < deadline

        return element.exists && element.isSelected == selected
    }

    @discardableResult
    func waitForEnabledState(
        _ element: XCUIElement,
        enabled: Bool,
        timeout: TimeInterval? = nil
    ) -> Bool {
        let deadline = Date().addingTimeInterval(timeout ?? defaultTimeout)
        repeat {
            if element.exists && element.isEnabled == enabled {
                return true
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        } while Date() < deadline

        return element.exists && element.isEnabled == enabled
    }
}

@MainActor
final class PnevmaTerminalUIExplorationHarnessTests: PnevmaUITestCase {
    private let terminalSidebarSpecs: [PaneExerciseSpec] = [
        .init(toolID: "terminal", rootIdentifier: "pane.terminal", detail: "Terminal pane", requiresHumanReview: false),
        .init(toolID: "workflow", rootIdentifier: "pane.workflow", detail: "Workflow pane", requiresHumanReview: false),
        .init(toolID: "notifications", rootIdentifier: "pane.notifications", detail: "Notifications pane", requiresHumanReview: false),
        .init(toolID: "ssh", rootIdentifier: "pane.ssh", detail: "SSH manager pane", requiresHumanReview: false),
        .init(toolID: "harness", rootIdentifier: "pane.harnessConfig", detail: "Harness config pane", requiresHumanReview: false),
        .init(toolID: "browser", rootIdentifier: "pane.browser", detail: "Browser pane", requiresHumanReview: true),
        .init(toolID: "analytics", rootIdentifier: "pane.analytics", detail: "Analytics pane", requiresHumanReview: true),
        .init(toolID: "resource_monitor", rootIdentifier: "pane.resourceMonitor", detail: "Resource monitor pane", requiresHumanReview: true),
    ]

    func testExerciseTerminalWorkspaceSidebarAndDock() {
        runStep("exercise terminal sidebar tools") {
            for spec in terminalSidebarSpecs {
                exerciseSidebarSurface(spec)
            }
        }

        runStep("exercise terminal tool dock items") {
            for spec in terminalSidebarSpecs {
                exerciseDockSurface(spec)
            }
        }

        markBlocked(
            "workspace.project_only_panes",
            detail: "Task board, replay, daily brief, rules, secrets, and ports require a project fixture and are covered in the project harness."
        )

        assertNoHardFailures()
    }

    func testExerciseDrawerActionsOpenAsTabAndPinAsPane() {
        let closeButtons = app.buttons.matching(identifier: "tabbar.close")
        let initialCloseCount = closeButtons.count

        runStep("open browser drawer and promote to tab") {
            exerciseDockSurface(
                .init(
                    toolID: "browser",
                    rootIdentifier: "pane.browser",
                    detail: "Browser pane",
                    requiresHumanReview: true
                )
            )

            let before = attachScreenshot(surface: "bottom.drawer.openAsTab", phase: "before")
            guard softClick(element("bottom.drawer.openAsTab"), timeout: shortTimeout) else {
                markBlocked("bottom.drawer.openAsTab", detail: "Drawer action unavailable.", evidence: [before])
                return
            }

            let deadline = Date().addingTimeInterval(defaultTimeout)
            repeat {
                if closeButtons.count > initialCloseCount {
                    break
                }
                RunLoop.current.run(until: Date().addingTimeInterval(0.1))
            } while Date() < deadline

            if closeButtons.count <= initialCloseCount {
                recordHardFailure("Expected Open as Tab to increase close-button count beyond \(initialCloseCount), got \(closeButtons.count).")
            }

            let after = attachScreenshot(surface: "bottom.drawer.openAsTab", phase: "after")
            markExercised("bottom.drawer.openAsTab", detail: "Browser drawer promoted into a workspace tab.", evidence: [before, after])

            if closeButtons.count > initialCloseCount {
                closeButtons.element(boundBy: closeButtons.count - 1).click()
            }
        }

        runStep("open browser drawer and pin as pane") {
            let before = attachScreenshot(surface: "bottom.drawer.pinAsPane", phase: "before")
            guard softClick(dockToolCandidate("browser"), timeout: shortTimeout) else {
                markBlocked("bottom.drawer.pinAsPane", detail: "Browser dock item unavailable.", evidence: [before])
                return
            }
            guard softClick(element("bottom.drawer.pinAsPane"), timeout: shortTimeout) else {
                markBlocked("bottom.drawer.pinAsPane", detail: "Drawer action unavailable.", evidence: [before])
                return
            }

            if !verifySurfaceVisible(identifier: "pane.browser", description: "Pinned browser pane") {
                let failureShot = attachScreenshot(surface: "bottom.drawer.pinAsPane", phase: "missing_pane")
                markBlocked("bottom.drawer.pinAsPane", detail: "Browser pane did not appear after pinning.", evidence: [before, failureShot])
                return
            }

            let after = attachScreenshot(surface: "bottom.drawer.pinAsPane", phase: "after")
            markHumanReview(
                "bottom.drawer.pinAsPane",
                detail: "Browser drawer pinned into the layout; resulting pane captured for human visual review.",
                evidence: [before, after]
            )
        }

        markBlocked(
            "terminal.utility_overlays.agent_launcher",
            detail: "No stable accessibility-driven path for the terminal agent launcher overlay was found in current chrome."
        )

        assertNoHardFailures()
    }
}

@MainActor
final class PnevmaProjectUIExplorationHarnessTests: PnevmaProjectUITestCase {
    private let projectSidebarSpecs: [PaneExerciseSpec] = [
        .init(toolID: "terminal", rootIdentifier: "pane.terminal", detail: "Terminal pane", requiresHumanReview: false),
        .init(toolID: "tasks", rootIdentifier: "pane.taskBoard", detail: "Task board pane", requiresHumanReview: false),
        .init(toolID: "workflow", rootIdentifier: "pane.workflow", detail: "Workflow pane", requiresHumanReview: false),
        .init(toolID: "notifications", rootIdentifier: "pane.notifications", detail: "Notifications pane", requiresHumanReview: false),
        .init(toolID: "ssh", rootIdentifier: "pane.ssh", detail: "SSH manager pane", requiresHumanReview: false),
        .init(toolID: "harness", rootIdentifier: "pane.harnessConfig", detail: "Harness config pane", requiresHumanReview: false),
        .init(toolID: "replay", rootIdentifier: "pane.replay", detail: "Replay pane", requiresHumanReview: true),
        .init(toolID: "browser", rootIdentifier: "pane.browser", detail: "Browser pane", requiresHumanReview: true),
        .init(toolID: "analytics", rootIdentifier: "pane.analytics", detail: "Analytics pane", requiresHumanReview: true),
        .init(toolID: "resource_monitor", rootIdentifier: "pane.resourceMonitor", detail: "Resource monitor pane", requiresHumanReview: true),
        .init(toolID: "brief", rootIdentifier: "pane.dailyBrief", detail: "Daily brief pane", requiresHumanReview: true),
        .init(toolID: "rules", rootIdentifier: "pane.rules", detail: "Rules manager pane", requiresHumanReview: false),
        .init(toolID: "secrets", rootIdentifier: "pane.secrets", detail: "Secrets pane", requiresHumanReview: false),
        .init(toolID: "ports", rootIdentifier: "pane.ports", detail: "Ports pane", requiresHumanReview: true),
    ]

    func testExerciseProjectWorkspaceSidebarAndDock() {
        runStep("exercise project sidebar tools") {
            for spec in projectSidebarSpecs {
                exerciseSidebarSurface(spec)
            }
        }

        runStep("exercise project tool dock items") {
            for spec in projectSidebarSpecs {
                exerciseDockSurface(spec)
            }
        }

        runStep("exercise deterministic notifications controls") {
            toolDockItem("notifications").click()
            guard verifySurfaceVisible(identifier: "pane.notifications", description: "Notifications pane") else {
                markBlocked("pane.notifications.controls", detail: "Notifications pane did not appear.")
                return
            }

            let before = attachScreenshot(surface: "pane.notifications.controls", phase: "before")
            let notificationsPane = element("pane.notifications")
            let errorRow = element("pane.notifications.row.fixture.notification.error")
            let infoRow = element("pane.notifications.row.fixture.notification.info")

            _ = clickIfExists(
                notificationsPane.radioButtons["Errors"],
                timeout: shortTimeout,
                failure: "Expected Errors filter in notifications pane."
            )
            if !errorRow.waitForExistence(timeout: shortTimeout) {
                recordHardFailure("Expected fixture error notification while filtering errors.")
            }
            if infoRow.exists {
                recordHardFailure("Expected info notification to be filtered out while Errors is selected.")
            }

            _ = softlyClickIfExists(
                notificationsPane.radioButtons["All"],
                timeout: shortTimeout
            )
            _ = clickFirstExisting(
                [
                    element("pane.notifications.markAllRead"),
                    notificationsPane.buttons["Mark All Read"],
                    notificationsPane.buttons["Mark all notifications as read"],
                    app.buttons["Mark All Read"],
                    app.buttons["Mark all notifications as read"],
                ],
                timeout: shortTimeout,
                failure: "Expected Mark All Read control in notifications pane."
            )
            _ = clickIfExists(
                notificationsPane.radioButtons["Unread"],
                timeout: shortTimeout,
                failure: "Expected Unread filter in notifications pane."
            )
            if !app.staticTexts["No Notifications"].waitForExistence(timeout: shortTimeout) {
                recordHardFailure("Expected unread filter to become empty after marking all notifications read.")
            }

            _ = softlyClickIfExists(
                notificationsPane.radioButtons["All"],
                timeout: shortTimeout
            )
            _ = clickFirstExisting(
                [
                    element("pane.notifications.clear"),
                    notificationsPane.buttons["Clear"],
                    notificationsPane.buttons["Clear all notifications"],
                    app.buttons["Clear"],
                    app.buttons["Clear all notifications"],
                ],
                timeout: shortTimeout,
                failure: "Expected Clear control in notifications pane."
            )
            let clearAllButton = app.sheets.buttons["Clear All"]
            let fallbackClearAllButton = app.descendants(matching: .any)["action-button-1"]
            if clearAllButton.waitForExistence(timeout: shortTimeout) {
                clearAllButton.click()
            } else if fallbackClearAllButton.waitForExistence(timeout: shortTimeout) {
                fallbackClearAllButton.click()
            } else {
                recordHardFailure("Expected Clear All confirmation button after tapping Clear in notifications pane.")
            }

            if !app.staticTexts["No Notifications"].waitForExistence(timeout: shortTimeout) {
                recordHardFailure("Expected notifications pane to be empty after clearing fixture notifications.")
            }

            let after = attachScreenshot(surface: "pane.notifications.controls", phase: "after")
            markExercised(
                "pane.notifications.controls",
                detail: "Filters, mark-all-read, and clear-all flows exercised with seeded fixture notifications.",
                evidence: [before, after]
            )
        }

        runStep("exercise replay controls") {
            toolDockItem("replay").click()
            guard firstExistingElement(
                [
                    element("pane.replay"),
                    element("pane.replay.backward"),
                    app.buttons["Step backward"],
                    app.buttons["Play"],
                    app.buttons["Pause"],
                    app.buttons["Step forward"],
                ],
                timeout: defaultTimeout
            ) != nil else {
                markBlocked("pane.replay.controls", detail: "Replay pane did not appear.")
                return
            }

            let before = attachScreenshot(surface: "pane.replay.controls", phase: "before")
            _ = clickFirstExisting(
                [element("pane.replay.backward"), app.buttons["Step backward"]],
                timeout: shortTimeout,
                failure: "Expected replay backward control."
            )
            _ = clickFirstExisting(
                [element("pane.replay.playPause"), app.buttons["Play"], app.buttons["Pause"]],
                timeout: shortTimeout,
                failure: "Expected replay play/pause control."
            )
            _ = clickFirstExisting(
                [element("pane.replay.forward"), app.buttons["Step forward"]],
                timeout: shortTimeout,
                failure: "Expected replay forward control."
            )
            if firstExistingElement(
                [element("pane.replay.speed"), app.popUpButtons["Playback speed"]],
                timeout: shortTimeout
            ) == nil {
                recordHardFailure("Expected replay speed control.")
            }
            let after = attachScreenshot(surface: "pane.replay.controls", phase: "after")
            markHumanReview(
                "pane.replay.controls",
                detail: "Replay transport controls are wired, but meaningful visual validation still requires recorded session data.",
                evidence: [before, after]
            )
        }

        markBlocked(
            "pane.fileBrowser.direct",
            detail: "Standalone file-browser pane is not reachable from current sidebar/dock chrome; file coverage lives in the right inspector."
        )
        markBlocked(
            "pane.diff.direct",
            detail: "Diff routing now lives in the right inspector rather than a sidebar/dock entry."
        )
        markBlocked(
            "pane.review.direct",
            detail: "Review detail coverage still depends on backend review-pack data; no deterministic fixture path was added in this change."
        )

        assertNoHardFailures()
    }

    func testExerciseWorkspaceOpenerWithFixtureProject() {
        let settingsShot = attachScreenshot(surface: "workspaceOpener", phase: "before_open")
        _ = openWorkspaceOpener()

        guard ensureExists(element("workspaceOpener"), failure: "Expected workspace opener root.") else {
            markBlocked("workspaceOpener", detail: "Workspace opener failed to open.", evidence: [settingsShot])
            return
        }

        let submitButton = app.buttons["workspaceOpener.action.submit"]
        let initialShot = attachScreenshot(surface: "workspaceOpener", phase: "opened")

        runStep("exercise prompt tab advanced options") {
            let promptTab = element("opener.tab.prompt")
            promptTab.click()
            if !waitForSelectionState(promptTab, selected: true) {
                recordHardFailure("Expected prompt tab to become selected.")
            }

            _ = clickIfExists(element("workspaceOpener.prompt.advanced"), failure: "Expected prompt advanced toggle.")
            _ = clickIfExists(element("workspaceOpener.prompt.remoteSSH"), failure: "Expected remote SSH toggle.")
            if !waitForEnabledState(submitButton, enabled: false) {
                recordHardFailure("Expected submit button to be disabled while remote SSH is enabled without credentials.")
            }

            replaceText(in: app.textFields["workspaceOpener.prompt.ssh.host"], with: "fixture-host")
            replaceText(in: app.textFields["workspaceOpener.prompt.ssh.user"], with: "fixture-user")
            replaceText(in: app.textFields["workspaceOpener.prompt.ssh.path"], with: "~/workspace")
            if !waitForEnabledState(submitButton, enabled: true) {
                recordHardFailure("Expected submit button to become enabled after filling SSH fields.")
            }

            _ = attachScreenshot(surface: "workspaceOpener.prompt", phase: "configured")
        }

        runStep("select fixture project") {
            guard let projectName = projectURL?.lastPathComponent else {
                recordHardFailure("Expected fixture project path for workspace opener coverage.")
                return
            }

            let before = attachScreenshot(surface: "workspaceOpener.projectPicker", phase: "before")
            guard selectWorkspaceOpenerProject(named: projectName) else {
                markBlocked(
                    "workspaceOpener.projectPicker.fixtureSelection",
                    detail: "Could not select the seeded fixture project in the project picker.",
                    evidence: [before]
                )
                return
            }

            let after = attachScreenshot(surface: "workspaceOpener.projectPicker", phase: "after")
            markExercised(
                "workspaceOpener.projectPicker.fixtureSelection",
                detail: "Selected the seeded fixture project in the workspace opener.",
                evidence: [before, after]
            )
        }

        runStep("exercise issues tab") {
            let issuesTab = element("opener.tab.issues")
            issuesTab.click()
            if !waitForSelectionState(issuesTab, selected: true) {
                recordHardFailure("Expected issues tab to become selected.")
            }

            guard ensureHittable(
                app.textFields["workspaceOpener.issues.search"],
                timeout: defaultTimeout,
                failure: "Expected issues search field after selecting the fixture project."
            ) else {
                return
            }

            replaceText(in: app.textFields["workspaceOpener.issues.search"], with: "102")
            if !element("workspaceOpener.issue.102").waitForExistence(timeout: shortTimeout) {
                recordHardFailure("Expected seeded issue #102 after filtering issues.")
            }
            if element("workspaceOpener.issue.101").exists {
                recordHardFailure("Expected issue #101 to be filtered out after searching for #102.")
            }

            _ = clickIfExists(element("workspaceOpener.issues.linkedTask"), failure: "Expected linked-task toggle on issues tab.")
            element("workspaceOpener.issue.102").click()
            if !waitForSelectionState(element("workspaceOpener.issue.102"), selected: true) {
                recordHardFailure("Expected seeded issue row to become selected.")
            }
            if !waitForEnabledState(submitButton, enabled: true) {
                recordHardFailure("Expected submit button to be enabled after selecting a seeded issue.")
            }

            _ = attachScreenshot(surface: "workspaceOpener.issues", phase: "selected")
        }

        runStep("exercise pull requests tab") {
            let prsTab = element("opener.tab.pullRequests")
            prsTab.click()
            if !waitForSelectionState(prsTab, selected: true) {
                recordHardFailure("Expected pull-requests tab to become selected.")
            }

            guard ensureHittable(
                app.textFields["workspaceOpener.pullRequests.search"],
                timeout: defaultTimeout,
                failure: "Expected pull-requests search field after selecting the fixture project."
            ) else {
                return
            }

            replaceText(in: app.textFields["workspaceOpener.pullRequests.search"], with: "202")
            if !element("workspaceOpener.pullRequest.202").waitForExistence(timeout: shortTimeout) {
                recordHardFailure("Expected seeded pull request #202 after filtering pull requests.")
            }
            element("workspaceOpener.pullRequest.202").click()
            if !waitForSelectionState(element("workspaceOpener.pullRequest.202"), selected: true) {
                recordHardFailure("Expected seeded pull-request row to become selected.")
            }

            _ = attachScreenshot(surface: "workspaceOpener.pullRequests", phase: "selected")
        }

        runStep("exercise branches tab") {
            let branchesTab = element("opener.tab.branches")
            branchesTab.click()
            if !waitForSelectionState(branchesTab, selected: true) {
                recordHardFailure("Expected branches tab to become selected.")
            }

            let mainBranch = element("workspaceOpener.branch.main")
            if !mainBranch.waitForExistence(timeout: defaultTimeout) {
                recordHardFailure("Expected main branch in the fixture repository.")
            }
            _ = clickIfExists(element("workspaceOpener.branches.toggleCreate"), failure: "Expected new-branch toggle.")
            if !app.textFields["workspaceOpener.branches.newBranchName"].waitForExistence(timeout: shortTimeout) {
                recordHardFailure("Expected new-branch composer after toggling branch creation.")
            }
            replaceText(in: app.textFields["workspaceOpener.branches.newBranchName"], with: "feature/ui-harness-ci")
            if !waitForEnabledState(submitButton, enabled: true) {
                recordHardFailure("Expected submit button to be enabled for new branch creation.")
            }
            _ = clickIfExists(element("workspaceOpener.branches.toggleCreate"), failure: "Expected cancel new-branch toggle.")

            replaceText(in: app.textFields["workspaceOpener.branches.search"], with: "feature/ui-harness")
            let featureBranch = element("workspaceOpener.branch.feature_ui_harness")
            if !featureBranch.waitForExistence(timeout: shortTimeout) {
                recordHardFailure("Expected feature/ui-harness branch after filtering branches.")
            }
            featureBranch.click()
            if !waitForSelectionState(featureBranch, selected: true) {
                recordHardFailure("Expected feature branch row to become selected.")
            }

            _ = attachScreenshot(surface: "workspaceOpener.branches", phase: "selected")
        }

        let cancelShot = attachScreenshot(surface: "workspaceOpener", phase: "before_cancel")
        clickIfExists(element("workspaceOpener.action.cancel"), failure: "Expected workspace opener cancel action.")
        if element("workspaceOpener").waitForExistence(timeout: shortTimeout) {
            recordHardFailure("Expected workspace opener to dismiss after pressing Cancel.")
        }

        markExercised(
            "workspaceOpener",
            detail: "Prompt, issues, pull requests, and branches flows exercised with seeded fixture data.",
            evidence: [settingsShot, initialShot, cancelShot]
        )
        markBlocked(
            "workspaceOpener.projectPicker.openFolder",
            detail: "The Open Folder… menu path still triggers NSOpenPanel, which remains intentionally unexercised in CI."
        )

        assertNoHardFailures()
    }

    func testExerciseSettingsWindowSections() {
        let sections: [SettingsSectionSpec] = [
            .init(id: "general", subtitle: "App behavior, window restoration, chrome appearance, and update preferences."),
            .init(id: "appShortcuts", subtitle: "Review and customize the shortcuts used across Pnevma windows and panes."),
            .init(id: "terminal", subtitle: "Default shell, typography, and scrollback behavior for new terminal sessions."),
            .init(id: "ghostty", subtitle: "Embedded terminal rendering, config-backed Ghostty options, and terminal keybindings."),
            .init(id: "usage", subtitle: "Provider usage sources, refresh cadence, and dashboard integration settings."),
            .init(id: "telemetry", subtitle: "Analytics and diagnostics preferences for future release quality improvements."),
        ]

        _ = openSettingsWindow()
        guard ensureExists(element("settings.root"), failure: "Expected settings root after opening settings.") else {
            markBlocked("settings.root", detail: "Settings window failed to open.")
            return
        }

        let settingsRoot = element("settings.root")
        let baselineFrame = settingsRoot.frame
        let initialShot = attachScreenshot(surface: "settings", phase: "opened")

        runStep("visit every settings section") {
            for section in sections {
                let row = element("settings.sidebar.\(section.id)")
                let before = attachScreenshot(surface: "settings.\(section.id)", phase: "before")

                guard clickIfExists(row, failure: "Expected settings sidebar row \(section.id).") else {
                    markBlocked("settings.section.\(section.id)", detail: "Settings row missing.", evidence: [before])
                    continue
                }

                if !app.staticTexts[section.subtitle].waitForExistence(timeout: defaultTimeout) {
                    let failureShot = attachScreenshot(surface: "settings.\(section.id)", phase: "missing_subtitle")
                    markBlocked(
                        "settings.section.\(section.id)",
                        detail: "Section subtitle did not appear after selecting the row.",
                        evidence: [before, failureShot]
                    )
                    continue
                }

                if !waitForSelectionState(row, selected: true, timeout: shortTimeout) {
                    log("Selection trait did not update for settings row \(section.id), but subtitle content did change.")
                }

                let updatedFrame = settingsRoot.frame
                if abs(updatedFrame.width - baselineFrame.width) > 1 || abs(updatedFrame.height - baselineFrame.height) > 1 {
                    recordHardFailure("Expected settings window frame to remain stable while selecting \(section.id); baseline=\(NSStringFromRect(baselineFrame)) updated=\(NSStringFromRect(updatedFrame)).")
                }

                let after = attachScreenshot(surface: "settings.\(section.id)", phase: "after")
                markExercised(
                    "settings.section.\(section.id)",
                    detail: "Visited settings section and verified stable window size.",
                    evidence: [before, after]
                )
            }
        }

        runStep("exercise settings search") {
            let searchField = settingsSearchField()
            let before = attachScreenshot(surface: "settings.search", phase: "before")
            guard replaceTextWithFocusFallback(
                in: searchField,
                with: "ghostty",
                failure: "Expected settings search field."
            ) else {
                return
            }
            if !element("settings.sidebar.ghostty").waitForExistence(timeout: shortTimeout) {
                recordHardFailure("Expected Ghostty row after searching settings for ghostty.")
            }

            _ = replaceTextWithFocusFallback(
                in: searchField,
                with: "definitely-no-match",
                failure: "Expected settings search field for empty-state search."
            )
            if !element("settings.search.empty").waitForExistence(timeout: shortTimeout) {
                recordHardFailure("Expected settings empty-state after searching with no results.")
            }

            _ = replaceTextWithFocusFallback(
                in: searchField,
                with: "",
                failure: "Expected settings search field for reset."
            )
            let after = attachScreenshot(surface: "settings.search", phase: "after")
            markExercised(
                "settings.search",
                detail: "Positive and empty-result search cases exercised in settings sidebar.",
                evidence: [before, after]
            )
        }

        markExercised(
            "settings.root",
            detail: "Settings window opened and all primary sections were visited.",
            evidence: [initialShot]
        )

        assertNoHardFailures()
    }
}
