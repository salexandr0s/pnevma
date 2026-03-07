import SwiftUI
import Cocoa

// MARK: - Data Models

struct SearchResult: Identifiable, Codable {
    var id: String { "\(filePath):\(lineNumber)" }
    let filePath: String
    let lineNumber: Int
    let lineContent: String
    let matchRanges: [MatchRange]?
}

struct MatchRange: Codable {
    let start: Int
    let end: Int
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
            if viewModel.results.isEmpty && !viewModel.query.isEmpty && !viewModel.isSearching {
                Spacer()
                Text("No results")
                    .foregroundStyle(.secondary)
                Spacer()
            } else if viewModel.results.isEmpty {
                Spacer()
                VStack(spacing: 8) {
                    Image(systemName: "doc.text.magnifyingglass")
                        .font(.largeTitle)
                        .foregroundStyle(.secondary)
                    Text("Search your project")
                        .foregroundStyle(.secondary)
                }
                Spacer()
            } else {
                List(viewModel.results) { result in
                    VStack(alignment: .leading, spacing: 2) {
                        HStack {
                            Text(result.filePath)
                                .font(.caption)
                                .foregroundStyle(Color.accentColor)
                            Text(":\(result.lineNumber)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Text(result.lineContent)
                            .font(.system(.body, design: .monospaced))
                            .lineLimit(1)
                    }
                    .padding(.vertical, 2)
                }
                .listStyle(.plain)
            }
        }
    }
}

// MARK: - ViewModel

final class SearchViewModel: ObservableObject {
    @Published var query: String = ""
    @Published var results: [SearchResult] = []
    @Published var isSearching = false

    func search() {
        guard !query.isEmpty else { return }
        isSearching = true
        // pnevma_call("project.search", ...) → results
        isSearching = false
    }

    func clear() {
        query = ""
        results = []
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
