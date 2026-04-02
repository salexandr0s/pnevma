import Cocoa

/// Direction of a binary split.
enum SplitDirection: String, Codable {
    case horizontal  // left | right
    case vertical    // top / bottom
}

/// Navigation direction for pane focus movement.
enum NavigationDirection {
    case left, right, up, down
}

/// A node in the binary split tree.
/// Each node is either a `.leaf` containing a single pane, or a `.split`
/// dividing space between two child nodes.
indirect enum SplitNode: Codable {
    case leaf(PaneID)
    case split(direction: SplitDirection, ratio: CGFloat, first: SplitNode, second: SplitNode)

    // MARK: - Codable

    private enum CodingKeys: String, CodingKey {
        case type, paneID, direction, ratio, first, second
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .leaf(let id):
            try container.encode("leaf", forKey: .type)
            try container.encode(id, forKey: .paneID)
        case .split(let dir, let ratio, let first, let second):
            try container.encode("split", forKey: .type)
            try container.encode(dir, forKey: .direction)
            try container.encode(ratio, forKey: .ratio)
            try container.encode(first, forKey: .first)
            try container.encode(second, forKey: .second)
        }
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(String.self, forKey: .type)
        switch type {
        case "leaf":
            let id = try container.decode(PaneID.self, forKey: .paneID)
            self = .leaf(id)
        case "split":
            let dir = try container.decode(SplitDirection.self, forKey: .direction)
            let ratio = try container.decode(CGFloat.self, forKey: .ratio)
            let first = try container.decode(SplitNode.self, forKey: .first)
            let second = try container.decode(SplitNode.self, forKey: .second)
            self = .split(direction: dir, ratio: ratio, first: first, second: second)
        default:
            throw DecodingError.dataCorruptedError(forKey: .type, in: container,
                                                    debugDescription: "Unknown node type: \(type)")
        }
    }
}

// MARK: - SplitNode Queries

extension SplitNode {
    /// All pane IDs in this subtree, in depth-first order.
    var allPaneIDs: [PaneID] {
        switch self {
        case .leaf(let id): return [id]
        case .split(_, _, let first, let second):
            return first.allPaneIDs + second.allPaneIDs
        }
    }

    /// Whether this subtree contains the given pane.
    func contains(_ paneID: PaneID) -> Bool {
        switch self {
        case .leaf(let id): return id == paneID
        case .split(_, _, let first, let second):
            return first.contains(paneID) || second.contains(paneID)
        }
    }

    /// Replace a single leaf node's ID, preserving the tree structure.
    /// Returns nil if the target leaf was not found.
    func replacingLeaf(_ target: PaneID, with newID: PaneID) -> SplitNode? {
        switch self {
        case .leaf(let id):
            return id == target ? .leaf(newID) : nil
        case .split(let dir, let ratio, let first, let second):
            if let newFirst = first.replacingLeaf(target, with: newID) {
                return .split(direction: dir, ratio: ratio, first: newFirst, second: second)
            }
            if let newSecond = second.replacingLeaf(target, with: newID) {
                return .split(direction: dir, ratio: ratio, first: first, second: newSecond)
            }
            return nil
        }
    }

    /// Remove leaf nodes whose IDs aren't in `keeping`.
    /// Returns nil if the entire subtree was pruned.
    func strippingOrphanedLeaves(keeping validIDs: Set<PaneID>) -> SplitNode? {
        switch self {
        case .leaf(let id):
            return validIDs.contains(id) ? self : nil
        case .split(let dir, let ratio, let first, let second):
            let prunedFirst = first.strippingOrphanedLeaves(keeping: validIDs)
            let prunedSecond = second.strippingOrphanedLeaves(keeping: validIDs)
            switch (prunedFirst, prunedSecond) {
            case let (f?, s?):
                return .split(direction: dir, ratio: ratio, first: f, second: s)
            case let (f?, nil):
                return f
            case let (nil, s?):
                return s
            case (nil, nil):
                return nil
            }
        }
    }
}

// MARK: - PaneLayoutEngine

/// Binary tree-based pane layout engine.
/// Each node is either a split (horizontal or vertical) or a leaf pane.
///
/// The engine computes frames for all panes given a bounding rectangle,
/// and supports split/close/resize/navigate operations.
class PaneLayoutEngine {

    /// Root of the split tree. Nil if no panes exist.
    var root: SplitNode?

    /// The currently focused pane.
    var activePaneID: PaneID?

    /// Cached layout frames, recomputed on every `layout(in:)` call.
    private(set) var paneFrames: [PaneID: NSRect] = [:]
    private(set) var paneDescriptors: [PaneID: PersistedPane] = [:]

    // MARK: - Init

    /// Create a layout engine with a single root pane.
    init(rootPaneID: PaneID) {
        self.root = .leaf(rootPaneID)
        self.activePaneID = rootPaneID
    }

    /// Create an empty layout engine (no panes yet).
    init() {
        self.root = nil
        self.activePaneID = nil
    }

    /// Reset the engine to a single root pane, clearing all existing state.
    /// Preserves the object identity (important for shared references).
    func reset(rootPaneID: PaneID) {
        root = .leaf(rootPaneID)
        activePaneID = rootPaneID
        paneFrames.removeAll()
        paneDescriptors.removeAll()
    }

    /// Clear all pane descriptors and cached frames.
    /// Used when replacing the tree contents in-place (e.g. template apply).
    func clearDescriptors() {
        paneDescriptors.removeAll()
        paneFrames.removeAll()
    }

    // MARK: - Layout Computation

    /// Compute frames for all panes within the given bounding rectangle.
    /// Call this whenever the container resizes.
    func layout(in rect: NSRect) {
        paneFrames.removeAll()
        guard let root = root else { return }
        computeFrames(node: root, rect: rect)
    }

    private func computeFrames(node: SplitNode, rect: NSRect) {
        switch node {
        case .leaf(let id):
            paneFrames[id] = rect

        case .split(let direction, let ratio, let first, let second):
            let (firstRect, secondRect) = splitRect(rect, direction: direction, ratio: ratio)
            computeFrames(node: first, rect: firstRect)
            computeFrames(node: second, rect: secondRect)
        }
    }

    private func splitRect(_ rect: NSRect, direction: SplitDirection, ratio: CGFloat) -> (NSRect, NSRect) {
        let divider = DesignTokens.Layout.dividerWidth
        switch direction {
        case .horizontal:
            let firstWidth = (rect.width - divider) * ratio
            let secondWidth = rect.width - firstWidth - divider
            let firstRect = NSRect(x: rect.minX, y: rect.minY,
                                   width: firstWidth, height: rect.height)
            let secondRect = NSRect(x: rect.minX + firstWidth + divider, y: rect.minY,
                                    width: secondWidth, height: rect.height)
            return (firstRect, secondRect)

        case .vertical:
            let firstHeight = (rect.height - divider) * ratio
            let secondHeight = rect.height - firstHeight - divider
            // Flipped coordinates (top-left origin): first=top (lower Y), second=bottom (higher Y).
            let firstRect = NSRect(x: rect.minX, y: rect.minY,
                                   width: rect.width, height: firstHeight)
            let secondRect = NSRect(x: rect.minX, y: rect.minY + firstHeight + divider,
                                    width: rect.width, height: secondHeight)
            return (firstRect, secondRect)
        }
    }

    // MARK: - Split Operations

    /// Split the given pane, creating a new pane alongside it.
    /// Returns the new pane's ID.
    @discardableResult
    func splitPane(_ paneID: PaneID, direction: SplitDirection,
                   ratio: CGFloat = 0.5, newPaneID: PaneID? = nil) -> PaneID? {
        guard let root = root else { return nil }
        let newID = newPaneID ?? PaneID()
        guard let newRoot = insertSplit(in: root, target: paneID, direction: direction,
                                        ratio: ratio, newPaneID: newID) else {
            return nil
        }
        self.root = newRoot
        self.activePaneID = newID
        return newID
    }

    private func insertSplit(in node: SplitNode, target: PaneID, direction: SplitDirection,
                             ratio: CGFloat, newPaneID: PaneID) -> SplitNode? {
        switch node {
        case .leaf(let id):
            if id == target {
                return .split(direction: direction, ratio: ratio,
                              first: .leaf(id), second: .leaf(newPaneID))
            }
            return nil

        case .split(let dir, let r, let first, let second):
            if let newFirst = insertSplit(in: first, target: target, direction: direction,
                                          ratio: ratio, newPaneID: newPaneID) {
                return .split(direction: dir, ratio: r, first: newFirst, second: second)
            }
            if let newSecond = insertSplit(in: second, target: target, direction: direction,
                                           ratio: ratio, newPaneID: newPaneID) {
                return .split(direction: dir, ratio: r, first: first, second: newSecond)
            }
            return nil
        }
    }

    // MARK: - Replace Operations

    /// Replace a leaf pane's ID in the tree without changing the structure.
    @discardableResult
    func replacePane(_ oldID: PaneID, with newID: PaneID) -> Bool {
        guard let root = root,
              let newRoot = root.replacingLeaf(oldID, with: newID) else {
            return false
        }
        self.root = newRoot
        if activePaneID == oldID {
            activePaneID = newID
        }
        return true
    }

    // MARK: - Close Operations

    /// Close the given pane. Its sibling takes over the parent's space.
    /// Returns true if the pane was found and removed.
    @discardableResult
    func closePane(_ paneID: PaneID) -> Bool {
        guard let root = root else { return false }

        // If root is the target leaf, clear everything.
        if case .leaf(let id) = root, id == paneID {
            self.root = nil
            self.activePaneID = nil
            return true
        }

        guard let newRoot = removePane(from: root, target: paneID) else { return false }
        self.root = newRoot

        // If the active pane was closed, focus the first available pane.
        if activePaneID == paneID {
            activePaneID = newRoot.allPaneIDs.first
        }
        return true
    }

    private func removePane(from node: SplitNode, target: PaneID) -> SplitNode? {
        guard case .split(let dir, let ratio, let first, let second) = node else {
            return nil
        }

        // If first child is the target leaf, return the second child.
        if case .leaf(let id) = first, id == target {
            return second
        }
        // If second child is the target leaf, return the first child.
        if case .leaf(let id) = second, id == target {
            return first
        }

        // Recurse into children.
        if let newFirst = removePane(from: first, target: target) {
            return .split(direction: dir, ratio: ratio, first: newFirst, second: second)
        }
        if let newSecond = removePane(from: second, target: target) {
            return .split(direction: dir, ratio: ratio, first: first, second: newSecond)
        }
        return nil
    }

    // MARK: - Resize

    /// Adjust the split ratio of the parent of the given pane.
    /// `delta` is added to the ratio (positive = first child grows).
    /// Only works correctly for simple (leaf-child) splits. For nested
    /// splits, use `resizeSplit(firstChildPaneIDs:delta:parentSize:)` instead.
    func resizeSplit(containing paneID: PaneID, delta: CGFloat, parentSize: CGFloat = 0) {
        guard let root = root else { return }
        self.root = adjustRatio(in: root, target: paneID, delta: delta, parentSize: parentSize)
    }

    /// Adjust the split ratio of the split node whose first child contains
    /// exactly the given set of pane IDs. `parentSize` is the pixel size of
    /// the split's container along the split axis, used for minimum-size clamping.
    func resizeSplit(firstChildPaneIDs: Set<PaneID>, delta: CGFloat, parentSize: CGFloat = 0) {
        guard let root = root else { return }
        self.root = adjustRatioByFirstChild(in: root, firstChildPaneIDs: firstChildPaneIDs, delta: delta, parentSize: parentSize)
    }

    /// Clamp a ratio so neither child falls below the minimum pane size.
    /// `parentSize` is the pixel size of the split's container along the split axis.
    private func clampedRatio(_ ratio: CGFloat, direction: SplitDirection, parentSize: CGFloat) -> CGFloat {
        let divider = DesignTokens.Layout.dividerWidth
        let minSize = direction == .horizontal
            ? DesignTokens.Layout.paneMinWidth
            : DesignTokens.Layout.paneMinHeight

        let available = parentSize - divider
        guard available > minSize * 2 else {
            // Container too small for pixel-based clamping; fall back to ratio limits.
            return min(0.9, max(0.1, ratio))
        }

        let minRatio = minSize / available
        let maxRatio = 1.0 - minRatio
        return min(maxRatio, max(minRatio, ratio))
    }

    private func adjustRatio(in node: SplitNode, target: PaneID, delta: CGFloat, parentSize: CGFloat) -> SplitNode {
        guard case .split(let dir, let ratio, let first, let second) = node else {
            return node
        }

        if first.contains(target) || second.contains(target) {
            // Check if target is an immediate child of this split.
            let isImmediate: Bool = {
                if case .leaf(let id) = first, id == target { return true }
                if case .leaf(let id) = second, id == target { return true }
                return false
            }()

            if isImmediate {
                let newRatio = clampedRatio(ratio + delta, direction: dir, parentSize: parentSize)
                return .split(direction: dir, ratio: newRatio, first: first, second: second)
            }

            // Recurse only into the child that contains the target.
            if first.contains(target) {
                let newFirst = adjustRatio(in: first, target: target, delta: delta, parentSize: parentSize)
                return .split(direction: dir, ratio: ratio, first: newFirst, second: second)
            } else {
                let newSecond = adjustRatio(in: second, target: target, delta: delta, parentSize: parentSize)
                return .split(direction: dir, ratio: ratio, first: first, second: newSecond)
            }
        }

        return node
    }

    private func adjustRatioByFirstChild(in node: SplitNode, firstChildPaneIDs: Set<PaneID>, delta: CGFloat, parentSize: CGFloat) -> SplitNode {
        guard case .split(let dir, let ratio, let first, let second) = node else {
            return node
        }

        // Match: this split's first child has exactly the target pane ID set.
        if Set(first.allPaneIDs) == firstChildPaneIDs {
            let newRatio = clampedRatio(ratio + delta, direction: dir, parentSize: parentSize)
            return .split(direction: dir, ratio: newRatio, first: first, second: second)
        }

        // Recurse into both children to find the target split.
        let newFirst = adjustRatioByFirstChild(in: first, firstChildPaneIDs: firstChildPaneIDs, delta: delta, parentSize: parentSize)
        let newSecond = adjustRatioByFirstChild(in: second, firstChildPaneIDs: firstChildPaneIDs, delta: delta, parentSize: parentSize)
        return .split(direction: dir, ratio: ratio, first: newFirst, second: newSecond)
    }

    // MARK: - Navigation

    /// Set the active pane.
    func setActivePane(_ paneID: PaneID) {
        if root?.contains(paneID) == true {
            activePaneID = paneID
        }
    }

    func upsertPersistedPane(_ pane: PersistedPane) {
        paneDescriptors[pane.paneID] = pane
    }

    func removePersistedPane(_ paneID: PaneID) {
        paneDescriptors.removeValue(forKey: paneID)
    }

    func persistedPane(for paneID: PaneID) -> PersistedPane? {
        paneDescriptors[paneID]
    }

    /// Navigate from the active pane in the given direction.
    /// Returns the newly focused pane ID, or nil if no neighbor exists.
    @discardableResult
    func navigate(_ direction: NavigationDirection) -> PaneID? {
        guard let active = activePaneID, !paneFrames.isEmpty else { return nil }
        guard let activeFrame = paneFrames[active] else { return nil }

        let candidates = paneFrames.filter { $0.key != active }
        var best: (PaneID, CGFloat)?

        for (id, frame) in candidates {
            let isNeighbor: Bool
            let distance: CGFloat

            switch direction {
            case .left:
                isNeighbor = frame.midX < activeFrame.minX
                distance = activeFrame.minX - frame.midX
            case .right:
                isNeighbor = frame.midX > activeFrame.maxX
                distance = frame.midX - activeFrame.maxX
            case .up:
                // Flipped coords: up = smaller Y
                isNeighbor = frame.midY < activeFrame.minY
                distance = activeFrame.minY - frame.midY
            case .down:
                // Flipped coords: down = larger Y
                isNeighbor = frame.midY > activeFrame.maxY
                distance = frame.midY - activeFrame.maxY
            }

            if isNeighbor {
                guard let currentBest = best else {
                    best = (id, distance)
                    continue
                }
                if distance < currentBest.1 {
                    best = (id, distance)
                }
            }
        }

        if let (id, _) = best {
            activePaneID = id
            return id
        }
        return nil
    }

    // MARK: - Equalize

    /// Reset split ratios to 0.5 (equal space).
    /// When `orientation` is nil, all splits are equalized.
    /// When provided, only splits matching that orientation are reset.
    func equalizeSplits(orientation: SplitDirection? = nil) {
        guard let root = root else { return }
        self.root = equalize(root, orientation: orientation)
    }

    private func equalize(_ node: SplitNode, orientation: SplitDirection?) -> SplitNode {
        switch node {
        case .leaf:
            return node
        case .split(let dir, let ratio, let first, let second):
            let nextRatio = if orientation == nil || orientation == dir { 0.5 } else { ratio }
            return .split(
                direction: dir,
                ratio: nextRatio,
                first: equalize(first, orientation: orientation),
                second: equalize(second, orientation: orientation)
            )
        }
    }

    // MARK: - Serialization

    func serialize() -> Data? {
        guard let root = root else { return nil }
        let panes = root.allPaneIDs.compactMap { paneDescriptors[$0] }
        let payload = SerializedLayout(root: root, activePaneID: activePaneID, panes: panes)
        return try? JSONEncoder().encode(payload)
    }

    static func deserialize(from data: Data) -> PaneLayoutEngine? {
        guard let payload = try? JSONDecoder().decode(SerializedLayout.self, from: data) else { return nil }
        let engine = PaneLayoutEngine()
        let descriptorMap = Dictionary(uniqueKeysWithValues: payload.panes.map { ($0.paneID, $0) })
        engine.paneDescriptors = descriptorMap

        // Strip leaf nodes that have no matching descriptor (orphaned panes).
        let validIDs = Set(descriptorMap.keys)
        engine.root = payload.root.strippingOrphanedLeaves(keeping: validIDs)

        // Validate activePaneID still exists in the pruned tree.
        if let active = payload.activePaneID, engine.root?.contains(active) == true {
            engine.activePaneID = active
        } else {
            engine.activePaneID = engine.root?.allPaneIDs.first
        }
        return engine
    }
}

// MARK: - Serialization Payload

private struct SerializedLayout: Codable {
    let root: SplitNode
    let activePaneID: PaneID?
    let panes: [PersistedPane]
}
