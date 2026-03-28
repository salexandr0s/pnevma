import Foundation

struct GitHubAuthAccount: Codable, Sendable, Equatable {
    let login: String
    let active: Bool
    let state: String
    let tokenSource: String?
    let gitProtocol: String?
    let scopes: [String]
}

struct GitHubGitHelperStatus: Codable, Sendable, Equatable {
    let state: String
    let message: String
    let detail: String?
}

struct GitHubAuthJob: Codable, Sendable, Equatable {
    let state: String
    let message: String?
    let startedAt: Date
    let finishedAt: Date?
}

struct GitHubAuthSnapshot: Codable, Sendable, Equatable {
    let host: String
    let cliAvailable: Bool
    let activeLogin: String?
    let accounts: [GitHubAuthAccount]
    let gitHelper: GitHubGitHelperStatus
    let authJob: GitHubAuthJob?
    let error: String?
    let lastRefreshedAt: Date?
}

struct GitHubAuthSwitchRequest: Encodable, Sendable {
    let login: String
}
