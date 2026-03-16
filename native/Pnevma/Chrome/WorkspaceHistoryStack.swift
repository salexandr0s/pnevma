import Foundation
import Observation

/// Fixed-size navigation history for workspace back/forward.
@Observable
@MainActor
final class WorkspaceHistoryStack {
    private var backStack: [UUID] = []
    private var forwardStack: [UUID] = []
    private let maxEntries = 50
    private var isNavigating = false

    var canNavigateBack: Bool { !backStack.isEmpty }
    var canNavigateForward: Bool { !forwardStack.isEmpty }

    func push(_ workspaceID: UUID) {
        guard !isNavigating else { return }
        backStack.append(workspaceID)
        forwardStack.removeAll()
        if backStack.count > maxEntries {
            backStack.removeFirst()
        }
    }

    func navigateBack(current: UUID) -> UUID? {
        guard let previous = backStack.popLast() else { return nil }
        isNavigating = true
        forwardStack.append(current)
        isNavigating = false
        return previous
    }

    func navigateForward(current: UUID) -> UUID? {
        guard let next = forwardStack.popLast() else { return nil }
        isNavigating = true
        backStack.append(current)
        isNavigating = false
        return next
    }
}
