import Foundation

enum CommandCenterDeepLinkTarget: String {
    case diff
    case review
}

extension Notification.Name {
    static let commandCenterDeepLinkDidChange = Notification.Name("CommandCenterDeepLinkDidChange")
}

@MainActor
final class CommandCenterDeepLinkStore {
    static let shared = CommandCenterDeepLinkStore()

    private var pendingTaskIDs: [CommandCenterDeepLinkTarget: String] = [:]

    private init() {}

    func setPendingTaskID(_ taskID: String, for target: CommandCenterDeepLinkTarget) {
        pendingTaskIDs[target] = taskID
        NotificationCenter.default.post(
            name: .commandCenterDeepLinkDidChange,
            object: self,
            userInfo: [
                "target": target.rawValue,
                "task_id": taskID,
            ]
        )
    }

    func consumePendingTaskID(
        for target: CommandCenterDeepLinkTarget,
        availableTaskIDs: Set<String>
    ) -> String? {
        guard let taskID = pendingTaskIDs[target], availableTaskIDs.contains(taskID) else {
            return nil
        }
        pendingTaskIDs[target] = nil
        return taskID
    }

    func clearPendingTaskIDs() {
        pendingTaskIDs.removeAll()
    }
}
