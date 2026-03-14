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

typealias CommandCenterRunRecord = CommandCenterFleetRun
