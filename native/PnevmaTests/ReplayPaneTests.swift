import XCTest
@testable import Pnevma

private actor ReplayCommandBus: CommandCalling {
    private let timelineJSON: String
    private let delayNanos: UInt64
    private var callCountValue = 0

    init(timelineJSON: String, delayNanos: UInt64 = 0) {
        self.timelineJSON = timelineJSON
        self.delayNanos = delayNanos
    }

    func call<T: Decodable & Sendable>(method: String, params: (any Encodable & Sendable)?) async throws -> T {
        switch method {
        case "session.timeline":
            callCountValue += 1
            if delayNanos > 0 {
                try await Task.sleep(nanoseconds: delayNanos)
            }
            let decoder = PnevmaJSON.decoder()
            return try decoder.decode(T.self, from: Data(timelineJSON.utf8))
        default:
            throw NSError(domain: "ReplayCommandBus", code: 1)
        }
    }

    func callCount() -> Int {
        callCountValue
    }
}

final class ReplayPaneTests: XCTestCase {

    func testBuildFramesSkipsDuplicateScrollbackSnapshot() {
        let entries = [
            ReplayTimelineEvent(
                timestamp: "2026-03-06T08:00:00Z",
                kind: "session_output",
                summary: "hello",
                payload: ReplayTimelinePayload(data: nil, chunk: "hello\n")
            ),
            ReplayTimelineEvent(
                timestamp: "2026-03-06T08:00:01Z",
                kind: "session_output",
                summary: "world",
                payload: ReplayTimelinePayload(data: nil, chunk: "world\n")
            ),
            ReplayTimelineEvent(
                timestamp: "2026-03-06T08:00:02Z",
                kind: "ScrollbackSnapshot",
                summary: "snapshot",
                payload: ReplayTimelinePayload(data: "hello\nworld\n", chunk: nil)
            )
        ]

        let frames = ReplayFrameBuilder.buildFrames(from: entries)

        XCTAssertEqual(frames, ["hello\n", "hello\nworld\n"])
    }

    func testBuildFramesUsesSnapshotAsInitialTranscript() {
        let entries = [
            ReplayTimelineEvent(
                timestamp: "2026-03-06T08:00:00Z",
                kind: "ScrollbackSnapshot",
                summary: "snapshot",
                payload: ReplayTimelinePayload(data: "restored\n", chunk: nil)
            )
        ]

        let frames = ReplayFrameBuilder.buildFrames(from: entries)

        XCTAssertEqual(frames, ["restored\n"])
    }

    func testBuildFramesAppendsChunksAfterSnapshot() {
        let entries = [
            ReplayTimelineEvent(
                timestamp: "2026-03-06T08:00:00Z",
                kind: "ScrollbackSnapshot",
                summary: "snapshot",
                payload: ReplayTimelinePayload(data: "restored\n", chunk: nil)
            ),
            ReplayTimelineEvent(
                timestamp: "2026-03-06T08:00:01Z",
                kind: "session_output",
                summary: "live",
                payload: ReplayTimelinePayload(data: nil, chunk: "next\n")
            )
        ]

        let frames = ReplayFrameBuilder.buildFrames(from: entries)

        XCTAssertEqual(frames, ["restored\n", "restored\nnext\n"])
    }

    func testBuildFramesIgnoresNonOutputSummaries() {
        let entries = [
            ReplayTimelineEvent(
                timestamp: "2026-03-06T08:00:00Z",
                kind: "task_updated",
                summary: "should not render",
                payload: ReplayTimelinePayload(data: nil, chunk: nil)
            )
        ]

        let frames = ReplayFrameBuilder.buildFrames(from: entries)

        XCTAssertTrue(frames.isEmpty)
    }
}

@MainActor
final class ReplayViewModelTests: XCTestCase {
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
        XCTFail("Timed out waiting for async condition", file: file, line: line)
    }

    func testReplayViewModelWaitsForActivationBeforeLoadingTimeline() async throws {
        let bus = ReplayCommandBus(
            timelineJSON: #"[{"timestamp":"2026-03-06T08:00:00Z","kind":"ScrollbackSnapshot","summary":"snapshot","payload":{"data":"restored\n","chunk":null}}]"#
        )
        let activationHub = ActiveWorkspaceActivationHub()
        let sessionOutputHub = SessionOutputHub()
        let viewModel = ReplayViewModel(
            sessionID: "session-1",
            commandBus: bus,
            activationHub: activationHub,
            sessionOutputHub: sessionOutputHub
        )

        await viewModel.activate()
        XCTAssertEqual(viewModel.emptyStateMessage, "Waiting for project activation...")
        let initialCallCount = await bus.callCount()
        XCTAssertEqual(initialCallCount, 0)

        activationHub.update(.open(workspaceID: UUID(), projectID: "project-1"))

        try await waitUntil {
            await bus.callCount() == 1
                && viewModel.currentFrame == "restored\n"
        }
    }

    func testReplayViewModelBuffersLiveOutputDuringBootstrap() async throws {
        let bus = ReplayCommandBus(
            timelineJSON: #"[{"timestamp":"2026-03-06T08:00:00Z","kind":"ScrollbackSnapshot","summary":"snapshot","payload":{"data":"restored\n","chunk":null}}]"#,
            delayNanos: 200_000_000
        )
        let activationHub = ActiveWorkspaceActivationHub()
        let sessionOutputHub = SessionOutputHub()
        let viewModel = ReplayViewModel(
            sessionID: "session-1",
            commandBus: bus,
            activationHub: activationHub,
            sessionOutputHub: sessionOutputHub
        )

        activationHub.update(.open(workspaceID: UUID(), projectID: "project-1"))
        await viewModel.activate()
        sessionOutputHub.publish(sessionID: "session-1", chunk: "live\n")

        try await waitUntil {
            viewModel.currentFrame == "restored\nlive\n"
        }
    }

    func testReplayViewModelDeduplicatesBufferedChunkAlreadyPresentInTimeline() async throws {
        let bus = ReplayCommandBus(
            timelineJSON: #"[{"timestamp":"2026-03-06T08:00:00Z","kind":"ScrollbackSnapshot","summary":"snapshot","payload":{"data":"restored\nlive\n","chunk":null}}]"#,
            delayNanos: 200_000_000
        )
        let activationHub = ActiveWorkspaceActivationHub()
        let sessionOutputHub = SessionOutputHub()
        let viewModel = ReplayViewModel(
            sessionID: "session-1",
            commandBus: bus,
            activationHub: activationHub,
            sessionOutputHub: sessionOutputHub
        )

        activationHub.update(.open(workspaceID: UUID(), projectID: "project-1"))
        await viewModel.activate()
        sessionOutputHub.publish(sessionID: "session-1", chunk: "live\n")

        try await waitUntil {
            viewModel.currentFrame == "restored\nlive\n"
        }
        XCTAssertEqual(viewModel.currentFrame, "restored\nlive\n")
    }
}
