import XCTest
@testable import Pnevma

@MainActor
final class WorkspaceOpenerPanelLayoutTests: XCTestCase {
    func testPromptLayoutDefaultsToCompactPanel() {
        let viewModel = WorkspaceOpenerViewModel()

        XCTAssertEqual(viewModel.preferredPanelSize.width, 484)
        XCTAssertEqual(viewModel.preferredPanelSize.height, 304)
    }

    func testPromptAdvancedRemoteLayoutExpandsButStaysCapped() {
        let viewModel = WorkspaceOpenerViewModel()
        viewModel.showAdvancedOptions = true
        viewModel.sshEnabled = true
        viewModel.errorMessage = "Example"

        XCTAssertEqual(viewModel.preferredPanelSize.width, 484)
        XCTAssertEqual(viewModel.preferredPanelSize.height, 476)
    }

    func testListTabsUseLargerBrowsingLayout() {
        let viewModel = WorkspaceOpenerViewModel()
        viewModel.selectedTab = .issues

        XCTAssertEqual(viewModel.preferredPanelSize.width, 560)
        XCTAssertEqual(viewModel.preferredPanelSize.height, 352)
    }
}
