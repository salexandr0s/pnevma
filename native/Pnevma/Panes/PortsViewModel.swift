import Cocoa
import Observation

@Observable
@MainActor
final class PortsViewModel {
    private(set) var ports: [PortEntry] = []
    private(set) var isLoading = false
    private var dismissedPorts: Set<Int> = []
    private var pollTask: Task<Void, Never>?

    var visiblePorts: [PortEntry] {
        ports.filter { !dismissedPorts.contains(Int($0.port)) }
    }

    func startPolling(using bus: any CommandCalling) {
        stopPolling()
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refresh(using: bus)
                try? await Task.sleep(for: .seconds(5))
            }
        }
    }

    func stopPolling() {
        pollTask?.cancel()
        pollTask = nil
    }

    func refresh(using bus: any CommandCalling) async {
        isLoading = true
        defer { isLoading = false }
        do {
            ports = try await bus.call(method: "ports.list")
        } catch {
            // Silently fail — ports are best-effort
        }
    }

    func openInBrowser(port: PortEntry) {
        let urlString = "http://localhost:\(port.port)"
        if let url = URL(string: urlString) {
            NSWorkspace.shared.open(url)
        }
    }

    func copyAddress(port: PortEntry) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(port.displayAddress, forType: .string)
    }

    func dismissPort(_ port: PortEntry) {
        dismissedPorts.insert(Int(port.port))
    }
}
