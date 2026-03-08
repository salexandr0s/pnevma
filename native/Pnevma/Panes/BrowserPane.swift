import Cocoa
import SwiftUI
import WebKit

// MARK: - PnevmaWebView

/// Custom WKWebView subclass that routes Cmd-key shortcuts to the app menu
/// first and supports click-to-focus.
class PnevmaWebView: WKWebView {
    var onRequestPanelFocus: (() -> Void)?
    var allowsFirstResponderAcquisition = true

    override var acceptsFirstResponder: Bool {
        allowsFirstResponderAcquisition
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        // Route Cmd-key shortcuts to the app menu before WebKit swallows them.
        if event.modifierFlags.contains(.command) {
            if let mainMenu = NSApp.mainMenu, mainMenu.performKeyEquivalent(with: event) {
                return true
            }
        }
        return super.performKeyEquivalent(with: event)
    }

    override func mouseDown(with event: NSEvent) {
        onRequestPanelFocus?()
        super.mouseDown(with: event)
    }

    // Mouse back/forward buttons
    override func otherMouseDown(with event: NSEvent) {
        switch event.buttonNumber {
        case 3: goBack()
        case 4: goForward()
        default: super.otherMouseDown(with: event)
        }
    }
}

// MARK: - BrowserSearchEngine

enum BrowserSearchEngine: String, CaseIterable, Identifiable {
    case google = "Google"
    case duckduckgo = "DuckDuckGo"
    case bing = "Bing"
    case kagi = "Kagi"

    var id: String { rawValue }

    func searchURL(query: String) -> URL? {
        guard let encoded = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) else {
            return nil
        }
        let urlString: String
        switch self {
        case .google:     urlString = "https://www.google.com/search?q=\(encoded)"
        case .duckduckgo: urlString = "https://duckduckgo.com/?q=\(encoded)"
        case .bing:       urlString = "https://www.bing.com/search?q=\(encoded)"
        case .kagi:       urlString = "https://kagi.com/search?q=\(encoded)"
        }
        return URL(string: urlString)
    }

    private static let defaultsKey = "browser.searchEngine"

    static var current: BrowserSearchEngine {
        get {
            UserDefaults.standard.string(forKey: defaultsKey)
                .flatMap(BrowserSearchEngine.init(rawValue:)) ?? .google
        }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: defaultsKey)
        }
    }
}

// MARK: - BrowserHistoryStore

@MainActor
final class BrowserHistoryStore {
    static let shared = BrowserHistoryStore()

    struct Entry: Codable, Identifiable {
        let url: String
        var title: String
        var lastVisited: Date
        var visitCount: Int
        var id: String { url }

        var frecencyScore: Double {
            let effectiveLastVisited = min(lastVisited, Date())
            let recency = max(0, 1.0 - Date().timeIntervalSince(effectiveLastVisited) / (30 * 24 * 3600))
            return Double(visitCount) * (0.3 + 0.7 * recency)
        }
    }

    private(set) var entries: [Entry] = []
    private let maxEntries = 5000
    private var saveTask: Task<Void, Never>?

    private var fileURL: URL {
        let configDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/pnevma")
        try? FileManager.default.createDirectory(at: configDir, withIntermediateDirectories: true)
        return configDir.appendingPathComponent("browser-history.json")
    }

    private init() {
        load()
    }

    func recordVisit(url: String, title: String) {
        if let idx = entries.firstIndex(where: { $0.url == url }) {
            entries[idx].title = title
            entries[idx].lastVisited = Date()
            entries[idx].visitCount += 1
        } else {
            entries.append(Entry(url: url, title: title, lastVisited: Date(), visitCount: 1))
        }
        if entries.count > maxEntries {
            entries.sort { $0.frecencyScore > $1.frecencyScore }
            entries = Array(entries.prefix(maxEntries))
        }
        scheduleSave()
    }

    func suggestions(for query: String) -> [Entry] {
        guard !query.isEmpty else { return [] }
        let lower = query.lowercased()
        return entries
            .filter { $0.url.lowercased().contains(lower) || $0.title.lowercased().contains(lower) }
            .sorted { $0.frecencyScore > $1.frecencyScore }
            .prefix(8)
            .map { $0 }
    }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL),
              let decoded = try? JSONDecoder().decode([Entry].self, from: data) else { return }
        entries = decoded
    }

    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 200_000_000) // 200ms debounce
            guard !Task.isCancelled else { return }
            self?.save()
        }
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(entries) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}

// MARK: - BrowserViewModel

@MainActor
final class BrowserViewModel: NSObject, ObservableObject {
    @Published var currentURL: URL?
    @Published var pageTitle: String = ""
    @Published var isLoading: Bool = false
    @Published var canGoBack: Bool = false
    @Published var canGoForward: Bool = false
    @Published var estimatedProgress: Double = 0
    @Published var omnibarText: String = ""
    @Published var suggestions: [BrowserHistoryStore.Entry] = []
    @Published var showSuggestions: Bool = false
    @Published var searchEngine: BrowserSearchEngine = .current
    @Published var shouldRenderWebView: Bool = false
    @Published var navigatedURL: URL?

    let webView: PnevmaWebView

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
        webView.load(URLRequest(url: url))
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

    func updateSuggestions(for query: String) {
        guard !query.isEmpty else {
            suggestions = []
            showSuggestions = false
            return
        }
        suggestions = BrowserHistoryStore.shared.suggestions(for: query)
        showSuggestions = !suggestions.isEmpty
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

// MARK: - WebViewRepresentable

struct WebViewRepresentable: NSViewRepresentable {
    let webView: PnevmaWebView

    func makeNSView(context: Context) -> PnevmaWebView {
        webView
    }

    func updateNSView(_ nsView: PnevmaWebView, context: Context) {}
}

// MARK: - BrowserView (SwiftUI)

struct BrowserView: View {
    @ObservedObject var viewModel: BrowserViewModel
    @ObservedObject private var theme = GhosttyThemeProvider.shared
    @StateObject private var readerState = BrowserReaderState()
    @State private var findState: BrowserFindState?

    var body: some View {
        VStack(spacing: 0) {
            // Omnibar chrome
            omnibar
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .background(Color.clear)

            // Progress bar
            if viewModel.isLoading {
                GeometryReader { geo in
                    Rectangle()
                        .fill(Color.accentColor)
                        .frame(width: geo.size.width * viewModel.estimatedProgress, height: 2)
                        .animation(.easeInOut(duration: 0.2), value: viewModel.estimatedProgress)
                }
                .frame(height: 2)
            }

            Divider()

            // Web content, reader mode, or new tab page
            ZStack {
                if readerState.isActive, let result = readerState.result {
                    BrowserReaderModeView(
                        result: result,
                        onClose: { readerState.isActive = false },
                        onCopyMarkdown: { readerState.copyMarkdown() },
                        onSaveMarkdown: { readerState.saveMarkdown() }
                    )
                } else if viewModel.shouldRenderWebView {
                    WebViewRepresentable(webView: viewModel.webView)
                } else {
                    newTabPage
                }

                // Extracting indicator
                if readerState.isExtracting {
                    ProgressView("Extracting content...")
                        .padding(20)
                        .background(
                            RoundedRectangle(cornerRadius: 10)
                                .fill(.ultraThinMaterial)
                        )
                }

                // Find overlay
                if let findState {
                    VStack {
                        HStack {
                            Spacer()
                            BrowserFindOverlay(
                                state: findState,
                                webView: viewModel.webView,
                                onClose: { self.findState = nil }
                            )
                            .frame(width: 320)
                            .padding(8)
                        }
                        Spacer()
                    }
                }
            }
        }
        .background(Color.clear)
        .onAppear {
            viewModel.webView.onRequestPanelFocus = { [weak viewModel] in
                viewModel?.showSuggestions = false
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .browserToggleFind)) { _ in
            if findState == nil {
                findState = BrowserFindState()
            } else {
                findState = nil
                BrowserFindJavaScript.clear(in: viewModel.webView)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .browserToggleReaderMode)) { _ in
            readerState.toggle(webView: viewModel.webView)
        }
        .onChange(of: viewModel.currentURL) { _, _ in
            if let findState {
                findState.totalMatches = 0
                findState.currentMatch = 0
                BrowserFindJavaScript.clear(in: viewModel.webView)
            }
        }
    }

    private var omnibar: some View {
        HStack(spacing: 6) {
            // Back
            Button(action: { viewModel.goBack() }) {
                Image(systemName: "chevron.left")
                    .font(.system(size: 13, weight: .medium))
            }
            .buttonStyle(.plain)
            .disabled(!viewModel.canGoBack)
            .opacity(viewModel.canGoBack ? 1 : 0.4)

            // Forward
            Button(action: { viewModel.goForward() }) {
                Image(systemName: "chevron.right")
                    .font(.system(size: 13, weight: .medium))
            }
            .buttonStyle(.plain)
            .disabled(!viewModel.canGoForward)
            .opacity(viewModel.canGoForward ? 1 : 0.4)

            // Reload / Stop
            Button(action: { viewModel.reload() }) {
                Image(systemName: viewModel.isLoading ? "xmark" : "arrow.clockwise")
                    .font(.system(size: 12, weight: .medium))
            }
            .buttonStyle(.plain)

            // Address bar pill
            ZStack {
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color(nsColor: theme.foregroundColor).opacity(0.06))
                    .frame(height: 28)

                OmnibarTextField(
                    text: $viewModel.omnibarText,
                    onCommit: {
                        viewModel.showSuggestions = false
                        viewModel.navigateSmart(viewModel.omnibarText)
                    },
                    onChange: { newValue in
                        viewModel.updateSuggestions(for: newValue)
                    }
                )
                .font(.system(size: 13))
                .padding(.horizontal, 10)
            }
            .overlay(alignment: .topLeading) {
                if viewModel.showSuggestions {
                    suggestionsDropdown
                        .offset(y: 32)
                }
            }

            // Reader mode / markdown
            Button(action: {
                NotificationCenter.default.post(name: .browserToggleReaderMode, object: nil)
            }) {
                Image(systemName: "doc.plaintext")
                    .font(.system(size: 12, weight: .medium))
            }
            .buttonStyle(.plain)
            .disabled(!viewModel.shouldRenderWebView)
            .opacity(viewModel.shouldRenderWebView ? 1 : 0.4)

            // Find
            Button(action: {
                NotificationCenter.default.post(name: .browserToggleFind, object: nil)
            }) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 12, weight: .medium))
            }
            .buttonStyle(.plain)
        }
    }

    private var suggestionsDropdown: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Search engine suggestion
            Button(action: {
                viewModel.showSuggestions = false
                viewModel.navigateSmart(viewModel.omnibarText)
            }) {
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text("Search \(viewModel.searchEngine.rawValue) for \"\(viewModel.omnibarText)\"")
                        .font(.system(size: 12))
                        .lineLimit(1)
                    Spacer()
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
            }
            .buttonStyle(.plain)

            if !viewModel.suggestions.isEmpty {
                Divider()
                ForEach(viewModel.suggestions) { entry in
                    Button(action: {
                        viewModel.showSuggestions = false
                        viewModel.omnibarText = entry.url
                        if let url = URL(string: entry.url) {
                            viewModel.navigate(to: url)
                        }
                    }) {
                        HStack(spacing: 8) {
                            Image(systemName: "clock.arrow.circlepath")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(entry.title)
                                    .font(.system(size: 12))
                                    .lineLimit(1)
                                Text(entry.url)
                                    .font(.system(size: 10))
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                            Spacer()
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .frame(maxWidth: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color(nsColor: theme.foregroundColor).opacity(0.06))
                .shadow(color: .black.opacity(0.2), radius: 8, y: 4)
        )
        .zIndex(100)
    }

    private var newTabPage: some View {
        VStack(spacing: 20) {
            Spacer()

            Image(systemName: "globe")
                .font(.system(size: 48))
                .foregroundStyle(.secondary.opacity(0.3))

            Text("Search or enter a URL")
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(.secondary)

            // Recent history
            if !BrowserHistoryStore.shared.entries.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text("RECENT")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)

                    let recent = BrowserHistoryStore.shared.entries
                        .sorted { $0.lastVisited > $1.lastVisited }
                        .prefix(6)

                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 140), spacing: 8)], spacing: 8) {
                        ForEach(Array(recent), id: \.url) { entry in
                            Button(action: {
                                if let url = URL(string: entry.url) {
                                    viewModel.navigate(to: url)
                                    viewModel.omnibarText = entry.url
                                }
                            }) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(entry.title)
                                        .font(.system(size: 12, weight: .medium))
                                        .lineLimit(1)
                                    Text(URL(string: entry.url)?.host(percentEncoded: false) ?? entry.url)
                                        .font(.system(size: 10))
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                }
                                .padding(8)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(
                                    RoundedRectangle(cornerRadius: 6)
                                        .fill(Color(nsColor: theme.foregroundColor).opacity(0.06))
                                )
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .frame(maxWidth: 500)
            }

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - OmnibarTextField (NSViewRepresentable for proper focus/select behavior)

struct OmnibarTextField: NSViewRepresentable {
    @Binding var text: String
    var onCommit: () -> Void
    var onChange: (String) -> Void

    func makeNSView(context: Context) -> NSTextField {
        let field = NSTextField()
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.placeholderString = "Search or enter URL"
        field.font = NSFont.systemFont(ofSize: 13)
        field.delegate = context.coordinator
        field.cell?.isScrollable = true
        field.cell?.wraps = false
        field.cell?.truncatesLastVisibleLine = true
        return field
    }

    func updateNSView(_ nsView: NSTextField, context: Context) {
        if nsView.stringValue != text {
            nsView.stringValue = text
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        let parent: OmnibarTextField

        init(_ parent: OmnibarTextField) {
            self.parent = parent
        }

        func controlTextDidChange(_ obj: Notification) {
            guard let field = obj.object as? NSTextField else { return }
            parent.text = field.stringValue
            parent.onChange(field.stringValue)
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            if commandSelector == #selector(NSResponder.insertNewline(_:)) {
                parent.onCommit()
                return true
            }
            if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
                // Dismiss suggestions on Escape
                parent.onChange("")
                return false
            }
            return false
        }
    }
}

// MARK: - Notification Names

extension Notification.Name {
    static let browserToggleFind = Notification.Name("browserToggleFind")
    static let browserToggleReaderMode = Notification.Name("browserToggleReaderMode")
}

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
        DispatchQueue.main.async { [weak self] in
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
