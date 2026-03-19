import Foundation

enum WorkspaceOpenerPanelLayout {
    static let minimumSize = CGSize(width: 480, height: 236)

    static func preferredSize(
        for selectedTab: WorkspaceOpenerTab,
        showAdvancedOptions: Bool,
        sshEnabled: Bool,
        hasErrorMessage: Bool
    ) -> CGSize {
        let width: CGFloat
        var height: CGFloat

        switch selectedTab {
        case .prompt:
            width = 484
            height = 304
            if showAdvancedOptions {
                height += sshEnabled ? 144 : 68
            }
        case .issues, .pullRequests, .branches:
            width = 560
            height = 352
        }

        if hasErrorMessage {
            height += 28
        }

        return CGSize(
            width: max(width, minimumSize.width),
            height: max(min(height, 480), minimumSize.height)
        )
    }
}
