import AppKit
import SwiftUI

@MainActor
final class BrowserReaderFindController {
    private weak var textView: NSTextView?
    private weak var scrollView: NSScrollView?
    private var renderedContent = NSAttributedString(string: "")
    private var plainText = ""
    private var lastQuery = ""
    private var matchRanges: [NSRange] = []
    private var currentMatchIndex: Int?

    private let matchColor = NSColor.systemYellow.withAlphaComponent(0.45)
    private let currentMatchColor = NSColor.systemOrange.withAlphaComponent(0.7)

    var actions: BrowserFindActions {
        BrowserFindActions(
            search: { [weak self] query in
                self?.search(query: query) ?? 0
            },
            navigate: { [weak self] forward in
                self?.navigate(forward: forward) ?? (0, 0)
            },
            clear: { [weak self] in
                self?.clear()
            }
        )
    }

    func bind(textView: NSTextView, inside scrollView: NSScrollView) {
        self.textView = textView
        self.scrollView = scrollView

        if textView.string != renderedContent.string || textView.textStorage?.length != renderedContent.length {
            textView.textStorage?.setAttributedString(renderedContent)
        }

        resizeTextView()
        reapplyHighlights(scrollToCurrent: false)
    }

    func refreshLayout() {
        resizeTextView()
    }

    func updateMarkdown(_ markdown: String) {
        renderedContent = Self.renderMarkdown(markdown)
        plainText = renderedContent.string

        if let textView {
            textView.textStorage?.setAttributedString(renderedContent)
            resizeTextView()
        }

        if lastQuery.isEmpty {
            restoreRenderedContent()
        } else {
            _ = search(query: lastQuery)
        }
    }

    @discardableResult
    func search(query: String) -> Int {
        lastQuery = query
        matchRanges = []
        currentMatchIndex = nil
        restoreRenderedContent()

        guard !query.isEmpty else { return 0 }

        matchRanges = Self.matchRanges(in: plainText, query: query)
        if !matchRanges.isEmpty {
            currentMatchIndex = 0
        }
        reapplyHighlights()
        return matchRanges.count
    }

    func navigate(forward: Bool) -> (current: Int, total: Int) {
        guard !matchRanges.isEmpty else { return (0, 0) }

        let delta = forward ? 1 : -1
        let nextIndex = ((currentMatchIndex ?? 0) + delta + matchRanges.count) % matchRanges.count
        currentMatchIndex = nextIndex
        reapplyHighlights()
        return (nextIndex + 1, matchRanges.count)
    }

    func clear() {
        lastQuery = ""
        matchRanges = []
        currentMatchIndex = nil
        restoreRenderedContent()
    }

    private func restoreRenderedContent() {
        guard let textView, let textStorage = textView.textStorage else { return }
        textStorage.setAttributedString(renderedContent)
    }

    private func reapplyHighlights(scrollToCurrent: Bool = true) {
        guard let textView, let textStorage = textView.textStorage else { return }

        restoreRenderedContent()

        for (index, range) in matchRanges.enumerated() {
            let color = index == currentMatchIndex ? currentMatchColor : matchColor
            textStorage.addAttribute(.backgroundColor, value: color, range: range)
        }

        guard scrollToCurrent,
              let currentMatchIndex,
              matchRanges.indices.contains(currentMatchIndex) else { return }

        textView.scrollRangeToVisible(matchRanges[currentMatchIndex])
    }

    private func resizeTextView() {
        guard let textView,
              let scrollView,
              let textContainer = textView.textContainer,
              let layoutManager = textView.layoutManager else { return }

        let contentWidth = max(scrollView.contentSize.width, 320)
        textView.frame.size.width = contentWidth
        textContainer.containerSize = NSSize(
            width: max(0, contentWidth - (textView.textContainerInset.width * 2)),
            height: CGFloat.greatestFiniteMagnitude
        )

        layoutManager.ensureLayout(for: textContainer)
        let usedRect = layoutManager.usedRect(for: textContainer)
        let height = ceil(usedRect.height + textView.textContainerInset.height * 2)
        textView.frame = NSRect(
            origin: .zero,
            size: NSSize(width: contentWidth, height: max(scrollView.contentSize.height, height))
        )
    }

    private static func matchRanges(in text: String, query: String) -> [NSRange] {
        let source = text as NSString
        var searchRange = NSRange(location: 0, length: source.length)
        var ranges: [NSRange] = []

        while searchRange.length > 0 {
            let found = source.range(
                of: query,
                options: [.caseInsensitive, .diacriticInsensitive],
                range: searchRange
            )
            guard found.location != NSNotFound else { break }
            ranges.append(found)
            let nextLocation = found.location + max(found.length, 1)
            searchRange = NSRange(location: nextLocation, length: source.length - nextLocation)
        }

        return ranges
    }

    private static func renderMarkdown(_ markdown: String) -> NSAttributedString {
        let base: NSAttributedString
        if let attributed = try? AttributedString(
            markdown: markdown,
            options: .init(
                interpretedSyntax: .full,
                failurePolicy: .returnPartiallyParsedIfPossible
            )
        ) {
            base = NSAttributedString(attributed)
        } else {
            base = NSAttributedString(
                string: markdown,
                attributes: [.font: NSFont.systemFont(ofSize: NSFont.systemFontSize)]
            )
        }

        let rendered = NSMutableAttributedString(attributedString: base)
        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.lineSpacing = 4
        paragraphStyle.paragraphSpacing = 8
        rendered.addAttribute(
            .paragraphStyle,
            value: paragraphStyle,
            range: NSRange(location: 0, length: rendered.length)
        )
        return rendered
    }
}

struct BrowserReaderDocumentView: NSViewRepresentable {
    let markdown: String
    let searchController: BrowserReaderFindController

    final class Coordinator {
        var lastMarkdown: String?
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true

        let textView = NSTextView()
        textView.drawsBackground = false
        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = true
        textView.importsGraphics = false
        textView.allowsUndo = false
        textView.usesFindBar = false
        textView.minSize = .zero
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.textContainerInset = NSSize(width: 24, height: 24)
        textView.isHorizontallyResizable = false
        textView.isVerticallyResizable = true
        textView.autoresizingMask = []

        if let textContainer = textView.textContainer {
            textContainer.lineFragmentPadding = 0
            textContainer.containerSize = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
            textContainer.widthTracksTextView = true
        }

        scrollView.documentView = textView
        searchController.bind(textView: textView, inside: scrollView)
        searchController.updateMarkdown(markdown)
        context.coordinator.lastMarkdown = markdown
        return scrollView
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
        guard let textView = nsView.documentView as? NSTextView else { return }
        searchController.bind(textView: textView, inside: nsView)

        if context.coordinator.lastMarkdown != markdown {
            searchController.updateMarkdown(markdown)
            context.coordinator.lastMarkdown = markdown
        } else {
            searchController.refreshLayout()
        }
    }
}
