import Foundation
import Observation

/// Persists collapse state for sidebar project groups via UserDefaults.
@Observable
@MainActor
final class SidebarGroupState {
    static let shared = SidebarGroupState()

    private let defaults = UserDefaults.standard
    private let storageKey = "sidebarGroupCollapseState"

    private var collapsedGroups: Set<String>

    private init() {
        let stored = UserDefaults.standard.stringArray(forKey: "sidebarGroupCollapseState") ?? []
        collapsedGroups = Set(stored)
    }

    func isCollapsed(_ groupName: String) -> Bool {
        collapsedGroups.contains(groupName)
    }

    func toggleCollapse(_ groupName: String) {
        if collapsedGroups.contains(groupName) {
            collapsedGroups.remove(groupName)
        } else {
            collapsedGroups.insert(groupName)
        }
        persist()
    }

    func setCollapsed(_ groupName: String, collapsed: Bool) {
        if collapsed {
            collapsedGroups.insert(groupName)
        } else {
            collapsedGroups.remove(groupName)
        }
        persist()
    }

    private func persist() {
        defaults.set(Array(collapsedGroups), forKey: storageKey)
    }
}
