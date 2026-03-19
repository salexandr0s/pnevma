import AppKit
import Foundation
import Observation

// MARK: - RPC Response Types

private struct PrListItem: Decodable, Sendable {
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

private struct WorkspaceOpenerPathParams: Encodable, Sendable {
    let path: String
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
    var isLoadingIssues: Bool = false

    // Pull requests tab
    var prSearchText: String = ""
    var pullRequests: [PullRequestItem] = []
    var selectedPRNumber: Int64?
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
    var gitHubStatus: WorkspaceOpenerGitHubStatus?
    var isLoadingGitHubStatus: Bool = false
    var isConnectingGitHub: Bool = false

    // Data loading tasks
    private var loadTask: Task<Void, Never>?

    var preferredPanelSize: CGSize {
        WorkspaceOpenerPanelLayout.preferredSize(
            for: selectedTab,
            showAdvancedOptions: showAdvancedOptions,
            sshEnabled: sshEnabled,
            hasErrorMessage: errorMessage != nil
        )
    }

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

    var issuesAvailable: Bool {
        gitHubStatus?.state == .ready
    }

    var githubAvailable: Bool {
        gitHubStatus?.state == .ready
    }

    var gitHubEmptyStateIcon: String {
        switch gitHubStatus?.state {
        case .missingGhCLI:
            return "arrow.down.circle"
        case .noGitHubRemote:
            return "arrow.triangle.branch"
        case .notGitRepo:
            return "folder.badge.questionmark"
        case .notAuthenticated, .noDefaultRepo, .ready, .none:
            return "exclamationmark.bubble"
        case .error:
            return "exclamationmark.triangle"
        }
    }

    var gitHubEmptyStateTitle: String {
        switch gitHubStatus?.state {
        case .missingGhCLI, .notAuthenticated, .noDefaultRepo, .ready:
            return "Connect GitHub"
        case .noGitHubRemote:
            return "No GitHub Remote"
        case .notGitRepo:
            return "Not a Git Repository"
        case .error:
            return "GitHub Unavailable"
        case .none:
            return "Select a Project"
        }
    }

    var gitHubEmptyStateMessage: String {
        guard let gitHubStatus else {
            return "Select a project to browse issues and pull requests."
        }

        if let detail = gitHubStatus.detail?.trimmingCharacters(in: .whitespacesAndNewlines),
           !detail.isEmpty {
            return "\(gitHubStatus.message)\n\(detail)"
        }

        return gitHubStatus.message
    }

    var gitHubActionTitle: String? {
        switch gitHubStatus?.state {
        case .missingGhCLI:
            return "Install GitHub CLI"
        case .notAuthenticated, .noDefaultRepo:
            return "Connect GitHub"
        default:
            return nil
        }
    }

    func loadProjects(
        from workspaceManager: WorkspaceManager,
        preferredProjectPath: String? = nil
    ) {
        var seen = Set<String>()
        var entries: [ProjectEntry] = []
        for group in workspaceManager.projectGroups {
            for ws in group.workspaces {
                if let path = ws.projectPath, seen.insert(path).inserted {
                    entries.append(ProjectEntry(path: path))
                }
            }
        }
        for ws in workspaceManager.pinnedWorkspaces {
            if let path = ws.projectPath, seen.insert(path).inserted {
                entries.append(ProjectEntry(path: path))
            }
        }
        applyAvailableProjects(entries, preferredProjectPath: preferredProjectPath)
    }

    func applyAvailableProjects(
        _ entries: [ProjectEntry],
        preferredProjectPath: String? = nil
    ) {
        availableProjects = entries.sorted {
            $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
        if let preferredProjectPath,
           availableProjects.contains(where: { $0.path == preferredProjectPath }) {
            selectedProjectPath = preferredProjectPath
        } else {
            selectedProjectPath = nil
        }
    }

    func onProjectChanged(using bus: any CommandCalling) {
        loadTask?.cancel()
        loadTask = Task { [weak self] in
            guard let self else { return }
            await self.fetchBranches(using: bus)
            await self.refreshGitHubStatus(using: bus)
            guard self.gitHubStatus?.state == .ready else {
                self.issues = []
                self.pullRequests = []
                return
            }
            await self.fetchIssues(using: bus)
            await self.fetchPullRequests(using: bus)
        }
    }

    func fetchBranches(using bus: any CommandCalling) async {
        guard let selectedProjectPath else {
            branches = []
            selectedBranchName = nil
            return
        }

        isLoadingBranches = true
        defer { isLoadingBranches = false }
        do {
            let names: [String] = try await bus.call(
                method: "workspace_opener.list_branches",
                params: WorkspaceOpenerPathParams(path: selectedProjectPath)
            )
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

    func refreshGitHubStatus(using bus: any CommandCalling) async {
        guard let selectedProjectPath else {
            gitHubStatus = nil
            return
        }

        isLoadingGitHubStatus = true
        defer { isLoadingGitHubStatus = false }

        do {
            gitHubStatus = try await bus.call(
                method: "workspace_opener.github_status",
                params: WorkspaceOpenerPathParams(path: selectedProjectPath)
            )
        } catch {
            gitHubStatus = WorkspaceOpenerGitHubStatus(
                state: .error,
                message: "Could not check GitHub status for this folder.",
                detail: error.localizedDescription,
                resolvedRepo: nil
            )
        }
    }

    func fetchIssues(using bus: any CommandCalling) async {
        guard let selectedProjectPath, gitHubStatus?.state == .ready else {
            issues = []
            selectedIssueNumber = nil
            return
        }

        isLoadingIssues = true
        defer { isLoadingIssues = false }
        do {
            let result: [GitHubIssueResult] = try await bus.call(
                method: "workspace_opener.list_issues",
                params: WorkspaceOpenerPathParams(path: selectedProjectPath)
            )
            issues = result.map {
                GitHubIssueItem(
                    number: $0.number,
                    title: $0.title,
                    state: $0.state,
                    labels: $0.labels,
                    author: $0.author
                )
            }
        } catch {
            issues = []
            selectedIssueNumber = nil
            await refreshGitHubStatus(using: bus)
        }
    }

    func fetchPullRequests(using bus: any CommandCalling) async {
        guard let selectedProjectPath, gitHubStatus?.state == .ready else {
            pullRequests = []
            selectedPRNumber = nil
            return
        }

        isLoadingPRs = true
        defer { isLoadingPRs = false }
        do {
            let result: [PrListItem] = try await bus.call(
                method: "workspace_opener.list_prs",
                params: WorkspaceOpenerPathParams(path: selectedProjectPath)
            )
            pullRequests = result.map {
                PullRequestItem(
                    number: $0.number,
                    title: $0.title,
                    sourceBranch: $0.sourceBranch,
                    targetBranch: $0.targetBranch,
                    status: $0.status
                )
            }
        } catch {
            pullRequests = []
            selectedPRNumber = nil
            await refreshGitHubStatus(using: bus)
        }
    }

    func connectGitHub(using bus: any CommandCalling) {
        guard selectedProjectPath != nil else { return }

        loadTask?.cancel()
        loadTask = Task { [weak self] in
            guard let self else { return }
            await self.performGitHubConnect(using: bus)
        }
    }

    private func performGitHubConnect(using bus: any CommandCalling) async {
        guard let selectedProjectPath else { return }

        isConnectingGitHub = true
        defer { isConnectingGitHub = false }

        if gitHubStatus == nil {
            await refreshGitHubStatus(using: bus)
        }

        switch gitHubStatus?.state {
        case .ready:
            await fetchIssues(using: bus)
            await fetchPullRequests(using: bus)

        case .missingGhCLI:
            if let url = URL(string: "https://cli.github.com/") {
                NSWorkspace.shared.open(url)
            }

        case .notAuthenticated:
            do {
                try launchGitHubLogin(for: selectedProjectPath)
                errorMessage = "Complete GitHub login in Terminal, then press Connect GitHub again."
            } catch {
                errorMessage = error.localizedDescription
            }

        case .noDefaultRepo:
            do {
                gitHubStatus = try await bus.call(
                    method: "workspace_opener.github_connect",
                    params: WorkspaceOpenerPathParams(path: selectedProjectPath)
                )
                if gitHubStatus?.state == .ready {
                    await fetchIssues(using: bus)
                    await fetchPullRequests(using: bus)
                }
            } catch {
                errorMessage = error.localizedDescription
                await refreshGitHubStatus(using: bus)
            }

        case .noGitHubRemote, .notGitRepo, .error, .none:
            await refreshGitHubStatus(using: bus)
        }
    }

    private func launchGitHubLogin(for path: String) throws {
        let command = "cd -- \(shellEscaped(path)) && gh auth login --hostname github.com --web --git-protocol https"
        let script = """
        tell application "Terminal"
            activate
            do script "\(appleScriptEscaped(command))"
        end tell
        """

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", script]
        let stderr = Pipe()
        process.standardError = stderr
        try process.run()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            let errorOutput = String(data: stderr.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            throw NSError(
                domain: "WorkspaceOpenerGitHubLogin",
                code: Int(process.terminationStatus),
                userInfo: [
                    NSLocalizedDescriptionKey: errorOutput?.isEmpty == false
                        ? errorOutput!
                        : "Could not launch GitHub login in Terminal."
                ]
            )
        }
    }

    private func shellEscaped(_ value: String) -> String {
        guard !value.isEmpty else { return "''" }
        return "'\(value.replacing("'", with: "'\\''"))'"
    }

    private func appleScriptEscaped(_ value: String) -> String {
        value
            .replacing("\\", with: "\\\\")
            .replacing("\"", with: "\\\"")
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
        gitHubStatus = nil
        isLoadingGitHubStatus = false
        isConnectingGitHub = false
        errorMessage = nil
        isLoading = false
        loadTask?.cancel()
    }
}
