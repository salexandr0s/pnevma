import Foundation
import os

enum Log {
    static let general = Logger(subsystem: "com.pnevma.app", category: "general")
    static let bridge = Logger(subsystem: "com.pnevma.app", category: "bridge")
    static let terminal = Logger(subsystem: "com.pnevma.app", category: "terminal")
    static let persistence = Logger(subsystem: "com.pnevma.app", category: "persistence")
    static let workspace = Logger(subsystem: "com.pnevma.app", category: "workspace")
    static let performance = Logger(subsystem: "com.pnevma.app", category: "performance")
}

enum ChromeTransitionReason: Hashable {
    case sidebar
    case rightInspector
}

extension Notification.Name {
    static let chromeTransitionDidBegin = Notification.Name("chromeTransitionDidBegin")
    static let chromeTransitionDidEnd = Notification.Name("chromeTransitionDidEnd")
}

final class ChromeTransitionCoordinator {
    static let shared = ChromeTransitionCoordinator()

    private struct State {
        var activeReasonCounts: [ChromeTransitionReason: Int] = [:]
        var totalActiveTransitions = 0
    }

    private let lock = OSAllocatedUnfairLock(initialState: State())

    private init() {}

    var isActive: Bool {
        lock.withLock { $0.totalActiveTransitions > 0 }
    }

    func begin(_ reason: ChromeTransitionReason) {
        let shouldNotify = lock.withLock { state in
            let wasInactive = state.totalActiveTransitions == 0
            state.activeReasonCounts[reason, default: 0] += 1
            state.totalActiveTransitions += 1
            return wasInactive
        }
        guard shouldNotify else { return }
        NotificationCenter.default.post(name: .chromeTransitionDidBegin, object: nil)
    }

    func end(_ reason: ChromeTransitionReason) {
        let shouldNotify = lock.withLock { state in
            guard let count = state.activeReasonCounts[reason], count > 0 else { return false }
            if count == 1 {
                state.activeReasonCounts.removeValue(forKey: reason)
            } else {
                state.activeReasonCounts[reason] = count - 1
            }
            state.totalActiveTransitions -= 1
            return state.totalActiveTransitions == 0
        }
        guard shouldNotify else { return }
        NotificationCenter.default.post(name: .chromeTransitionDidEnd, object: nil)
    }

    func reset() {
        let shouldNotify = lock.withLock { state in
            let hadActiveTransitions = state.totalActiveTransitions > 0
            state.activeReasonCounts.removeAll()
            state.totalActiveTransitions = 0
            return hadActiveTransitions
        }
        guard shouldNotify else { return }
        NotificationCenter.default.post(name: .chromeTransitionDidEnd, object: nil)
    }
}

final class PerformanceDiagnostics {
    static let shared = PerformanceDiagnostics()

    private let signposter = OSSignposter(logger: Log.performance)
    private let countersLock = OSAllocatedUnfairLock(initialState: Counters())

    private struct Counters {
        var browserDrawerRootViewAssignments = 0
        var browserWebViewCreations = 0
        var terminalSurfaceResizeCount = 0
    }

    private init() {}

    var browserDrawerRootViewAssignments: Int {
        countersLock.withLock { $0.browserDrawerRootViewAssignments }
    }

    var browserWebViewCreations: Int {
        countersLock.withLock { $0.browserWebViewCreations }
    }

    var terminalSurfaceResizeCount: Int {
        countersLock.withLock { $0.terminalSurfaceResizeCount }
    }

    func beginInterval(_ name: StaticString) -> OSSignpostIntervalState {
        signposter.beginInterval(name)
    }

    func endInterval(_ name: StaticString, _ state: OSSignpostIntervalState) {
        signposter.endInterval(name, state)
    }

    func recordBrowserDrawerRootViewAssignment() {
        countersLock.withLock { $0.browserDrawerRootViewAssignments += 1 }
        signposter.emitEvent("browser_drawer_root_assignment")
    }

    func recordBrowserWebViewCreation() {
        countersLock.withLock { $0.browserWebViewCreations += 1 }
        signposter.emitEvent("browser_webview_created")
    }

    func recordTerminalSurfaceResize() {
        countersLock.withLock { $0.terminalSurfaceResizeCount += 1 }
        signposter.emitEvent("terminal_surface_resize")
    }

    func resetCounters() {
        countersLock.withLock { counters in
            counters.browserDrawerRootViewAssignments = 0
            counters.browserWebViewCreations = 0
            counters.terminalSurfaceResizeCount = 0
        }
    }
}
