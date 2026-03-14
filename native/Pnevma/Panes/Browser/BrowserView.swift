import SwiftUI
import WebKit

// MARK: - BrowserView (SwiftUI)

struct BrowserView: View {
    @Bindable var session: BrowserWorkspaceSession
    @Environment(GhosttyThemeProvider.self) var theme
    @State private var readerState = BrowserReaderState()
    @State private var findState: BrowserFindState?
    @State private var readerFindController = BrowserReaderFindController()
    @State private var findTargetGeneration = 0

    var body: some View {
        VStack(spacing: 0) {
            // Omnibar chrome
            omnibar
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .background(Color.clear)

            // Progress bar
            if viewModel.isLoading {
                Rectangle()
                    .fill(Color.accentColor)
                    .containerRelativeFrame(.horizontal) { width, _ in
                        width * viewModel.estimatedProgress
                    }
                    .frame(height: 2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .animation(.easeInOut(duration: 0.2), value: viewModel.estimatedProgress)
            }

            Divider()

            // Web content, reader mode, or new tab page
            ZStack {
                if readerState.isActive, let result = readerState.result {
                    BrowserReaderModeView(
                        result: result,
                        searchController: readerFindController,
                        onClose: { readerState.isActive = false },
                        onCopyMarkdown: copyReaderMarkdown,
                        onSaveMarkdown: savePageAsMarkdown
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

                // Find overlay (centered)
                if let findState {
                    VStack {
                        BrowserFindOverlay(
                            state: findState,
                            actions: activeFindActions,
                            targetGeneration: findTargetGeneration,
                            currentGeneration: { findTargetGeneration },
                            onClose: closeFindOverlay
                        )
                        .id(findTargetGeneration)
                        .frame(width: 320)
                        .padding(.top, 8)
                        Spacer()
                    }
                }
            }
        }
        .background(Color.clear)
        .accessibilityIdentifier("pane.browser")
        .onAppear {
            viewModel.webView.onRequestPanelFocus = { [weak viewModel] in
                viewModel?.showSuggestions = false
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .browserToggleFind)) { _ in
            if findState == nil {
                findState = BrowserFindState()
            } else {
                closeFindOverlay()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .browserToggleReaderMode)) { _ in
            readerState.toggle(webView: viewModel.webView)
        }
        .onChange(of: viewModel.currentURL) { _, _ in
            if let findState {
                invalidateFindTarget()
                findState.totalMatches = 0
                findState.currentMatch = 0
                clearAllFindHighlights()
            }
        }
        .onChange(of: readerState.isActive) { _, _ in
            invalidateFindTarget()
            refreshFindResultsForCurrentTarget()
        }
    }

    private var viewModel: BrowserViewModel {
        session.viewModel
    }

    private var activeFindActions: BrowserFindActions {
        readerState.isActive ? readerFindController.actions : .webView(viewModel.webView)
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
            .accessibilityLabel("Go back")

            // Forward
            Button(action: { viewModel.goForward() }) {
                Image(systemName: "chevron.right")
                    .font(.system(size: 13, weight: .medium))
            }
            .buttonStyle(.plain)
            .disabled(!viewModel.canGoForward)
            .opacity(viewModel.canGoForward ? 1 : 0.4)
            .accessibilityLabel("Go forward")

            // Reload / Stop
            Button(action: { viewModel.reload() }) {
                Image(systemName: viewModel.isLoading ? "xmark" : "arrow.clockwise")
                    .font(.system(size: 12, weight: .medium))
            }
            .buttonStyle(.plain)
            .accessibilityLabel(viewModel.isLoading ? "Stop loading" : "Reload page")

            // Address bar pill
            ZStack {
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color(nsColor: theme.foregroundColor).opacity(0.06))
                    .frame(height: 28)

                OmnibarTextField(
                    text: Binding(
                        get: { viewModel.omnibarText },
                        set: { viewModel.omnibarText = $0 }
                    ),
                    focusToken: viewModel.omnibarFocusToken,
                    onCommit: {
                        viewModel.showSuggestions = false
                        viewModel.navigateSmart(viewModel.omnibarText)
                    },
                    onChange: { newValue in
                        viewModel.updateSuggestions(for: newValue)
                    }
                )
                .font(.body)
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
            .accessibilityLabel("Reader mode")

            Menu {
                Button("Copy Selection with Source URL", action: copySelectionWithSource)
                Button("Save Page as Markdown", action: savePageAsMarkdown)
                Button("Copy Page Link List", action: copyPageLinkList)
            } label: {
                Image(systemName: "square.and.arrow.down.on.square")
                    .font(.system(size: 12, weight: .medium))
            }
            .menuStyle(.borderlessButton)
            .disabled(!viewModel.shouldRenderWebView)
            .opacity(viewModel.shouldRenderWebView ? 1 : 0.4)
            .accessibilityLabel("Capture browser content")

            // Find
            Button(action: {
                NotificationCenter.default.post(name: .browserToggleFind, object: nil)
            }) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 12, weight: .medium))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Find in page")
            .keyboardShortcut("f", modifiers: .command)
        }
    }

    private func clearAllFindHighlights() {
        BrowserFindJavaScript.clear(in: viewModel.webView)
        readerFindController.clear()
    }

    private func closeFindOverlay() {
        invalidateFindTarget()
        clearAllFindHighlights()
        findState = nil
    }

    private func invalidateFindTarget() {
        findTargetGeneration &+= 1
    }

    private func refreshFindResultsForCurrentTarget() {
        guard let findState else {
            clearAllFindHighlights()
            return
        }

        clearAllFindHighlights()

        let query = findState.needle
        guard !query.isEmpty else {
            findState.totalMatches = 0
            findState.currentMatch = 0
            return
        }

        let actions = activeFindActions
        let generation = findTargetGeneration
        Task { @MainActor [findState] in
            let total = await actions.search(query)
            guard generation == findTargetGeneration else { return }
            guard self.findState === findState else { return }
            self.findState?.totalMatches = total
            self.findState?.currentMatch = total > 0 ? 1 : 0
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
                        .font(.callout)
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
                                    .font(.callout)
                                    .lineLimit(1)
                                Text(entry.url)
                                    .font(.caption2)
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

    private var recentHistory: [BrowserHistoryStore.Entry] {
        viewModel.recentHistory
    }

    private func copySelectionWithSource() {
        Task { @MainActor in
            do {
                let capture = try await session.copySelectionWithSource()
                ToastManager.shared.show(
                    "Copied selection with source from \(capture.sourceURL.host(percentEncoded: false) ?? capture.sourceURL.absoluteString)",
                    icon: "doc.on.doc",
                    style: .success
                )
            } catch {
                showCaptureError(error)
            }
        }
    }

    private func savePageAsMarkdown() {
        Task { @MainActor in
            do {
                let saved = try await session.savePageAsMarkdown(
                    extractedMarkdown: readerState.isActive ? readerState.result : nil
                )
                ToastManager.shared.show(
                    "Saved markdown to \(saved.outputURL.lastPathComponent)",
                    icon: "square.and.arrow.down",
                    style: .success
                )
            } catch {
                showCaptureError(error)
            }
        }
    }

    private func copyPageLinkList() {
        Task { @MainActor in
            do {
                let capture = try await session.copyPageLinkListAsMarkdown()
                ToastManager.shared.show(
                    "Copied \(capture.links.count) page links as markdown",
                    icon: "list.bullet.clipboard",
                    style: .success
                )
            } catch {
                showCaptureError(error)
            }
        }
    }

    private func copyReaderMarkdown() {
        guard let markdown = readerState.result?.markdown else {
            showCaptureError(BrowserCaptureError.noActivePage)
            return
        }

        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(markdown, forType: .string)
        ToastManager.shared.show(
            "Copied page markdown",
            icon: "doc.on.doc",
            style: .success
        )
    }

    private func showCaptureError(_ error: Error) {
        ToastManager.shared.show(
            error.localizedDescription,
            icon: "exclamationmark.triangle",
            style: .error
        )
    }

    private var newTabPage: some View {
        VStack(spacing: 20) {
            Spacer()

            Image(systemName: "globe")
                .font(.system(size: 48))
                .foregroundStyle(.secondary.opacity(0.3))
                .accessibilityHidden(true)

            Text("Search or enter a URL")
                .font(.body.weight(.medium))
                .foregroundStyle(.secondary)

            // Recent history
            if !recentHistory.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text("RECENT")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)

                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 140), spacing: 8)], spacing: 8) {
                        ForEach(recentHistory, id: \.url) { entry in
                            Button(action: {
                                if let url = URL(string: entry.url) {
                                    viewModel.navigate(to: url)
                                    viewModel.omnibarText = entry.url
                                }
                            }) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(entry.title)
                                        .font(.callout.weight(.medium))
                                        .lineLimit(1)
                                    Text(URL(string: entry.url)?.host(percentEncoded: false) ?? entry.url)
                                        .font(.caption2)
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
                            .accessibilityLabel("\(entry.title), \(URL(string: entry.url)?.host(percentEncoded: false) ?? entry.url)")
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
