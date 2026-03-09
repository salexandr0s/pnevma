import Cocoa
import SwiftUI

// MARK: - BrowserPaneView (NSView + PaneContent wrapper)

final class BrowserPaneView: NSView, PaneContent {
    let paneID = PaneID()
    let paneType = "browser"
    let shouldPersist = true
    var title: String { viewModel.pageTitle.isEmpty ? "Browser" : viewModel.pageTitle }

    private let viewModel = BrowserViewModel()
    private var initialURL: URL?

    var metadataJSON: String? {
        guard let url = viewModel.navigatedURL ?? viewModel.currentURL else { return nil }
        guard let data = try? JSONSerialization.data(
            withJSONObject: ["url": url.absoluteString],
            options: []
        ) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    convenience init(frame: NSRect, url: URL?) {
        self.init(frame: frame)
        if let url {
            initialURL = url
        }
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        _ = addSwiftUISubview(BrowserView(viewModel: viewModel))
    }

    required init?(coder: NSCoder) { fatalError() }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil, let url = initialURL {
            initialURL = nil
            viewModel.navigate(to: url)
        }
    }

    func activate() {
        if viewModel.shouldRenderWebView {
            window?.makeFirstResponder(viewModel.webView)
        }
    }

    func deactivate() {
        viewModel.webView.allowsFirstResponderAcquisition = false
        Task { @MainActor [weak self] in
            self?.viewModel.webView.allowsFirstResponderAcquisition = true
        }
    }

    func dispose() {
        viewModel.webView.stopLoading()
        viewModel.webView.navigationDelegate = nil
        viewModel.webView.uiDelegate = nil
    }

    /// Restore URL from persisted metadata
    static func fromMetadata(_ json: String?) -> BrowserPaneView {
        let view = BrowserPaneView(frame: .zero)
        if let json, let data = json.data(using: .utf8),
           let dict = try? JSONSerialization.jsonObject(with: data) as? [String: String],
           let urlStr = dict["url"], let url = URL(string: urlStr) {
            view.initialURL = url
        }
        return view
    }
}
