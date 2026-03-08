import Foundation

// MARK: - Types

struct AppVersionInfo {
    let shortVersion: String  // CFBundleShortVersionString
    let build: String         // CFBundleVersion
    let releasePageURL: URL

    static var current: AppVersionInfo {
        let bundle = Bundle.main
        return AppVersionInfo(
            shortVersion: bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.0",
            build: bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0",
            releasePageURL: URL(string: "https://github.com/salexandr0s/pnevma/releases")!
        )
    }
}

enum AppUpdateStatus: Equatable {
    case idle
    case checking
    case updateAvailable(version: String, url: URL)
    case upToDate
    case failed(String)
}

struct AppUpdateState {
    var status: AppUpdateStatus
    var lastCheckAt: Date?
    var latestVersion: String?
    var currentVersion: String
    var currentBuild: String
}

// MARK: - Protocol

protocol ReleaseVersionChecking: Sendable {
    func fetchLatestRelease() async throws -> (version: String, url: URL)
}

// MARK: - GitHub Implementation

struct GitHubReleaseVersionChecker: ReleaseVersionChecking {
    let repositoryOwner: String
    let repositoryName: String

    private struct GitHubRelease: Decodable {
        let tag_name: String
        let html_url: String
    }

    func fetchLatestRelease() async throws -> (version: String, url: URL) {
        let urlString = "https://api.github.com/repos/\(repositoryOwner)/\(repositoryName)/releases/latest"
        guard let url = URL(string: urlString) else {
            throw URLError(.badURL)
        }

        var request = URLRequest(url: url)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 15

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse,
              (200...299).contains(httpResponse.statusCode) else {
            throw URLError(.badServerResponse)
        }

        let release = try JSONDecoder().decode(GitHubRelease.self, from: data)

        // Trim optional leading "v" from tag
        var version = release.tag_name
        if version.hasPrefix("v") || version.hasPrefix("V") {
            version = String(version.dropFirst())
        }

        guard let releaseURL = URL(string: release.html_url) else {
            throw URLError(.badURL)
        }

        return (version, releaseURL)
    }
}

// MARK: - Semantic Version Comparison

enum SemanticVersion {
    /// Returns true if `remote` is newer than `local`.
    /// Both should be dot-separated numeric strings like "2.1.0".
    static func isNewer(remote: String, than local: String) -> Bool {
        let remoteParts = remote.split(separator: ".").compactMap { Int($0) }
        let localParts = local.split(separator: ".").compactMap { Int($0) }

        let maxLen = max(remoteParts.count, localParts.count)
        for i in 0..<maxLen {
            let r = i < remoteParts.count ? remoteParts[i] : 0
            let l = i < localParts.count ? localParts[i] : 0
            if r > l { return true }
            if r < l { return false }
        }
        return false
    }
}

// MARK: - Coordinator

@MainActor
final class AppUpdateCoordinator: ObservableObject {

    @Published private(set) var state: AppUpdateState

    private let versionChecker: any ReleaseVersionChecking
    private let userDefaults: UserDefaults
    private let checkInterval: TimeInterval

    private static let lastCheckKey = "AppUpdateCoordinator.lastCheckAt"
    private static let lastKnownVersionKey = "AppUpdateCoordinator.lastKnownVersion"

    init(
        versionChecker: any ReleaseVersionChecking = GitHubReleaseVersionChecker(
            repositoryOwner: "salexandr0s",
            repositoryName: "pnevma"
        ),
        userDefaults: UserDefaults = .standard,
        checkInterval: TimeInterval = 24 * 60 * 60  // 24 hours
    ) {
        self.versionChecker = versionChecker
        self.userDefaults = userDefaults
        self.checkInterval = checkInterval

        let versionInfo = AppVersionInfo.current
        let lastCheck = userDefaults.object(forKey: Self.lastCheckKey) as? Date
        let lastKnown = userDefaults.string(forKey: Self.lastKnownVersionKey)

        self.state = AppUpdateState(
            status: .idle,
            lastCheckAt: lastCheck,
            latestVersion: lastKnown,
            currentVersion: versionInfo.shortVersion,
            currentBuild: versionInfo.build
        )
    }

    /// Run an automatic check -- respects auto_update setting and 24h cooldown.
    func automaticCheck() {
        guard AppRuntimeSettings.shared.autoUpdate else { return }

        if let lastCheck = state.lastCheckAt,
           Date().timeIntervalSince(lastCheck) < checkInterval {
            return
        }

        Task { @MainActor in
            await performCheck(isManual: false)
        }
    }

    /// Run a manual check -- always runs regardless of auto_update or cooldown.
    func manualCheck() async {
        await performCheck(isManual: true)
    }

    private func performCheck(isManual: Bool) async {
        state.status = .checking

        do {
            let (version, url) = try await versionChecker.fetchLatestRelease()
            let now = Date()

            state.lastCheckAt = now
            state.latestVersion = version
            userDefaults.set(now, forKey: Self.lastCheckKey)
            userDefaults.set(version, forKey: Self.lastKnownVersionKey)

            if SemanticVersion.isNewer(remote: version, than: state.currentVersion) {
                state.status = .updateAvailable(version: version, url: url)
            } else {
                state.status = .upToDate
            }
        } catch {
            state.status = .failed(error.localizedDescription)
        }
    }
}
