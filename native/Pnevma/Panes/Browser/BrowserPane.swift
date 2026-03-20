import Cocoa
import SwiftUI

// MARK: - BrowserPaneView (NSView + PaneContent wrapper)

final class BrowserPaneView: NSView, PaneContent {
    let paneID = PaneID()
    let paneType = "browser"
    let shouldPersist = true
    var title: String { session.viewModel.pageTitle.isEmpty ? "Browser" : session.viewModel.pageTitle }

    private let session: BrowserWorkspaceSession
    private var initialURL: URL?
    private var pendingActivation = false

    var metadataJSON: String? {
        guard let url = session.currentURL else { return nil }
        guard let data = try? JSONSerialization.data(
            withJSONObject: ["url": url.absoluteString],
            options: []
        ) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    convenience init(frame: NSRect, session: BrowserWorkspaceSession, url: URL?) {
        self.init(frame: frame, session: session)
        if let url {
            initialURL = url
        }
    }

    init(frame: NSRect, session: BrowserWorkspaceSession) {
        self.session = session
        super.init(frame: frame)
        _ = addSwiftUISubview(BrowserView(session: session))
    }

    required init?(coder: NSCoder) { fatalError() }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil, let url = initialURL {
            initialURL = nil
            session.navigate(to: url, revealInDrawer: false)
        } else if window != nil {
            session.restoreIfNeeded()
        }
        activateIfReady()
    }

    func activate() {
        pendingActivation = true
        activateIfReady()
    }

    func deactivate() {
        guard let webView = session.viewModel.existingWebView else { return }
        webView.allowsFirstResponderAcquisition = false
        Task { @MainActor [weak self] in
            self?.session.viewModel.existingWebView?.allowsFirstResponderAcquisition = true
        }
    }

    func dispose() {}

    /// Restore URL from persisted metadata
    static func fromMetadata(_ json: String?) -> BrowserPaneView {
        let session = PaneFactory.activeWorkspaceProvider?().flatMap { PaneFactory.browserSessionProvider?($0) }
            ?? BrowserWorkspaceSession()
        let view = BrowserPaneView(frame: .zero, session: session)
        if let json, let data = json.data(using: .utf8),
           let dict = try? JSONSerialization.jsonObject(with: data) as? [String: String],
           let urlStr = dict["url"], let url = URL(string: urlStr) {
            session.updateRestoredURL(url)
            view.initialURL = url
        }
        return view
    }

    private func activateIfReady() {
        guard pendingActivation, session.viewModel.shouldRenderWebView else { return }
        guard let window, session.viewModel.webView.window === window else { return }
        pendingActivation = false
        window.makeFirstResponder(session.viewModel.webView)
    }
}
