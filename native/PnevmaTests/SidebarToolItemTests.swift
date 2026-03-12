import XCTest
@testable import Pnevma

@MainActor
final class SidebarToolItemTests: XCTestCase {
    func testProjectWorkspaceSidebarIncludesHarnessConfigNearSshTools() {
        let workspace = Workspace(name: "Project", projectPath: "/tmp/project")

        let tools = sidebarTools(for: workspace).map(\.id)

        XCTAssertTrue(tools.contains("harness"))
        XCTAssertEqual(tools.firstIndex(of: "ssh"), 4)
        XCTAssertEqual(tools.firstIndex(of: "harness"), 5)
        XCTAssertEqual(tools.firstIndex(of: "replay"), 6)
    }

    func testTerminalWorkspaceSidebarIncludesHarnessConfig() {
        let workspace = Workspace(name: "Terminal")

        let tools = sidebarTools(for: workspace).map(\.id)

        XCTAssertEqual(
            tools,
            ["terminal", "workflow", "notifications", "ssh", "harness", "browser", "analytics"]
        )
    }

    func testSidebarToolDefinitionsExposeRecommendedDefaultPresentations() {
        let expectedDefaults: [String: SidebarToolDefaultPresentation] = [
            "terminal": .pane,
            "tasks": .pane,
            "workflow": .tab,
            "notifications": .pane,
            "files": .pane,
            "ssh": .pane,
            "harness": .tab,
            "replay": .tab,
            "browser": .pane,
            "review": .tab,
            "diff": .tab,
            "analytics": .tab,
            "brief": .tab,
            "rules": .pane,
        ]

        for (toolID, presentation) in expectedDefaults {
            XCTAssertEqual(
                sidebarToolDefinition(id: toolID)?.defaultPresentation,
                presentation,
                "Unexpected default presentation for \(toolID)"
            )
        }
    }

    func testSidebarToolDefinitionLookupByPaneTypeUsesSidebarMappings() {
        XCTAssertEqual(sidebarToolDefinition(id: "files")?.paneType, "file_browser")
        XCTAssertEqual(sidebarToolDefinition(id: "brief")?.paneType, "daily_brief")
        XCTAssertNil(sidebarToolDefinition(paneType: "merge_queue"), "merge_queue moved to right inspector")
    }
}
