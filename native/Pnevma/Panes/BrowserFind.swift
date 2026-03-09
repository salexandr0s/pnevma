import SwiftUI
import Observation
import WebKit

// MARK: - BrowserFindJavaScript

enum BrowserFindJavaScript {
    /// Inject find-in-page search. Returns match count.
    static func search(in webView: WKWebView, query: String) async -> Int {
        let escaped = query
            .replacing("\\", with: "\\\\")
            .replacing("'", with: "\\'")
            .replacing("\n", with: "\\n")
            .replacing("\r", with: "\\r")
            .replacing("\u{2028}", with: "\\u2028")
            .replacing("\u{2029}", with: "\\u2029")

        let js = """
        (function() {
            // Remove existing highlights
            document.querySelectorAll('mark.__pnevma-find').forEach(function(m) {
                var parent = m.parentNode;
                parent.replaceChild(document.createTextNode(m.textContent), m);
                parent.normalize();
            });

            var query = '\(escaped)'.toLowerCase();
            if (!query) return JSON.stringify({total: 0, current: 0});

            var walker = document.createTreeWalker(
                document.body,
                NodeFilter.SHOW_TEXT,
                null,
                false
            );
            var matches = [];
            var node;
            while (node = walker.nextNode()) {
                var text = node.textContent.toLowerCase();
                var idx = 0;
                while ((idx = text.indexOf(query, idx)) !== -1) {
                    matches.push({node: node, index: idx});
                    idx += query.length;
                }
            }

            // Wrap matches in <mark> elements (reverse order to preserve indices)
            var processed = new Set();
            for (var i = matches.length - 1; i >= 0; i--) {
                var m = matches[i];
                if (processed.has(m.node)) continue;
                processed.add(m.node);

                var parent = m.node.parentNode;
                var text = m.node.textContent;
                var frag = document.createDocumentFragment();
                var lastIdx = 0;

                // Find all matches in this text node
                var lowerText = text.toLowerCase();
                var nodeIdx = 0;
                while ((nodeIdx = lowerText.indexOf(query, nodeIdx)) !== -1) {
                    if (nodeIdx > lastIdx) {
                        frag.appendChild(document.createTextNode(text.substring(lastIdx, nodeIdx)));
                    }
                    var mark = document.createElement('mark');
                    mark.className = '__pnevma-find';
                    mark.textContent = text.substring(nodeIdx, nodeIdx + query.length);
                    frag.appendChild(mark);
                    lastIdx = nodeIdx + query.length;
                    nodeIdx += query.length;
                }
                if (lastIdx < text.length) {
                    frag.appendChild(document.createTextNode(text.substring(lastIdx)));
                }
                parent.replaceChild(frag, m.node);
            }

            var allMarks = document.querySelectorAll('mark.__pnevma-find');
            if (allMarks.length > 0) {
                allMarks[0].classList.add('__pnevma-find-current');
                allMarks[0].scrollIntoView({behavior: 'smooth', block: 'center'});
            }

            // Inject highlight styles if not present
            if (!document.getElementById('__pnevma-find-style')) {
                var style = document.createElement('style');
                style.id = '__pnevma-find-style';
                style.textContent = 'mark.__pnevma-find { background: #ffd54f; color: #000; border-radius: 2px; } mark.__pnevma-find.__pnevma-find-current { background: #ff9800; }';
                document.head.appendChild(style);
            }

            return JSON.stringify({total: allMarks.length, current: allMarks.length > 0 ? 1 : 0});
        })()
        """

        do {
            let result = try await webView.evaluateJavaScript(js)
            if let jsonStr = result as? String,
               let data = jsonStr.data(using: .utf8),
               let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Int] {
                return dict["total"] ?? 0
            }
        } catch {}
        return 0
    }

    /// Navigate to next/previous match. Returns {current, total}.
    static func navigate(in webView: WKWebView, forward: Bool) async -> (current: Int, total: Int) {
        let direction = forward ? "1" : "-1"
        let js = """
        (function() {
            var marks = document.querySelectorAll('mark.__pnevma-find');
            if (marks.length === 0) return JSON.stringify({current: 0, total: 0});

            var currentIdx = -1;
            for (var i = 0; i < marks.length; i++) {
                if (marks[i].classList.contains('__pnevma-find-current')) {
                    currentIdx = i;
                    marks[i].classList.remove('__pnevma-find-current');
                    break;
                }
            }

            var dir = \(direction);
            var nextIdx = currentIdx + dir;
            if (nextIdx >= marks.length) nextIdx = 0;
            if (nextIdx < 0) nextIdx = marks.length - 1;

            marks[nextIdx].classList.add('__pnevma-find-current');
            marks[nextIdx].scrollIntoView({behavior: 'smooth', block: 'center'});

            return JSON.stringify({current: nextIdx + 1, total: marks.length});
        })()
        """

        do {
            let result = try await webView.evaluateJavaScript(js)
            if let jsonStr = result as? String,
               let data = jsonStr.data(using: .utf8),
               let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Int] {
                return (dict["current"] ?? 0, dict["total"] ?? 0)
            }
        } catch {}
        return (0, 0)
    }

    /// Remove all find highlights.
    static func clear(in webView: WKWebView) {
        let js = """
        (function() {
            document.querySelectorAll('mark.__pnevma-find').forEach(function(m) {
                var parent = m.parentNode;
                parent.replaceChild(document.createTextNode(m.textContent), m);
                parent.normalize();
            });
        })()
        """
        webView.evaluateJavaScript(js, completionHandler: nil)
    }
}

// MARK: - BrowserFindState

@Observable @MainActor
final class BrowserFindState {
    var needle: String = ""
    var currentMatch: Int = 0
    var totalMatches: Int = 0
}

// MARK: - BrowserFindOverlay

struct BrowserFindOverlay: View {
    @Bindable var state: BrowserFindState
    @Environment(GhosttyThemeProvider.self) var theme
    let webView: WKWebView
    let onClose: () -> Void

    @State private var searchTask: Task<Void, Never>?

    var body: some View {
        HStack(spacing: 6) {
            // Search field
            TextField("Find in page", text: $state.needle)
                .textFieldStyle(.plain)
                .font(.body)
                .frame(minWidth: 120)
                .onSubmit {
                    navigateNext()
                }
                .onChange(of: state.needle) { _, newValue in
                    performSearch(newValue)
                }

            // Match count
            if state.totalMatches > 0 || !state.needle.isEmpty {
                Text("\(state.currentMatch)/\(state.totalMatches)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }

            // Previous
            Button(action: { navigatePrev() }) {
                Image(systemName: "chevron.up")
                    .font(.caption.weight(.medium))
            }
            .buttonStyle(.plain)
            .disabled(state.totalMatches == 0)
            .accessibilityLabel("Previous match")

            // Next
            Button(action: { navigateNext() }) {
                Image(systemName: "chevron.down")
                    .font(.caption.weight(.medium))
            }
            .buttonStyle(.plain)
            .disabled(state.totalMatches == 0)
            .accessibilityLabel("Next match")

            // Close
            Button(action: {
                BrowserFindJavaScript.clear(in: webView)
                onClose()
            }) {
                Image(systemName: "xmark")
                    .font(.caption.weight(.medium))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Close find")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color(nsColor: theme.foregroundColor).opacity(0.06))
                .shadow(color: .black.opacity(0.15), radius: 4, y: 2)
        )
    }

    private func performSearch(_ query: String) {
        searchTask?.cancel()
        searchTask = Task { @MainActor in
            // Small debounce
            try? await Task.sleep(for: .milliseconds(100))
            guard !Task.isCancelled else { return }

            let total = await BrowserFindJavaScript.search(in: webView, query: query)
            state.totalMatches = total
            state.currentMatch = total > 0 ? 1 : 0
        }
    }

    private func navigateNext() {
        Task { @MainActor in
            let result = await BrowserFindJavaScript.navigate(in: webView, forward: true)
            state.currentMatch = result.current
            state.totalMatches = result.total
        }
    }

    private func navigatePrev() {
        Task { @MainActor in
            let result = await BrowserFindJavaScript.navigate(in: webView, forward: false)
            state.currentMatch = result.current
            state.totalMatches = result.total
        }
    }
}
