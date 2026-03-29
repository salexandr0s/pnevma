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

private struct BranchListItem: Decodable, Sendable {
    let name: String
    let hasWorktree: Bool
    let worktreePath: String?
}

private struct WorkspaceOpenerPathParams: Encodable, Sendable {
    let path: String
}

@Observable
@MainActor
final class WorkspaceOpenerViewModel {
    @ObservationIgnored
    private let bridgeEventHub: BridgeEventHub

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
    var createLinkedTaskWorktree: Bool = false

    // Pull requests tab
    var prSearchText: String = ""
    var pullRequests: [PullRequestItem] = []
    var selectedPRNumber: Int64?
    var isLoadingPRs: Bool = false

    // Branches tab
    var branchSearchText: String = ""
    var branches: [BranchItem] = []
    var selectedBranchName: String?
    var isCreatingNewBranch: Bool = false
    var newBranchName: String = ""
    var branchFilter: BranchFilter = .all
    var isLoadingBranches: Bool = false

    // Shared
    var isLoading: Bool = false
    var errorMessage: String?
    var gitHubStatus: WorkspaceOpenerGitHubStatus?
    var isLoadingGitHubStatus: Bool = false
    var isConnectingGitHub: Bool = false

    // Data loading tasks
    @ObservationIgnored
    private var loadTask: Task<Void, Never>?
    @ObservationIgnored
    private var bridgeObserverID: UUID?
    @ObservationIgnored
    private var commandBusForEvents: (any CommandCalling)?

    init(bridgeEventHub: BridgeEventHub = .shared) {
        self.bridgeEventHub = bridgeEventHub
        bridgeObserverID = bridgeEventHub.addObserver { [weak self] event in
            guard event.name == "github_auth_changed" else { return }
            self?.reloadGitHubFromEvent()
        }
    }

    deinit {
        MainActor.assumeIsolated {
            if let bridgeObserverID {
                bridgeEventHub.removeObserver(bridgeObserverID)
            }
        }
    }

    var promptHasText: Bool {
        !promptText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var promptEditorHeight: CGFloat {
        promptHasText ? 96 : 60
    }

    var preferredPanelSize: CGSize {
        WorkspaceOpenerPanelLayout.preferredSize(
            for: selectedTab,
            promptHasText: promptHasText,
            showAdvancedOptions: showAdvancedOptions,
            sshEnabled: sshEnabled,
            isCreatingNewBranch: isCreatingNewBranch,
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
            guard selectedProjectPath != nil else { return false }
            if isCreatingNewBranch {
                return !trimmedNewBranchName.isEmpty
            }
            return selectedBranchName != nil
        }
    }

    var submitButtonTitle: String {
        switch selectedTab {
        case .prompt, .issues, .pullRequests:
            return "Create Workspace"
        case .branches:
            if isCreatingNewBranch {
                return "Create and Checkout Branch"
            }
            guard let selectedBranch else {
                return "Open Branch Workspace"
            }
            return selectedBranch.hasWorktree
                ? "Open Branch Workspace"
                : "Checkout and Open Workspace"
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

    var selectedBranch: BranchItem? {
        guard let selectedBranchName else { return nil }
        return branches.first { $0.name == selectedBranchName }
    }

    var trimmedNewBranchName: String {
        newBranchName.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var issuesAvailable: Bool {
        gitHubStatus?.state == .ready
    }

    var githubAvailable: Bool {
        gitHubStatus?.state == .ready
    }

    var gitHubConnectionLabel: String? {
        gitHubStatus?.activeLogin.map { "@\($0)" }
    }

    var gitHubHelperWarning: String? {
        gitHubStatus?.gitHelperWarning?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var gitHubAuthJobRunning: Bool {
        gitHubStatus?.authJobState == "running"
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
        case .missingGhCLI, .notAuthenticated, .ready:
            return "Connect GitHub"
        case .noDefaultRepo:
            return "GitHub Unavailable"
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

        if gitHubStatus.authJobState == "running" {
            return "Finish GitHub sign-in in your browser. Pnevma refreshes automatically when it finishes."
        }

        if let detail = gitHubStatus.detail?.trimmingCharacters(in: .whitespacesAndNewlines),
           !detail.isEmpty {
            return "\(gitHubStatus.message)\n\(detail)"
        }

        return gitHubStatus.message
    }

    var gitHubActionTitle: String? {
        if gitHubAuthJobRunning {
            return nil
        }
        switch gitHubStatus?.state {
        case .missingGhCLI:
            return "Install GitHub CLI"
        case .notAuthenticated:
            return "Connect GitHub"
        case .noDefaultRepo:
            return "Refresh GitHub"
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
        commandBusForEvents = bus
        loadTask?.cancel()
        errorMessage = nil
        selectedBranchName = nil
        isCreatingNewBranch = false
        newBranchName = ""
        loadTask = Task { [weak self] in
            guard let self else { return }
            await self.fetchBranches(using: bus)
            if UITestFixtureData.isEnabled {
                self.gitHubStatus = UITestFixtureData.workspaceOpenerGitHubStatus
                self.issues = UITestFixtureData.workspaceOpenerIssues
                self.pullRequests = UITestFixtureData.workspaceOpenerPullRequests
                self.errorMessage = nil
                return
            }
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
            let items: [BranchListItem] = try await bus.call(
                method: "workspace_opener.list_branches",
                params: WorkspaceOpenerPathParams(path: selectedProjectPath)
            )
            let previousSelection = selectedBranchName
            branches = items.map { item in
                BranchItem(
                    name: item.name,
                    isDefault: item.name == "main" || item.name == "master",
                    hasWorktree: item.hasWorktree,
                    worktreePath: item.worktreePath
                )
            }
            if let previousSelection,
               branches.contains(where: { $0.name == previousSelection }) {
                selectedBranchName = previousSelection
            } else if !isCreatingNewBranch {
                selectedBranchName = nil
            }
            errorMessage = nil
        } catch {
            branches = []
            selectedBranchName = nil
            errorMessage = "Could not load branches: \(error.localizedDescription)"
        }
    }

    func refreshGitHubStatus(using bus: any CommandCalling) async {
        guard let selectedProjectPath else {
            gitHubStatus = nil
            return
        }

        if UITestFixtureData.isEnabled {
            _ = selectedProjectPath
            gitHubStatus = UITestFixtureData.workspaceOpenerGitHubStatus
            return
        }

        isLoadingGitHubStatus = true
        defer { isLoadingGitHubStatus = false }

        do {
            gitHubStatus = try await bus.call(
                method: "workspace_opener.github_status",
                params: WorkspaceOpenerPathParams(path: selectedProjectPath)
            )
            if gitHubStatus?.state == .ready {
                errorMessage = nil
            }
        } catch {
            gitHubStatus = WorkspaceOpenerGitHubStatus(
                state: .error,
                message: "Could not check GitHub status for this folder.",
                detail: error.localizedDescription,
                resolvedRepo: nil,
                activeLogin: nil,
                accountCount: nil,
                authJobState: nil,
                gitHelperWarning: nil
            )
        }
    }

    func fetchIssues(using bus: any CommandCalling) async {
        guard let selectedProjectPath, gitHubStatus?.state == .ready else {
            issues = []
            selectedIssueNumber = nil
            return
        }

        if UITestFixtureData.isEnabled {
            _ = selectedProjectPath
            issues = UITestFixtureData.workspaceOpenerIssues
            selectedIssueNumber = nil
            errorMessage = nil
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
            errorMessage = nil
        } catch {
            issues = []
            selectedIssueNumber = nil
            errorMessage = "Could not load GitHub issues: \(error.localizedDescription)"
        }
    }

    func fetchPullRequests(using bus: any CommandCalling) async {
        guard let selectedProjectPath, gitHubStatus?.state == .ready else {
            pullRequests = []
            selectedPRNumber = nil
            return
        }

        if UITestFixtureData.isEnabled {
            _ = selectedProjectPath
            pullRequests = UITestFixtureData.workspaceOpenerPullRequests
            selectedPRNumber = nil
            errorMessage = nil
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
            errorMessage = nil
        } catch {
            pullRequests = []
            selectedPRNumber = nil
            errorMessage = "Could not load pull requests: \(error.localizedDescription)"
        }
    }

    func connectGitHub(using bus: any CommandCalling) {
        guard selectedProjectPath != nil else { return }
        commandBusForEvents = bus

        loadTask?.cancel()
        loadTask = Task { [weak self] in
            guard let self else { return }
            await self.performGitHubConnect(using: bus)
        }
    }

    private func performGitHubConnect(using bus: any CommandCalling) async {
        guard let selectedProjectPath else { return }

        if UITestFixtureData.isEnabled {
            _ = selectedProjectPath
            gitHubStatus = UITestFixtureData.workspaceOpenerGitHubStatus
            issues = UITestFixtureData.workspaceOpenerIssues
            pullRequests = UITestFixtureData.workspaceOpenerPullRequests
            errorMessage = nil
            return
        }

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
                let _: GitHubAuthSnapshot = try await bus.call(method: "github.auth.add_account", params: nil)
                errorMessage = "Finish GitHub sign-in in your browser. Pnevma refreshes automatically when it finishes."
                await refreshGitHubStatus(using: bus)
            } catch {
                errorMessage = error.localizedDescription
            }

        case .noDefaultRepo, .noGitHubRemote, .notGitRepo, .error, .none:
            await refreshGitHubStatus(using: bus)
        }
    }

    func addGitHubAccount(using bus: any CommandCalling) {
        commandBusForEvents = bus
        Task {
            do {
                let _: GitHubAuthSnapshot = try await bus.call(method: "github.auth.add_account", params: nil)
                errorMessage = "Finish GitHub sign-in in your browser. Pnevma refreshes automatically when it finishes."
                await refreshGitHubStatus(using: bus)
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    func fixGitHubHelper(using bus: any CommandCalling) {
        commandBusForEvents = bus
        Task {
            do {
                let _: GitHubAuthSnapshot = try await bus.call(method: "github.auth.fix_git_helper", params: nil)
                await refreshGitHubStatus(using: bus)
                if gitHubStatus?.state == .ready {
                    await fetchIssues(using: bus)
                    await fetchPullRequests(using: bus)
                }
                errorMessage = nil
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func reloadGitHubFromEvent() {
        guard let bus = commandBusForEvents, selectedProjectPath != nil else { return }
        loadTask?.cancel()
        loadTask = Task { [weak self] in
            guard let self else { return }
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
        createLinkedTaskWorktree = false
        prSearchText = ""
        pullRequests = []
        selectedPRNumber = nil
        branchSearchText = ""
        branches = []
        selectedBranchName = nil
        isCreatingNewBranch = false
        newBranchName = ""
        gitHubStatus = nil
        isLoadingGitHubStatus = false
        isConnectingGitHub = false
        errorMessage = nil
        isLoading = false
        loadTask?.cancel()
    }

    func selectBranch(_ branchName: String) {
        selectedBranchName = branchName
        isCreatingNewBranch = false
        newBranchName = ""
    }

    func beginNewBranchCreation() {
        selectedBranchName = nil
        isCreatingNewBranch = true
    }

    func cancelNewBranchCreation() {
        isCreatingNewBranch = false
        newBranchName = ""
    }
}
