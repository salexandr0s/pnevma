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

enum WorkspaceLocalBindingRole: String, Codable {
    case base
    case worktree
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

    private enum CodingKeys: String, CodingKey {
        case sshProfileID = "ssh_profile_id"
        case sshProfileName = "ssh_profile_name"
        case host
        case port
        case user
        case identityFile = "identity_file"
        case proxyJump = "proxy_jump"
        case remotePath = "remote_path"
    }

    /// Whether the remote path contains only safe printable characters (no control chars).
    var isRemotePathSafe: Bool {
        !remotePath.isEmpty && remotePath.unicodeScalars.allSatisfy {
            !CharacterSet.controlCharacters.contains($0)
        }
    }

    var remoteShellCommand: String {
        // Validate remotePath contains only printable characters to prevent shell injection.
        guard isRemotePathSafe else {
            return "echo 'Error: remote path contains invalid characters'; exit 1"
        }
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
        let escaped = value.replacing("'", with: "'\\''")
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
    let backendPaneID: String?
    let agentTeamID: String?
    let agentTeamRole: String?
    let agentTeamMemberIndex: Int?

    private enum CodingKeys: String, CodingKey {
        case launchMode = "launch_mode"
        case startBehavior = "start_behavior"
        case remoteTarget = "remote_target"
        case backendPaneID = "backend_pane_id"
        case agentTeamID = "agent_team_id"
        case agentTeamRole = "agent_team_role"
        case agentTeamMemberIndex = "agent_team_member_index"
    }

    init(
        launchMode: TerminalLaunchMode,
        startBehavior: TerminalStartBehavior,
        remoteTarget: WorkspaceRemoteTarget?,
        backendPaneID: String? = nil,
        agentTeamID: String? = nil,
        agentTeamRole: String? = nil,
        agentTeamMemberIndex: Int? = nil
    ) {
        self.launchMode = launchMode
        self.startBehavior = startBehavior
        self.remoteTarget = remoteTarget
        self.backendPaneID = backendPaneID
        self.agentTeamID = agentTeamID
        self.agentTeamRole = agentTeamRole
        self.agentTeamMemberIndex = agentTeamMemberIndex
    }

    var shouldAutoStart: Bool {
        startBehavior == .immediate
    }

    func encodedJSON() -> String? {
        let encoder = JSONEncoder()
        guard let data = try? encoder.encode(self) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func from(json: String?) -> TerminalLaunchMetadata? {
        guard let json, let data = json.data(using: .utf8) else { return nil }
        let decoder = JSONDecoder()
        return try? decoder.decode(Self.self, from: data)
    }
}

struct TerminalPaneSeed {
    let workingDirectory: String?
    let sessionID: String?
    let taskID: String?
    let metadataJSON: String?
}

struct WorkspaceLaunchSource: Codable, Equatable, Sendable {
    let kind: String
    let number: Int64
    let title: String
    let url: String
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

    /// The two primary tabs shown in the inspector tab bar.
    static var tabBarCases: [RightInspectorSection] { [.changes, .files] }
}

/// A single tab within a workspace. Each tab has its own pane layout.
@MainActor
final class WorkspaceTab: Identifiable {
    nonisolated let id: UUID
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
            guard existingPane.type == "welcome" || existingPane.type == "terminal" else {
                return false
            }

            layoutEngine.upsertPersistedPane(
                PersistedPane(
                    paneID: rootPaneID,
                    type: "terminal",
                    workingDirectory: seed.workingDirectory ?? existingPane.workingDirectory,
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

    func paneID(
        matching match: (TerminalLaunchMetadata) -> Bool
    ) -> PaneID? {
        layoutEngine.root?.allPaneIDs.first { paneID in
            guard let metadata = TerminalLaunchMetadata.from(
                json: layoutEngine.persistedPane(for: paneID)?.metadataJSON
            ) else {
                return false
            }
            return match(metadata)
        }
    }
}

// MARK: - WorkspaceOperationalState

enum WorkspaceOperationalState: String, CaseIterable {
    case attention  // activationFailure, high unread count, stuck agent
    case active     // activeAgents > 0
    case review     // activeTasks > 0, no active agents
    case idle       // default

    var sortOrder: Int {
        switch self {
        case .attention: return 0
        case .active: return 1
        case .review: return 2
        case .idle: return 3
        }
    }

    var label: String {
        switch self {
        case .attention: return "Needs Attention"
        case .active: return "Active"
        case .review: return "In Review"
        case .idle: return "Idle"
        }
    }
}

/// A workspace represents an open project with its own tabs, terminal sessions,
/// and connection to the Rust backend (via a shared PnevmaBridge).
@Observable
@MainActor
final class Workspace: Identifiable {

    nonisolated let id: UUID
    var name: String
    var projectPath: String?
    var checkoutPath: String?
    var localBindingRole: WorkspaceLocalBindingRole?
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
    var browserDrawerHeight: Double?
    var launchSource: WorkspaceLaunchSource?

    /// Tabs within this workspace.
    var tabs: [WorkspaceTab]

    /// Index of the currently active tab.
    var activeTabIndex: Int = 0

    /// The active tab's pane layout engine.
    /// Both init paths guarantee at least one tab, so `tabs` is never empty.
    var layoutEngine: PaneLayoutEngine {
        precondition(!tabs.isEmpty, "Workspace must always have at least one tab")
        let clampedIndex = min(max(activeTabIndex, 0), tabs.count - 1)
        return tabs[clampedIndex].layoutEngine
    }

    /// When this workspace was created.
    let createdAt: Date

    init(
        id: UUID = UUID(),
        name: String,
        projectPath: String? = nil,
        checkoutPath: String? = nil,
        kind: WorkspaceKind = .terminal,
        location: WorkspaceLocation = .local,
        terminalMode: WorkspaceTerminalMode = .persistent,
        localBindingRole: WorkspaceLocalBindingRole? = nil,
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
        let resolvedCheckoutPath = checkoutPath ?? projectPath

        self.id = id
        self.name = name
        self.projectPath = projectPath
        self.checkoutPath = resolvedCheckoutPath
        self.localBindingRole = resolvedLocation == .local && resolvedKind == .project
            ? (localBindingRole ?? (resolvedCheckoutPath == projectPath ? .base : .worktree))
            : nil
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
        checkoutPath: String?,
        kind: WorkspaceKind,
        location: WorkspaceLocation,
        terminalMode: WorkspaceTerminalMode,
        localBindingRole: WorkspaceLocalBindingRole?,
        remoteTarget: WorkspaceRemoteTarget?,
        tabs: [WorkspaceTab],
        activeTabIndex: Int
    ) {
        let resolvedCheckoutPath = checkoutPath ?? projectPath
        self.id = id
        self.name = name
        self.projectPath = projectPath
        self.checkoutPath = resolvedCheckoutPath
        self.localBindingRole = location == .local && kind == .project
            ? (localBindingRole ?? (resolvedCheckoutPath == projectPath ? .base : .worktree))
            : nil
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

    // MARK: - Signal Pack Properties

    var diffInsertions: Int?
    var diffDeletions: Int?
    var linkedPRNumber: UInt64?
    var linkedPRURL: String?
    var ciStatus: String?
    var attentionReason: String?

    var operationalState: WorkspaceOperationalState {
        if activationFailureMessage != nil { return .attention }
        if attentionReason != nil { return .attention }
        if activeAgents > 0 { return .active }
        if activeTasks > 0 { return .review }
        return .idle
    }

    var projectRoot: String? {
        projectPath.map { URL(fileURLWithPath: $0).lastPathComponent }
            ?? remoteTarget?.remotePath
    }

    var activeProjectPath: String? {
        switch location {
        case .local:
            return checkoutPath ?? projectPath
        case .remote:
            return projectPath ?? remoteTarget?.remotePath
        }
    }

    var isPermanent: Bool {
        kind == .terminal
    }

    var displayPath: String? {
        switch location {
        case .local:
            return activeProjectPath
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
            return activeProjectPath ?? NSHomeDirectory()
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

    /// Rename a tab by index. Returns true if the title was accepted.
    @discardableResult
    func renameTab(at index: Int, to newTitle: String) -> Bool {
        guard index >= 0, index < tabs.count else { return false }
        let trimmed = newTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        tabs[index].title = trimmed
        return true
    }

    /// Rename a tab by ID. Returns true if the title was accepted.
    @discardableResult
    func renameTab(id: UUID, to newTitle: String) -> Bool {
        guard let index = tabs.firstIndex(where: { $0.id == id }) else { return false }
        return renameTab(at: index, to: newTitle)
    }

    @discardableResult
    func ensureActiveTabHasDisplayableRootPane(
        seed: TerminalPaneSeed? = nil
    ) -> Bool {
        ensureTabHasDisplayableRootPane(at: activeTabIndex, seed: seed)
    }

    @discardableResult
    func ensureTabHasDisplayableRootPane(
        at index: Int,
        seed: TerminalPaneSeed? = nil
    ) -> Bool {
        guard index >= 0, index < tabs.count else { return false }
        return tabs[index].ensureDisplayableRootPane(seed: seed ?? defaultTerminalSeed())
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

    func tabIndex(for tabID: UUID) -> Int? {
        tabs.firstIndex { $0.id == tabID }
    }

    func paneLocation(
        backendPaneID: String
    ) -> WorkspacePaneLocation? {
        for (tabIndex, tab) in tabs.enumerated() {
            if let paneID = tab.paneID(matching: { $0.backendPaneID == backendPaneID }) {
                return WorkspacePaneLocation(tabIndex: tabIndex, paneID: paneID)
            }
        }
        return nil
    }

    func agentTeamPaneLocation(
        teamID: String,
        role: String? = nil
    ) -> WorkspacePaneLocation? {
        for (tabIndex, tab) in tabs.enumerated() {
            if let paneID = tab.paneID(matching: { metadata in
                guard metadata.agentTeamID == teamID else { return false }
                return role == nil || metadata.agentTeamRole == role
            }) {
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
        let checkoutPath: String?
        let kind: WorkspaceKind?
        let location: WorkspaceLocation?
        let terminalMode: WorkspaceTerminalMode?
        let localBindingRole: WorkspaceLocalBindingRole?
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
        var browserDrawerHeight: Double?
        var launchSource: WorkspaceLaunchSource?
    }

    func snapshot() -> Snapshot {
        Snapshot(
            id: id,
            name: name,
            projectPath: projectPath,
            checkoutPath: checkoutPath,
            kind: kind,
            location: location,
            terminalMode: terminalMode,
            localBindingRole: localBindingRole,
            remoteTarget: remoteTarget,
            tabSnapshots: tabs.map { $0.snapshot() },
            activeTabIndex: activeTabIndex,
            layoutData: nil,
            customColor: customColor,
            isPinned: isPinned,
            rightInspectorSection: rightInspectorSection,
            browserLastURL: browserLastURL,
            browserDrawerHeight: nil,
            launchSource: launchSource
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
                checkoutPath: snapshot.checkoutPath ?? snapshot.projectPath,
                kind: resolvedKind,
                location: resolvedLocation,
                terminalMode: resolvedTerminalMode,
                localBindingRole: snapshot.localBindingRole,
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
                checkoutPath: snapshot.checkoutPath ?? snapshot.projectPath,
                kind: resolvedKind,
                location: resolvedLocation,
                terminalMode: resolvedTerminalMode,
                localBindingRole: snapshot.localBindingRole,
                remoteTarget: snapshot.remoteTarget,
                layoutEngine: restoredLayout
            )
        }
        self.customColor = snapshot.customColor
        self.isPinned = snapshot.isPinned ?? false
        self.rightInspectorSection = snapshot.rightInspectorSection ?? .files
        self.browserLastURL = snapshot.browserLastURL
        self.browserDrawerHeight = snapshot.browserDrawerHeight
        self.launchSource = snapshot.launchSource
    }
}
