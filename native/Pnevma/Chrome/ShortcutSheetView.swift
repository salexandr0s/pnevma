import SwiftUI

/// A grouped display of all keyboard shortcuts.
struct ShortcutSheetView: View {
    let shortcuts: [ShortcutGroup]
    let onDismiss: () -> Void

    @Environment(GhosttyThemeProvider.self) private var theme

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text("Keyboard Shortcuts")
                    .font(.headline)
                Spacer()
                Button("Dismiss", systemImage: "xmark.circle.fill", action: onDismiss)
                    .labelStyle(.iconOnly)
                    .foregroundStyle(.secondary)
                    .buttonStyle(.plain)
                    .keyboardShortcut(.cancelAction)
            }
            .padding(DesignTokens.Spacing.md)

            Divider()

            // Shortcut groups
            ScrollView {
                LazyVStack(alignment: .leading, spacing: DesignTokens.Spacing.md) {
                    ForEach(shortcuts) { group in
                        shortcutGroupView(group)
                    }
                }
                .padding(DesignTokens.Spacing.md)
            }
        }
        .frame(width: 480, height: 520)
        .accessibilityIdentifier("shortcutSheet")
    }

    private func shortcutGroupView(_ group: ShortcutGroup) -> some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.xs) {
            Text(group.title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.bottom, 2)

            ForEach(group.shortcuts) { shortcut in
                HStack {
                    Text(shortcut.label)
                        .font(.body)
                    Spacer()
                    Text(shortcut.keys)
                        .font(.system(.body, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(
                            RoundedRectangle(cornerRadius: 4)
                                .fill(Color.secondary.opacity(DesignTokens.Opacity.subtle))
                        )
                }
                .padding(.vertical, 2)
            }
        }
    }
}

// MARK: - Models

struct ShortcutGroup: Identifiable {
    let id = UUID()
    let title: String
    let shortcuts: [ShortcutEntry]
}

struct ShortcutEntry: Identifiable {
    let id = UUID()
    let label: String
    let keys: String
}

// MARK: - Default Shortcuts

extension ShortcutSheetView {
    static var defaultShortcuts: [ShortcutGroup] {
        [
            ShortcutGroup(title: "General", shortcuts: [
                ShortcutEntry(label: "Command Palette", keys: "⌘K"),
                ShortcutEntry(label: "Quick Open File", keys: "⌘P"),
                ShortcutEntry(label: "Show Shortcuts", keys: "⌘?"),
                ShortcutEntry(label: "Toggle Focus Mode", keys: "⇧⌘F"),
                ShortcutEntry(label: "Toggle Sidebar", keys: "⌘B"),
            ]),
            ShortcutGroup(title: "Workspaces", shortcuts: [
                ShortcutEntry(label: "New Workspace", keys: "⌘N"),
                ShortcutEntry(label: "Close Workspace", keys: "⌘W"),
                ShortcutEntry(label: "Navigate Back", keys: "⌘["),
                ShortcutEntry(label: "Navigate Forward", keys: "⌘]"),
                ShortcutEntry(label: "Next Workspace", keys: "⌃⇥"),
                ShortcutEntry(label: "Previous Workspace", keys: "⌃⇧⇥"),
            ]),
            ShortcutGroup(title: "Panes", shortcuts: [
                ShortcutEntry(label: "Split Horizontal", keys: "⌘D"),
                ShortcutEntry(label: "Split Vertical", keys: "⇧⌘D"),
                ShortcutEntry(label: "Close Pane", keys: "⇧⌘W"),
                ShortcutEntry(label: "Next Pane", keys: "⌥⌘→"),
                ShortcutEntry(label: "Previous Pane", keys: "⌥⌘←"),
            ]),
            ShortcutGroup(title: "Tabs", shortcuts: [
                ShortcutEntry(label: "New Tab", keys: "⌘T"),
                ShortcutEntry(label: "Close Tab", keys: "⌥⌘W"),
                ShortcutEntry(label: "Next Tab", keys: "⌘}"),
                ShortcutEntry(label: "Previous Tab", keys: "⌘{"),
            ]),
            ShortcutGroup(title: "Tools", shortcuts: [
                ShortcutEntry(label: "Toggle Tool Dock", keys: "⌘J"),
                ShortcutEntry(label: "Toggle Inspector", keys: "⌥⌘I"),
                ShortcutEntry(label: "Command Center", keys: "⇧⌘K"),
            ]),
        ]
    }
}
