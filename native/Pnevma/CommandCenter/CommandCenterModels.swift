import Foundation

struct CommandCenterSummary: Decodable {
    let activeCount: Int
    let queuedCount: Int
    let idleCount: Int
    let stuckCount: Int
    let reviewNeededCount: Int
    let failedCount: Int
    let retryingCount: Int
    let slotLimit: Int
    let slotInUse: Int
    let costTodayUsd: Double
}

struct CommandCenterRun: Decodable, Hashable {
    let id: String
    let taskID: String?
    let taskTitle: String?
    let taskStatus: String?
    let sessionID: String?
    let sessionName: String?
    let sessionStatus: String?
    let sessionHealth: String?
    let provider: String?
    let model: String?
    let agentProfile: String?
    let branch: String?
    let worktreeID: String?
    let primaryFilePath: String?
    let scopePaths: [String]
    let worktreePath: String?
    let state: String
    let attentionReason: String?
    let startedAt: Date
    let lastActivityAt: Date
    let retryCount: Int
    let retryAfter: Date?
    let costUsd: Double
    let tokensIn: Int
    let tokensOut: Int
    let availableActions: [String]

    private enum CodingKeys: String, CodingKey {
        case id
        case taskID
        case taskTitle
        case taskStatus
        case sessionID
        case sessionName
        case sessionStatus
        case sessionHealth
        case provider
        case model
        case agentProfile
        case branch
        case worktreeID
        case primaryFilePath
        case scopePaths
        case worktreePath
        case state
        case attentionReason
        case startedAt
        case lastActivityAt
        case retryCount
        case retryAfter
        case costUsd
        case tokensIn
        case tokensOut
        case availableActions
    }

    init(
        id: String,
        taskID: String?,
        taskTitle: String?,
        taskStatus: String?,
        sessionID: String?,
        sessionName: String?,
        sessionStatus: String?,
        sessionHealth: String?,
        provider: String?,
        model: String?,
        agentProfile: String?,
        branch: String?,
        worktreeID: String?,
        primaryFilePath: String?,
        scopePaths: [String],
        worktreePath: String?,
        state: String,
        attentionReason: String?,
        startedAt: Date,
        lastActivityAt: Date,
        retryCount: Int,
        retryAfter: Date?,
        costUsd: Double,
        tokensIn: Int,
        tokensOut: Int,
        availableActions: [String]
    ) {
        self.id = id
        self.taskID = taskID
        self.taskTitle = taskTitle
        self.taskStatus = taskStatus
        self.sessionID = sessionID
        self.sessionName = sessionName
        self.sessionStatus = sessionStatus
        self.sessionHealth = sessionHealth
        self.provider = provider
        self.model = model
        self.agentProfile = agentProfile
        self.branch = branch
        self.worktreeID = worktreeID
        self.primaryFilePath = primaryFilePath
        self.scopePaths = scopePaths
        self.worktreePath = worktreePath
        self.state = state
        self.attentionReason = attentionReason
        self.startedAt = startedAt
        self.lastActivityAt = lastActivityAt
        self.retryCount = retryCount
        self.retryAfter = retryAfter
        self.costUsd = costUsd
        self.tokensIn = tokensIn
        self.tokensOut = tokensOut
        self.availableActions = availableActions
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        taskID = try container.decodeIfPresent(String.self, forKey: .taskID)
        taskTitle = try container.decodeIfPresent(String.self, forKey: .taskTitle)
        taskStatus = try container.decodeIfPresent(String.self, forKey: .taskStatus)
        sessionID = try container.decodeIfPresent(String.self, forKey: .sessionID)
        sessionName = try container.decodeIfPresent(String.self, forKey: .sessionName)
        sessionStatus = try container.decodeIfPresent(String.self, forKey: .sessionStatus)
        sessionHealth = try container.decodeIfPresent(String.self, forKey: .sessionHealth)
        provider = try container.decodeIfPresent(String.self, forKey: .provider)
        model = try container.decodeIfPresent(String.self, forKey: .model)
        agentProfile = try container.decodeIfPresent(String.self, forKey: .agentProfile)
        branch = try container.decodeIfPresent(String.self, forKey: .branch)
        worktreeID = try container.decodeIfPresent(String.self, forKey: .worktreeID)
        primaryFilePath = try container.decodeIfPresent(String.self, forKey: .primaryFilePath)
        scopePaths = try container.decodeIfPresent([String].self, forKey: .scopePaths) ?? []
        worktreePath = try container.decodeIfPresent(String.self, forKey: .worktreePath)
        state = try container.decode(String.self, forKey: .state)
        attentionReason = try container.decodeIfPresent(String.self, forKey: .attentionReason)
        startedAt = try container.decode(Date.self, forKey: .startedAt)
        lastActivityAt = try container.decode(Date.self, forKey: .lastActivityAt)
        retryCount = try container.decode(Int.self, forKey: .retryCount)
        retryAfter = try container.decodeIfPresent(Date.self, forKey: .retryAfter)
        costUsd = try container.decode(Double.self, forKey: .costUsd)
        tokensIn = try container.decode(Int.self, forKey: .tokensIn)
        tokensOut = try container.decode(Int.self, forKey: .tokensOut)
        availableActions = try container.decodeIfPresent([String].self, forKey: .availableActions) ?? []
    }

    var relatedFilesPath: String? {
        primaryFilePath ?? scopePaths.first ?? worktreePath
    }
}

struct CommandCenterSnapshot: Decodable {
    let projectID: String
    let projectName: String
    let projectPath: String
    let generatedAt: Date
    let summary: CommandCenterSummary
    let runs: [CommandCenterRun]
}

enum CommandCenterAction: String, CaseIterable, Identifiable {
    case openTerminal = "open_terminal"
    case openReplay = "open_replay"
    case openDiff = "open_diff"
    case openReview = "open_review"
    case openFiles = "open_files"
    case killSession = "kill_session"
    case restartSession = "restart_session"
    case reattachSession = "reattach_session"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .openTerminal: return "Terminal"
        case .openReplay: return "Replay"
        case .openDiff: return "Diff"
        case .openReview: return "Review"
        case .openFiles: return "Files"
        case .killSession: return "Kill"
        case .restartSession: return "Restart"
        case .reattachSession: return "Reattach"
        }
    }

    var systemImage: String {
        switch self {
        case .openTerminal: return "terminal"
        case .openReplay: return "play.rectangle"
        case .openDiff: return "doc.text.magnifyingglass"
        case .openReview: return "checklist"
        case .openFiles: return "folder"
        case .killSession: return "xmark.circle"
        case .restartSession: return "arrow.clockwise"
        case .reattachSession: return "link"
        }
    }

    var isDestructive: Bool {
        self == .killSession
    }
}

struct CommandCenterFleetSummary {
    let workspaceCount: Int
    let activeCount: Int
    let queuedCount: Int
    let idleCount: Int
    let stuckCount: Int
    let reviewNeededCount: Int
    let failedCount: Int
    let retryingCount: Int
    let slotLimit: Int
    let slotInUse: Int
    let costTodayUsd: Double

    var attentionCount: Int {
        stuckCount + reviewNeededCount + failedCount + retryingCount
    }
}

struct CommandCenterFleetRun: Identifiable {
    let id: String
    let workspaceID: UUID
    let workspaceName: String
    let workspacePath: String
    let generatedAt: Date
    let run: CommandCenterRun

    var title: String {
        run.taskTitle ?? run.sessionName ?? run.sessionID ?? "Untitled Run"
    }

    var subtitle: String {
        var parts: [String] = []
        if let provider = run.provider {
            if let model = run.model, !model.isEmpty {
                parts.append("\(provider) / \(model)")
            } else {
                parts.append(provider)
            }
        }
        if let branch = run.branch, !branch.isEmpty {
            parts.append(branch)
        }
        if let profile = run.agentProfile, !profile.isEmpty {
            parts.append(profile)
        }
        return parts.joined(separator: " • ")
    }

    var availableActionEnums: [CommandCenterAction] {
        run.availableActions.compactMap(CommandCenterAction.init(rawValue:))
    }

    func preferredTerminalWorkingDirectory(fallback: String?) -> String? {
        run.worktreePath ?? fallback
    }
}

struct CommandCenterWorkspaceSnapshot: Identifiable {
    let id: UUID
    let workspaceName: String
    let workspacePath: String
    let snapshot: CommandCenterSnapshot?
    let errorMessage: String?

    var runs: [CommandCenterFleetRun] {
        guard let snapshot else { return [] }
        return snapshot.runs.map { run in
            CommandCenterFleetRun(
                id: "\(id.uuidString):\(run.id)",
                workspaceID: id,
                workspaceName: workspaceName,
                workspacePath: workspacePath,
                generatedAt: snapshot.generatedAt,
                run: run
            )
        }
    }
}

struct CommandCenterWorkspaceSection: Identifiable {
    let id: UUID
    let workspaceName: String
    let workspacePath: String
    let runs: [CommandCenterFleetRun]
    let errorMessage: String?
}

enum CommandCenterSeverity: Int, Comparable {
    case quiet = 0
    case active = 1
    case watch = 2
    case urgent = 3

    static func < (lhs: CommandCenterSeverity, rhs: CommandCenterSeverity) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

enum CommandCenterFleetHealth: Equatable {
    case healthy
    case degraded
    case interventionNeeded

    var title: String {
        switch self {
        case .healthy:
            return "Fleet healthy"
        case .degraded:
            return "Fleet needs watching"
        case .interventionNeeded:
            return "Fleet needs intervention"
        }
    }
}

enum CommandCenterBoardSectionKind: String, CaseIterable, Identifiable {
    case attention
    case active
    case queued
    case recent

    var id: String { rawValue }

    var title: String {
        switch self {
        case .attention: return "Attention now"
        case .active: return "Active runs"
        case .queued: return "Queued"
        case .recent: return "Recent / idle"
        }
    }

    var systemImage: String {
        switch self {
        case .attention: return "exclamationmark.triangle.fill"
        case .active: return "bolt.fill"
        case .queued: return "clock.arrow.circlepath"
        case .recent: return "moon.stars"
        }
    }
}

struct CommandCenterBoardSection: Identifiable {
    let kind: CommandCenterBoardSectionKind
    let runs: [CommandCenterFleetRun]

    var id: CommandCenterBoardSectionKind { kind }
}

enum CommandCenterIncidentKind: String, Identifiable, Equatable {
    case workspaceError
    case failed
    case stuck
    case review
    case retrying
    case idle
    case attention

    var id: String { rawValue }

    var systemImage: String {
        switch self {
        case .workspaceError: return "externaldrive.badge.exclamationmark"
        case .failed: return "xmark.octagon.fill"
        case .stuck: return "exclamationmark.triangle.fill"
        case .review: return "checklist"
        case .retrying: return "arrow.clockwise.circle.fill"
        case .idle: return "pause.circle.fill"
        case .attention: return "bell.badge.fill"
        }
    }
}

struct CommandCenterIncident: Identifiable {
    let kind: CommandCenterIncidentKind
    let title: String
    let summary: String
    let count: Int
    let severity: CommandCenterSeverity
    let oldestAt: Date?
    let workspaceIDs: [UUID]

    var id: String {
        "\(kind.rawValue)-\(workspaceIDs.map(\.uuidString).joined(separator: ":"))"
    }
}

struct CommandCenterWorkspaceCluster: Identifiable {
    let id: UUID
    let workspaceName: String
    let workspacePath: String
    let activeCount: Int
    let queuedCount: Int
    let idleCount: Int
    let attentionCount: Int
    let errorMessage: String?

    var totalCount: Int {
        activeCount + queuedCount + idleCount + attentionCount
    }

    var severity: CommandCenterSeverity {
        if errorMessage != nil || attentionCount > 0 {
            return .urgent
        }
        if activeCount > 0 || queuedCount > 0 {
            return .active
        }
        return .quiet
    }
}

struct CommandCenterTimelineEntry: Identifiable {
    let title: String
    let detail: String
    let timestamp: Date

    var id: String {
        "\(title)-\(timestamp.timeIntervalSinceReferenceDate)"
    }
}

extension CommandCenterAction {
    fileprivate func rank(for run: CommandCenterFleetRun) -> Int {
        switch run.normalizedState {
        case "review_needed":
            switch self {
            case .openReview: return 0
            case .openDiff: return 1
            case .openTerminal: return 2
            case .openFiles: return 3
            case .openReplay: return 4
            case .reattachSession: return 5
            case .restartSession: return 6
            case .killSession: return 7
            }
        case "failed":
            switch self {
            case .openReplay: return 0
            case .restartSession: return 1
            case .openTerminal: return 2
            case .openDiff: return 3
            case .openFiles: return 4
            case .openReview: return 5
            case .reattachSession: return 6
            case .killSession: return 7
            }
        case "stuck":
            switch self {
            case .openTerminal: return 0
            case .openReplay: return 1
            case .restartSession: return 2
            case .reattachSession: return 3
            case .openFiles: return 4
            case .openDiff: return 5
            case .openReview: return 6
            case .killSession: return 7
            }
        case "queued":
            switch self {
            case .openFiles: return 0
            case .openDiff: return 1
            case .openReview: return 2
            case .openTerminal: return 3
            case .openReplay: return 4
            case .restartSession: return 5
            case .reattachSession: return 6
            case .killSession: return 7
            }
        default:
            switch self {
            case .openTerminal: return 0
            case .openReplay: return 1
            case .openDiff: return 2
            case .openReview: return 3
            case .openFiles: return 4
            case .reattachSession: return 5
            case .restartSession: return 6
            case .killSession: return 7
            }
        }
    }
}

extension CommandCenterFleetRun {
    var normalizedState: String {
        run.state.lowercased()
    }

    var stateDisplayTitle: String {
        humanizeCommandCenterString(normalizedState) ?? normalizedState.capitalized
    }

    var humanizedAttentionReason: String? {
        humanizeCommandCenterString(run.attentionReason)
    }

    var taskStatusDisplay: String? {
        humanizeCommandCenterString(run.taskStatus)
    }

    var sessionHealthDisplay: String? {
        humanizeCommandCenterString(run.sessionHealth)
    }

    var needsAttention: Bool {
        if run.attentionReason != nil {
            return true
        }
        switch normalizedState {
        case "failed", "stuck", "review_needed", "retrying":
            return true
        default:
            return false
        }
    }

    var severity: CommandCenterSeverity {
        switch normalizedState {
        case "failed", "stuck":
            return .urgent
        case "review_needed", "retrying":
            return .watch
        case "running", "queued":
            return .active
        default:
            return run.attentionReason == nil ? .quiet : .watch
        }
    }

    var boardSectionKind: CommandCenterBoardSectionKind {
        if needsAttention {
            return .attention
        }
        switch normalizedState {
        case "running":
            return .active
        case "queued":
            return .queued
        default:
            return .recent
        }
    }

    var attentionSummary: String? {
        if let humanizedAttentionReason {
            return humanizedAttentionReason
        }
        switch normalizedState {
        case "failed":
            return "Run failed"
        case "stuck":
            return "Run appears stuck"
        case "review_needed":
            return "Waiting on manual review"
        case "retrying":
            return retryCountdownText ?? "Retrying automatically"
        case "idle":
            return "Run is idle"
        default:
            return nil
        }
    }

    var retryCountdownText: String? {
        guard let retryAfter = run.retryAfter else { return nil }
        return "Next retry \(retryAfter.formatted(date: .omitted, time: .shortened))"
    }

    var metadataBadges: [String] {
        var badges: [String] = []
        if let provider = run.provider, !provider.isEmpty {
            if let model = run.model, !model.isEmpty {
                badges.append("\(provider) / \(model)")
            } else {
                badges.append(provider)
            }
        }
        if let branch = run.branch, !branch.isEmpty {
            badges.append(branch)
        }
        if let sessionHealthDisplay, !sessionHealthDisplay.isEmpty {
            badges.append("Session \(sessionHealthDisplay)")
        }
        if let taskStatusDisplay, !taskStatusDisplay.isEmpty {
            badges.append(taskStatusDisplay)
        }
        if let profile = run.agentProfile, !profile.isEmpty {
            badges.append(profile)
        }
        if let worktreeID = run.worktreeID, !worktreeID.isEmpty {
            badges.append(worktreeID)
        }
        return badges
    }

    var relatedFileLabels: [String] {
        var seen: Set<String> = []
        let candidates: [String?] = [run.primaryFilePath]
            + run.scopePaths.prefix(2).map(Optional.some)
            + [run.worktreePath]
        return candidates.compactMap { path in
            guard let path, !path.isEmpty else { return nil }
            let label = URL(fileURLWithPath: path).lastPathComponent
            guard !label.isEmpty, seen.insert(label).inserted else { return nil }
            return label
        }
    }

    var orderedActions: [CommandCenterAction] {
        availableActionEnums.sorted { lhs, rhs in
            lhs.rank(for: self) < rhs.rank(for: self)
        }
    }

    var primaryAction: CommandCenterAction? {
        orderedActions.first
    }

    var quickActions: [CommandCenterAction] {
        Array(orderedActions.filter { !$0.isDestructive }.prefix(3))
    }

    var primaryActions: [CommandCenterAction] {
        orderedActions.filter { !$0.isDestructive }
    }

    var destructiveActions: [CommandCenterAction] {
        orderedActions.filter(\.isDestructive)
    }

    var timelineEntries: [CommandCenterTimelineEntry] {
        var entries: [CommandCenterTimelineEntry] = [
            CommandCenterTimelineEntry(
                title: "Started",
                detail: startedAtDescription,
                timestamp: run.startedAt
            ),
            CommandCenterTimelineEntry(
                title: "Last activity",
                detail: lastActivityDescription,
                timestamp: run.lastActivityAt
            ),
            CommandCenterTimelineEntry(
                title: "Snapshot refreshed",
                detail: generatedAt.formatted(date: .omitted, time: .shortened),
                timestamp: generatedAt
            ),
        ]

        if run.retryCount > 0 {
            entries.append(
                CommandCenterTimelineEntry(
                    title: "Retries",
                    detail: "\(run.retryCount) attempt\(run.retryCount == 1 ? "" : "s")",
                    timestamp: run.retryAfter ?? run.lastActivityAt
                )
            )
        }

        if let retryAfter = run.retryAfter {
            entries.append(
                CommandCenterTimelineEntry(
                    title: "Retry scheduled",
                    detail: retryAfter.formatted(date: .omitted, time: .shortened),
                    timestamp: retryAfter
                )
            )
        }

        if let attentionSummary {
            entries.append(
                CommandCenterTimelineEntry(
                    title: "Needs attention",
                    detail: attentionSummary,
                    timestamp: run.lastActivityAt
                )
            )
        }

        return entries.sorted { $0.timestamp > $1.timestamp }
    }

    private var startedAtDescription: String {
        run.startedAt.formatted(date: .abbreviated, time: .shortened)
    }

    private var lastActivityDescription: String {
        run.lastActivityAt.formatted(date: .abbreviated, time: .shortened)
    }
}

typealias CommandCenterRunRecord = CommandCenterFleetRun

private func humanizeCommandCenterString(_ raw: String?) -> String? {
    guard let raw,
          !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
        return nil
    }

    return raw
        .replacing("-", with: " ")
        .replacing("_", with: " ")
        .split(separator: " ")
        .map { component in
            let token = String(component)
            if token == token.uppercased() {
                return token
            }
            return token.prefix(1).uppercased() + token.dropFirst().lowercased()
        }
        .joined(separator: " ")
}
