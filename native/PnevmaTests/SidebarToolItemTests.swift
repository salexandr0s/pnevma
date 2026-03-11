import XCTest
@testable import Pnevma

@MainActor
final class SidebarToolItemTests: XCTestCase {
    func testProjectWorkspaceSidebarIncludesHarnessConfigNearSshTools() {
        let workspace = Workspace(name: "Project", projectPath: "/tmp/project")

        let tools = sidebarTools(for: workspace).map(\.id)

        XCTAssertTrue(tools.contains("harness"))
        XCTAssertEqual(tools.firstIndex(of: "ssh"), 5)
        XCTAssertEqual(tools.firstIndex(of: "harness"), 6)
        XCTAssertEqual(tools.firstIndex(of: "replay"), 7)
    }

    func testTerminalWorkspaceSidebarIncludesHarnessConfig() {
        let workspace = Workspace(name: "Terminal")

        let tools = sidebarTools(for: workspace).map(\.id)

        XCTAssertEqual(
            tools,
            ["terminal", "workflow", "notifications", "ssh", "harness", "browser", "analytics"]
        )
    }
}
