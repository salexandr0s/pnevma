import Foundation
import Observation

/// Chip data for the agent strip — merged from SessionStore and CommandCenterStore.
struct AgentStripEntry: Identifiable {
    let id: String  // session ID
    let title: String
    let provider: String?
    let model: String?
    let state: String
    let startedAt: Date
    let lastActivityAt: Date
    let costUSD: Double
    let attentionReason: String?

    var isAttention: Bool { attentionReason != nil }

    var elapsedFormatted: String {
        let elapsed = Date().timeIntervalSince(startedAt)
        if elapsed < 60 { return "\(Int(elapsed))s" }
        if elapsed < 3600 { return "\(Int(elapsed / 60))m" }
        return "\(Int(elapsed / 3600))h \(Int((elapsed.truncatingRemainder(dividingBy: 3600)) / 60))m"
    }

    var lastActivityAge: String {
        let age = Date().timeIntervalSince(lastActivityAt)
        if age < 10 { return "just now" }
        if age < 60 { return "\(Int(age))s ago" }
        return "\(Int(age / 60))m ago"
    }
}

@Observable
@MainActor
final class AgentStripState {
    private(set) var entries: [AgentStripEntry] = []

    var hasEntries: Bool { !entries.isEmpty }
    var entryCount: Int { entries.count }
    var attentionCount: Int { entries.filter(\.isAttention).count }

    func update(from sessions: [LiveSessionEntry], runs: [CommandCenterRunEntry]) {
        entries = sessions.compactMap { session in
            let matchingRun = runs.first { $0.sessionID == session.id }
            return AgentStripEntry(
                id: session.id,
                title: matchingRun?.taskTitle ?? session.name,
                provider: matchingRun?.provider,
                model: matchingRun?.model,
                state: session.status,
                startedAt: session.startedAt,
                lastActivityAt: session.lastActivityAt,
                costUSD: matchingRun?.costUSD ?? 0,
                attentionReason: matchingRun?.attentionReason
            )
        }
    }
}

/// Minimal session info for agent strip enrichment.
struct LiveSessionEntry {
    let id: String
    let name: String
    let status: String
    let startedAt: Date
    let lastActivityAt: Date
}

/// Minimal run info for agent strip enrichment.
struct CommandCenterRunEntry {
    let sessionID: String?
    let taskTitle: String?
    let provider: String?
    let model: String?
    let costUSD: Double
    let attentionReason: String?
}
