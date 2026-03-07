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
        let rightID = engine.splitPane(rootID, direction: .horizontal)!

        // Register descriptors so deserialization doesn't prune as orphans.
        for id in [rootID, rightID] {
            engine.upsertPersistedPane(PersistedPane(
                paneID: id, type: "terminal",
                workingDirectory: nil, sessionID: nil, taskID: nil, metadataJSON: nil
            ))
        }

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

    // MARK: - replacingLeaf

    func testReplacingLeafFindsTarget() {
        let oldID = PaneID()
        let newID = PaneID()
        let node = SplitNode.leaf(oldID)
        let result = node.replacingLeaf(oldID, with: newID)
        XCTAssertEqual(result?.allPaneIDs, [newID])
    }

    func testReplacingLeafReturnsNilWhenNotFound() {
        let a = PaneID()
        let b = PaneID()
        let node = SplitNode.leaf(a)
        XCTAssertNil(node.replacingLeaf(b, with: PaneID()))
    }

    func testReplacingLeafInSplitTree() {
        let a = PaneID()
        let b = PaneID()
        let c = PaneID()
        let tree = SplitNode.split(
            direction: .horizontal, ratio: 0.5,
            first: .leaf(a), second: .leaf(b)
        )
        let result = tree.replacingLeaf(b, with: c)
        XCTAssertNotNil(result)
        XCTAssertEqual(Set(result!.allPaneIDs), [a, c])
    }

    // MARK: - strippingOrphanedLeaves

    func testStrippingOrphanedLeavesKeepsValid() {
        let a = PaneID()
        let b = PaneID()
        let tree = SplitNode.split(
            direction: .horizontal, ratio: 0.5,
            first: .leaf(a), second: .leaf(b)
        )
        let result = tree.strippingOrphanedLeaves(keeping: [a, b])
        XCTAssertEqual(Set(result!.allPaneIDs), [a, b])
    }

    func testStrippingOrphanedLeavesRemovesOrphan() {
        let a = PaneID()
        let b = PaneID()
        let tree = SplitNode.split(
            direction: .horizontal, ratio: 0.5,
            first: .leaf(a), second: .leaf(b)
        )
        let result = tree.strippingOrphanedLeaves(keeping: [a])
        XCTAssertEqual(result?.allPaneIDs, [a])
        // Should collapse to a leaf since only one child survives
        if case .leaf(let id) = result {
            XCTAssertEqual(id, a)
        } else {
            XCTFail("Expected leaf after pruning one side")
        }
    }

    func testStrippingOrphanedLeavesAllOrphans() {
        let a = PaneID()
        let b = PaneID()
        let tree = SplitNode.split(
            direction: .horizontal, ratio: 0.5,
            first: .leaf(a), second: .leaf(b)
        )
        let result = tree.strippingOrphanedLeaves(keeping: [])
        XCTAssertNil(result)
    }

    func testStrippingOrphanedLeavesIdentity() {
        let a = PaneID()
        let node = SplitNode.leaf(a)
        let result = node.strippingOrphanedLeaves(keeping: [a])
        XCTAssertEqual(result?.allPaneIDs, [a])
    }

    // MARK: - replacePane (engine level)

    func testReplacePaneUpdatesActiveID() {
        let rootID = PaneID()
        let engine = PaneLayoutEngine(rootPaneID: rootID)
        let newID = PaneID()

        XCTAssertTrue(engine.replacePane(rootID, with: newID))
        XCTAssertEqual(engine.activePaneID, newID)
        XCTAssertEqual(engine.root?.allPaneIDs, [newID])
    }

    func testReplacePaneReturnsFalseForMissingID() {
        let rootID = PaneID()
        let engine = PaneLayoutEngine(rootPaneID: rootID)

        XCTAssertFalse(engine.replacePane(PaneID(), with: PaneID()))
        // Original state unchanged
        XCTAssertEqual(engine.activePaneID, rootID)
    }

    func testReplacePanePreservesInactiveID() {
        let rootID = PaneID()
        let engine = PaneLayoutEngine(rootPaneID: rootID)
        let rightID = engine.splitPane(rootID, direction: .horizontal)!
        engine.setActivePane(rightID)

        let replacement = PaneID()
        XCTAssertTrue(engine.replacePane(rootID, with: replacement))
        // Active pane should stay on rightID, not jump to replacement
        XCTAssertEqual(engine.activePaneID, rightID)
        XCTAssertTrue(engine.root!.contains(replacement))
    }

    // MARK: - deserialize with orphans

    func testDeserializeStripsOrphanedPanes() {
        let rootID = PaneID()
        let engine = PaneLayoutEngine(rootPaneID: rootID)
        let rightID = engine.splitPane(rootID, direction: .horizontal)!

        // Persist descriptors for both panes
        engine.upsertPersistedPane(PersistedPane(
            paneID: rootID, type: "terminal",
            workingDirectory: nil, sessionID: nil, taskID: nil, metadataJSON: nil
        ))
        engine.upsertPersistedPane(PersistedPane(
            paneID: rightID, type: "terminal",
            workingDirectory: nil, sessionID: nil, taskID: nil, metadataJSON: nil
        ))

        guard let data = engine.serialize() else {
            XCTFail("serialize should succeed")
            return
        }

        // Tamper: remove one pane descriptor from the JSON to simulate an orphan.
        guard var json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              var panes = json["panes"] as? [[String: Any]] else {
            XCTFail("should be valid JSON")
            return
        }
        panes.removeAll { ($0["paneID"] as? String) == rightID.uuidString }
        json["panes"] = panes
        let tamperedData = try! JSONSerialization.data(withJSONObject: json)

        guard let restored = PaneLayoutEngine.deserialize(from: tamperedData) else {
            XCTFail("deserialize should handle orphans gracefully")
            return
        }

        // Only rootID should remain, as a leaf
        XCTAssertEqual(restored.root?.allPaneIDs, [rootID])
        XCTAssertEqual(restored.activePaneID, rootID)
    }
}
