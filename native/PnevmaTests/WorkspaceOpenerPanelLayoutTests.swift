import XCTest
@testable import Pnevma

final class WorkspaceOpenerPanelLayoutTests: XCTestCase {
    func testPromptPanelGrowsWhenAdvancedExpands() {
        let collapsed = WorkspaceOpenerPanelLayout.preferredSize(
            for: .prompt,
            promptHasText: false,
            showAdvancedOptions: false,
            sshEnabled: false,
            isCreatingNewBranch: false,
            hasErrorMessage: false
        )

        let advanced = WorkspaceOpenerPanelLayout.preferredSize(
            for: .prompt,
            promptHasText: false,
            showAdvancedOptions: true,
            sshEnabled: false,
            isCreatingNewBranch: false,
            hasErrorMessage: false
        )

        let ssh = WorkspaceOpenerPanelLayout.preferredSize(
            for: .prompt,
            promptHasText: false,
            showAdvancedOptions: true,
            sshEnabled: true,
            isCreatingNewBranch: false,
            hasErrorMessage: false
        )

        XCTAssertGreaterThan(advanced.height, collapsed.height)
        XCTAssertGreaterThan(ssh.height, advanced.height)
        XCTAssertEqual(collapsed.width, advanced.width)
        XCTAssertEqual(advanced.width, ssh.width)
    }

    func testPromptPanelCollapsesBackToBaseline() {
        let collapsed = WorkspaceOpenerPanelLayout.preferredSize(
            for: .prompt,
            promptHasText: false,
            showAdvancedOptions: false,
            sshEnabled: false,
            isCreatingNewBranch: false,
            hasErrorMessage: false
        )

        XCTAssertEqual(collapsed.height, 420)
    }

    func testBranchPanelSizeIsStableAcrossCreationStateChanges() {
        let existingBranch = WorkspaceOpenerPanelLayout.preferredSize(
            for: .branches,
            promptHasText: false,
            showAdvancedOptions: false,
            sshEnabled: false,
            isCreatingNewBranch: false,
            hasErrorMessage: false
        )

        let creatingBranch = WorkspaceOpenerPanelLayout.preferredSize(
            for: .branches,
            promptHasText: false,
            showAdvancedOptions: false,
            sshEnabled: false,
            isCreatingNewBranch: true,
            hasErrorMessage: true
        )

        XCTAssertEqual(existingBranch, creatingBranch)
    }
}
