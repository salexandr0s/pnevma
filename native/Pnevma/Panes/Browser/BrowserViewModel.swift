import Foundation
import Observation
import WebKit

// MARK: - BrowserViewModel

@Observable @MainActor
final class BrowserViewModel: NSObject {
    var currentURL: URL?
    var pageTitle: String = ""
    var isLoading: Bool = false
    var canGoBack: Bool = false
    var canGoForward: Bool = false
    var estimatedProgress: Double = 0
    var omnibarText: String = ""
    var suggestions: [BrowserHistoryStore.Entry] = []
    var showSuggestions: Bool = false
    var searchEngine: BrowserSearchEngine = .current
    var shouldRenderWebView: Bool = false
    var navigatedURL: URL?
    var omnibarFocusToken: Int = 0

    var recentHistory: [BrowserHistoryStore.Entry] {
        Array(
            BrowserHistoryStore.shared.entries
                .sorted { $0.lastVisited > $1.lastVisited }
                .prefix(6)
        )
    }

    var onURLChanged: ((URL?) -> Void)?

    var existingWebView: PnevmaWebView? {
        webViewStorage
    }

    var webView: PnevmaWebView {
        if let webViewStorage {
            return webViewStorage
        }

        let webView = makeWebView()
        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.onRequestPanelFocus = panelFocusHandler
        installObservations(on: webView)
        webViewStorage = webView
        return webView
    }

    @ObservationIgnored
    private var webViewStorage: PnevmaWebView?
    private var observations: [NSKeyValueObservation] = []
    private var panelFocusHandler: (() -> Void)?

    override init() {
        super.init()
    }

    // KVO observations are automatically invalidated when their tokens are deallocated.

    func navigate(to url: URL) {
        navigatedURL = url
        shouldRenderWebView = true
        omnibarText = url.absoluteString
        webView.load(URLRequest(url: url))
    }

    func setPendingURL(_ url: URL) {
        navigatedURL = url
        omnibarText = url.absoluteString
    }

    func navigateSmart(_ input: String) {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        // Detect URL-like input: has a dot, no spaces
        if trimmed.contains(".") && !trimmed.contains(" ") {
            var urlString = trimmed
            if !urlString.contains("://") {
                urlString = "https://" + urlString
            }
            if let url = URL(string: urlString) {
                navigate(to: url)
                return
            }
        }

        // Otherwise, search
        if let searchURL = searchEngine.searchURL(query: trimmed) {
            navigate(to: searchURL)
        }
    }

    func goBack() { webView.goBack() }
    func goForward() { webView.goForward() }

    func reload() {
        if isLoading {
            webView.stopLoading()
        } else {
            webView.reload()
        }
    }

    func requestOmnibarFocus() {
        omnibarFocusToken &+= 1
    }

    func setPanelFocusHandler(_ handler: @escaping () -> Void) {
        panelFocusHandler = handler
        webViewStorage?.onRequestPanelFocus = handler
    }

    func updateSuggestions(for query: String) {
        guard !query.isEmpty else {
            suggestions = []
            showSuggestions = false
            return
        }
        suggestions = BrowserHistoryStore.shared.suggestions(for: query)
        showSuggestions = !suggestions.isEmpty
    }

    var persistedURL: URL? {
        currentURL ?? navigatedURL
    }

    func prepareForTeardown() {
        onURLChanged = nil
        observations.removeAll()
        panelFocusHandler = nil
        guard let webView = webViewStorage else { return }
        webViewStorage = nil
        webView.stopLoading()
        webView.navigationDelegate = nil
        webView.uiDelegate = nil
        webView.onRequestPanelFocus = nil
        webView.removeFromSuperview()
    }

    private func makeWebView() -> PnevmaWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()
        config.preferences.isElementFullscreenEnabled = true
        config.defaultWebpagePreferences.allowsContentJavaScript = true

        let bootstrap = WKUserScript(
            source: """
            (function() {
                window.__pnevmaConsoleLog = [];
                window.__pnevmaErrorLog = [];
                var orig = console.log.bind(console);
                console.log = function() {
                    window.__pnevmaConsoleLog.push(Array.from(arguments).map(String).join(' '));
                    orig.apply(console, arguments);
                };
                window.addEventListener('error', function(e) {
                    window.__pnevmaErrorLog.push(e.message + ' at ' + e.filename + ':' + e.lineno);
                });
            })();
            """,
            injectionTime: .atDocumentStart,
            forMainFrameOnly: true
        )
        config.userContentController.addUserScript(bootstrap)

        let darkModeHint = WKUserScript(
            source: "document.documentElement.style.colorScheme = 'dark light';",
            injectionTime: .atDocumentEnd,
            forMainFrameOnly: true
        )
        config.userContentController.addUserScript(darkModeHint)

        let webView = PnevmaWebView(frame: .zero, configuration: config)
        PerformanceDiagnostics.shared.recordBrowserWebViewCreation()
        let isDark = NSApp?.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        webView.appearance = NSAppearance(named: isDark ? .darkAqua : .aqua)
        webView.underPageBackgroundColor = isDark
            ? NSColor(white: 0.15, alpha: 1.0)
            : .controlBackgroundColor
        webView.allowsBackForwardNavigationGestures = true
        webView.customUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.2 Safari/605.1.15"

        #if DEBUG
        if #available(macOS 13.3, *) {
            webView.isInspectable = true
        }
        #endif

        return webView
    }

    private func installObservations(on webView: PnevmaWebView) {
        // KVO closures may fire on a background thread. Do NOT read WKWebView
        // properties inside the closure; dispatch to MainActor and re-read there.
        observations = [
            webView.observe(\.url) { [weak self] _, _ in
                self?.applyObservedUpdate {
                    let url = $0.existingWebView?.url
                    $0.currentURL = url
                    $0.omnibarText = url?.absoluteString ?? ""
                    $0.onURLChanged?(url)
                }
            },
            webView.observe(\.title) { [weak self] _, _ in
                self?.applyObservedUpdate { $0.pageTitle = $0.existingWebView?.title ?? "" }
            },
            webView.observe(\.isLoading) { [weak self] _, _ in
                self?.applyObservedUpdate { $0.isLoading = $0.existingWebView?.isLoading ?? false }
            },
            webView.observe(\.canGoBack) { [weak self] _, _ in
                self?.applyObservedUpdate { $0.canGoBack = $0.existingWebView?.canGoBack ?? false }
            },
            webView.observe(\.canGoForward) { [weak self] _, _ in
                self?.applyObservedUpdate { $0.canGoForward = $0.existingWebView?.canGoForward ?? false }
            },
            webView.observe(\.estimatedProgress) { [weak self] _, _ in
                self?.applyObservedUpdate { $0.estimatedProgress = $0.existingWebView?.estimatedProgress ?? 0 }
            },
        ]
    }

    private func isLocalhostURL(_ url: URL) -> Bool {
        guard let host = url.host(percentEncoded: false)?.lowercased() else { return false }
        return host == "localhost" || host == "127.0.0.1" || host == "::1" || host == "0.0.0.0"
    }

    nonisolated private func applyObservedUpdate(_ update: @escaping @MainActor (BrowserViewModel) -> Void) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            update(self)
        }
    }
}

// MARK: - WKNavigationDelegate

extension BrowserViewModel: WKNavigationDelegate {
    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction
    ) async -> WKNavigationActionPolicy {
        guard let url = navigationAction.request.url else {
            return .cancel
        }

        // Block non-web schemes — open externally
        if url.scheme != "https" && url.scheme != "http" && url.scheme != "about" && url.scheme != "blob" {
            NSWorkspace.shared.open(url)
            return .cancel
        }

        // Block HTTP except localhost
        if url.scheme == "http" && !isLocalhostURL(url) {
            // Upgrade to HTTPS silently
            var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
            components?.scheme = "https"
            if let httpsURL = components?.url {
                webView.load(URLRequest(url: httpsURL))
                return .cancel
            }
        }

        return .allow
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        if let url = webView.url {
            BrowserHistoryStore.shared.recordVisit(
                url: url.absoluteString,
                title: webView.title ?? url.absoluteString
            )
        }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        // Navigation failures are handled passively — WebKit shows its own error page
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        // Same as above
    }
}

// MARK: - WKUIDelegate

extension BrowserViewModel: WKUIDelegate {
    func webView(
        _ webView: WKWebView,
        createWebViewWith configuration: WKWebViewConfiguration,
        for navigationAction: WKNavigationAction,
        windowFeatures: WKWindowFeatures
    ) -> WKWebView? {
        // Open "new window" requests in the same web view
        if let url = navigationAction.request.url {
            webView.load(URLRequest(url: url))
        }
        return nil
    }
}
