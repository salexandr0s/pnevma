import Foundation

enum WorkspaceOpenerLaunchContext: Equatable {
    case generic
    case project(path: String)

    var preferredProjectPath: String? {
        switch self {
        case .generic:
            return nil
        case .project(let path):
            return path
        }
    }
}

enum WorkspaceOpenerTab: String, CaseIterable, Identifiable {
    case prompt = "Prompt"
    case issues = "Issues"
    case pullRequests = "Pull Requests"
    case branches = "Branches"

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .prompt: "text.cursor"
        case .issues: "exclamationmark.bubble"
        case .pullRequests: "arrow.triangle.pull"
        case .branches: "arrow.triangle.branch"
        }
    }
}

struct ProjectEntry: Identifiable, Hashable {
    let path: String
    let name: String
    var id: String { path }
}

extension ProjectEntry {
    init(path: String) {
        self.init(path: path, name: URL(fileURLWithPath: path).lastPathComponent)
    }
}

struct BranchItem: Identifiable {
    let name: String
    let isDefault: Bool
    let hasWorktree: Bool
    let worktreePath: String?
    var id: String { name }
}

enum BranchFilter: String, CaseIterable {
    case all = "All"
    case worktrees = "Worktrees"
}

struct GitHubIssueItem: Identifiable {
    let number: Int64
    let title: String
    let state: String
    let labels: [String]
    let author: String
    var id: Int64 { number }
}

struct PullRequestItem: Identifiable {
    let number: Int64
    let title: String
    let sourceBranch: String
    let targetBranch: String
    let status: String
    var id: Int64 { number }
}

enum WorkspaceOpenerGitHubState: String, Decodable {
    case ready
    case missingGhCLI = "missing_gh_cli"
    case notAuthenticated = "not_authenticated"
    case noGitHubRemote = "no_github_remote"
    case noDefaultRepo = "no_default_repo"
    case notGitRepo = "not_git_repo"
    case error
}

struct WorkspaceOpenerGitHubStatus: Decodable {
    let state: WorkspaceOpenerGitHubState
    let message: String
    let detail: String?
    let resolvedRepo: String?
}

struct WorkspaceOpenerIssueLaunchParams: Encodable, Sendable {
    let path: String
    let issueNumber: Int64
    let createLinkedTaskWorktree: Bool
}

struct WorkspaceOpenerPullRequestLaunchParams: Encodable, Sendable {
    let path: String
    let prNumber: Int64
    let createLinkedTaskWorktree: Bool
}

struct WorkspaceOpenerLaunchResult: Decodable, Sendable {
    let projectPath: String
    let workspaceName: String
    let launchSource: WorkspaceLaunchSource
    let workingDirectory: String?
    let taskID: String?
    let branch: String?
}
