import SwiftUI
import Cocoa

// MARK: - Data Models

struct SearchResult: Identifiable, Decodable {
    let id: String
    let source: String
    let title: String
    let snippet: String
    let path: String?
    let taskId: String?
    let sessionId: String?
    let timestamp: String?

    // Display aliases
    var filePath: String? { path }
    var lineContent: String { snippet }
}

private struct SearchParams: Encodable {
    let query: String
    let limit: Int?
}

// MARK: - SearchView

struct SearchView: View {
    @StateObject private var viewModel = SearchViewModel()

    var body: some View {
        VStack(spacing: 0) {
            // Search bar
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("Search in project...", text: $viewModel.query)
                    .textFieldStyle(.plain)
                    .onSubmit { viewModel.search() }

                if viewModel.isSearching {
                    ProgressView()
                        .controlSize(.small)
                }

                if !viewModel.query.isEmpty {
                    Button(action: { viewModel.clear() }) {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(12)

            Divider()

            // Results
            if let statusMessage = viewModel.statusMessage {
                EmptyStateView(
                    icon: "doc.text.magnifyingglass",
                    title: statusMessage
                )
            } else if viewModel.results.isEmpty && !viewModel.query.isEmpty && !viewModel.isSearching {
                EmptyStateView(
                    icon: "magnifyingglass",
                    title: "No results",
                    message: "Try a different search term"
                )
            } else if viewModel.results.isEmpty {
                EmptyStateView(
                    icon: "doc.text.magnifyingglass",
                    title: "Search your project",
                    message: "Enter a query above to search across all files"
                )
            } else {
                List(viewModel.results) { result in
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 4) {
                            if let filePath = result.filePath {
                                Text(filePath)
                                    .font(.caption)
                                    .foregroundStyle(Color.accentColor)
                                    .lineLimit(1)
                            } else {
                                Text(result.title)
                                    .font(.caption)
                                    .foregroundStyle(Color.accentColor)
                                    .lineLimit(1)
                            }
                            Text("·")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Text(result.source)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Text(result.lineContent)
                            .font(.system(.body, design: .monospaced))
                            .textSelection(.enabled)
                            .lineLimit(1)
                    }
                    .padding(.vertical, 2)
                }
                .listStyle(.plain)
            }
        }
        .onAppear { viewModel.activate() }
    }
}

// MARK: - ViewModel

@MainActor
final class SearchViewModel: ObservableObject {
    private enum ViewState: Equatable {
        case waiting(String)
        case ready
        case failed(String)
    }

    @Published var query: String = ""
    @Published var results: [SearchResult] = []
    @Published var isSearching = false
    @Published private var viewState: ViewState = .waiting("Open a project to search.")

    private let commandBus: (any CommandCalling)?
    private let activationHub: ActiveWorkspaceActivationHub
    private var activationObserverID: UUID?
    private var searchTask: Task<Void, Never>?

    init(
        commandBus: (any CommandCalling)? = CommandBus.shared,
        activationHub: ActiveWorkspaceActivationHub = .shared
    ) {
        self.commandBus = commandBus
        self.activationHub = activationHub

        activationObserverID = activationHub.addObserver { [weak self] state in
            Task { @MainActor [weak self] in
                self?.handleActivationState(state)
            }
        }
    }

    deinit {
        if let activationObserverID {
            activationHub.removeObserver(activationObserverID)
        }
    }

    var statusMessage: String? {
        switch viewState {
        case .waiting(let message), .failed(let message):
            return message
        case .ready:
            return nil
        }
    }

    func activate() {
        handleActivationState(activationHub.currentState)
    }

    func search() {
        guard !query.isEmpty else { return }
        guard let bus = commandBus else {
            viewState = .failed("Search is unavailable because the command bus is not configured.")
            return
        }
        guard activationHub.currentState.isOpen else { return }
        isSearching = true
        let currentQuery = query
        searchTask?.cancel()
        searchTask = Task { [weak self] in
            guard let self else { return }
            do {
                let items: [SearchResult] = try await bus.call(
                    method: "project.search",
                    params: SearchParams(query: currentQuery, limit: nil)
                )
                guard !Task.isCancelled else { return }
                self.results = items
                self.isSearching = false
            } catch {
                guard !Task.isCancelled else { return }
                self.isSearching = false
                self.handleLoadFailure(error)
            }
        }
    }

    func clear() {
        query = ""
        results = []
    }

    private func handleActivationState(_ state: ActiveWorkspaceActivationState) {
        switch state {
        case .idle:
            viewState = .waiting("Waiting for project activation...")
        case .opening:
            viewState = .waiting("Waiting for project activation...")
        case .open:
            viewState = .ready
        case .failed(_, _, let message):
            viewState = .failed(message)
        case .closed:
            viewState = .waiting("Open a project to search.")
            results = []
        }
    }

    private func handleLoadFailure(_ error: Error) {
        if PnevmaError.isProjectNotReady(error) {
            viewState = .waiting("Waiting for project activation...")
            return
        }
        viewState = .failed(error.localizedDescription)
    }
}

// MARK: - NSView Wrapper

final class SearchPaneView: NSView, PaneContent {
    let paneID = PaneID()
    let paneType = "search"
    let shouldPersist = false
    var title: String { "Search" }

    override init(frame: NSRect) {
        super.init(frame: frame)
        _ = addSwiftUISubview(SearchView())
    }

    required init?(coder: NSCoder) { fatalError() }
}
