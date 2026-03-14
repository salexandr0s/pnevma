import Foundation
import Observation

@Observable @MainActor
final class BrowserWorkspaceSession {
    let viewModel: BrowserViewModel
    var isDrawerVisible = false

    private var restoredURL: URL?
    private var hasRestoredInitialURL = false
    private var onURLChanged: ((URL?) -> Void)?

    init(
        restoredURL: URL? = nil,
        viewModel: BrowserViewModel? = nil,
        onURLChanged: ((URL?) -> Void)? = nil
    ) {
        self.viewModel = viewModel ?? BrowserViewModel()
        self.restoredURL = restoredURL
        self.onURLChanged = onURLChanged
        self.viewModel.onURLChanged = { [weak self] url in
            self?.onURLChanged?(url)
        }
    }

    var currentURL: URL? {
        viewModel.persistedURL ?? restoredURL
    }

    func updateRestoredURL(_ url: URL?) {
        restoredURL = url
        if viewModel.persistedURL == nil {
            hasRestoredInitialURL = false
        }
    }

    func restoreIfNeeded() {
        guard !hasRestoredInitialURL else { return }
        hasRestoredInitialURL = true
        guard viewModel.persistedURL == nil, let restoredURL else { return }
        viewModel.setPendingURL(restoredURL)
        viewModel.navigate(to: restoredURL)
    }

    func showDrawer(focusOmnibar: Bool = true) {
        restoreIfNeeded()
        isDrawerVisible = true
        if focusOmnibar {
            viewModel.requestOmnibarFocus()
        }
    }

    func hideDrawer() {
        isDrawerVisible = false
    }

    func navigate(to url: URL, revealInDrawer: Bool = true, focusOmnibar: Bool = false) {
        if revealInDrawer {
            isDrawerVisible = true
        }
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
}
