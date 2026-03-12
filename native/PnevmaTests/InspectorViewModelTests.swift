import XCTest
@testable import Pnevma
import AppKit

private struct InspectorAnyEncodable: Encodable {
    private let encodeImpl: (Encoder) throws -> Void

    init(_ wrapped: Encodable) {
        encodeImpl = wrapped.encode
    }

    func encode(to encoder: Encoder) throws {
        try encodeImpl(encoder)
    }
}

private struct MockInspectorResponse {
    let json: String
    let error: Error?
    let delayNanos: UInt64

    init(json: String, error: Error? = nil, delayNanos: UInt64 = 0) {
        self.json = json
        self.error = error
        self.delayNanos = delayNanos
    }
}

private actor MockInspectorCommandBus: CommandCalling {
    private var responsesByMethod: [String: [MockInspectorResponse]]

    init(responsesByMethod: [String: [MockInspectorResponse]]) {
        self.responsesByMethod = responsesByMethod
    }

    func call<T: Decodable>(method: String, params: Encodable?) async throws -> T {
        _ = try encodeParams(params)

        guard var responses = responsesByMethod[method], !responses.isEmpty else {
            throw NSError(domain: "MockInspectorCommandBus", code: 1)
        }
        let response = responses.removeFirst()
        responsesByMethod[method] = responses

        if response.delayNanos > 0 {
            try? await Task.sleep(nanoseconds: response.delayNanos)
        }
        if let error = response.error {
            throw error
        }
        return try PnevmaJSON.decoder().decode(T.self, from: Data(response.json.utf8))
    }

    private func encodeParams(_ params: Encodable?) throws -> [String: Any] {
        guard let params else { return [:] }
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        let data = try encoder.encode(InspectorAnyEncodable(params))
        return (try JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
    }
}

@MainActor
final class InspectorViewModelTests: XCTestCase {
    private func waitUntil(
        timeoutNanos: UInt64 = 1_000_000_000,
        pollIntervalNanos: UInt64 = 10_000_000,
        file: StaticString = #filePath,
        line: UInt = #line,
        _ condition: @escaping () async -> Bool
    ) async throws {
        let deadline = DispatchTime.now().uptimeNanoseconds + timeoutNanos
        while DispatchTime.now().uptimeNanoseconds < deadline {
            if await condition() {
                return
            }
            try await Task.sleep(nanoseconds: pollIntervalNanos)
        }
        XCTFail("Timed out waiting for inspector condition", file: file, line: line)
    }

    func testWorkspaceChangesIgnoresLateDiffFromPreviousWorkspace() async throws {
        let bus = MockInspectorCommandBus(responsesByMethod: [
            "workspace.changes": [
                MockInspectorResponse(
                    json: #"""
                    [{"path":"shared.txt","status":" M","modified":true,"staged":false,"conflicted":false,"untracked":false}]
                    """#
                ),
                MockInspectorResponse(
                    json: #"""
                    [{"path":"shared.txt","status":" M","modified":true,"staged":false,"conflicted":false,"untracked":false}]
                    """#
                ),
            ],
            "workspace.change.diff": [
                MockInspectorResponse(
                    json: #"""
                    {"path":"shared.txt","hunks":[{"header":"@@ -1 +1 @@","lines":["-old-from-a","+old-from-a"]}]}
                    """#,
                    delayNanos: 250_000_000
                ),
                MockInspectorResponse(
                    json: #"""
                    {"path":"shared.txt","hunks":[{"header":"@@ -1 +1 @@","lines":["-old-from-b","+new-from-b"]}]}
                    """#,
                    delayNanos: 10_000_000
                ),
            ],
        ])
        let activationHub = ActiveWorkspaceActivationHub()
        let viewModel = WorkspaceChangesViewModel(commandBus: bus, activationHub: activationHub)

        await viewModel.activate()
        let workspaceA = UUID()
        let workspaceB = UUID()

        activationHub.update(.open(workspaceID: workspaceA, projectID: "project-a"))
        try await waitUntil {
            viewModel.selectedPath == "shared.txt" && viewModel.isLoadingDiff
        }

        activationHub.update(.opening(workspaceID: workspaceB, generation: 1))
        activationHub.update(.open(workspaceID: workspaceB, projectID: "project-b"))

        try await waitUntil {
            viewModel.selectedDiffFile?.hunks
                .flatMap(\.lines)
                .contains(where: { $0.content == "new-from-b" }) == true
        }

        try await Task.sleep(nanoseconds: 350_000_000)

        XCTAssertEqual(viewModel.selectedPath, "shared.txt")
        XCTAssertTrue(viewModel.changes.contains(where: { $0.path == "shared.txt" }))
        XCTAssertTrue(
            viewModel.selectedDiffFile?.hunks
                .flatMap(\.lines)
                .contains(where: { $0.content == "new-from-b" }) == true
        )
        XCTAssertFalse(
            viewModel.selectedDiffFile?.hunks
                .flatMap(\.lines)
                .contains(where: { $0.content == "old-from-a" }) == true
        )
    }

    func testWorkspaceChangesDoesNotPresentPreviewForAutoSelection() async throws {
        let bus = MockInspectorCommandBus(responsesByMethod: [
            "workspace.changes": [
                MockInspectorResponse(
                    json: #"""
                    [{"path":"shared.txt","status":" M","modified":true,"staged":false,"conflicted":false,"untracked":false}]
                    """#
                ),
            ],
            "workspace.change.diff": [
                MockInspectorResponse(
                    json: #"""
                    {"path":"shared.txt","hunks":[{"header":"@@ -1 +1 @@","lines":["-before","+after"]}]}
                    """#
                ),
            ],
        ])
        let activationHub = ActiveWorkspaceActivationHub()
        let viewModel = WorkspaceChangesViewModel(commandBus: bus, activationHub: activationHub)

        await viewModel.activate()
        let workspaceID = UUID()
        activationHub.update(.open(workspaceID: workspaceID, projectID: "project-a"))

        try await waitUntil {
            viewModel.selectedPath == "shared.txt"
                && viewModel.selectedDiffFile?.path == "shared.txt"
        }

        XCTAssertFalse(viewModel.isShowingPreview)

        viewModel.selectPath("shared.txt", presentPreview: true)

        XCTAssertTrue(viewModel.isShowingPreview)

        viewModel.clearSelection()

        XCTAssertFalse(viewModel.isShowingPreview)
        XCTAssertNil(viewModel.selectedPath)
    }

    func testReviewIgnoresLatePackAndDiffFromPreviousWorkspace() async throws {
        let bus = MockInspectorCommandBus(responsesByMethod: [
            "task.list": [
                MockInspectorResponse(
                    json: #"""
                    [{"id":"task-1","title":"Task A","status":"Review","priority":"P1","cost_usd":1.0}]
                    """#
                ),
                MockInspectorResponse(
                    json: #"""
                    [{"id":"task-1","title":"Task B","status":"Review","priority":"P1","cost_usd":2.0}]
                    """#
                ),
            ],
            "review.get_pack": [
                MockInspectorResponse(
                    json: #"""
                    {"task_id":"task-1","status":"Pending","review_pack_path":"/tmp/review-a.md","reviewer_notes":"Workspace A","approved_at":null,"pack":{"acceptance_criteria":["Ship A"]}}
                    """#,
                    delayNanos: 200_000_000
                ),
                MockInspectorResponse(
                    json: #"""
                    {"task_id":"task-1","status":"Pending","review_pack_path":"/tmp/review-b.md","reviewer_notes":"Workspace B","approved_at":null,"pack":{"acceptance_criteria":["Ship B"]}}
                    """#,
                    delayNanos: 10_000_000
                ),
            ],
            "review.diff": [
                MockInspectorResponse(
                    json: #"""
                    {"task_id":"task-1","diff_path":"/tmp/review-a.diff","files":[{"path":"shared.txt","hunks":[{"header":"@@ -1 +1 @@","lines":["-review-a","+review-a"]}]}]}
                    """#,
                    delayNanos: 250_000_000
                ),
                MockInspectorResponse(
                    json: #"""
                    {"task_id":"task-1","diff_path":"/tmp/review-b.diff","files":[{"path":"shared.txt","hunks":[{"header":"@@ -1 +1 @@","lines":["-review-b","+review-b"]}]}]}
                    """#,
                    delayNanos: 10_000_000
                ),
            ],
        ])
        let activationHub = ActiveWorkspaceActivationHub()
        let bridgeHub = BridgeEventHub()
        let viewModel = ReviewViewModel(
            commandBus: bus,
            bridgeEventHub: bridgeHub,
            activationHub: activationHub
        )

        await viewModel.activate()
        let workspaceA = UUID()
        let workspaceB = UUID()

        activationHub.update(.open(workspaceID: workspaceA, projectID: "project-a"))
        try await waitUntil {
            viewModel.reviewTasks.first?.title == "Task A"
        }

        viewModel.selectedTaskID = "task-1"
        try await waitUntil {
            viewModel.isLoadingPack && viewModel.isLoadingDiff
        }

        activationHub.update(.opening(workspaceID: workspaceB, generation: 1))
        activationHub.update(.open(workspaceID: workspaceB, projectID: "project-b"))
        try await waitUntil {
            viewModel.reviewTasks.first?.title == "Task B"
        }

        viewModel.selectedTaskID = "task-1"
        try await waitUntil {
            viewModel.reviewPack?.reviewPackPath == "/tmp/review-b.md"
                && viewModel.diffFiles.first?.hunks
                    .flatMap(\.lines)
                    .contains(where: { $0.content == "review-b" }) == true
        }

        try await Task.sleep(nanoseconds: 350_000_000)

        XCTAssertEqual(viewModel.reviewPack?.reviewPackPath, "/tmp/review-b.md")
        XCTAssertEqual(viewModel.notes, "Workspace B")
        XCTAssertEqual(viewModel.criteria.map(\.description), ["Ship B"])
        XCTAssertTrue(
            viewModel.diffFiles.first?.hunks
                .flatMap(\.lines)
                .contains(where: { $0.content == "review-b" }) == true
        )
        XCTAssertFalse(
            viewModel.diffFiles.first?.hunks
                .flatMap(\.lines)
                .contains(where: { $0.content == "review-a" }) == true
        )
    }

    func testReviewRefreshKeepsLocalNotesAndCriteriaForCurrentSelection() async throws {
        let bus = MockInspectorCommandBus(responsesByMethod: [
            "task.list": [
                MockInspectorResponse(
                    json: #"""
                    [{"id":"task-1","title":"Task A","status":"Review","priority":"P1","cost_usd":1.0}]
                    """#
                ),
                MockInspectorResponse(
                    json: #"""
                    [{"id":"task-1","title":"Task A (refreshed)","status":"Review","priority":"P1","cost_usd":1.0}]
                    """#
                ),
            ],
            "review.get_pack": [
                MockInspectorResponse(
                    json: #"""
                    {"task_id":"task-1","status":"Pending","review_pack_path":"/tmp/review.md","reviewer_notes":"Server note","approved_at":null,"pack":{"acceptance_criteria":["Ship it"]}}
                    """#
                ),
            ],
            "review.diff": [
                MockInspectorResponse(
                    json: #"""
                    {"task_id":"task-1","diff_path":"/tmp/review.diff","files":[{"path":"shared.txt","hunks":[{"header":"@@ -1 +1 @@","lines":["-before","+after"]}]}]}
                    """#
                ),
            ],
        ])
        let activationHub = ActiveWorkspaceActivationHub()
        let bridgeHub = BridgeEventHub()
        let viewModel = ReviewViewModel(
            commandBus: bus,
            bridgeEventHub: bridgeHub,
            activationHub: activationHub
        )

        await viewModel.activate()
        let workspaceID = UUID()
        activationHub.update(.open(workspaceID: workspaceID, projectID: "project-a"))
        try await waitUntil {
            viewModel.reviewTasks.first?.title == "Task A"
        }

        viewModel.selectedTaskID = "task-1"
        try await waitUntil {
            viewModel.reviewPack?.reviewPackPath == "/tmp/review.md"
                && viewModel.diffFiles.first?.path == "shared.txt"
        }

        viewModel.criteria[0].met = true
        viewModel.notes = "Local draft note"

        bridgeHub.post(BridgeEvent(name: "task_updated", payloadJSON: "{}"))

        try await waitUntil {
            viewModel.reviewTasks.first?.title == "Task A (refreshed)"
        }

        XCTAssertEqual(viewModel.notes, "Local draft note")
        XCTAssertEqual(viewModel.criteria.map(\.description), ["Ship it"])
        XCTAssertEqual(viewModel.criteria.map(\.met), [true])
        XCTAssertEqual(viewModel.reviewPack?.reviewPackPath, "/tmp/review.md")
        XCTAssertEqual(viewModel.diffFiles.first?.path, "shared.txt")
    }

    func testExplicitReviewRefreshReloadsSelectedDetail() async throws {
        let bus = MockInspectorCommandBus(responsesByMethod: [
            "task.list": [
                MockInspectorResponse(
                    json: #"""
                    [{"id":"task-1","title":"Task A","status":"Review","priority":"P1","cost_usd":1.0}]
                    """#
                ),
                MockInspectorResponse(
                    json: #"""
                    [{"id":"task-1","title":"Task A (refreshed)","status":"Review","priority":"P1","cost_usd":1.0}]
                    """#
                ),
            ],
            "review.get_pack": [
                MockInspectorResponse(
                    json: #"""
                    {"task_id":"task-1","status":"Pending","review_pack_path":"/tmp/review-a.md","reviewer_notes":"Server note A","approved_at":null,"pack":{"acceptance_criteria":["Ship A"]}}
                    """#
                ),
                MockInspectorResponse(
                    json: #"""
                    {"task_id":"task-1","status":"Pending","review_pack_path":"/tmp/review-b.md","reviewer_notes":"Server note B","approved_at":null,"pack":{"acceptance_criteria":["Ship B"]}}
                    """#
                ),
            ],
            "review.diff": [
                MockInspectorResponse(
                    json: #"""
                    {"task_id":"task-1","diff_path":"/tmp/review-a.diff","files":[{"path":"shared.txt","hunks":[{"header":"@@ -1 +1 @@","lines":["-before","+after-a"]}]}]}
                    """#
                ),
                MockInspectorResponse(
                    json: #"""
                    {"task_id":"task-1","diff_path":"/tmp/review-b.diff","files":[{"path":"shared.txt","hunks":[{"header":"@@ -1 +1 @@","lines":["-before","+after-b"]}]}]}
                    """#
                ),
            ],
        ])
        let activationHub = ActiveWorkspaceActivationHub()
        let bridgeHub = BridgeEventHub()
        let viewModel = ReviewViewModel(
            commandBus: bus,
            bridgeEventHub: bridgeHub,
            activationHub: activationHub
        )

        await viewModel.activate()
        let workspaceID = UUID()
        activationHub.update(.open(workspaceID: workspaceID, projectID: "project-a"))
        try await waitUntil {
            viewModel.reviewTasks.first?.title == "Task A"
        }

        viewModel.selectedTaskID = "task-1"
        try await waitUntil {
            viewModel.reviewPack?.reviewPackPath == "/tmp/review-a.md"
                && viewModel.diffFiles.first?.hunks
                    .flatMap(\.lines)
                    .contains(where: { $0.content == "after-a" }) == true
        }

        viewModel.notes = "Local draft note"
        viewModel.criteria[0].met = true

        viewModel.refresh()

        try await waitUntil {
            viewModel.reviewPack?.reviewPackPath == "/tmp/review-b.md"
                && viewModel.diffFiles.first?.hunks
                    .flatMap(\.lines)
                    .contains(where: { $0.content == "after-b" }) == true
        }

        XCTAssertEqual(viewModel.reviewTasks.first?.title, "Task A (refreshed)")
        XCTAssertEqual(viewModel.notes, "Server note B")
        XCTAssertEqual(viewModel.criteria.map(\.description), ["Ship B"])
        XCTAssertEqual(viewModel.criteria.map(\.met), [false])
    }

    func testRightInspectorDiffRendererUsesOverlaySafeForegroundColors() {
        let diffFile = DiffFile(
            path: "example.swift",
            hunks: [
                DiffHunk(
                    header: "@@ -1 +1 @@",
                    lines: [
                        DiffLine(rawString: " unchanged"),
                        DiffLine(rawString: "-old"),
                        DiffLine(rawString: "+new"),
                    ]
                )
            ]
        )

        let rendered = RightInspectorDiffRenderer.render(diffFile: diffFile)
        let fullText = rendered.text.string

        XCTAssertTrue(fullText.contains("@@ -1 +1 @@"))
        XCTAssertTrue(fullText.contains(" unchanged"))
        XCTAssertTrue(fullText.contains("-old"))
        XCTAssertTrue(fullText.contains("+new"))
        XCTAssertEqual(rendered.lineBackgroundColors.count, 4)
        XCTAssertEqual(rendered.lineBackgroundColors.first, RightInspectorDiffRenderer.overlayHeaderBackgroundColor)

        let headerColor = rendered.text.attribute(
            NSAttributedString.Key.foregroundColor,
            at: 0,
            effectiveRange: nil
        ) as? NSColor
        XCTAssertEqual(
            headerColor?.usingColorSpace(NSColorSpace.deviceRGB),
            RightInspectorDiffRenderer.overlaySecondaryTextColor.usingColorSpace(NSColorSpace.deviceRGB)
        )

        let contextRange = (fullText as NSString).range(of: " unchanged")
        let contextColor = rendered.text.attribute(
            NSAttributedString.Key.foregroundColor,
            at: contextRange.location,
            effectiveRange: nil
        ) as? NSColor
        XCTAssertEqual(
            contextColor?.usingColorSpace(NSColorSpace.deviceRGB),
            RightInspectorDiffRenderer.overlayPrimaryTextColor.usingColorSpace(NSColorSpace.deviceRGB)
        )
    }
}
