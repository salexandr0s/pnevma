import XCTest
@testable import Pnevma

final class WorkspaceOpenerPanelLayoutTests: XCTestCase {
    func testPromptPanelSizeIsStableAcrossPromptStateChanges() {
        let baseline = WorkspaceOpenerPanelLayout.preferredSize(
            for: .prompt,
            promptHasText: false,
            showAdvancedOptions: false,
            sshEnabled: false,
            isCreatingNewBranch: false,
            hasErrorMessage: false
        )

        let expanded = WorkspaceOpenerPanelLayout.preferredSize(
            for: .prompt,
            promptHasText: true,
            showAdvancedOptions: true,
            sshEnabled: true,
            isCreatingNewBranch: false,
            hasErrorMessage: true
        )

        XCTAssertEqual(baseline, expanded)
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
