import Foundation
import Observation

// MARK: - RPC Response Types

private struct PrListItem: Decodable, Sendable {
    let id: String
    let number: Int64
    let title: String
    let sourceBranch: String
    let targetBranch: String
    let status: String
}

private struct GitHubIssueResult: Decodable, Sendable {
    let number: Int64
    let title: String
    let state: String
    let labels: [String]
    let author: String
}

@Observable
@MainActor
final class WorkspaceOpenerViewModel {
    // Tab state
    var selectedTab: WorkspaceOpenerTab = .prompt

    // Project picker
    var selectedProjectPath: String?
    var availableProjects: [ProjectEntry] = []

    // Prompt tab
    var promptText: String = ""
    var selectedAgentID: String?
    var showAdvancedOptions: Bool = false
    var terminalMode: WorkspaceTerminalMode = .persistent
    var sshEnabled: Bool = false
    var sshHost: String = ""
    var sshUser: String = ""
    var sshPort: String = "22"
    var sshRemotePath: String = "~"
    var workspaceNameOverride: String = ""

    // Issues tab
    var issueSearchText: String = ""
    var issues: [GitHubIssueItem] = []
    var selectedIssueNumber: Int64?
    var issuesAvailable: Bool = false
    var isLoadingIssues: Bool = false

    // Pull requests tab
    var prSearchText: String = ""
    var pullRequests: [PullRequestItem] = []
    var selectedPRNumber: Int64?
    var githubAvailable: Bool = false
    var isLoadingPRs: Bool = false

    // Branches tab
    var branchSearchText: String = ""
    var branches: [BranchItem] = []
    var selectedBranchName: String?
    var branchFilter: BranchFilter = .all
    var isLoadingBranches: Bool = false

    // Shared
    var isLoading: Bool = false
    var errorMessage: String?

    // Data loading tasks
    private var loadTask: Task<Void, Never>?

    var canSubmit: Bool {
        switch selectedTab {
        case .prompt:
            if sshEnabled {
                return !sshHost.isEmpty && !sshUser.isEmpty
            }
            return selectedProjectPath != nil
        case .issues:
            return selectedIssueNumber != nil && selectedProjectPath != nil
        case .pullRequests:
            return selectedPRNumber != nil && selectedProjectPath != nil
        case .branches:
            return selectedBranchName != nil && selectedProjectPath != nil
        }
    }

    var filteredIssues: [GitHubIssueItem] {
        guard !issueSearchText.isEmpty else { return issues }
        let query = issueSearchText.lowercased()
        return issues.filter {
            $0.title.lowercased().contains(query)
                || String($0.number).contains(query)
                || $0.author.lowercased().contains(query)
        }
    }

    var filteredPRs: [PullRequestItem] {
        guard !prSearchText.isEmpty else { return pullRequests }
        let query = prSearchText.lowercased()
        return pullRequests.filter {
            $0.title.lowercased().contains(query)
                || String($0.number).contains(query)
        }
    }

    var filteredBranches: [BranchItem] {
        var items = branches
        if branchFilter == .worktrees {
            items = items.filter { $0.hasWorktree }
        }
        guard !branchSearchText.isEmpty else { return items }
        let query = branchSearchText.lowercased()
        return items.filter { $0.name.lowercased().contains(query) }
    }

    func loadProjects(from workspaceManager: WorkspaceManager) {
        var seen = Set<String>()
        var entries: [ProjectEntry] = []
        for group in workspaceManager.projectGroups {
            for ws in group.workspaces {
                if let path = ws.projectPath, seen.insert(path).inserted {
                    let name = URL(fileURLWithPath: path).lastPathComponent
                    entries.append(ProjectEntry(path: path, name: name))
                }
            }
        }
        for ws in workspaceManager.pinnedWorkspaces {
            if let path = ws.projectPath, seen.insert(path).inserted {
                let name = URL(fileURLWithPath: path).lastPathComponent
                entries.append(ProjectEntry(path: path, name: name))
            }
        }
        availableProjects = entries.sorted {
            $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
        if selectedProjectPath == nil {
            selectedProjectPath = entries.first?.path
        }
    }

    func onProjectChanged(using bus: any CommandCalling) {
        loadTask?.cancel()
        loadTask = Task { [weak self] in
            guard let self else { return }
            await self.fetchBranches(using: bus)
            await self.fetchIssues(using: bus)
            await self.fetchPullRequests(using: bus)
        }
    }

    func fetchBranches(using bus: any CommandCalling) async {
        isLoadingBranches = true
        defer { isLoadingBranches = false }
        do {
            let names: [String] = try await bus.call(method: "git.list_branches")
            branches = names.map { name in
                BranchItem(
                    name: name,
                    isDefault: name == "main" || name == "master",
                    hasWorktree: false,
                    worktreePath: nil
                )
            }
        } catch {
            branches = []
        }
    }

    func fetchIssues(using bus: any CommandCalling) async {
        isLoadingIssues = true
        defer { isLoadingIssues = false }
        do {
            let result: [GitHubIssueResult] = try await bus.call(method: "project.list_issues")
            issues = result.map {
                GitHubIssueItem(
                    number: $0.number,
                    title: $0.title,
                    state: $0.state,
                    labels: $0.labels,
                    author: $0.author
                )
            }
            issuesAvailable = true
        } catch {
            issues = []
            issuesAvailable = false
        }
    }

    func fetchPullRequests(using bus: any CommandCalling) async {
        isLoadingPRs = true
        defer { isLoadingPRs = false }
        do {
            let result: [PrListItem] = try await bus.call(method: "project.list_prs")
            pullRequests = result.map {
                PullRequestItem(
                    number: $0.number,
                    title: $0.title,
                    sourceBranch: $0.sourceBranch,
                    targetBranch: $0.targetBranch,
                    status: $0.status
                )
            }
            githubAvailable = true
        } catch {
            pullRequests = []
            githubAvailable = false
        }
    }

    func reset() {
        promptText = ""
        selectedAgentID = nil
        showAdvancedOptions = false
        sshEnabled = false
        sshHost = ""
        sshUser = ""
        sshPort = "22"
        sshRemotePath = "~"
        workspaceNameOverride = ""
        issueSearchText = ""
        issues = []
        selectedIssueNumber = nil
        prSearchText = ""
        pullRequests = []
        selectedPRNumber = nil
        branchSearchText = ""
        branches = []
        selectedBranchName = nil
        errorMessage = nil
        isLoading = false
        loadTask?.cancel()
    }
}
