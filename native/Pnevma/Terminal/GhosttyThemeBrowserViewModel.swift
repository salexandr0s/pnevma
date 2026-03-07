import Foundation

@MainActor
class GhosttyThemeBrowserViewModel: ObservableObject {
    enum FilterMode: String, CaseIterable, Identifiable {
        case all, dark, light

        var id: String { rawValue }

        var title: String {
            switch self {
            case .all: return "All"
            case .dark: return "Dark"
            case .light: return "Light"
            }
        }
    }

    @Published var themes: [GhosttyThemeFile] = []
    @Published var searchText = ""
    @Published var filterMode: FilterMode = .all
    var currentThemeName: String?

    var filteredThemes: [GhosttyThemeFile] {
        themes.filter { theme in
            switch filterMode {
            case .all: break
            case .dark: guard theme.isDark else { return false }
            case .light: guard !theme.isDark else { return false }
            }

            let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
            if !query.isEmpty {
                return theme.name.localizedCaseInsensitiveContains(query)
            }
            return true
        }
    }

    func loadThemes() {
        themes = GhosttyThemeFile.loadAll()
    }
}
