import Foundation
import Observation

@Observable @MainActor
final class GhosttyThemeBrowserViewModel {
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

    var themes: [GhosttyThemeFile] = []
    var searchText = ""
    var filterMode: FilterMode = .all
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
