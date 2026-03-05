import XCTest
@testable import Pnevma

final class PaneLayoutEngineTests: XCTestCase {

    func testInitialState() {
        let rootID = PaneID()
        let engine = PaneLayoutEngine(rootPaneID: rootID)
        XCTAssertEqual(engine.activePaneID, rootID)
        XCTAssertNotNil(engine.root)
    }

    func testSplitHorizontalCreatesTwoChildren() {
        let rootID = PaneID()
        let engine = PaneLayoutEngine(rootPaneID: rootID)

        let newID = engine.splitPane(rootID, direction: .horizontal)
        XCTAssertNotNil(newID, "splitPane should return new pane ID")

        guard case .split(let dir, _, let first, let second) = engine.root else {
            XCTFail("root should be a split node after splitting")
            return
        }
        XCTAssertEqual(dir, .horizontal)
        XCTAssertEqual(first.allPaneIDs, [rootID])
        XCTAssertEqual(second.allPaneIDs, [newID!])
    }

    func testSplitVerticalCreatesTwoChildren() {
        let rootID = PaneID()
        let engine = PaneLayoutEngine(rootPaneID: rootID)

        let newID = engine.splitPane(rootID, direction: .vertical)
        XCTAssertNotNil(newID)

        guard case .split(let dir, _, _, _) = engine.root else {
            XCTFail("root should be a split node")
            return
        }
        XCTAssertEqual(dir, .vertical)
    }

    func testClosePaneRemovesIt() {
        let rootID = PaneID()
        let engine = PaneLayoutEngine(rootPaneID: rootID)
        let newID = engine.splitPane(rootID, direction: .horizontal)!

        // Close the new pane — root should go back to a leaf
        let closed = engine.closePane(newID)
        XCTAssertTrue(closed)
        guard case .leaf(let remainingID) = engine.root else {
            XCTFail("root should be a leaf after closing sibling")
            return
        }
        XCTAssertEqual(remainingID, rootID)
    }

    func testCloseLastPaneClearsRoot() {
        let rootID = PaneID()
        let engine = PaneLayoutEngine(rootPaneID: rootID)

        let closed = engine.closePane(rootID)
        XCTAssertTrue(closed)
        XCTAssertNil(engine.root)
        XCTAssertNil(engine.activePaneID)
    }

    func testNavigateFocusMovesToNeighbor() {
        let rootID = PaneID()
        let engine = PaneLayoutEngine(rootPaneID: rootID)
        let rightID = engine.splitPane(rootID, direction: .horizontal)!

        // Lay out in a known rect
        engine.layout(in: NSRect(x: 0, y: 0, width: 1000, height: 500))

        // Active pane is the newly split one (rightID). Navigate left.
        engine.setActivePane(rightID)
        let navigated = engine.navigate(.left)
        XCTAssertEqual(navigated, rootID, "navigating left from right pane should reach root pane")
    }

    func testResizeSplitAdjustsRatio() {
        let rootID = PaneID()
        let engine = PaneLayoutEngine(rootPaneID: rootID)
        let _ = engine.splitPane(rootID, direction: .horizontal, ratio: 0.5)

        engine.resizeSplit(containing: rootID, delta: 0.1)

        guard case .split(_, let ratio, _, _) = engine.root else {
            XCTFail("root should still be a split")
            return
        }
        XCTAssertEqual(ratio, 0.6, accuracy: 0.001)
    }

    func testSerializeDeserializeRoundTrip() {
        let rootID = PaneID()
        let engine = PaneLayoutEngine(rootPaneID: rootID)
        let _ = engine.splitPane(rootID, direction: .horizontal)

        guard let data = engine.serialize() else {
            XCTFail("serialize should succeed")
            return
        }

        guard let restored = PaneLayoutEngine.deserialize(from: data) else {
            XCTFail("deserialize should succeed")
            return
        }

        XCTAssertEqual(engine.root?.allPaneIDs, restored.root?.allPaneIDs)
    }
}
