import XCTest
@testable import Pnevma

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
