import Foundation
import Observation

// MARK: - Models

struct ResourceSnapshot: Decodable, Sendable {
    let timestamp: String
    let host: HostInfo
    let app: AppResourceGroup
    let sessions: [SessionResources]
    let totals: ResourceTotals
}

struct HostInfo: Decodable, Sendable {
    let hostname: String
    let osVersion: String
    let cpuCores: Int
    let totalMemoryBytes: UInt64
    let uptimeSeconds: UInt64
}

struct ProcessMetrics: Decodable, Sendable, Identifiable {
    let pid: UInt32
    let name: String
    let cpuPercent: Float
    let memoryBytes: UInt64
    let memoryPercent: Float

    var id: UInt32 { pid }
}

struct AppResourceGroup: Decodable, Sendable {
    let main: ProcessMetrics
    let helpers: [ProcessMetrics]
    let totalCpuPercent: Float
    let totalMemoryBytes: UInt64
    let totalMemoryPercent: Float
}

struct SessionResources: Decodable, Sendable, Identifiable {
    let sessionID: String
    let sessionName: String
    let status: String
    let process: ProcessMetrics?
    let children: [ProcessMetrics]
    let totalCpuPercent: Float
    let totalMemoryBytes: UInt64

    var id: String { sessionID }
}

struct ResourceTotals: Decodable, Sendable {
    let cpuPercent: Float
    let memoryBytes: UInt64
    let memoryPercent: Float
    let processCount: Int
}

// MARK: - Time Series

struct ResourceTimePoint: Identifiable, Sendable {
    let id = UUID()
    let date: Date
    let cpuPercent: Float
    let memoryBytes: UInt64
    let memoryPercent: Float
}

// MARK: - Store

@Observable @MainActor
final class ResourceMonitorStore {
    static let shared = ResourceMonitorStore()

    var snapshot: ResourceSnapshot?
    var timeSeriesBuffer: [ResourceTimePoint] = []
    var isLoading = false
    var errorMessage: String?

    @ObservationIgnored
    private let commandBus: (any CommandCalling)?
    @ObservationIgnored
    private var pollTask: Task<Void, Never>?
    @ObservationIgnored
    private var isInteractive = false

    private static let interactiveInterval: TimeInterval = 2.0
    private static let idleInterval: TimeInterval = 15.0
    private static let maxTimeSeriesAge: TimeInterval = 300.0 // 5 minutes

    init(commandBus: (any CommandCalling)? = CommandBus.shared) {
        self.commandBus = commandBus
    }

    func setInteractiveMode(_ active: Bool) {
        guard isInteractive != active else { return }
        isInteractive = active
        restartPolling()
    }

    func activate() async {
        await refresh()
        restartPolling()
    }

    func refresh() async {
        guard let commandBus else {
            errorMessage = "Resource monitor unavailable: command bus not configured."
            return
        }
        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false }

        do {
            let result: ResourceSnapshot = try await commandBus.call(method: "system.resource_snapshot")
            snapshot = result
            errorMessage = nil
            appendTimePoint(from: result)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func stopPolling() {
        pollTask?.cancel()
        pollTask = nil
    }

    // MARK: - Private

    private func appendTimePoint(from snap: ResourceSnapshot) {
        let point = ResourceTimePoint(
            date: Date(),
            cpuPercent: snap.totals.cpuPercent,
            memoryBytes: snap.totals.memoryBytes,
            memoryPercent: snap.totals.memoryPercent
        )
        timeSeriesBuffer.append(point)
        let cutoff = Date().addingTimeInterval(-Self.maxTimeSeriesAge)
        timeSeriesBuffer.removeAll { $0.date < cutoff }
    }

    private func restartPolling() {
        pollTask?.cancel()
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                let interval = self?.isInteractive == true
                    ? Self.interactiveInterval
                    : Self.idleInterval
                try? await Task.sleep(for: .seconds(interval))
                guard !Task.isCancelled else { break }
                await self?.refresh()
            }
        }
    }
}
