import Foundation
import Observation

enum WorkspaceKind: String, Codable {
    case terminal
    case project
}

enum WorkspaceLocation: String, Codable {
    case local
    case remote
}

enum WorkspaceTerminalMode: String, Codable {
    case persistent
    case nonPersistent
}

struct WorkspaceRemoteTarget: Codable, Equatable {
    let sshProfileID: String
    let sshProfileName: String
    let host: String
    let port: Int
    let user: String
    let identityFile: String?
    let proxyJump: String?
    let remotePath: String

    var remoteShellCommand: String {
        let destination = "\(user)@\(host)"
        var args = ["ssh", "-p", String(port)]
        if let identityFile, !identityFile.isEmpty {
            args.append(contentsOf: ["-i", identityFile])
        }
        if let proxyJump, !proxyJump.isEmpty {
            args.append(contentsOf: ["-J", proxyJump])
        }
        args.append(destination)
        args.append("cd -- \(shellDirectoryExpression) && exec ${SHELL:-/bin/zsh} -l")
        return args.map(Self.shellEscapeArg).joined(separator: " ")
    }

    var shellDirectoryExpression: String {
        Self.shellDirectoryExpression(for: remotePath)
    }

    private static func shellDirectoryExpression(for value: String) -> String {
        if value == "~" {
            return "${HOME}"
        }
        if value.hasPrefix("~/") {
            let suffix = String(value.dropFirst(2))
            return suffix.isEmpty ? "${HOME}" : "${HOME}/\(shellEscapeArg(suffix))"
        }
        return shellEscapeArg(value)
    }

    private static func shellEscapeArg(_ value: String) -> String {
        guard !value.isEmpty else { return "''" }
        let escaped = value.replacingOccurrences(of: "'", with: "'\\''")
        return "'\(escaped)'"
    }
}

enum TerminalLaunchMode: String, Codable {
    case managedSession
    case localShell
    case remoteShell
}

enum TerminalStartBehavior: String, Codable {
    case immediate
    case deferUntilActivate
}

struct TerminalLaunchMetadata: Codable, Equatable {
    let launchMode: TerminalLaunchMode
    let startBehavior: TerminalStartBehavior
    let remoteTarget: WorkspaceRemoteTarget?

    var shouldAutoStart: Bool {
        startBehavior == .immediate
    }

    func encodedJSON() -> String? {
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        guard let data = try? encoder.encode(self) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func from(json: String?) -> TerminalLaunchMetadata? {
        guard let json, let data = json.data(using: .utf8) else { return nil }
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try? decoder.decode(Self.self, from: data)
    }
}

struct TerminalPaneSeed {
    let workingDirectory: String?
    let sessionID: String?
    let taskID: String?
    let metadataJSON: String?
}

struct WorkspacePaneLocation: Equatable {
    let tabIndex: Int
    let paneID: PaneID
}

enum RightInspectorSection: String, Codable, CaseIterable {
    case files
    case changes
    case review
    case mergeQueue

    var title: String {
        switch self {
        case .files: return "Files"
        case .changes: return "Changes"
        case .review: return "Review"
        case .mergeQueue: return "Merge"
        }
    }

    var icon: String {
        switch self {
        case .files: return "folder"
        case .changes: return "point.3.connected.trianglepath.dotted"
        case .review: return "checklist"
        case .mergeQueue: return "arrow.triangle.merge"
        }
    }
}

/// A single tab within a workspace. Each tab has its own pane layout.
final class WorkspaceTab: Identifiable {
    let id: UUID
    var title: String
    let layoutEngine: PaneLayoutEngine

    init(id: UUID = UUID(), title: String = "Terminal", layoutEngine: PaneLayoutEngine? = nil, rootPaneID: PaneID = PaneID()) {
        self.id = id
        self.title = title
        self.layoutEngine = layoutEngine ?? PaneLayoutEngine(rootPaneID: rootPaneID)
    }

    /// Ensure a brand-new single-pane tab can always be reconstructed.
    @discardableResult
    func ensureDisplayableRootPane(seed: TerminalPaneSeed) -> Bool {
        let rootPaneID: PaneID
        if let existingRootPaneID = layoutEngine.root?.allPaneIDs.first {
            rootPaneID = existingRootPaneID
            if layoutEngine.activePaneID == nil {
                layoutEngine.activePaneID = existingRootPaneID
            }
        } else {
            let newRootPaneID = PaneID()
            layoutEngine.root = .leaf(newRootPaneID)
            layoutEngine.activePaneID = newRootPaneID
            rootPaneID = newRootPaneID
        }

        let paneIDs = layoutEngine.root?.allPaneIDs ?? [rootPaneID]
        guard paneIDs.count == 1 else { return false }

        if let existingPane = layoutEngine.persistedPane(for: rootPaneID) {
            guard existingPane.type == "welcome" else {
                return false
            }

            layoutEngine.upsertPersistedPane(
                PersistedPane(
                    paneID: rootPaneID,
                    type: "terminal",
                    workingDirectory: seed.workingDirectory,
                    sessionID: existingPane.sessionID ?? seed.sessionID,
                    taskID: existingPane.taskID ?? seed.taskID,
                    metadataJSON: seed.metadataJSON ?? existingPane.metadataJSON
                )
            )
            return true
        }

        layoutEngine.upsertPersistedPane(
                PersistedPane(
                    paneID: rootPaneID,
                    type: "terminal",
                    workingDirectory: seed.workingDirectory,
                    sessionID: seed.sessionID,
                    taskID: seed.taskID,
                    metadataJSON: seed.metadataJSON
                )
        )
        return true
    }
}

extension WorkspaceTab {
    func firstPaneID(ofType paneType: String) -> PaneID? {
        layoutEngine.root?.allPaneIDs.first { paneID in
            layoutEngine.persistedPane(for: paneID)?.type == paneType
        }
    }
}

/// A workspace represents an open project with its own tabs, terminal sessions,
/// and connection to the Rust backend (via a shared PnevmaBridge).
@Observable
final class Workspace: Identifiable {

    let id: UUID
    var name: String
    var projectPath: String?
    let kind: WorkspaceKind
    let location: WorkspaceLocation
    let terminalMode: WorkspaceTerminalMode
    let remoteTarget: WorkspaceRemoteTarget?
    var gitBranch: String?
    var activeTasks: Int = 0
    var activeAgents: Int = 0
    var costToday: Double = 0.0
    var unreadNotifications: Int = 0
    var terminalNotificationCount: Int = 0
    var customColor: String?
    var isPinned: Bool = false
    var gitDirty: Bool = false
    var activationFailureMessage: String?
    var rightInspectorSection: RightInspectorSection = .files
    var browserLastURL: String?

    /// Tabs within this workspace.
    var tabs: [WorkspaceTab]

    /// Index of the currently active tab.
    var activeTabIndex: Int = 0

    /// The active tab's pane layout engine.
    var layoutEngine: PaneLayoutEngine {
        tabs[activeTabIndex].layoutEngine
    }

    /// When this workspace was created.
    let createdAt: Date

    init(
        id: UUID = UUID(),
        name: String,
        projectPath: String? = nil,
        kind: WorkspaceKind = .terminal,
        location: WorkspaceLocation = .local,
        terminalMode: WorkspaceTerminalMode = .persistent,
        remoteTarget: WorkspaceRemoteTarget? = nil,
        layoutEngine: PaneLayoutEngine? = nil,
        rootPaneID: PaneID = PaneID()
    ) {
        let resolvedKind: WorkspaceKind = {
            if projectPath != nil || remoteTarget != nil {
                return .project
            }
            return kind
        }()
        let resolvedLocation: WorkspaceLocation = remoteTarget == nil ? location : .remote

        self.id = id
        self.name = name
        self.projectPath = projectPath
        self.kind = resolvedKind
        self.location = resolvedLocation
        if resolvedKind == .terminal && projectPath == nil && remoteTarget == nil && terminalMode == .persistent {
            self.terminalMode = .nonPersistent
        } else {
            self.terminalMode = terminalMode
        }
        self.remoteTarget = remoteTarget
        let initialTab = WorkspaceTab(
            title: "Terminal",
            layoutEngine: layoutEngine,
            rootPaneID: rootPaneID
        )
        self.tabs = [initialTab]
        self.activeTabIndex = 0
        self.createdAt = Date.now
    }

    /// Initialize with pre-built tabs (used for restore).
    init(
        id: UUID,
        name: String,
        projectPath: String?,
        kind: WorkspaceKind,
        location: WorkspaceLocation,
        terminalMode: WorkspaceTerminalMode,
        remoteTarget: WorkspaceRemoteTarget?,
        tabs: [WorkspaceTab],
        activeTabIndex: Int
    ) {
        self.id = id
        self.name = name
        self.projectPath = projectPath
        self.kind = kind
        self.location = location
        if kind == .terminal && projectPath == nil && remoteTarget == nil && terminalMode == .persistent {
            self.terminalMode = .nonPersistent
        } else {
            self.terminalMode = terminalMode
        }
        self.remoteTarget = remoteTarget
        let resolvedTabs = tabs.isEmpty ? [WorkspaceTab(title: "Terminal")] : tabs
        self.tabs = resolvedTabs
        self.activeTabIndex = min(activeTabIndex, resolvedTabs.count - 1)
        self.createdAt = Date.now
    }

    var isPermanent: Bool {
        kind == .terminal
    }

    var displayPath: String? {
        switch location {
        case .local:
            return projectPath
        case .remote:
            return remoteTarget?.remotePath
        }
    }

    var supportsBackendProject: Bool {
        kind == .project
    }

    var supportsProjectTools: Bool {
        kind == .project
    }

    var showsProjectToolsInUI: Bool {
        kind == .project && activationFailureMessage == nil
    }

    var defaultWorkingDirectory: String? {
        switch location {
        case .local:
            return projectPath ?? NSHomeDirectory()
        case .remote:
            return nil
        }
    }

    func defaultTerminalMetadata(
        startBehavior: TerminalStartBehavior = .immediate
    ) -> TerminalLaunchMetadata {
        let launchMode: TerminalLaunchMode
        switch (location, terminalMode) {
        case (.remote, .nonPersistent):
            launchMode = .remoteShell
        case (.remote, .persistent):
            launchMode = .managedSession
        case (.local, .nonPersistent):
            launchMode = .localShell
        case (.local, .persistent):
            launchMode = .managedSession
        }

        return TerminalLaunchMetadata(
            launchMode: launchMode,
            startBehavior: startBehavior,
            remoteTarget: remoteTarget
        )
    }

    func defaultTerminalSeed(
        startBehavior: TerminalStartBehavior = .immediate
    ) -> TerminalPaneSeed {
        TerminalPaneSeed(
            workingDirectory: defaultWorkingDirectory,
            sessionID: nil,
            taskID: nil,
            metadataJSON: defaultTerminalMetadata(startBehavior: startBehavior).encodedJSON()
        )
    }

    // MARK: - Tab Operations

    /// Add a new tab and make it active. Returns the new tab.
    @discardableResult
    func addTab(title: String = "Terminal", rootPaneID: PaneID = PaneID()) -> WorkspaceTab {
        let tab = WorkspaceTab(title: title, rootPaneID: rootPaneID)
        tabs.append(tab)
        activeTabIndex = tabs.count - 1
        return tab
    }

    /// Close a tab by index. Returns true if the tab was closed.
    @discardableResult
    func closeTab(at index: Int) -> Bool {
        guard tabs.count > 1, index >= 0, index < tabs.count else { return false }
        tabs.remove(at: index)
        if activeTabIndex >= tabs.count {
            activeTabIndex = tabs.count - 1
        } else if activeTabIndex > index {
            activeTabIndex -= 1
        }
        return true
    }

    /// Close a tab by ID. Returns true if the tab was closed.
    @discardableResult
    func closeTab(id: UUID) -> Bool {
        guard let index = tabs.firstIndex(where: { $0.id == id }) else { return false }
        return closeTab(at: index)
    }

    /// Switch to tab at the given index.
    func switchToTab(_ index: Int) {
        guard index >= 0, index < tabs.count else { return }
        activeTabIndex = index
    }

    @discardableResult
    func ensureActiveTabHasDisplayableRootPane() -> Bool {
        ensureTabHasDisplayableRootPane(at: activeTabIndex)
    }

    @discardableResult
    func ensureTabHasDisplayableRootPane(at index: Int) -> Bool {
        guard index >= 0, index < tabs.count else { return false }
        return tabs[index].ensureDisplayableRootPane(seed: defaultTerminalSeed())
    }

    func activeTabPaneID(ofType paneType: String) -> PaneID? {
        guard activeTabIndex >= 0, activeTabIndex < tabs.count else { return nil }
        return tabs[activeTabIndex].firstPaneID(ofType: paneType)
    }

    func preferredPaneLocation(ofType paneType: String) -> WorkspacePaneLocation? {
        if let paneID = activeTabPaneID(ofType: paneType) {
            return WorkspacePaneLocation(tabIndex: activeTabIndex, paneID: paneID)
        }
        return firstPaneLocation(ofType: paneType)
    }

    func firstPaneLocation(ofType paneType: String) -> WorkspacePaneLocation? {
        for (tabIndex, tab) in tabs.enumerated() {
            if let paneID = tab.firstPaneID(ofType: paneType) {
                return WorkspacePaneLocation(tabIndex: tabIndex, paneID: paneID)
            }
        }
        return nil
    }
}

// MARK: - Codable serialization for persistence

extension WorkspaceTab {
    struct Snapshot: Codable {
        let id: UUID
        let title: String
        let layoutData: Data?
    }

    func snapshot() -> Snapshot {
        Snapshot(id: id, title: title, layoutData: layoutEngine.serialize())
    }

    convenience init(snapshot: Snapshot) {
        let engine = snapshot.layoutData.flatMap(PaneLayoutEngine.deserialize(from:))
        self.init(id: snapshot.id, title: snapshot.title, layoutEngine: engine)
    }
}

extension Workspace {
    struct Snapshot: Codable {
        let id: UUID
        let name: String
        let projectPath: String?
        let kind: WorkspaceKind?
        let location: WorkspaceLocation?
        let terminalMode: WorkspaceTerminalMode?
        let remoteTarget: WorkspaceRemoteTarget?
        // New: per-tab serialization
        var tabSnapshots: [WorkspaceTab.Snapshot]?
        var activeTabIndex: Int?
        // Legacy: single layout (pre-tabs). Kept for backward compat.
        let layoutData: Data?
        var customColor: String?
        var isPinned: Bool?
        var rightInspectorSection: RightInspectorSection?
        var browserLastURL: String?
    }

    func snapshot() -> Snapshot {
        Snapshot(
            id: id,
            name: name,
            projectPath: projectPath,
            kind: kind,
            location: location,
            terminalMode: terminalMode,
            remoteTarget: remoteTarget,
            tabSnapshots: tabs.map { $0.snapshot() },
            activeTabIndex: activeTabIndex,
            layoutData: nil,
            customColor: customColor,
            isPinned: isPinned,
            rightInspectorSection: rightInspectorSection,
            browserLastURL: browserLastURL
        )
    }

    convenience init(snapshot: Snapshot) {
        let hasProjectBinding = snapshot.projectPath != nil || snapshot.remoteTarget != nil
        let resolvedKind: WorkspaceKind = {
            if hasProjectBinding {
                return .project
            }
            return snapshot.kind ?? .terminal
        }()
        let resolvedLocation: WorkspaceLocation = snapshot.remoteTarget == nil
            ? (snapshot.location ?? .local)
            : .remote
        let resolvedTerminalMode = snapshot.terminalMode
            ?? (resolvedKind == .terminal ? .nonPersistent : .persistent)

        if let tabSnapshots = snapshot.tabSnapshots, !tabSnapshots.isEmpty {
            // New format: restore tabs
            let restoredTabs = tabSnapshots.map(WorkspaceTab.init(snapshot:))
            self.init(
                id: snapshot.id,
                name: snapshot.name,
                projectPath: snapshot.projectPath,
                kind: resolvedKind,
                location: resolvedLocation,
                terminalMode: resolvedTerminalMode,
                remoteTarget: snapshot.remoteTarget,
                tabs: restoredTabs,
                activeTabIndex: snapshot.activeTabIndex ?? 0
            )
        } else {
            // Legacy format: single layout -> single tab
            let restoredLayout = snapshot.layoutData.flatMap(PaneLayoutEngine.deserialize(from:))
            self.init(
                id: snapshot.id,
                name: snapshot.name,
                projectPath: snapshot.projectPath,
                kind: resolvedKind,
                location: resolvedLocation,
                terminalMode: resolvedTerminalMode,
                remoteTarget: snapshot.remoteTarget,
                layoutEngine: restoredLayout
            )
        }
        self.customColor = snapshot.customColor
        self.isPinned = snapshot.isPinned ?? false
        self.rightInspectorSection = snapshot.rightInspectorSection ?? .files
        self.browserLastURL = snapshot.browserLastURL
    }
}
