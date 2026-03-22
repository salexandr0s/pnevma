import Foundation

enum WorkspaceOpenerPanelLayout {
    static let minimumSize = CGSize(width: 560, height: 360)

    static func preferredSize(
        for selectedTab: WorkspaceOpenerTab,
        promptHasText: Bool,
        showAdvancedOptions: Bool,
        sshEnabled: Bool,
        isCreatingNewBranch: Bool,
        hasErrorMessage: Bool
    ) -> CGSize {
        switch selectedTab {
        case .prompt:
            var height: CGFloat = 420
            if showAdvancedOptions { height += 80 }
            if showAdvancedOptions && sshEnabled { height += 120 }
            return CGSize(width: 620, height: height)
        case .issues, .pullRequests:
            return CGSize(width: 720, height: 520)
        case .branches:
            return CGSize(width: 720, height: 540)
        }
    }
}
