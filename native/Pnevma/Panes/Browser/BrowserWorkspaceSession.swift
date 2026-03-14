import Foundation
import Observation

@Observable @MainActor
final class BrowserWorkspaceSession {
    let viewModel: BrowserViewModel
    let workspaceID: UUID
    var isDrawerVisible = false
    var preferredDrawerHeight: CGFloat?
    private(set) var workspaceProjectPath: String?

    private var restoredURL: URL?
    private var hasRestoredInitialURL = false
    private var onURLChanged: ((URL?) -> Void)?
    private var onDrawerHeightChanged: ((Double?) -> Void)?
    @ObservationIgnored
    nonisolated(unsafe) private var pendingDrawerRestoreTask: Task<Void, Never>?

    init(
        workspaceID: UUID = UUID(),
        workspaceProjectPath: String? = nil,
        restoredURL: URL? = nil,
        restoredDrawerHeight: Double? = nil,
        viewModel: BrowserViewModel? = nil,
        onURLChanged: ((URL?) -> Void)? = nil,
        onDrawerHeightChanged: ((Double?) -> Void)? = nil
    ) {
        self.viewModel = viewModel ?? BrowserViewModel()
        self.workspaceID = workspaceID
        self.workspaceProjectPath = workspaceProjectPath
        self.restoredURL = restoredURL
        self.preferredDrawerHeight = restoredDrawerHeight.map { CGFloat($0) }
        self.onURLChanged = onURLChanged
        self.onDrawerHeightChanged = onDrawerHeightChanged
        self.viewModel.onURLChanged = { [weak self] url in
            self?.onURLChanged?(url)
        }
    }

    deinit {
        pendingDrawerRestoreTask?.cancel()
    }

    var currentURL: URL? {
        viewModel.persistedURL ?? restoredURL
    }

    func updateRestoredURL(_ url: URL?) {
        cancelPendingDrawerRestore()
        restoredURL = url
        if viewModel.persistedURL == nil {
            hasRestoredInitialURL = false
        }
    }

    func updateRestoredDrawerHeight(_ height: Double?) {
        preferredDrawerHeight = height.map { CGFloat($0) }
    }

    func updateWorkspaceProjectPath(_ path: String?) {
        workspaceProjectPath = path
    }

    func restoreIfNeeded() {
        pendingDrawerRestoreTask?.cancel()
        pendingDrawerRestoreTask = nil
        guard !hasRestoredInitialURL else { return }
        hasRestoredInitialURL = true
        guard viewModel.persistedURL == nil, let restoredURL else { return }
        viewModel.setPendingURL(restoredURL)
        viewModel.navigate(to: restoredURL)
    }

    func showDrawer(focusOmnibar: Bool = true) {
        isDrawerVisible = true
        if focusOmnibar {
            viewModel.requestOmnibarFocus()
        }
    }

    func hideDrawer() {
        cancelPendingDrawerRestore()
        isDrawerVisible = false
    }

    func navigate(to url: URL, revealInDrawer: Bool = true, focusOmnibar: Bool = false) {
        if revealInDrawer {
            isDrawerVisible = true
        }
        cancelPendingDrawerRestore()
        hasRestoredInitialURL = true
        restoredURL = url
        viewModel.navigate(to: url)
        if focusOmnibar {
            viewModel.requestOmnibarFocus()
        }
    }

    func requestOmnibarFocus() {
        viewModel.requestOmnibarFocus()
    }

    func cancelPendingDrawerRestore() {
        pendingDrawerRestoreTask?.cancel()
        pendingDrawerRestoreTask = nil
    }

    func scheduleDrawerRestoreIfNeeded(after delay: Duration = .seconds(0)) {
        cancelPendingDrawerRestore()
        guard isDrawerVisible else { return }
        guard !hasRestoredInitialURL else { return }
        guard viewModel.persistedURL == nil, restoredURL != nil else { return }

        pendingDrawerRestoreTask = Task { @MainActor [weak self] in
            guard let self else { return }
            if delay > .zero {
                try? await Task.sleep(for: delay)
            }
            guard !Task.isCancelled else { return }
            guard self.isDrawerVisible else { return }
            self.restoreIfNeeded()
        }
    }

    func resolvedDrawerHeight(for availableHeight: CGFloat) -> CGFloat {
        BrowserDrawerSizing.resolvedHeight(
            storedHeight: preferredDrawerHeight,
            availableHeight: availableHeight
        )
    }

    func setDrawerHeight(_ height: CGFloat?) {
        let normalizedHeight = height.map { max(0, $0) }
        guard !isEffectivelyEqual(preferredDrawerHeight, normalizedHeight) else { return }
        preferredDrawerHeight = normalizedHeight
        onDrawerHeightChanged?(normalizedHeight.map(Double.init))
    }

    func adjustDrawerHeight(by delta: CGFloat, availableHeight: CGFloat) {
        let nextHeight = BrowserDrawerSizing.clamp(
            resolvedDrawerHeight(for: availableHeight) + delta,
            availableHeight: availableHeight
        )
        setDrawerHeight(nextHeight)
    }

    func copySelectionWithSource() async throws -> BrowserSelectionCaptureResult {
        try await BrowserCaptureUtilities.copySelection(from: viewModel.webView)
    }

    func copyPageLinkListAsMarkdown() async throws -> BrowserLinkListCaptureResult {
        try await BrowserCaptureUtilities.copyLinkListAsMarkdown(from: viewModel.webView)
    }

    func savePageAsMarkdown(
        extractedMarkdown: MarkdownResult? = nil
    ) async throws -> BrowserSavedMarkdownCaptureResult {
        let captureContext = BrowserCaptureContext(
            workspaceID: workspaceID,
            projectPath: workspaceProjectPath
        )

        if let extractedMarkdown {
            return try BrowserCaptureUtilities.saveMarkdown(
                extractedMarkdown,
                context: captureContext
            )
        }

        return try await BrowserCaptureUtilities.savePageAsMarkdown(
            from: viewModel.webView,
            context: captureContext
        )
    }

    private func isEffectivelyEqual(_ lhs: CGFloat?, _ rhs: CGFloat?) -> Bool {
        switch (lhs, rhs) {
        case (nil, nil):
            return true
        case let (lhs?, rhs?):
            return abs(lhs - rhs) < 0.5
        default:
            return false
        }
    }
}
