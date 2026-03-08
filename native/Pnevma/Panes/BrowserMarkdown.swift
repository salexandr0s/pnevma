import SwiftUI
import WebKit

// MARK: - MarkdownResult

struct MarkdownResult {
    let title: String
    let markdown: String
    let url: URL?
    let excerpt: String?
}

// MARK: - BrowserMarkdownConverter

@MainActor
final class BrowserMarkdownConverter {

    /// Extract page content as markdown using injected Readability.js + Turndown.js
    static func extractMarkdown(from webView: WKWebView) async throws -> MarkdownResult {
        let url = webView.url

        // Inject Readability.js
        let readabilityJS = readabilityScript()
        try await webView.evaluateJavaScript(readabilityJS)

        // Extract article with Readability
        let extractJS = """
        (function() {
            try {
                var clone = document.cloneNode(true);
                var article = new Readability(clone).parse();
                if (article) {
                    return JSON.stringify({
                        title: article.title || '',
                        content: article.content || '',
                        excerpt: article.excerpt || '',
                        byline: article.byline || ''
                    });
                }
            } catch(e) {}
            // Fallback: use body content
            return JSON.stringify({
                title: document.title || '',
                content: document.body.innerHTML || '',
                excerpt: '',
                byline: ''
            });
        })()
        """

        let articleResult = try await webView.evaluateJavaScript(extractJS)
        guard let jsonStr = articleResult as? String,
              let data = jsonStr.data(using: .utf8),
              let article = try? JSONSerialization.jsonObject(with: data) as? [String: String] else {
            // Ultimate fallback: plain text
            let text = try await webView.evaluateJavaScript("document.body.innerText") as? String ?? ""
            return MarkdownResult(
                title: webView.title ?? "",
                markdown: text,
                url: url,
                excerpt: nil
            )
        }

        let htmlContent = article["content"] ?? ""
        let articleTitle = article["title"] ?? webView.title ?? ""
        let excerpt = article["excerpt"]

        // Inject Turndown.js and convert HTML to markdown
        let turndownJS = turndownScript()
        try await webView.evaluateJavaScript(turndownJS)

        let convertJS = """
        (function() {
            var td = new TurndownService({
                headingStyle: 'atx',
                codeBlockStyle: 'fenced',
                emDelimiter: '*',
                bulletListMarker: '-'
            });
            var html = \(escapeForJS(htmlContent));
            return td.turndown(html);
        })()
        """

        let markdownResult = try await webView.evaluateJavaScript(convertJS)
        let markdown = markdownResult as? String ?? htmlContent

        // Prepend title as H1
        var fullMarkdown = ""
        if !articleTitle.isEmpty {
            fullMarkdown += "# \(articleTitle)\n\n"
        }
        if let url {
            fullMarkdown += "Source: \(url.absoluteString)\n\n"
        }
        fullMarkdown += markdown

        return MarkdownResult(
            title: articleTitle,
            markdown: fullMarkdown,
            url: url,
            excerpt: excerpt
        )
    }

    /// Plain-text fallback extraction
    static func extractPlainText(from webView: WKWebView) async -> String {
        do {
            let text = try await webView.evaluateJavaScript("document.body.innerText") as? String
            return text ?? ""
        } catch {
            return ""
        }
    }

    private static func escapeForJS(_ str: String) -> String {
        let escaped = str
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "'", with: "\\'")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\r", with: "\\r")
            .replacingOccurrences(of: "\t", with: "\\t")
            .replacingOccurrences(of: "\u{2028}", with: "\\u2028")
            .replacingOccurrences(of: "\u{2029}", with: "\\u2029")
        return "'\(escaped)'"
    }

    // MARK: - Embedded JS Libraries

    /// Mozilla Readability.js — MIT License
    /// Minified version embedded as a string constant.
    /// If a bundled .js resource is available, load from there instead.
    private static func readabilityScript() -> String {
        // Try loading from bundle first
        if let url = Bundle.main.url(forResource: "readability.min", withExtension: "js"),
           let script = try? String(contentsOf: url, encoding: .utf8) {
            return script
        }
        // Inline fallback — simplified Readability implementation
        return readabilityFallback
    }

    /// Turndown HTML-to-Markdown — MIT License
    /// Minified version embedded as a string constant.
    private static func turndownScript() -> String {
        if let url = Bundle.main.url(forResource: "turndown.min", withExtension: "js"),
           let script = try? String(contentsOf: url, encoding: .utf8) {
            return script
        }
        // Inline fallback — simplified turndown
        return turndownFallback
    }

    // Simplified Readability fallback (extracts main content heuristically)
    private static let readabilityFallback = """
    if (typeof Readability === 'undefined') {
        var Readability = function(doc) {
            this.doc = doc;
        };
        Readability.prototype.parse = function() {
            var doc = this.doc;
            var title = doc.title || '';

            // Try to find article content
            var candidates = ['article', 'main', '[role="main"]', '.post-content', '.article-content', '.entry-content', '#content', '.content'];
            var content = null;
            for (var i = 0; i < candidates.length; i++) {
                content = doc.querySelector(candidates[i]);
                if (content) break;
            }
            if (!content) content = doc.body;

            // Remove script/style/nav/header/footer elements
            var removeSelectors = ['script', 'style', 'nav', 'header', 'footer', 'aside', '.sidebar', '.nav', '.menu', '.ad', '.advertisement', '[role="navigation"]', '[role="banner"]', '[role="contentinfo"]'];
            var clone = content.cloneNode(true);
            removeSelectors.forEach(function(sel) {
                clone.querySelectorAll(sel).forEach(function(el) { el.remove(); });
            });

            return {
                title: title,
                content: clone.innerHTML,
                excerpt: '',
                byline: ''
            };
        };
    }
    """

    // Simplified Turndown fallback (basic HTML to markdown conversion)
    private static let turndownFallback = """
    if (typeof TurndownService === 'undefined') {
        var TurndownService = function(options) {
            this.options = options || {};
        };
        TurndownService.prototype.turndown = function(html) {
            var div = document.createElement('div');
            div.innerHTML = html;
            return this._process(div);
        };
        TurndownService.prototype._process = function(el) {
            var result = '';
            for (var i = 0; i < el.childNodes.length; i++) {
                var node = el.childNodes[i];
                if (node.nodeType === 3) {
                    result += node.textContent;
                } else if (node.nodeType === 1) {
                    var tag = node.tagName.toLowerCase();
                    var inner = this._process(node);
                    switch(tag) {
                        case 'h1': result += '\\n# ' + inner.trim() + '\\n\\n'; break;
                        case 'h2': result += '\\n## ' + inner.trim() + '\\n\\n'; break;
                        case 'h3': result += '\\n### ' + inner.trim() + '\\n\\n'; break;
                        case 'h4': result += '\\n#### ' + inner.trim() + '\\n\\n'; break;
                        case 'h5': result += '\\n##### ' + inner.trim() + '\\n\\n'; break;
                        case 'h6': result += '\\n###### ' + inner.trim() + '\\n\\n'; break;
                        case 'p': result += '\\n' + inner.trim() + '\\n\\n'; break;
                        case 'br': result += '\\n'; break;
                        case 'strong': case 'b': result += '**' + inner + '**'; break;
                        case 'em': case 'i': result += '*' + inner + '*'; break;
                        case 'a':
                            var href = node.getAttribute('href') || '';
                            result += '[' + inner + '](' + href + ')';
                            break;
                        case 'img':
                            var src = node.getAttribute('src') || '';
                            var alt = node.getAttribute('alt') || '';
                            result += '![' + alt + '](' + src + ')';
                            break;
                        case 'code':
                            if (node.parentElement && (node.parentElement.tagName === 'PRE')) {
                                result += inner;
                            } else {
                                result += '`' + inner + '`';
                            }
                            break;
                        case 'pre':
                            result += '\\n```\\n' + inner.trim() + '\\n```\\n\\n';
                            break;
                        case 'blockquote':
                            result += '\\n' + inner.trim().split('\\n').map(function(l) { return '> ' + l; }).join('\\n') + '\\n\\n';
                            break;
                        case 'ul': case 'ol':
                            result += '\\n' + inner + '\\n';
                            break;
                        case 'li':
                            var prefix = (node.parentElement && node.parentElement.tagName === 'OL') ?
                                (Array.from(node.parentElement.children).indexOf(node) + 1) + '. ' : '- ';
                            result += prefix + inner.trim() + '\\n';
                            break;
                        case 'hr': result += '\\n---\\n\\n'; break;
                        case 'table': result += '\\n' + inner + '\\n'; break;
                        case 'tr': result += '| ' + inner + '\\n'; break;
                        case 'td': case 'th': result += inner.trim() + ' | '; break;
                        case 'div': case 'section': case 'article': case 'main':
                            result += inner;
                            break;
                        case 'script': case 'style': case 'nav': case 'footer': case 'header':
                            break;
                        default: result += inner; break;
                    }
                }
            }
            return result;
        };
    }
    """
}

// MARK: - BrowserReaderModeView

struct BrowserReaderModeView: View {
    let result: MarkdownResult
    let onClose: () -> Void
    let onCopyMarkdown: () -> Void
    let onSaveMarkdown: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            // Toolbar
            HStack(spacing: 8) {
                Button(action: onClose) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 16))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)

                Text("Reader Mode")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.secondary)

                Spacer()

                Button("Copy as Markdown", action: onCopyMarkdown)
                    .buttonStyle(.bordered)
                    .controlSize(.small)

                Button("Save as .md", action: onSaveMarkdown)
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(Color.clear)

            Divider()

            // Markdown content
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    Text(LocalizedStringKey(formatMarkdownForDisplay(result.markdown)))
                        .textSelection(.enabled)
                        .font(.system(size: 14, design: .default))
                        .lineSpacing(4)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(24)
                .frame(maxWidth: 720)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.clear)
        }
    }

    private func formatMarkdownForDisplay(_ md: String) -> String {
        // SwiftUI Text with LocalizedStringKey supports basic markdown
        md
    }
}

// MARK: - Reader Mode Integration

@MainActor
final class BrowserReaderState: ObservableObject {
    @Published var isActive: Bool = false
    @Published var result: MarkdownResult?
    @Published var isExtracting: Bool = false

    func toggle(webView: WKWebView) {
        if isActive {
            isActive = false
            result = nil
            return
        }

        isExtracting = true
        Task { @MainActor in
            do {
                let extracted = try await BrowserMarkdownConverter.extractMarkdown(from: webView)
                self.result = extracted
                self.isActive = true
            } catch {
                // Fallback to plain text
                let text = await BrowserMarkdownConverter.extractPlainText(from: webView)
                self.result = MarkdownResult(
                    title: webView.title ?? "Untitled",
                    markdown: text,
                    url: webView.url,
                    excerpt: nil
                )
                self.isActive = true
            }
            self.isExtracting = false
        }
    }

    func copyMarkdown() {
        guard let markdown = result?.markdown else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(markdown, forType: .string)
    }

    func saveMarkdown() {
        guard let markdown = result?.markdown else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.plainText]
        panel.nameFieldStringValue = sanitizeFilename(result?.title ?? "page") + ".md"
        panel.canCreateDirectories = true

        guard panel.runModal() == .OK, let url = panel.url else { return }
        try? markdown.write(to: url, atomically: true, encoding: .utf8)
    }

    private func sanitizeFilename(_ name: String) -> String {
        let invalid = CharacterSet(charactersIn: "/\\:*?\"<>|")
        return name.components(separatedBy: invalid).joined(separator: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .prefix(100)
            .description
    }
}
