import XCTest
@testable import Pnevma

@MainActor
final class WorkspaceOpenerPanelLayoutTests: XCTestCase {
    func testPromptLayoutDefaultsToCompactPanel() {
        let viewModel = WorkspaceOpenerViewModel()

        XCTAssertEqual(viewModel.preferredPanelSize.width, 484)
        XCTAssertEqual(viewModel.preferredPanelSize.height, 320)
    }

    func testPromptTypingExpandsPanelHeight() {
        let viewModel = WorkspaceOpenerViewModel()
        viewModel.promptText = "a"

        XCTAssertEqual(viewModel.preferredPanelSize.width, 484)
        XCTAssertEqual(viewModel.preferredPanelSize.height, 356)
    }

    func testPromptAdvancedLocalLayoutUsesTallerPanel() {
        let viewModel = WorkspaceOpenerViewModel()
        viewModel.showAdvancedOptions = true

        XCTAssertEqual(viewModel.preferredPanelSize.width, 484)
        XCTAssertEqual(viewModel.preferredPanelSize.height, 412)
    }

    func testPromptAdvancedRemoteLayoutExpandsButStaysCapped() {
        let viewModel = WorkspaceOpenerViewModel()
        viewModel.showAdvancedOptions = true
        viewModel.sshEnabled = true
        viewModel.errorMessage = "Example"

        XCTAssertEqual(viewModel.preferredPanelSize.width, 484)
        XCTAssertEqual(viewModel.preferredPanelSize.height, 520)
    }

    func testListTabsUseLargerBrowsingLayout() {
        let viewModel = WorkspaceOpenerViewModel()
        viewModel.selectedTab = .issues

        XCTAssertEqual(viewModel.preferredPanelSize.width, 560)
        XCTAssertEqual(viewModel.preferredPanelSize.height, 368)
    }

    func testBranchesTabGetsTallerDefaultLayout() {
        let viewModel = WorkspaceOpenerViewModel()
        viewModel.selectedTab = .branches

        XCTAssertEqual(viewModel.preferredPanelSize.width, 560)
        XCTAssertEqual(viewModel.preferredPanelSize.height, 404)
    }

    func testBranchesTabExpandsForNewBranchComposer() {
        let viewModel = WorkspaceOpenerViewModel()
        viewModel.selectedTab = .branches
        viewModel.isCreatingNewBranch = true

        XCTAssertEqual(viewModel.preferredPanelSize.width, 560)
        XCTAssertEqual(viewModel.preferredPanelSize.height, 468)
    }
}
