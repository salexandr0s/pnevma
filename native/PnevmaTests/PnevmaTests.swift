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
}
