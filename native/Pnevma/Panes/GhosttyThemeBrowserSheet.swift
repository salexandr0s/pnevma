import SwiftUI

struct GhosttyThemeBrowserSheet: View {
    @State private var browser = GhosttyThemeBrowserViewModel()
    let currentThemeName: String?
    let onApply: (String) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            themeGrid
            Divider()
            bottomBar
        }
        .frame(minWidth: 700, minHeight: 500)
        .task {
            browser.currentThemeName = currentThemeName
            browser.loadThemes()
        }
    }

    private var toolbar: some View {
        HStack(spacing: DesignTokens.Spacing.sm) {
            TextField("Search themes\u{2026}", text: $browser.searchText)
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 280)

            Picker("Filter", selection: $browser.filterMode) {
                ForEach(GhosttyThemeBrowserViewModel.FilterMode.allCases) { mode in
                    Text(mode.title).tag(mode)
                }
            }
            .labelsHidden()
            .pickerStyle(.segmented)
            .frame(width: 180)

            Spacer()

            Text("\(browser.filteredThemes.count) themes")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, DesignTokens.Spacing.md)
        .padding(.vertical, DesignTokens.Spacing.sm)
    }

    private var themeGrid: some View {
        Group {
            if browser.filteredThemes.isEmpty {
                EmptyStateView(
                    icon: "magnifyingglass",
                    title: "No Matching Themes",
                    message: "Try a different search term or filter."
                )
            } else {
                ScrollView {
                    LazyVGrid(
                        columns: [GridItem(.adaptive(minimum: 200, maximum: 280))],
                        spacing: DesignTokens.Spacing.md
                    ) {
                        ForEach(browser.filteredThemes) { theme in
                            ThemeCard(
                                theme: theme,
                                isActive: theme.name == browser.currentThemeName
                            )
                            .accessibilityAddTraits(.isButton)
                            .accessibilityLabel("Select theme: \(theme.name)")
                            .onTapGesture {
                                browser.currentThemeName = theme.name
                                onApply(theme.name)
                            }
                        }
                    }
                    .padding(DesignTokens.Spacing.md)
                }
            }
        }
    }

    private var bottomBar: some View {
        HStack {
            Spacer()
            Button("Done") { dismiss() }
                .keyboardShortcut(.cancelAction)
        }
        .padding(.horizontal, DesignTokens.Spacing.md)
        .padding(.vertical, DesignTokens.Spacing.sm)
    }
}

private struct ThemeCard: View {
    let theme: GhosttyThemeFile
    let isActive: Bool
    @State private var isHovering = false

    private var bgColor: Color {
        Color(nsColor: NSColor(hexString: theme.background) ?? .black)
    }

    private var fgColor: Color {
        Color(nsColor: NSColor(hexString: theme.foreground) ?? .white)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            terminalPreview
            paletteStrip
            nameBar
        }
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(isActive ? Color.accentColor : Color.secondary.opacity(isHovering ? 0.5 : 0.2), lineWidth: isActive ? 2 : 1)
        )
        .onHover { isHovering = $0 }
    }

    private var terminalPreview: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("$ ls -la")
                .foregroundStyle(fgColor)
            HStack(spacing: 0) {
                Text("drwxr-xr-x  ")
                    .foregroundStyle(fgColor)
                Text("Documents")
                    .foregroundStyle(paletteColor(4, fallback: fgColor))
            }
            HStack(spacing: 0) {
                Text("-rw-r--r--  ")
                    .foregroundStyle(fgColor)
                Text("README.md")
                    .foregroundStyle(paletteColor(2, fallback: fgColor))
            }
        }
        .font(.system(size: 10, design: .monospaced))
        .padding(DesignTokens.Spacing.sm)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(bgColor)
    }

    private var paletteStrip: some View {
        HStack(spacing: 0) {
            ForEach(0..<16, id: \.self) { i in
                paletteColor(i, fallback: fgColor)
                    .frame(maxWidth: .infinity, minHeight: 6)
            }
        }
    }

    private var nameBar: some View {
        HStack(spacing: DesignTokens.Spacing.xs) {
            Text(theme.name)
                .font(.caption)
                .lineLimit(1)
                .truncationMode(.tail)

            if theme.source == .user {
                Text("User")
                    .font(.caption2)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 1)
                    .background(Capsule().fill(Color.secondary.opacity(0.2)))
            }

            Spacer()

            if isActive {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .font(.caption)
            }
        }
        .padding(.horizontal, DesignTokens.Spacing.sm)
        .padding(.vertical, 4)
        .background(Color(nsColor: .controlBackgroundColor))
    }

    private func paletteColor(_ index: Int, fallback: Color) -> Color {
        guard let hex = theme.palette[index],
              let nsColor = NSColor(hexString: hex) else { return fallback }
        return Color(nsColor: nsColor)
    }
}
