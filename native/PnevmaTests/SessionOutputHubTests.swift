import XCTest
@testable import Pnevma

@MainActor
final class SessionOutputHubTests: XCTestCase {
    func testSessionOutputHubCoalescesBurstForSingleSession() {
        let expectation = expectation(description: "coalesced output")
        var receivedChunks: [String] = []
        let observerID = SessionOutputHub.shared.addObserver(for: "session-1") { event in
            receivedChunks.append(event.chunk)
            expectation.fulfill()
        }

        SessionOutputHub.shared.publish(sessionID: "session-1", chunk: "hello")
        SessionOutputHub.shared.publish(sessionID: "session-1", chunk: " world")

        waitForExpectations(timeout: 1.0)
        SessionOutputHub.shared.removeObserver(observerID)

        XCTAssertEqual(receivedChunks, ["hello world"])
    }

    func testSessionOutputHubFiltersBySessionID() {
        let expectation = expectation(description: "matching session only")
        var receivedChunks: [String] = []
        let observerID = SessionOutputHub.shared.addObserver(for: "session-2") { event in
            receivedChunks.append(event.chunk)
            expectation.fulfill()
        }

        SessionOutputHub.shared.publish(sessionID: "session-1", chunk: "ignore")
        SessionOutputHub.shared.publish(sessionID: "session-2", chunk: "deliver")

        waitForExpectations(timeout: 1.0)
        SessionOutputHub.shared.removeObserver(observerID)

        XCTAssertEqual(receivedChunks, ["deliver"])
    }
}
