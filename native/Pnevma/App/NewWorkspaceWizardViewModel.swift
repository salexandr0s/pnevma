import Foundation
import Observation

enum WorkspaceIntakeSource: String, CaseIterable, Identifiable {
    case localFolder = "Open Local Folder"
    case remoteSSH = "Open Remote SSH"
    case fromBranch = "Create from Branch"
    case fromPR = "From GitHub PR"
    case fromIssue = "From Issue URL"
    case importWorktree = "Import Worktree"

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .localFolder: return "folder"
        case .remoteSSH: return "network"
        case .fromBranch: return "arrow.triangle.branch"
        case .fromPR: return "arrow.triangle.pull"
        case .fromIssue: return "exclamationmark.bubble"
        case .importWorktree: return "tray.and.arrow.down"
        }
    }
}

// MARK: - RPC Response Types

private struct PRResolveResponse: Decodable {
    let number: UInt64?
    let title: String?
    let headRef: String?
    let baseRef: String?
    let url: String?
}

private struct IssueResolveResponse: Decodable {
    let number: UInt64?
    let title: String?
    let url: String?
}

private struct ResolveURLParams: Encodable {
    let url: String
}

@Observable
@MainActor
final class NewWorkspaceWizardViewModel {
    var selectedSource: WorkspaceIntakeSource = .localFolder
    var projectPath: String = ""
    var branchName: String = ""
    var prURL: String = ""
    var issueURL: String = ""
    var worktreePath: String = ""
    var terminalMode: WorkspaceTerminalMode = .persistent
    var isLoading = false
    var errorMessage: String?

    // SSH fields
    var sshProfileID: String = ""
    var sshHost: String = ""
    var sshUser: String = ""
    var sshPort: String = "22"
    var sshRemotePath: String = "~"

    // PR metadata (auto-filled)
    var prNumber: UInt64?
    var prTitle: String?
    var prHeadBranch: String?
    var prBaseBranch: String?

    // Issue metadata (auto-filled)
    var issueNumber: UInt64?
    var issueTitle: String?

    // Available branches for picker
    var availableBranches: [String] = []

    var canSubmit: Bool {
        switch selectedSource {
        case .localFolder:
            return !projectPath.isEmpty
        case .remoteSSH:
            return !sshHost.isEmpty && !sshUser.isEmpty
        case .fromBranch:
            return !projectPath.isEmpty && !branchName.isEmpty
        case .fromPR:
            return !prURL.isEmpty && prHeadBranch != nil
        case .fromIssue:
            return !issueURL.isEmpty
        case .importWorktree:
            return !worktreePath.isEmpty
        }
    }

    func reset() {
        projectPath = ""
        branchName = ""
        prURL = ""
        issueURL = ""
        worktreePath = ""
        errorMessage = nil
        prNumber = nil
        prTitle = nil
        prHeadBranch = nil
        prBaseBranch = nil
        issueNumber = nil
        issueTitle = nil
        isLoading = false
    }

    func fetchPRMetadata(using bus: any CommandCalling) async {
        guard !prURL.isEmpty else { return }
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }

        do {
            let result: PRResolveResponse = try await bus.call(
                method: "project.resolve_pr_url",
                params: ResolveURLParams(url: prURL)
            )
            prNumber = result.number
            prTitle = result.title
            prHeadBranch = result.headRef
            prBaseBranch = result.baseRef
        } catch {
            errorMessage = "Failed to resolve PR: \(error.localizedDescription)"
        }
    }

    func fetchIssueMetadata(using bus: any CommandCalling) async {
        guard !issueURL.isEmpty else { return }
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }

        do {
            let result: IssueResolveResponse = try await bus.call(
                method: "project.resolve_issue_url",
                params: ResolveURLParams(url: issueURL)
            )
            issueNumber = result.number
            issueTitle = result.title
        } catch {
            errorMessage = "Failed to resolve issue: \(error.localizedDescription)"
        }
    }

    func fetchBranches(using bus: any CommandCalling) async {
        do {
            let branches: [String] = try await bus.call(method: "git.list_branches")
            availableBranches = branches
        } catch {
            availableBranches = []
        }
    }
}
