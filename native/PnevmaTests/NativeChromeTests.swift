import XCTest
@testable import Pnevma

private actor TitlebarGitActionCommandBus: CommandCalling {
    enum Mode {
        case commitFailure(String)
        case pushFailure(String)
    }

    private let mode: Mode

    init(mode: Mode) {
        self.mode = mode
    }

    func call<T: Decodable & Sendable>(
        method: String,
        params: (any Encodable & Sendable)?
    ) async throws -> T {
        switch (mode, method) {
        case let (.commitFailure(message), "workspace.commit"):
            return try decode([
                "success": false,
                "commit_sha": NSNull(),
                "error_message": message,
            ])
        case let (.pushFailure(message), "workspace.push"):
            return try decode([
                "success": false,
                "error_message": message,
            ])
        default:
            throw NSError(domain: "TitlebarGitActionCommandBus", code: 1)
        }
    }

    private func decode<T: Decodable>(_ object: [String: Any]) throws -> T {
        let data = try JSONSerialization.data(withJSONObject: object)
        return try PnevmaJSON.decoder().decode(T.self, from: data)
    }
}

private final class ResolvedTitlebarGitActionCommandBus: CommandCalling, @unchecked Sendable {
    func call<T: Decodable & Sendable>(
        method: String,
        params: (any Encodable & Sendable)?
    ) async throws -> T {
        throw NSError(domain: "ResolvedTitlebarGitActionCommandBus", code: 1)
    }
}

@MainActor
private final class TitlebarGitActionWorkspaceManagerStub: TitlebarGitActionWorkspaceManaging {
    private let readinessResult: Result<(workspace: Workspace, runtime: WorkspaceRuntime?), Error>

    let activeWorkspaceID: UUID?
    private(set) var requestedWorkspaceID: UUID?
    private(set) var requestedTimeoutNanoseconds: UInt64?

    init(
        activeWorkspaceID: UUID?,
        readinessResult: Result<(workspace: Workspace, runtime: WorkspaceRuntime?), Error>
    ) {
        self.activeWorkspaceID = activeWorkspaceID
        self.readinessResult = readinessResult
    }

    func ensureWorkspaceReady(
        _ workspaceID: UUID,
        timeoutNanoseconds: UInt64
    ) async throws -> (workspace: Workspace, runtime: WorkspaceRuntime?) {
        requestedWorkspaceID = workspaceID
        requestedTimeoutNanoseconds = timeoutNanoseconds
        return try readinessResult.get()
    }
}

@MainActor
final class NativeChromeTests: XCTestCase {
    func testPanePresentationRoleMapsPrimaryPaneFamilies() {
        XCTAssertEqual(PanePresentationRole(paneType: "terminal"), .document)
        XCTAssertEqual(PanePresentationRole(paneType: "file_browser"), .document)
        XCTAssertEqual(PanePresentationRole(paneType: "secrets"), .manager)
        XCTAssertEqual(PanePresentationRole(paneType: "analytics"), .monitor)
        XCTAssertEqual(PanePresentationRole(paneType: "review"), .inspectorDriven)
        XCTAssertEqual(PanePresentationRole(paneType: "replay"), .utility)
    }

    func testChromeSurfaceStyleResolvedColorUsesBaseWhenNoTintProvided() {
        XCTAssertEqual(
            ChromeSurfaceStyle.window.resolvedColor(),
            ChromeSurfaceStyle.window.baseColor
        )
        XCTAssertEqual(
            ChromeSurfaceStyle.toolbar.resolvedColor(),
            ChromeSurfaceStyle.toolbar.baseColor
        )
    }

    func testTitlebarStatusLayoutStateHidesOptionalItemsAsWidthShrinks() {
        XCTAssertEqual(
            TitlebarStatusLayoutState.resolved(for: 420, hasPullRequest: true),
            TitlebarStatusLayoutState(showsPullRequest: true, showsAgents: true)
        )
        XCTAssertEqual(
            TitlebarStatusLayoutState.resolved(for: 320, hasPullRequest: true),
            TitlebarStatusLayoutState(showsPullRequest: false, showsAgents: true)
        )
        XCTAssertEqual(
            TitlebarStatusLayoutState.resolved(for: 240, hasPullRequest: true),
            TitlebarStatusLayoutState(showsPullRequest: false, showsAgents: false)
        )
    }

    func testOpenInMenuKnownEditorsIncludesGhostty() {
        XCTAssertTrue(
            OpenInMenuController.knownEditors.contains {
                $0.name == "Ghostty" && $0.bundleID == "com.mitchellh.ghostty"
            }
        )
    }

    func testOpenInMenuPrioritizesLastUsedEditor() {
        let editors = [
            OpenInMenuController.EditorInfo(name: "Finder", bundleID: "com.apple.finder", fallbackIcon: "folder"),
            OpenInMenuController.EditorInfo(name: "Terminal", bundleID: "com.apple.Terminal", fallbackIcon: "terminal"),
            OpenInMenuController.EditorInfo(name: "Ghostty", bundleID: "com.mitchellh.ghostty", fallbackIcon: "terminal.fill"),
        ]

        let prioritized = OpenInMenuController.prioritizedEditors(
            editors,
            lastUsedBundleID: "com.mitchellh.ghostty"
        )

        XCTAssertEqual(prioritized.map(\.bundleID), [
            "com.mitchellh.ghostty",
            "com.apple.finder",
            "com.apple.Terminal",
        ])
    }

    func testTitlebarStatusSessionsPopoverAnchorSitsBelowChrome() {
        let statusView = TitlebarStatusView(frame: NSRect(x: 0, y: 0, width: 320, height: DesignTokens.Layout.titlebarGroupHeight))
        statusView.layoutSubtreeIfNeeded()

        let anchorRect = statusView.sessionsPopoverAnchorRect

        XCTAssertGreaterThan(anchorRect.width, 0)
        XCTAssertEqual(anchorRect.maxY, 0, accuracy: 0.5)
        XCTAssertLessThan(anchorRect.minY, 0)
    }

    func testTitlebarStatusBranchPopoverAnchorSitsBelowChrome() {
        let statusView = TitlebarStatusView(frame: NSRect(x: 0, y: 0, width: 320, height: DesignTokens.Layout.titlebarGroupHeight))
        statusView.layoutSubtreeIfNeeded()

        let anchorRect = statusView.branchPopoverAnchorRect

        XCTAssertGreaterThan(anchorRect.width, 0)
        XCTAssertEqual(anchorRect.maxY, 0, accuracy: 0.5)
        XCTAssertLessThan(anchorRect.minY, 0)
    }

    func testCapsuleButtonToolbarAttachmentAnchorSitsBelowChrome() {
        let button = CapsuleButton(icon: "point.3.connected.trianglepath.dotted", label: "Commit")
        button.frame = NSRect(origin: .zero, size: button.intrinsicContentSize)
        button.layoutSubtreeIfNeeded()

        let anchorRect = button.toolbarAttachmentAnchorRect(
            widthRatio: 0.52,
            minWidth: 38,
            maxWidth: 62
        )

        XCTAssertGreaterThan(anchorRect.width, 0)
        XCTAssertEqual(anchorRect.maxY, 0, accuracy: 0.5)
        XCTAssertLessThan(anchorRect.minY, 0)
    }

    func testCapsuleButtonUsesTrailingSegmentForSplitMenu() {
        let button = CapsuleButton(icon: "point.3.connected.trianglepath.dotted", label: "Commit")
        button.showsDropdownIndicator = true
        button.onMenuRequested = { _ in }
        button.frame = NSRect(origin: .zero, size: button.intrinsicContentSize)
        button.layoutSubtreeIfNeeded()

        XCTAssertEqual(
            button.interactionSegment(at: NSPoint(x: button.bounds.maxX - 6, y: button.bounds.midY)),
            .menu
        )
        XCTAssertEqual(
            button.interactionSegment(at: NSPoint(x: 8, y: button.bounds.midY)),
            .primary
        )
    }

    func testResolveTitlebarGitActionCommandBusUsesReadyWorkspaceRuntimeBus() async throws {
        let bus = ResolvedTitlebarGitActionCommandBus()
        let workspace = Workspace(name: "Repo", projectPath: "/tmp/repo")
        let runtime = WorkspaceRuntime(workspaceID: workspace.id, commandBus: bus)
        let manager = TitlebarGitActionWorkspaceManagerStub(
            activeWorkspaceID: workspace.id,
            readinessResult: .success((workspace: workspace, runtime: runtime))
        )

        let resolved = try await resolveTitlebarGitActionCommandBus(
            workspaceManager: manager,
            timeoutNanoseconds: 123
        )

        XCTAssertTrue((resolved as AnyObject) === (bus as AnyObject))
        XCTAssertEqual(manager.requestedWorkspaceID, workspace.id)
        XCTAssertEqual(manager.requestedTimeoutNanoseconds, 123)
    }

    func testResolveTitlebarGitActionCommandBusRejectsMissingWorkspace() async {
        let manager = TitlebarGitActionWorkspaceManagerStub(
            activeWorkspaceID: nil,
            readinessResult: .failure(WorkspaceActionError.workspaceUnavailable)
        )

        do {
            _ = try await resolveTitlebarGitActionCommandBus(workspaceManager: manager)
            XCTFail("Expected missing workspace to throw")
        } catch let error as WorkspaceActionError {
            guard case .workspaceUnavailable = error else {
                return XCTFail("Unexpected workspace action error: \(error)")
            }
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testResolveTitlebarGitActionCommandBusRejectsRuntimeWithoutProjectBus() async {
        let workspace = Workspace(name: "Terminal")
        let manager = TitlebarGitActionWorkspaceManagerStub(
            activeWorkspaceID: workspace.id,
            readinessResult: .success((workspace: workspace, runtime: nil))
        )

        do {
            _ = try await resolveTitlebarGitActionCommandBus(workspaceManager: manager)
            XCTFail("Expected missing runtime to throw")
        } catch let error as WorkspaceActionError {
            guard case .runtimeNotReady = error else {
                return XCTFail("Unexpected workspace action error: \(error)")
            }
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testResolveTitlebarStatusControlAvailabilityAllowsSessionsWithoutProjectRuntime() {
        XCTAssertEqual(
            resolveTitlebarStatusControlAvailability(hasProject: false, hasSessionStore: true),
            TitlebarStatusControlAvailability(branchEnabled: false, sessionsEnabled: true)
        )
    }

    func testResolveTitlebarStatusControlAvailabilityAllowsBranchWhenProjectExists() {
        XCTAssertEqual(
            resolveTitlebarStatusControlAvailability(hasProject: true, hasSessionStore: false),
            TitlebarStatusControlAvailability(branchEnabled: true, sessionsEnabled: false)
        )
    }

    func testHandleTitlebarCommitShowsBackendFailureToast() async {
        let appDelegate = AppDelegate()
        let bus = TitlebarGitActionCommandBus(mode: .commitFailure("nothing to commit"))
        defer { ToastManager.shared.dismiss() }

        await appDelegate.handleTitlebarCommit(message: "No changes", using: bus)

        XCTAssertEqual(ToastManager.shared.currentToast?.style, .error)
        XCTAssertEqual(ToastManager.shared.currentToast?.text, "nothing to commit")
    }

    func testHandleTitlebarPushShowsBackendFailureToast() async {
        let appDelegate = AppDelegate()
        let bus = TitlebarGitActionCommandBus(mode: .pushFailure("No configured push destination."))
        defer { ToastManager.shared.dismiss() }

        await appDelegate.handleTitlebarPush(using: bus)

        XCTAssertEqual(ToastManager.shared.currentToast?.style, .error)
        XCTAssertEqual(
            ToastManager.shared.currentToast?.text,
            "No configured push destination."
        )
    }
}
