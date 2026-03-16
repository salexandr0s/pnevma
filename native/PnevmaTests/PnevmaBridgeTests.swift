import XCTest
@testable import Pnevma

final class PnevmaBridgeTests: XCTestCase {

    // MARK: - Init & Destroy

    func testBridgeInitAndDestroy() {
        let bridge = PnevmaBridge()
        // Verify a sync call returns a non-nil result (even if it's an error,
        // the bridge is alive).
        let result = bridge.call(method: "task.list", params: "{}")
        XCTAssertNotNil(result, "sync call on a live bridge should return non-nil")

        bridge.destroy()

        // After destroy, calls should return nil.
        let afterDestroy = bridge.call(method: "task.list", params: "{}")
        XCTAssertNil(afterDestroy, "sync call after destroy should return nil")
    }

    // MARK: - Async

    func testAsyncCallCompletesWithCallback() {
        let bridge = PnevmaBridge()
        let expectation = self.expectation(description: "async callback fires")

        bridge.callAsync(method: "task.list", params: "{}") { result in
            // Result may be success or error depending on DB state — just
            // verify the callback actually fires.
            expectation.fulfill()
        }

        waitForExpectations(timeout: 3)
        bridge.destroy()
    }

    func testDestroyPreventsSubsequentCalls() {
        let bridge = PnevmaBridge()
        bridge.destroy()

        let syncResult = bridge.call(method: "task.list", params: "{}")
        XCTAssertNil(syncResult, "sync call after destroy should return nil")

        let expectation = self.expectation(description: "async callback fires with nil")
        bridge.callAsync(method: "task.list", params: "{}") { result in
            XCTAssertNil(result, "async call after destroy should complete with nil")
            expectation.fulfill()
        }
        waitForExpectations(timeout: 3)
    }

    func testConcurrentAsyncCallsFromSwift() {
        let bridge = PnevmaBridge()
        let expectations = (0..<10).map { i in
            self.expectation(description: "async call \(i)")
        }

        DispatchQueue.concurrentPerform(iterations: 10) { i in
            bridge.callAsync(method: "task.list", params: "{}") { _ in
                expectations[i].fulfill()
            }
        }

        waitForExpectations(timeout: 5)
        bridge.destroy()
    }

    func testBridgeDestroyIsIdempotent() {
        let bridge = PnevmaBridge()
        bridge.destroy()
        // Second destroy must not crash.
        bridge.destroy()
    }

    // MARK: - In-Flight Teardown Safety

    func testAsyncCallDuringDestroy() {
        // Fire an async call and immediately destroy — must not crash.
        let bridge = PnevmaBridge()
        bridge.callAsync(method: "task.list", params: "{}") { _ in }
        bridge.destroy()
    }

    func testDestroyDoesNotCrashWithPendingCallbacks() {
        // Fire multiple async calls and destroy without waiting for completion.
        let bridge = PnevmaBridge()
        for _ in 0..<5 {
            bridge.callAsync(method: "task.list", params: "{}") { _ in }
        }
        bridge.destroy()
    }
}
