import XCTest
@testable import Pnevma

final class BrowserCaptureTests: XCTestCase {
    func testScratchDirectoryUsesWorkspaceProjectMetadataPath() throws {
        let workspaceID = UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!
        let context = BrowserCaptureContext(
            workspaceID: workspaceID,
            projectPath: "/tmp/project-alpha"
        )

        let scratchURL = try BrowserCaptureUtilities.scratchDirectory(for: context)

        XCTAssertEqual(
            scratchURL.path,
            "/tmp/project-alpha/.pnevma/data/browser-captures"
        )
    }

    func testScratchDirectoryFallsBackToApplicationSupportByWorkspaceID() throws {
        let workspaceID = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
        let context = BrowserCaptureContext(workspaceID: workspaceID, projectPath: nil)
        let appSupportURL = URL(fileURLWithPath: "/tmp/pnevma-browser-captures-tests", isDirectory: true)

        let scratchURL = try BrowserCaptureUtilities.scratchDirectory(
            for: context,
            applicationSupportURL: appSupportURL
        )

        XCTAssertEqual(
            scratchURL.path,
            "/tmp/pnevma-browser-captures-tests/Pnevma/BrowserCaptures/\(workspaceID.uuidString)"
        )
    }

    func testDeterministicFilenameIsStableForSamePage() {
        let url = URL(string: "https://example.com/docs/getting-started")!

        let first = BrowserCaptureUtilities.deterministicFilename(
            title: "Getting Started",
            sourceURL: url
        )
        let second = BrowserCaptureUtilities.deterministicFilename(
            title: "Getting Started",
            sourceURL: url
        )

        XCTAssertEqual(first, second)
        XCTAssertTrue(first.hasPrefix("getting-started-"))
        XCTAssertTrue(first.hasSuffix(".md"))
    }

    func testMarkdownLinkListFormatsTextAndBareURLs() {
        let markdown = BrowserCaptureUtilities.markdownLinkList(for: [
            BrowserPageLink(text: "Docs", url: URL(string: "https://example.com/docs")!),
            BrowserPageLink(text: "", url: URL(string: "https://example.com/changelog")!),
        ])

        XCTAssertEqual(
            markdown,
            """
            - [Docs](https://example.com/docs)
            - <https://example.com/changelog>
            """
        )
    }

    func testFilteredLinksDeduplicatesAndDropsUnsupportedSchemes() {
        let links = BrowserCaptureUtilities.filteredLinks(from: [
            .init(text: "Docs", url: "https://example.com/docs"),
            .init(text: "Docs duplicate", url: "https://example.com/docs"),
            .init(text: "Mail", url: "mailto:hello@example.com"),
            .init(text: "Unsupported", url: "javascript:void(0)"),
        ])

        XCTAssertEqual(
            links,
            [
                BrowserPageLink(text: "Docs", url: URL(string: "https://example.com/docs")!),
                BrowserPageLink(text: "Mail", url: URL(string: "mailto:hello@example.com")!),
            ]
        )
    }

    func testSaveMarkdownWritesToDeterministicWorkspaceScratchLocation() throws {
        let tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("pnevma-browser-capture-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempRoot) }
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)

        let saved = try BrowserCaptureUtilities.saveMarkdown(
            MarkdownResult(
                title: "Getting Started",
                markdown: "# Getting Started\n\nSource: https://example.com/docs",
                url: URL(string: "https://example.com/docs")!,
                excerpt: nil
            ),
            context: BrowserCaptureContext(workspaceID: UUID(), projectPath: tempRoot.path)
        )

        XCTAssertTrue(saved.outputURL.path.contains(".pnevma/data/browser-captures/"))
        XCTAssertEqual(
            try String(contentsOf: saved.outputURL, encoding: .utf8),
            "# Getting Started\n\nSource: https://example.com/docs"
        )
    }
}
