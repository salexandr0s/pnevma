import XCTest
@testable import Pnevma

@MainActor
final class SidebarToolItemTests: XCTestCase {
    func testProjectWorkspaceSidebarIncludesHarnessConfigNearSshTools() {
        let workspace = Workspace(name: "Project", projectPath: "/tmp/project")

        let tools = sidebarTools(for: workspace).map(\.id)

        XCTAssertEqual(
            tools,
            [
                "terminal",
                "tasks",
                "workflow",
                "notifications",
                "ssh",
                "harness",
                "replay",
                "browser",
                "analytics",
                "resource_monitor",
                "brief",
                "rules",
                "secrets",
                "ports",
            ]
        )
        XCTAssertFalse(tools.contains("settings"))
    }

    func testTerminalWorkspaceSidebarIncludesHarnessConfig() {
        let workspace = Workspace(name: "Terminal")

        let tools = sidebarTools(for: workspace).map(\.id)

        XCTAssertEqual(
            tools,
            ["terminal", "workflow", "notifications", "ssh", "harness", "browser", "analytics", "resource_monitor"]
        )
    }

    func testSettingsIsDefinedButNotIncludedInWorkspaceToolLists() {
        let project = Workspace(name: "Project", projectPath: "/tmp/project")
        let terminal = Workspace(name: "Terminal")

        XCTAssertEqual(sidebarToolDefinition(id: "settings")?.paneType, "settings")
        XCTAssertFalse(sidebarTools(for: project).contains { $0.id == "settings" })
        XCTAssertFalse(sidebarTools(for: terminal).contains { $0.id == "settings" })
    }

    func testSidebarToolDefinitionLookupByPaneTypeUsesSidebarMappings() {
        XCTAssertEqual(sidebarToolDefinition(id: "files")?.paneType, "file_browser")
        XCTAssertEqual(sidebarToolDefinition(id: "brief")?.paneType, "daily_brief")
        XCTAssertNil(sidebarToolDefinition(paneType: "merge_queue"), "merge_queue moved to right inspector")
    }

    func testSidebarToolsOnlyExposePaneTypesAvailableForWorkspaceMode() {
        let project = Workspace(name: "Project", projectPath: "/tmp/project")
        let terminal = Workspace(name: "Terminal")

        for workspace in [project, terminal] {
            let tools = sidebarTools(for: workspace)
            let availablePaneTypes = PaneFactory.availablePaneTypes(for: workspace)

            XCTAssertEqual(Set(tools.map(\.id)).count, tools.count)
            XCTAssertTrue(tools.allSatisfy { availablePaneTypes.contains($0.paneType) })
        }
    }

    func testSingleTerminalWorkspaceDoesNotNeedSectionHeader() {
        let terminal = Workspace(name: "Terminal", kind: .terminal)

        XCTAssertFalse(SidebarWorkspacePresentation.shouldShowTerminalSectionHeader(for: [terminal]))
    }

    func testMultipleTerminalWorkspacesStillShowSectionHeader() {
        let primary = Workspace(name: "Terminal", kind: .terminal)
        let secondary = Workspace(name: "Scratch", kind: .terminal)

        XCTAssertTrue(SidebarWorkspacePresentation.shouldShowTerminalSectionHeader(for: [primary, secondary]))
    }

    func testCollapsedRailUsesTerminalIconAndProjectInitial() {
        let terminal = Workspace(name: "Terminal", kind: .terminal)
        let project = Workspace(name: "Project Atlas", projectPath: "/tmp/project-atlas")

        XCTAssertEqual(
            SidebarWorkspacePresentation.collapsedIndicator(for: terminal),
            .icon("terminal")
        )
        XCTAssertEqual(
            SidebarWorkspacePresentation.collapsedIndicator(for: project),
            .text("P")
        )
    }
}
