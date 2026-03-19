import Foundation

enum WorkspaceOpenerPanelLayout {
    static let minimumSize = CGSize(width: 480, height: 236)
    private static let maximumHeight: CGFloat = 520

    static func preferredSize(
        for selectedTab: WorkspaceOpenerTab,
        promptHasText: Bool,
        showAdvancedOptions: Bool,
        sshEnabled: Bool,
        isCreatingNewBranch: Bool,
        hasErrorMessage: Bool
    ) -> CGSize {
        let width: CGFloat
        var height: CGFloat

        switch selectedTab {
        case .prompt:
            width = 484
            height = promptHasText ? 356 : 320
            if showAdvancedOptions {
                height += sshEnabled ? 172 : 92
            }
        case .issues, .pullRequests:
            width = 560
            height = 368
        case .branches:
            width = 560
            height = isCreatingNewBranch ? 468 : 404
        }

        if hasErrorMessage {
            height += 28
        }

        return CGSize(
            width: max(width, minimumSize.width),
            height: max(min(height, maximumHeight), minimumSize.height)
        )
    }
}
