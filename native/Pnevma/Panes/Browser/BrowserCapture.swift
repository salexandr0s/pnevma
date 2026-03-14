import AppKit
import CryptoKit
import Foundation
import WebKit

struct BrowserCaptureContext: Equatable {
    let workspaceID: UUID
    let projectPath: String?
}

struct BrowserSelectionCaptureResult: Equatable {
    let selectedText: String
    let clipboardText: String
    let sourceURL: URL
}

struct BrowserSavedMarkdownCaptureResult: Equatable {
    let title: String
    let sourceURL: URL?
    let outputURL: URL
    let markdown: String
}

struct BrowserLinkListCaptureResult: Equatable {
    let markdown: String
    let links: [BrowserPageLink]
    let sourceURL: URL
}

struct BrowserPageLink: Codable, Equatable {
    let text: String
    let url: URL
}

enum BrowserCaptureError: LocalizedError {
    case noActivePage
    case noSelectedText
    case noPageLinks
    case invalidLinkPayload
    case applicationSupportDirectoryUnavailable

    var errorDescription: String? {
        switch self {
        case .noActivePage:
            return "No active browser page"
        case .noSelectedText:
            return "No selected text found on the page"
        case .noPageLinks:
            return "No page links found to copy"
        case .invalidLinkPayload:
            return "Failed to extract page links"
        case .applicationSupportDirectoryUnavailable:
            return "Could not resolve a browser capture scratch directory"
        }
    }
}

enum BrowserCaptureUtilities {
    struct BrowserPageLinkPayload: Decodable {
        let text: String
        let url: String
    }

    private static let supportedLinkSchemes: Set<String> = ["file", "http", "https", "mailto"]

    @MainActor
    static func copySelection(
        from webView: WKWebView,
        pasteboard: NSPasteboard = .general
    ) async throws -> BrowserSelectionCaptureResult {
        guard let sourceURL = webView.url else {
            throw BrowserCaptureError.noActivePage
        }

        let rawSelection = try await webView.evaluateJavaScript(
            """
            (function() {
                const selection = window.getSelection();
                return selection ? selection.toString() : "";
            })()
            """
        ) as? String ?? ""
        let selectedText = rawSelection.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !selectedText.isEmpty else {
            throw BrowserCaptureError.noSelectedText
        }

        let clipboardText = "\(selectedText)\n\nSource: \(sourceURL.absoluteString)"
        copyPlainText(clipboardText, to: pasteboard)
        return BrowserSelectionCaptureResult(
            selectedText: selectedText,
            clipboardText: clipboardText,
            sourceURL: sourceURL
        )
    }

    @MainActor
    static func copyLinkListAsMarkdown(
        from webView: WKWebView,
        pasteboard: NSPasteboard = .general
    ) async throws -> BrowserLinkListCaptureResult {
        guard let sourceURL = webView.url else {
            throw BrowserCaptureError.noActivePage
        }

        let links = try await extractPageLinks(from: webView)
        guard !links.isEmpty else {
            throw BrowserCaptureError.noPageLinks
        }

        let markdown = markdownLinkList(for: links)
        copyPlainText(markdown, to: pasteboard)
        return BrowserLinkListCaptureResult(markdown: markdown, links: links, sourceURL: sourceURL)
    }

    @MainActor
    static func savePageAsMarkdown(
        from webView: WKWebView,
        context: BrowserCaptureContext,
        applicationSupportURL: URL? = nil,
        fileManager: FileManager = .default
    ) async throws -> BrowserSavedMarkdownCaptureResult {
        let extracted = try await BrowserMarkdownConverter.extractMarkdown(from: webView)
        return try saveMarkdown(
            extracted,
            context: context,
            applicationSupportURL: applicationSupportURL,
            fileManager: fileManager
        )
    }

    static func saveMarkdown(
        _ extracted: MarkdownResult,
        context: BrowserCaptureContext,
        applicationSupportURL: URL? = nil,
        fileManager: FileManager = .default
    ) throws -> BrowserSavedMarkdownCaptureResult {
        let targetDirectory = try scratchDirectory(
            for: context,
            applicationSupportURL: applicationSupportURL,
            fileManager: fileManager
        )
        try fileManager.createDirectory(at: targetDirectory, withIntermediateDirectories: true)

        let fileName = deterministicFilename(title: extracted.title, sourceURL: extracted.url)
        let outputURL = targetDirectory.appendingPathComponent(fileName, isDirectory: false)
        try extracted.markdown.write(to: outputURL, atomically: true, encoding: .utf8)
        return BrowserSavedMarkdownCaptureResult(
            title: extracted.title,
            sourceURL: extracted.url,
            outputURL: outputURL,
            markdown: extracted.markdown
        )
    }

    static func scratchDirectory(
        for context: BrowserCaptureContext,
        applicationSupportURL: URL? = nil,
        fileManager: FileManager = .default
    ) throws -> URL {
        if let projectPath = context.projectPath?.trimmingCharacters(in: .whitespacesAndNewlines),
           !projectPath.isEmpty {
            return URL(fileURLWithPath: projectPath, isDirectory: true)
                .appendingPathComponent(".pnevma", isDirectory: true)
                .appendingPathComponent("data", isDirectory: true)
                .appendingPathComponent("browser-captures", isDirectory: true)
        }

        guard let baseURL = applicationSupportURL
            ?? fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            throw BrowserCaptureError.applicationSupportDirectoryUnavailable
        }

        return baseURL
            .appendingPathComponent("Pnevma", isDirectory: true)
            .appendingPathComponent("BrowserCaptures", isDirectory: true)
            .appendingPathComponent(context.workspaceID.uuidString, isDirectory: true)
    }

    static func deterministicFilename(title: String, sourceURL: URL?) -> String {
        let slugSource = preferredSlugSource(title: title, sourceURL: sourceURL)
        let slug = sanitizeFilenameComponent(slugSource)
        let hashInput = sourceURL?.absoluteString ?? slugSource
        let digest = SHA256.hash(data: Data(hashInput.utf8))
        let shortHash = digest.prefix(4).map { String(format: "%02x", $0) }.joined()
        return "\(slug)-\(shortHash).md"
    }

    static func markdownLinkList(for links: [BrowserPageLink]) -> String {
        links.map { link in
            let trimmedText = link.text.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmedText.isEmpty {
                return "- <\(link.url.absoluteString)>"
            }
            return "- [\(trimmedText)](\(link.url.absoluteString))"
        }
        .joined(separator: "\n")
    }

    static func filteredLinks(from payloads: [BrowserPageLinkPayload]) -> [BrowserPageLink] {
        var seenURLs = Set<String>()
        return payloads.compactMap { payload in
            let trimmedURL = payload.url.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let url = URL(string: trimmedURL),
                  let scheme = url.scheme?.lowercased(),
                  supportedLinkSchemes.contains(scheme),
                  seenURLs.insert(url.absoluteString).inserted else {
                return nil
            }

            return BrowserPageLink(
                text: payload.text.trimmingCharacters(in: .whitespacesAndNewlines),
                url: url
            )
        }
    }

    @MainActor
    private static func extractPageLinks(from webView: WKWebView) async throws -> [BrowserPageLink] {
        let result = try await webView.evaluateJavaScript(
            """
            (function() {
                const anchors = Array.from(document.querySelectorAll('a[href]'));
                const links = anchors.map((anchor) => {
                    const rawHref = (anchor.getAttribute('href') || '').trim();
                    if (!rawHref) {
                        return null;
                    }

                    try {
                        const resolved = new URL(rawHref, document.baseURI).toString();
                        const text = String(anchor.innerText || anchor.textContent || '')
                            .replace(/\\s+/g, ' ')
                            .trim();
                        return { text: text, url: resolved };
                    } catch (_) {
                        return null;
                    }
                }).filter(Boolean);
                return JSON.stringify(links);
            })()
            """
        )

        guard let rawJSON = result as? String,
              let data = rawJSON.data(using: .utf8),
              let payloads = try? JSONDecoder().decode([BrowserPageLinkPayload].self, from: data) else {
            throw BrowserCaptureError.invalidLinkPayload
        }

        return filteredLinks(from: payloads)
    }

    private static func copyPlainText(_ text: String, to pasteboard: NSPasteboard) {
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

    private static func preferredSlugSource(title: String, sourceURL: URL?) -> String {
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedTitle.isEmpty {
            return trimmedTitle
        }

        guard let sourceURL else {
            return "page"
        }

        var components: [String] = []
        if let host = sourceURL.host(percentEncoded: false), !host.isEmpty {
            components.append(host)
        }

        let pathComponent = sourceURL.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if !pathComponent.isEmpty {
            components.append(pathComponent.replacingOccurrences(of: "/", with: "-"))
        }

        return components.isEmpty ? "page" : components.joined(separator: "-")
    }

    private static func sanitizeFilenameComponent(_ value: String) -> String {
        let normalized = value
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .lowercased()
        let parts = normalized
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
        let slug = parts.joined(separator: "-")
        let trimmed = slug.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        guard !trimmed.isEmpty else {
            return "page"
        }
        return String(trimmed.prefix(72))
    }
}
