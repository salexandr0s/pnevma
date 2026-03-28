import Foundation

@MainActor
enum UITestFixtureData {
    static var isEnabled: Bool {
        AppLaunchContext.uiTestSeedFixtures
    }

    static let workspaceOpenerGitHubStatus = WorkspaceOpenerGitHubStatus(
        state: .ready,
        message: "UI test fixture GitHub data is active.",
        detail: "Seeded issues and pull requests are shown to keep opener coverage deterministic.",
        resolvedRepo: "pnevma/ui-test-fixture",
        activeLogin: "fixture-bot",
        accountCount: 2,
        authJobState: nil,
        gitHelperWarning: nil
    )

    static let workspaceOpenerIssues: [GitHubIssueItem] = [
        GitHubIssueItem(
            number: 101,
            title: "Stabilize inspector overlay focus handling",
            state: "open",
            labels: ["ui-tests", "inspector"],
            author: "fixture-bot"
        ),
        GitHubIssueItem(
            number: 102,
            title: "Collect screenshot evidence for settings regressions",
            state: "open",
            labels: ["release", "settings"],
            author: "fixture-bot"
        ),
    ]

    static let workspaceOpenerPullRequests: [PullRequestItem] = [
        PullRequestItem(
            number: 201,
            title: "Improve workspace opener test coverage",
            sourceBranch: "feature/opener-coverage",
            targetBranch: "main",
            status: "open"
        ),
        PullRequestItem(
            number: 202,
            title: "Add richer UI evidence attachments",
            sourceBranch: "feature/ui-evidence",
            targetBranch: "main",
            status: "open"
        ),
    ]

    static let notifications: [NotificationItem] = [
        NotificationItem(
            id: "fixture.notification.error",
            level: "error",
            title: "Fixture error notification",
            body: "Used by UI automation to exercise error filtering and mark-read flows.",
            timestamp: "2026-03-27T10:00:00Z",
            isRead: false,
            sourcePaneType: "workflow",
            sessionID: "fixture-session-1",
            taskID: "fixture-task-1"
        ),
        NotificationItem(
            id: "fixture.notification.info",
            level: "info",
            title: "Fixture info notification",
            body: "Used by UI automation to exercise clear-all behavior.",
            timestamp: "2026-03-27T10:05:00Z",
            isRead: false,
            sourcePaneType: "notifications",
            sessionID: nil,
            taskID: nil
        ),
    ]
}
