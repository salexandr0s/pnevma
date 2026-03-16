import Foundation

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
