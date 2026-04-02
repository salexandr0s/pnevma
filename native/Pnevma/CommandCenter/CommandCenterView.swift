import Observation
import SwiftUI

struct CommandCenterView: View {
    @Bindable var store: CommandCenterStore
    let focusSearchField: () -> Void
    let isSearchFieldFocused: () -> Bool

    @State private var boardFocusToken = 0

    init(
        store: CommandCenterStore,
        focusSearchField: @escaping () -> Void = {},
        isSearchFieldFocused: @escaping () -> Bool = { false }
    ) {
        self.store = store
        self.focusSearchField = focusSearchField
        self.isSearchFieldFocused = isSearchFieldFocused
    }

    var body: some View {
        NavigationSplitView {
            CommandCenterSidebarView(
                store: store,
                onIncidentSelection: handleIncidentSelection,
                onWorkspaceSelection: handleWorkspaceSelection
            )
            .navigationSplitViewColumnWidth(min: 240, ideal: 258, max: 300)
        } content: {
            CommandCenterBoardView(
                store: store,
                boardFocusToken: boardFocusToken,
                onClearFilters: clearFiltersAndFocusBoard,
                onRunAction: { action, run in
                    store.performAction(action, on: run)
                },
                onPrimaryAction: { run in
                    store.performPrimaryAction(on: run)
                }
            )
            .navigationSplitViewColumnWidth(min: 560, ideal: 760)
        } detail: {
            detailPane
                .navigationSplitViewColumnWidth(min: 360, ideal: 390, max: 460)
        }
        .navigationSplitViewStyle(.balanced)
        .frame(minWidth: 1180, minHeight: 760)
        .background(ChromeSurfaceStyle.window.color)
        .background(commandShortcuts)
    }

    private var detailPane: some View {
        Group {
            if let run = store.selectedRun {
                CommandCenterInspectorView(run: run) { action in
                    store.performAction(action, on: run)
                }
            } else {
                ContentUnavailableView(
                    "Select a run",
                    systemImage: "cursorarrow.click",
                    description: Text("Choose a run from the board to inspect the session, files, review context, and recovery actions.")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(ChromeSurfaceStyle.inspector.color)
    }

    private var commandShortcuts: some View {
        Group {
            HiddenShortcutButton(title: "Focus search", key: "f", modifiers: [.command]) {
                focusSearchField()
            }
            HiddenShortcutButton(title: "Refresh command center", key: "r", modifiers: [.command]) {
                store.refreshNow()
            }
            HiddenShortcutButton(title: "All runs", key: "1", modifiers: [.command]) {
                handleFilterSelection(.all)
            }
            HiddenShortcutButton(title: "Attention runs", key: "2", modifiers: [.command]) {
                handleFilterSelection(.attention)
            }
            HiddenShortcutButton(title: "Active runs", key: "3", modifiers: [.command]) {
                handleFilterSelection(.active)
            }
            HiddenShortcutButton(title: "Queued runs", key: "4", modifiers: [.command]) {
                handleFilterSelection(.queued)
            }
            HiddenShortcutButton(title: "Review runs", key: "5", modifiers: [.command]) {
                handleFilterSelection(.review)
            }
            HiddenShortcutButton(title: "Failed runs", key: "6", modifiers: [.command]) {
                handleFilterSelection(.failed)
            }
            HiddenShortcutButton(title: "Idle runs", key: "7", modifiers: [.command]) {
                handleFilterSelection(.idle)
            }
            HiddenShortcutButton(title: "Attention queue", key: "a", modifiers: [.command, .shift]) {
                store.focusAttentionQueue()
                handOffToBoard()
            }
            HiddenShortcutButton(title: "Clear search or filters", key: .escape, modifiers: []) {
                handleEscapeShortcut()
            }
            HiddenShortcutButton(title: "Open selected run", key: .return, modifiers: []) {
                handleReturnShortcut()
            }
            HiddenShortcutButton(title: "Open terminal", key: "t", modifiers: [.command, .option]) {
                store.performSelectedAction(.openTerminal)
            }
            HiddenShortcutButton(title: "Open replay", key: "r", modifiers: [.command, .option]) {
                store.performSelectedAction(.openReplay)
            }
            HiddenShortcutButton(title: "Open diff", key: "d", modifiers: [.command, .option]) {
                store.performSelectedAction(.openDiff)
            }
            HiddenShortcutButton(title: "Open review", key: "v", modifiers: [.command, .option]) {
                store.performSelectedAction(.openReview)
            }
            HiddenShortcutButton(title: "Open files", key: "f", modifiers: [.command, .option]) {
                store.performSelectedAction(.openFiles)
            }
            HiddenShortcutButton(title: "Restart session", key: "s", modifiers: [.command, .option]) {
                store.performSelectedAction(.restartSession)
            }
            HiddenShortcutButton(title: "Kill session", key: "k", modifiers: [.command, .option]) {
                store.performSelectedAction(.killSession)
            }
            HiddenShortcutButton(title: "Reattach session", key: "e", modifiers: [.command, .option]) {
                store.performSelectedAction(.reattachSession)
            }
        }
    }

    private func handleReturnShortcut() {
        if isSearchFieldFocused() {
            store.selectFirstRun()
            handOffToBoard()
            return
        }

        guard let selectedRun = store.selectedRun else { return }
        store.performPrimaryAction(on: selectedRun)
    }

    private func handleEscapeShortcut() {
        let hadSearch = !store.searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let hadConstraints = store.hasActiveConstraints
        store.clearSearchOrFilters()
        if hadSearch || hadConstraints {
            handOffToBoard()
        }
    }

    private func handleFilterSelection(_ filter: CommandCenterStore.Filter) {
        store.filter = filter
        handOffToBoard()
    }

    private func handleWorkspaceSelection(_ workspaceID: UUID?) {
        store.selectWorkspace(workspaceID)
        handOffToBoard()
    }

    private func handleIncidentSelection(_ incident: CommandCenterIncident) {
        store.focusIncident(incident)
        handOffToBoard()
    }

    private func clearFiltersAndFocusBoard() {
        store.clearFilters()
        handOffToBoard()
    }

    private func handOffToBoard() {
        boardFocusToken &+= 1
    }
}

struct HiddenShortcutButton: View {
    let title: String
    let key: KeyEquivalent
    let modifiers: EventModifiers
    let action: () -> Void

    init(title: String, key: String, modifiers: EventModifiers, action: @escaping () -> Void) {
        self.title = title
        self.key = KeyEquivalent(Character(key))
        self.modifiers = modifiers
        self.action = action
    }

    init(title: String, key: KeyEquivalent, modifiers: EventModifiers, action: @escaping () -> Void) {
        self.title = title
        self.key = key
        self.modifiers = modifiers
        self.action = action
    }

    var body: some View {
        Button(title, action: action)
            .keyboardShortcut(key, modifiers: modifiers)
            .opacity(0.001)
            .frame(width: 0, height: 0)
    }
}
