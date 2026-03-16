import Foundation
import Observation

@Observable
@MainActor
final class InspectorChangesViewModel {
    private(set) var fileStats: [InspectorDiffFileStat] = []
    private(set) var checkSummary: CheckStatusSummary?
    private(set) var mergeReadiness: MergeReadiness?
    private(set) var isLoading = false
    private(set) var lastError: String?

    var commitMessage: String = ""
    var isPushing = false

    // PR chip data (read from workspace)
    var linkedPRNumber: UInt64?
    var linkedPRURL: String?

    /// Directory tree grouping of file stats.
    var filesByDirectory: [(directory: String, files: [InspectorDiffFileStat])] {
        var groups: [String: [InspectorDiffFileStat]] = [:]
        for stat in fileStats {
            groups[stat.directory, default: []].append(stat)
        }
        return groups
            .sorted { $0.key < $1.key }
            .map { (directory: $0.key, files: $0.value) }
    }

    var totalAdditions: Int { fileStats.reduce(0) { $0 + $1.additions } }
    var totalDeletions: Int { fileStats.reduce(0) { $0 + $1.deletions } }
    var reviewedCount: Int { fileStats.filter(\.isReviewed).count }

    func refresh(using bus: any CommandCalling) async {
        isLoading = true
        lastError = nil
        defer { isLoading = false }

        // Fetch changes summary
        do {
            struct FileChangeResponse: Decodable {
                let path: String
                let additions: Int
                let deletions: Int
            }
            let changes: [FileChangeResponse] = try await bus.call(method: "workspace.changes_summary")
            fileStats = changes.map {
                InspectorDiffFileStat(path: $0.path, additions: $0.additions, deletions: $0.deletions)
            }
        } catch {
            lastError = error.localizedDescription
        }

        // Fetch check summary
        do {
            checkSummary = try await bus.call(method: "review.check_summary")
        } catch {
            // Non-fatal: checks may not be available
        }

        // Fetch merge readiness
        do {
            mergeReadiness = try await bus.call(method: "merge.queue.readiness")
        } catch {
            // Non-fatal
        }
    }

    func commitAndPush(using bus: any CommandCalling) async {
        guard !commitMessage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        isPushing = true
        defer { isPushing = false }

        struct CommitParams: Encodable {
            let message: String
        }
        struct CommitResult: Decodable {
            let success: Bool
            let commitSha: String?
            let pushError: String?
        }

        do {
            let result: CommitResult = try await bus.call(
                method: "workspace.commit_and_push",
                params: CommitParams(message: commitMessage)
            )
            if result.success {
                commitMessage = ""
            } else if let error = result.pushError {
                lastError = error
            }
        } catch {
            lastError = error.localizedDescription
        }
    }

    func toggleReviewed(path: String) {
        if let index = fileStats.firstIndex(where: { $0.path == path }) {
            fileStats[index].isReviewed.toggle()
        }
    }
}
