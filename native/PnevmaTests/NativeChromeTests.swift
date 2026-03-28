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

private struct TitlebarGitHubTestError: LocalizedError {
    let message: String

    var errorDescription: String? { message }
}

private struct GitHubAuthBridgePayloadFixture: Encodable {
    let snapshot: GitHubAuthSnapshot
}

private actor TitlebarGitHubCommandBusStub: CommandCalling {
    struct Invocation: Equatable {
        let method: String
        let login: String?
    }

    enum Response {
        case snapshot(GitHubAuthSnapshot)
        case failure(String)
    }

    private let statusResponse: Response
    private let refreshResponse: Response
    private let switchResponses: [String: Response]
    private let addAccountResponse: Response
    private var invocations: [Invocation] = []

    init(
        statusResponse: Response,
        refreshResponse: Response? = nil,
        switchResponses: [String: Response] = [:],
        addAccountResponse: Response? = nil
    ) {
        self.statusResponse = statusResponse
        self.refreshResponse = refreshResponse ?? statusResponse
        self.switchResponses = switchResponses
        self.addAccountResponse = addAccountResponse ?? statusResponse
    }

    func call<T: Decodable & Sendable>(
        method: String,
        params: (any Encodable & Sendable)?
    ) async throws -> T {
        let login = (params as? GitHubAuthSwitchRequest)?.login
        invocations.append(Invocation(method: method, login: login))

        let response: Response
        switch method {
        case "github.auth.status":
            response = statusResponse
        case "github.auth.refresh":
            response = refreshResponse
        case "github.auth.switch":
            guard let login, let matched = switchResponses[login] else {
                throw TitlebarGitHubTestError(message: "No switch response for \(login ?? "<nil>")")
            }
            response = matched
        case "github.auth.add_account":
            response = addAccountResponse
        default:
            throw TitlebarGitHubTestError(message: "Unexpected method \(method)")
        }

        switch response {
        case let .snapshot(snapshot):
            return try decode(snapshot)
        case let .failure(message):
            throw TitlebarGitHubTestError(message: message)
        }
    }

    func recordedInvocations() -> [Invocation] {
        invocations
    }

    private func decode<T: Decodable & Sendable>(_ snapshot: GitHubAuthSnapshot) throws -> T {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(snapshot)
        return try PnevmaJSON.decoder().decode(T.self, from: data)
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
final class TitlebarStatusButtonTests: XCTestCase {
    override func setUp() {
        super.setUp()
        MainActor.assumeIsolated { _ = NSApplication.shared }
    }

    private func makeTitlebarStatusView(width: CGFloat = 320) -> TitlebarStatusView {
        let view = TitlebarStatusView(
            frame: NSRect(x: 0, y: 0, width: width, height: DesignTokens.Layout.titlebarGroupHeight)
        )
        view.updateBranch("main")
        view.updateSessions(1)
        return view
    }

    private func makeWindow(with contentView: NSView) -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 500, height: 100),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.contentView = contentView
        window.makeKeyAndOrderFront(nil)
        return window
    }

    // MARK: - TitlebarStatusButton intrinsics

    func testTitlebarStatusButtonMouseDownCanMoveWindowReturnsFalse() {
        let button = TitlebarStatusButton(frame: NSRect(x: 0, y: 0, width: 80, height: 24))
        button.bezelStyle = .inline
        button.isBordered = false
        XCTAssertFalse(button.mouseDownCanMoveWindow)
    }

    func testTitlebarStatusButtonAcceptsFirstMouse() {
        let button = TitlebarStatusButton(frame: NSRect(x: 0, y: 0, width: 80, height: 24))
        XCTAssertTrue(button.acceptsFirstMouse(for: nil))
    }

    // TitlebarStatusButton is display-only; mouse events are handled
    // by TitlebarStatusView.mouseDown — no button-level mouseDown tests needed.

    // MARK: - Hit testing: branchButton reachable

    func testHitTestReturnsSelfForPointsInsideBounds() {
        // TitlebarStatusView claims all hits so NSThemeFrame sees
        // mouseDownCanMoveWindow=false and forwards the event.
        let statusView = makeTitlebarStatusView()
        let window = makeWindow(with: statusView)
        _ = window
        statusView.layoutSubtreeIfNeeded()

        let center = NSPoint(x: statusView.bounds.midX, y: statusView.bounds.midY)
        let hitView = statusView.hitTest(center)
        XCTAssertTrue(hitView === statusView, "hitTest should return self, not a child view")
    }

    func testHitTestReturnsNilForPointsOutsideBounds() {
        let statusView = makeTitlebarStatusView()
        let window = makeWindow(with: statusView)
        _ = window
        statusView.layoutSubtreeIfNeeded()

        let outside = NSPoint(x: -10, y: statusView.bounds.midY)
        XCTAssertNil(statusView.hitTest(outside))
    }

    // MARK: - Full click → callback chain

    func testBranchButtonClickFiresCallback() {
        let statusView = makeTitlebarStatusView()
        let window = makeWindow(with: statusView)
        statusView.layoutSubtreeIfNeeded()

        var callbackFired = false
        statusView.onBranchClicked = { callbackFired = true }

        // Hit test to find the branch button
        let branchPoint = NSPoint(x: 40, y: statusView.bounds.midY)
        guard let hitView = statusView.hitTest(branchPoint) else {
            XCTFail("No view found at branch point")
            return
        }

        let windowPoint = statusView.convert(branchPoint, to: nil)
        let event = NSEvent.mouseEvent(
            with: .leftMouseDown,
            location: windowPoint,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: window.windowNumber,
            context: nil,
            eventNumber: 0,
            clickCount: 1,
            pressure: 1
        )!
        hitView.mouseDown(with: event)

        XCTAssertTrue(callbackFired, "Branch button click should fire onBranchClicked callback")
    }

    func testSessionsButtonClickFiresCallback() {
        let statusView = makeTitlebarStatusView()
        let window = makeWindow(with: statusView)
        statusView.layoutSubtreeIfNeeded()

        var callbackFired = false
        statusView.onSessionsClicked = { callbackFired = true }

        let sessionsBtn = statusView.sessionsButton
        let sessionsPoint = sessionsBtn.superview!.convert(
            NSPoint(x: sessionsBtn.frame.midX, y: sessionsBtn.frame.midY),
            to: statusView
        )
        guard let hitView = statusView.hitTest(sessionsPoint) else {
            XCTFail("No view found at sessions button center")
            return
        }

        let windowPoint = statusView.convert(sessionsPoint, to: nil)
        let event = NSEvent.mouseEvent(
            with: .leftMouseDown,
            location: windowPoint,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: window.windowNumber,
            context: nil,
            eventNumber: 0,
            clickCount: 1,
            pressure: 1
        )!
        hitView.mouseDown(with: event)

        XCTAssertTrue(callbackFired, "Sessions button click should fire onSessionsClicked callback")
    }

    func testGitHubButtonClickFiresCallback() {
        let statusView = makeTitlebarStatusView()
        let window = makeWindow(with: statusView)
        statusView.updateGitHub("octocat")
        statusView.layoutSubtreeIfNeeded()

        var callbackFired = false
        statusView.onGitHubClicked = { callbackFired = true }

        let gitHubRect = statusView.gitHubButtonRect
        let gitHubPoint = NSPoint(x: gitHubRect.midX, y: gitHubRect.midY)
        guard let hitView = statusView.hitTest(gitHubPoint) else {
            XCTFail("No view found at GitHub button center")
            return
        }

        let windowPoint = statusView.convert(gitHubPoint, to: nil)
        let event = NSEvent.mouseEvent(
            with: .leftMouseDown,
            location: windowPoint,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: window.windowNumber,
            context: nil,
            eventNumber: 0,
            clickCount: 1,
            pressure: 1
        )!
        hitView.mouseDown(with: event)

        XCTAssertTrue(callbackFired, "GitHub button click should fire onGitHubClicked callback")
    }

    // MARK: - Button target/action integrity

    func testCallbacksAreWireable() {
        let statusView = makeTitlebarStatusView()
        XCTAssertNil(statusView.onBranchClicked)
        XCTAssertNil(statusView.onSessionsClicked)

        var branchFired = false
        var sessionsFired = false
        statusView.onBranchClicked = { branchFired = true }
        statusView.onSessionsClicked = { sessionsFired = true }

        statusView.onBranchClicked?()
        statusView.onSessionsClicked?()
        XCTAssertTrue(branchFired)
        XCTAssertTrue(sessionsFired)
    }

    func testSessionsButtonHasNonZeroFrame() {
        let statusView = makeTitlebarStatusView()
        let window = makeWindow(with: statusView)
        _ = window
        statusView.layoutSubtreeIfNeeded()

        let sessionsBtn = statusView.sessionsButton
        XCTAssertGreaterThan(sessionsBtn.frame.width, 0)
        XCTAssertGreaterThan(sessionsBtn.frame.height, 0)
    }

    func testUpdateGitHubReflectsActiveAndAuthenticatingStates() {
        let statusView = makeTitlebarStatusView()

        statusView.updateGitHub("octocat")
        XCTAssertEqual(statusView.gitHubTitle, "@octocat")

        statusView.updateGitHub(nil, isAuthenticating: true)
        XCTAssertEqual(statusView.gitHubTitle, "Signing in…")

        statusView.updateGitHub(nil)
        XCTAssertEqual(statusView.gitHubTitle, "GitHub")
    }

    func testNarrowWidthKeepsGitHubVisibleWhileOptionalItemsCollapse() {
        let statusView = makeTitlebarStatusView(width: 240)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 240, height: 100),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.contentView = statusView
        window.makeKeyAndOrderFront(nil)
        _ = window

        statusView.updateAgents(3)
        statusView.updatePR(number: 42, url: "https://example.com/pr/42")
        statusView.updateGitHub("octocat")
        statusView.layoutSubtreeIfNeeded()

        XCTAssertFalse(statusView.showsAgents)
        XCTAssertFalse(statusView.showsPullRequest)
        XCTAssertGreaterThan(statusView.branchButtonRect.width, 0)
        XCTAssertGreaterThan(statusView.sessionsButtonRect.width, 0)
        XCTAssertGreaterThan(statusView.gitHubButtonRect.width, 0)
        XCTAssertLessThan(statusView.branchButtonRect.minX, statusView.sessionsButtonRect.minX)
        XCTAssertLessThan(statusView.sessionsButtonRect.minX, statusView.gitHubButtonRect.minX)
    }

    // MARK: - Hit test in fullSizeContentView window (mimics real app)

    func testButtonsClickableInFullSizeContentViewWindow() {
        let statusView = makeTitlebarStatusView()
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 500, height: 100),
            styleMask: [.titled, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.titlebarAppearsTransparent = true
        window.contentView = statusView
        window.makeKeyAndOrderFront(nil)
        statusView.layoutSubtreeIfNeeded()

        var branchFired = false
        var sessionsFired = false
        statusView.onBranchClicked = { branchFired = true }
        statusView.onSessionsClicked = { sessionsFired = true }

        // Branch click — use center of branch button region
        let branchPoint = NSPoint(x: 40, y: statusView.bounds.midY)
        if let hitView = statusView.hitTest(branchPoint) {
            let windowPoint = statusView.convert(branchPoint, to: nil)
            let event = NSEvent.mouseEvent(
                with: .leftMouseDown,
                location: windowPoint,
                modifierFlags: [],
                timestamp: 0,
                windowNumber: window.windowNumber,
                context: nil,
                eventNumber: 0,
                clickCount: 1,
                pressure: 1
            )!
            hitView.mouseDown(with: event)
        }
        XCTAssertTrue(branchFired, "Branch button should fire in fullSizeContentView window")

        // Sessions click — use actual button center
        let sessionsBtn = statusView.sessionsButton
        let sessionsPoint = sessionsBtn.superview!.convert(
            NSPoint(x: sessionsBtn.frame.midX, y: sessionsBtn.frame.midY),
            to: statusView
        )
        if let hitView = statusView.hitTest(sessionsPoint) {
            let windowPoint = statusView.convert(sessionsPoint, to: nil)
            let event = NSEvent.mouseEvent(
                with: .leftMouseDown,
                location: windowPoint,
                modifierFlags: [],
                timestamp: 0,
                windowNumber: window.windowNumber,
                context: nil,
                eventNumber: 0,
                clickCount: 1,
                pressure: 1
            )!
            hitView.mouseDown(with: event)
        }
        XCTAssertTrue(sessionsFired, "Sessions button should fire in fullSizeContentView window")
    }

    // MARK: - Real app layout: TitlebarStatusView inside MainWindowContentView in titlebar area

    func testButtonsFireViaSendEventInRealAppLayout() {
        // Mimic the real app: fullSizeContentView + transparent titlebar,
        // TitlebarStatusView is a subview of a container (not the contentView itself),
        // positioned in the titlebar area.
        let window = NSWindow(
            contentRect: NSRect(x: 200, y: 200, width: 800, height: 400),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.titlebarAppearsTransparent = true
        window.title = ""
        window.titleVisibility = .hidden

        let windowContent = NSView(frame: NSRect(x: 0, y: 0, width: 800, height: 400))
        windowContent.autoresizingMask = [.width, .height]
        window.contentView = windowContent

        let statusView = makeTitlebarStatusView(width: 250)
        statusView.translatesAutoresizingMaskIntoConstraints = false
        windowContent.addSubview(statusView)

        // Position in titlebar area (centered horizontally, at the top)
        NSLayoutConstraint.activate([
            statusView.centerXAnchor.constraint(equalTo: windowContent.centerXAnchor),
            statusView.centerYAnchor.constraint(equalTo: windowContent.safeAreaLayoutGuide.topAnchor, constant: -14),
        ])

        window.makeKeyAndOrderFront(nil)
        windowContent.layoutSubtreeIfNeeded()

        var branchFired = false
        var sessionsFired = false
        statusView.onBranchClicked = { branchFired = true }
        statusView.onSessionsClicked = { sessionsFired = true }

        // -- Test branch button via window.sendEvent --
        let branchPoint = NSPoint(x: 40, y: statusView.bounds.midY)
        let branchWindowPoint = statusView.convert(branchPoint, to: nil)
        if let downEvent = NSEvent.mouseEvent(
            with: .leftMouseDown,
            location: branchWindowPoint,
            modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber,
            context: nil,
            eventNumber: 0,
            clickCount: 1,
            pressure: 1
        ) {
            window.sendEvent(downEvent)
        }
        XCTAssertTrue(branchFired, "Branch button must fire via window.sendEvent in real app layout")

        // -- Test sessions button via window.sendEvent --
        let sessionsBtn = statusView.sessionsButton
        let sessionsLocalPoint = sessionsBtn.superview!.convert(
            NSPoint(x: sessionsBtn.frame.midX, y: sessionsBtn.frame.midY),
            to: statusView
        )
        let sessionsWindowPoint = statusView.convert(sessionsLocalPoint, to: nil)
        if let downEvent = NSEvent.mouseEvent(
            with: .leftMouseDown,
            location: sessionsWindowPoint,
            modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber,
            context: nil,
            eventNumber: 0,
            clickCount: 1,
            pressure: 1
        ) {
            window.sendEvent(downEvent)
        }
        XCTAssertTrue(sessionsFired, "Sessions button must fire via window.sendEvent in real app layout")

        window.orderOut(nil)
    }
}

@MainActor
final class TitlebarGitHubControllerTests: XCTestCase {
    override func setUp() {
        super.setUp()
        MainActor.assumeIsolated { _ = NSApplication.shared }
    }

    private func makeTitlebarStatusView(width: CGFloat = 320) -> TitlebarStatusView {
        let view = TitlebarStatusView(
            frame: NSRect(x: 0, y: 0, width: width, height: DesignTokens.Layout.titlebarGroupHeight)
        )
        view.updateBranch("main")
        view.updateSessions(1)
        view.layoutSubtreeIfNeeded()
        return view
    }

    private func makeSnapshot(
        cliAvailable: Bool = true,
        activeLogin: String? = "octocat",
        accounts: [GitHubAuthAccount]? = nil,
        authJob: GitHubAuthJob? = nil
    ) -> GitHubAuthSnapshot {
        let resolvedAccounts = accounts ?? activeLogin.map {
            [GitHubAuthAccount(
                login: $0,
                active: true,
                state: "success",
                tokenSource: "keyring",
                gitProtocol: "https",
                scopes: ["repo"]
            )]
        } ?? []

        return GitHubAuthSnapshot(
            host: "github.com",
            cliAvailable: cliAvailable,
            activeLogin: activeLogin,
            accounts: resolvedAccounts,
            gitHelper: GitHubGitHelperStatus(
                state: "ready",
                message: "GitHub CLI manages HTTPS auth.",
                detail: nil
            ),
            authJob: authJob,
            error: nil,
            lastRefreshedAt: Date(timeIntervalSince1970: 1_710_000_000)
        )
    }

    private func makeBridgePayloadJSON(snapshot: GitHubAuthSnapshot) throws -> String {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(GitHubAuthBridgePayloadFixture(snapshot: snapshot))
        guard let json = String(data: data, encoding: .utf8) else {
            throw TitlebarGitHubTestError(message: "Failed to encode bridge payload")
        }
        return json
    }

    func testGitHubAccountPickerPrimaryActionUsesInstallWhenCLIMissing() {
        XCTAssertNil(GitHubAccountPickerPrimaryAction.resolve(snapshot: nil))
        let snapshot = makeSnapshot(cliAvailable: false, activeLogin: nil, accounts: [])
        XCTAssertEqual(
            GitHubAccountPickerPrimaryAction.resolve(snapshot: snapshot),
            .installCLI
        )
        XCTAssertEqual(
            GitHubAccountPickerPrimaryAction.resolve(snapshot: makeSnapshot()),
            .addAccount
        )
    }

    func testRefreshUpdatesTitlebarFromStatusSnapshot() async {
        let statusView = makeTitlebarStatusView()
        let snapshot = makeSnapshot(activeLogin: "alice")
        let bus = TitlebarGitHubCommandBusStub(statusResponse: .snapshot(snapshot))
        let controller = TitlebarGitHubController(commandBusProvider: { bus })
        controller.attachTitlebarStatusView(statusView)

        await controller.refresh()

        XCTAssertEqual(controller.snapshot, snapshot)
        XCTAssertEqual(statusView.gitHubTitle, "@alice")
    }

    func testRefreshWithoutCommandBusDisablesGitHubControl() async {
        let statusView = makeTitlebarStatusView()
        let controller = TitlebarGitHubController(commandBusProvider: { nil })
        controller.attachTitlebarStatusView(statusView)
        statusView.updateGitHubEnabled(true)

        await controller.refresh()

        XCTAssertFalse(statusView.isGitHubEnabled)
        XCTAssertEqual(statusView.gitHubTitle, "GitHub")
    }

    func testRefreshFailureClearsStaleSnapshot() async {
        let statusView = makeTitlebarStatusView()
        let bus = TitlebarGitHubCommandBusStub(
            statusResponse: .snapshot(makeSnapshot(activeLogin: "alice")),
            refreshResponse: .failure("status refresh failed")
        )
        let controller = TitlebarGitHubController(commandBusProvider: { bus })
        controller.attachTitlebarStatusView(statusView)

        await controller.refresh()
        XCTAssertEqual(controller.snapshot?.activeLogin, "alice")
        XCTAssertEqual(statusView.gitHubTitle, "@alice")

        await controller.refresh(force: true)

        XCTAssertNil(controller.snapshot)
        XCTAssertEqual(statusView.gitHubTitle, "GitHub")
    }

    func testSwitchAccountUpdatesTitlebarAndShowsSuccessToast() async {
        let statusView = makeTitlebarStatusView()
        let initialSnapshot = makeSnapshot(activeLogin: "alice")
        let switchedSnapshot = makeSnapshot(
            activeLogin: "bob",
            accounts: [
                GitHubAuthAccount(
                    login: "alice",
                    active: false,
                    state: "success",
                    tokenSource: "keyring",
                    gitProtocol: "https",
                    scopes: ["repo"]
                ),
                GitHubAuthAccount(
                    login: "bob",
                    active: true,
                    state: "success",
                    tokenSource: "keyring",
                    gitProtocol: "https",
                    scopes: ["repo"]
                ),
            ]
        )
        let bus = TitlebarGitHubCommandBusStub(
            statusResponse: .snapshot(initialSnapshot),
            switchResponses: ["bob": .snapshot(switchedSnapshot)]
        )
        var toasts: [(text: String, style: ToastMessage.ToastStyle)] = []
        let controller = TitlebarGitHubController(
            commandBusProvider: { bus },
            showToast: { text, _, style in
                toasts.append((text: text, style: style))
            }
        )
        controller.attachTitlebarStatusView(statusView)
        await controller.refresh()

        await controller.switchAccount(login: "bob")

        let invocations = await bus.recordedInvocations()
        XCTAssertEqual(statusView.gitHubTitle, "@bob")
        XCTAssertEqual(controller.snapshot?.activeLogin, "bob")
        XCTAssertEqual(toasts.last?.text, "Using GitHub account @bob")
        XCTAssertEqual(toasts.last?.style, .success)
        XCTAssertEqual(
            invocations,
            [
                .init(method: "github.auth.status", login: nil),
                .init(method: "github.auth.switch", login: "bob"),
            ]
        )
    }

    func testSwitchAccountFailurePreservesExistingLabelAndShowsErrorToast() async {
        let statusView = makeTitlebarStatusView()
        let initialSnapshot = makeSnapshot(activeLogin: "alice")
        let bus = TitlebarGitHubCommandBusStub(
            statusResponse: .snapshot(initialSnapshot),
            switchResponses: ["bob": .failure("Unable to switch accounts")]
        )
        var toasts: [(text: String, style: ToastMessage.ToastStyle)] = []
        let controller = TitlebarGitHubController(
            commandBusProvider: { bus },
            showToast: { text, _, style in
                toasts.append((text: text, style: style))
            }
        )
        controller.attachTitlebarStatusView(statusView)
        await controller.refresh()

        await controller.switchAccount(login: "bob")

        XCTAssertEqual(statusView.gitHubTitle, "@alice")
        XCTAssertEqual(controller.snapshot?.activeLogin, "alice")
        XCTAssertEqual(toasts.last?.text, "Unable to switch accounts")
        XCTAssertEqual(toasts.last?.style, .error)
    }

    func testAddAccountShowsRunningStateAndInfoToast() async {
        let statusView = makeTitlebarStatusView()
        let authJob = GitHubAuthJob(
            state: "running",
            message: "Finish sign-in in your browser.",
            startedAt: Date(timeIntervalSince1970: 1_710_000_123),
            finishedAt: nil
        )
        let runningSnapshot = makeSnapshot(
            activeLogin: nil,
            accounts: [],
            authJob: authJob
        )
        let bus = TitlebarGitHubCommandBusStub(
            statusResponse: .snapshot(makeSnapshot(activeLogin: nil, accounts: [])),
            addAccountResponse: .snapshot(runningSnapshot)
        )
        var toasts: [(text: String, style: ToastMessage.ToastStyle)] = []
        let controller = TitlebarGitHubController(
            commandBusProvider: { bus },
            showToast: { text, _, style in
                toasts.append((text: text, style: style))
            }
        )
        controller.attachTitlebarStatusView(statusView)

        await controller.addAccount()

        XCTAssertEqual(controller.snapshot?.authJob?.state, "running")
        XCTAssertEqual(statusView.gitHubTitle, "Signing in…")
        XCTAssertEqual(toasts.last?.text, "Continue GitHub sign-in in your browser")
        XCTAssertEqual(toasts.last?.style, .info)
    }

    func testHandleBridgePayloadUpdatesTitlebarAfterBrowserSignIn() async throws {
        let statusView = makeTitlebarStatusView()
        let runningSnapshot = makeSnapshot(
            activeLogin: nil,
            accounts: [],
            authJob: GitHubAuthJob(
                state: "running",
                message: "Finish sign-in in your browser.",
                startedAt: Date(timeIntervalSince1970: 1_710_000_123),
                finishedAt: nil
            )
        )
        let controller = TitlebarGitHubController(commandBusProvider: { nil })
        controller.attachTitlebarStatusView(statusView)
        controller.clear()
        let runningPayload = try makeBridgePayloadJSON(snapshot: runningSnapshot)

        await controller.handleBridgePayload(runningPayload)
        XCTAssertEqual(statusView.gitHubTitle, "Signing in…")

        let completedSnapshot = makeSnapshot(activeLogin: "carol")
        let completedPayload = try makeBridgePayloadJSON(snapshot: completedSnapshot)
        await controller.handleBridgePayload(completedPayload)

        XCTAssertEqual(statusView.gitHubTitle, "@carol")
        XCTAssertEqual(controller.snapshot?.activeLogin, "carol")
    }

    func testInstallGitHubCLIUsesOfficialURL() {
        var openedURLs: [URL] = []
        let controller = TitlebarGitHubController(
            commandBusProvider: { nil },
            openURL: { url in
                openedURLs.append(url)
            }
        )

        controller.installCLI()

        XCTAssertEqual(openedURLs, [URL(string: "https://cli.github.com/")!])
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
            TitlebarStatusLayoutState.resolved(for: 460, hasPullRequest: true),
            TitlebarStatusLayoutState(showsPullRequest: true, showsAgents: true)
        )
        XCTAssertEqual(
            TitlebarStatusLayoutState.resolved(for: 360, hasPullRequest: true),
            TitlebarStatusLayoutState(showsPullRequest: false, showsAgents: true)
        )
        XCTAssertEqual(
            TitlebarStatusLayoutState.resolved(for: 260, hasPullRequest: true),
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
            resolveTitlebarStatusControlAvailability(
                hasProject: false,
                hasGitBranch: false,
                hasSessionStore: true,
                hasCommandBus: false
            ),
            TitlebarStatusControlAvailability(
                branchEnabled: false,
                sessionsEnabled: true,
                gitHubEnabled: false
            )
        )
    }

    func testResolveTitlebarStatusControlAvailabilityAllowsBranchWhenProjectExists() {
        XCTAssertEqual(
            resolveTitlebarStatusControlAvailability(
                hasProject: true,
                hasGitBranch: false,
                hasSessionStore: false,
                hasCommandBus: true
            ),
            TitlebarStatusControlAvailability(
                branchEnabled: true,
                sessionsEnabled: false,
                gitHubEnabled: true
            )
        )
    }

    func testResolveTitlebarStatusControlAvailabilityAllowsBranchWhenGitBranchExists() {
        // Terminal workspace with no projectPath but a detected git branch
        XCTAssertEqual(
            resolveTitlebarStatusControlAvailability(
                hasProject: false,
                hasGitBranch: true,
                hasSessionStore: true,
                hasCommandBus: true
            ),
            TitlebarStatusControlAvailability(
                branchEnabled: true,
                sessionsEnabled: true,
                gitHubEnabled: true
            )
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
