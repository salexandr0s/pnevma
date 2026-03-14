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

    let webView: PnevmaWebView

    var onURLChanged: ((URL?) -> Void)?

    private var observations: [NSKeyValueObservation] = []

    override init() {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()
        config.preferences.isElementFullscreenEnabled = true
        config.defaultWebpagePreferences.allowsContentJavaScript = true

        // Bootstrap script for console/error telemetry
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

        webView = PnevmaWebView(frame: .zero, configuration: config)
        webView.appearance = NSAppearance(named: .darkAqua)
        webView.underPageBackgroundColor = NSColor(white: 0.15, alpha: 1.0)
        webView.allowsBackForwardNavigationGestures = true

        // Safari user agent to avoid bot checks
        webView.customUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.2 Safari/605.1.15"

        #if DEBUG
        // Enable Web Inspector only in debug builds
        if #available(macOS 13.3, *) {
            webView.isInspectable = true
        }
        #endif

        super.init()

        webView.navigationDelegate = self
        webView.uiDelegate = self

        observations = [
            webView.observe(\.url) { [weak self] wv, _ in
                Task { @MainActor [weak self] in
                    self?.currentURL = wv.url
                    self?.omnibarText = wv.url?.absoluteString ?? ""
                    self?.onURLChanged?(wv.url)
                }
            },
            webView.observe(\.title) { [weak self] wv, _ in
                Task { @MainActor [weak self] in
                    self?.pageTitle = wv.title ?? ""
                }
            },
            webView.observe(\.isLoading) { [weak self] wv, _ in
                Task { @MainActor [weak self] in
                    self?.isLoading = wv.isLoading
                }
            },
            webView.observe(\.canGoBack) { [weak self] wv, _ in
                Task { @MainActor [weak self] in
                    self?.canGoBack = wv.canGoBack
                }
            },
            webView.observe(\.canGoForward) { [weak self] wv, _ in
                Task { @MainActor [weak self] in
                    self?.canGoForward = wv.canGoForward
                }
            },
            webView.observe(\.estimatedProgress) { [weak self] wv, _ in
                Task { @MainActor [weak self] in
                    self?.estimatedProgress = wv.estimatedProgress
                }
            },
        ]
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

    private func isLocalhostURL(_ url: URL) -> Bool {
        guard let host = url.host(percentEncoded: false)?.lowercased() else { return false }
        return host == "localhost" || host == "127.0.0.1" || host == "::1" || host == "0.0.0.0"
    }
}

// MARK: - WKNavigationDelegate

extension BrowserViewModel: WKNavigationDelegate {
    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
    ) {
        guard let url = navigationAction.request.url else {
            decisionHandler(.cancel)
            return
        }

        // Block non-web schemes — open externally
        if url.scheme != "https" && url.scheme != "http" && url.scheme != "about" && url.scheme != "blob" {
            NSWorkspace.shared.open(url)
            decisionHandler(.cancel)
            return
        }

        // Block HTTP except localhost
        if url.scheme == "http" && !isLocalhostURL(url) {
            // Upgrade to HTTPS silently
            var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
            components?.scheme = "https"
            if let httpsURL = components?.url {
                decisionHandler(.cancel)
                webView.load(URLRequest(url: httpsURL))
                return
            }
        }

        decisionHandler(.allow)
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
