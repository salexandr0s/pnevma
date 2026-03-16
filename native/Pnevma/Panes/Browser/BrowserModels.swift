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

@MainActor
enum BrowserSearchEngine: String, CaseIterable, Identifiable {
    case google = "Google"
    case duckduckgo = "DuckDuckGo"
    case bing = "Bing"
    case kagi = "Kagi"

    nonisolated var id: String { rawValue }

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
            let effectiveLastVisited = min(lastVisited, Date.now)
            let recency = max(0, 1.0 - Date.now.timeIntervalSince(effectiveLastVisited) / (30 * 24 * 3600))
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
            entries[idx].lastVisited = Date.now
            entries[idx].visitCount += 1
        } else {
            entries.append(Entry(url: url, title: title, lastVisited: Date.now, visitCount: 1))
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
            try? await Task.sleep(for: .milliseconds(200)) // 200ms debounce
            guard !Task.isCancelled else { return }
            self?.save()
        }
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(entries) else { return }
        try? data.write(to: fileURL, options: .atomic)
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

// MARK: - Notification Names

extension Notification.Name {
    static let browserToggleFind = Notification.Name("browserToggleFind")
    static let browserToggleReaderMode = Notification.Name("browserToggleReaderMode")
}
