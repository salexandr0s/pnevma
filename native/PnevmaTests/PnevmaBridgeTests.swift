import XCTest
@testable import Pnevma

@MainActor
final class PnevmaBridgeTests: XCTestCase {
    private let probeMethod = "__bridge_probe__.missing"

    private func syncCallOffMain(
        _ bridge: PnevmaBridge,
        method: String,
        params: String
    ) async -> BridgeCallResult? {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(returning: bridge.call(method: method, params: params))
            }
        }
    }

    // MARK: - Async

    func testAsyncCallCompletesWithCallback() {
        let bridge = PnevmaBridge()
        let expectation = self.expectation(description: "async callback fires")

        bridge.callAsync(method: "task.list", params: "{}") { _ in
            expectation.fulfill()
        }

        waitForExpectations(timeout: 3)
        bridge.destroy()
    }

    func testDestroyPreventsSubsequentCalls() async {
        let bridge = PnevmaBridge()
        bridge.destroy()

        let syncResult = await syncCallOffMain(bridge, method: probeMethod, params: "{}")
        XCTAssertNil(syncResult, "sync call after destroy should return nil")

        let expectation = self.expectation(description: "async callback fires with nil")
        bridge.callAsync(method: "task.list", params: "{}") { result in
            XCTAssertNil(result, "async call after destroy should complete with nil")
            expectation.fulfill()
        }
        await fulfillment(of: [expectation], timeout: 3)
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
        bridge.destroy()
    }

    // MARK: - In-Flight Teardown Safety

    func testAsyncCallDuringDestroy() {
        let bridge = PnevmaBridge()
        bridge.callAsync(method: "task.list", params: "{}") { _ in }
        bridge.destroy()
    }

    func testDestroyDoesNotCrashWithPendingCallbacks() {
        let bridge = PnevmaBridge()
        for _ in 0..<5 {
            bridge.callAsync(method: "task.list", params: "{}") { _ in }
        }
        bridge.destroy()
    }
}
