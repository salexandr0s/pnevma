import XCTest
@testable import Pnevma

@MainActor
final class PnevmaTests: XCTestCase {
    func testWorkspaceOpenerGenericLaunchDoesNotAutoSelectFirstProject() throws {
        let viewModel = WorkspaceOpenerViewModel()

        viewModel.applyAvailableProjects([
            ProjectEntry(path: "/tmp/zeta"),
            ProjectEntry(path: "/tmp/alpha"),
        ])

        XCTAssertEqual(viewModel.availableProjects.map(\.path), ["/tmp/alpha", "/tmp/zeta"])
        XCTAssertNil(viewModel.selectedProjectPath)
    }

    func testWorkspaceOpenerProjectLaunchKeepsRequestedProjectSelection() throws {
        let viewModel = WorkspaceOpenerViewModel()

        viewModel.applyAvailableProjects(
            [
                ProjectEntry(path: "/tmp/alpha"),
                ProjectEntry(path: "/tmp/zeta"),
            ],
            preferredProjectPath: "/tmp/zeta"
        )

        XCTAssertEqual(viewModel.selectedProjectPath, "/tmp/zeta")
    }

    func testWorkspaceOpenerMissingPreferredProjectFallsBackToNoSelection() throws {
        let viewModel = WorkspaceOpenerViewModel()

        viewModel.applyAvailableProjects(
            [
                ProjectEntry(path: "/tmp/alpha"),
                ProjectEntry(path: "/tmp/zeta"),
            ],
            preferredProjectPath: "/tmp/missing"
        )

        XCTAssertNil(viewModel.selectedProjectPath)
    }

    func testWorkspaceOpenerLinkedTaskWorktreeDefaultsOffAndResets() throws {
        let viewModel = WorkspaceOpenerViewModel()

        XCTAssertFalse(viewModel.createLinkedTaskWorktree)

        viewModel.createLinkedTaskWorktree = true
        viewModel.reset()

        XCTAssertFalse(viewModel.createLinkedTaskWorktree)
    }

    func testWorkspaceOpenerBranchCreationRequiresNewBranchName() throws {
        let viewModel = WorkspaceOpenerViewModel()
        viewModel.selectedTab = .branches
        viewModel.selectedProjectPath = "/tmp/project"

        viewModel.beginNewBranchCreation()
        XCTAssertFalse(viewModel.canSubmit)

        viewModel.newBranchName = "feature/new-branch"
        XCTAssertTrue(viewModel.canSubmit)
        XCTAssertEqual(viewModel.submitButtonTitle, "Create and Checkout Branch")
    }

    func testWorkspaceOpenerSelectingExistingBranchExitsNewBranchMode() throws {
        let viewModel = WorkspaceOpenerViewModel()
        viewModel.beginNewBranchCreation()
        viewModel.newBranchName = "feature/new-branch"

        viewModel.selectBranch("feature/existing")

        XCTAssertEqual(viewModel.selectedBranchName, "feature/existing")
        XCTAssertFalse(viewModel.isCreatingNewBranch)
        XCTAssertEqual(viewModel.newBranchName, "")
    }
}
