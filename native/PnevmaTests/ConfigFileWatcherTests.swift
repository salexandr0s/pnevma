import Foundation
import XCTest
@testable import Pnevma

final class ConfigFileWatcherTests: XCTestCase {

    private var tempDir: URL!

    override func setUp() {
        super.setUp()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ConfigFileWatcherTests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempDir)
        super.tearDown()
    }

    func testCallbackFiredOnFileWrite() {
        let fileURL = tempDir.appendingPathComponent("test.toml")
        FileManager.default.createFile(atPath: fileURL.path, contents: Data("initial".utf8))

        let expectation = expectation(description: "onChange called")
        let watcher = ConfigFileWatcher(url: fileURL, debounceInterval: 0.05) {
            expectation.fulfill()
        }
        watcher.start()

        // Write to file after a short delay
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            try? "updated".write(to: fileURL, atomically: true, encoding: .utf8)
        }

        waitForExpectations(timeout: 2)
        watcher.stop()
    }

    func testCallbackFiredOnAtomicRename() {
        let fileURL = tempDir.appendingPathComponent("config.toml")
        FileManager.default.createFile(atPath: fileURL.path, contents: Data("v1".utf8))

        let expectation = expectation(description: "onChange called after rename")
        let watcher = ConfigFileWatcher(url: fileURL, debounceInterval: 0.05) {
            expectation.fulfill()
        }
        watcher.start()

        // Simulate Vim-style atomic write: write to temp, rename over original
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            let tmpURL = self.tempDir.appendingPathComponent("config.toml.tmp")
            try? "v2".write(to: tmpURL, atomically: false, encoding: .utf8)
            try? FileManager.default.removeItem(at: fileURL)
            try? FileManager.default.moveItem(at: tmpURL, to: fileURL)
        }

        waitForExpectations(timeout: 2)
        watcher.stop()
    }

    func testStopPreventsCallback() {
        let fileURL = tempDir.appendingPathComponent("stopped.toml")
        FileManager.default.createFile(atPath: fileURL.path, contents: Data("initial".utf8))

        var callbackCount = 0
        let watcher = ConfigFileWatcher(url: fileURL, debounceInterval: 0.05) {
            callbackCount += 1
        }
        watcher.start()
        watcher.stop()

        try? "modified".write(to: fileURL, atomically: true, encoding: .utf8)

        let expectation = expectation(description: "wait for potential callback")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            expectation.fulfill()
        }
        waitForExpectations(timeout: 1)

        XCTAssertEqual(callbackCount, 0)
    }
}
