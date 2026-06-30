import XCTest
@testable import Domain

/// Contract tests for the recursive pane-split tree used to split one terminal tab into multiple
/// live panes (#68). They describe what `SplitNode` promises outward — that splitting replaces the
/// focused leaf, closing a pane collapses its sibling up, focus cycles through the leaves, and the
/// pure geometry sizes panes within a rect while reserving the divider gap and honoring an
/// axis-aware floor — not how it works inside. Works in `Double`/`SplitRect` so Domain stays free
/// of CoreGraphics. Mirrors `SplitLayoutTests`. Don't edit a contract test to make an
/// implementation pass; if the contract is wrong, flag it.
final class SplitTreeTests: XCTestCase {

    // MARK: leaves

    func testSingleLeafReportsItselfAsTheOnlyLeaf() {
        let tree = SplitNode.leaf("a")
        XCTAssertEqual(tree.leafIDs, ["a"])
        XCTAssertEqual(tree.firstLeaf, "a")
        XCTAssertEqual(tree.leafCount, 1)
        XCTAssertTrue(tree.contains("a"))
        XCTAssertFalse(tree.contains("b"))
    }

    func testLeafIDsAreReportedInDepthFirstFirstThenSecondOrder() {
        let tree = SplitNode.split(axis: .horizontal, fraction: 0.5,
                                   first: .leaf("a"),
                                   second: .split(axis: .vertical, fraction: 0.5,
                                                  first: .leaf("b"), second: .leaf("c")))
        XCTAssertEqual(tree.leafIDs, ["a", "b", "c"])
        XCTAssertEqual(tree.firstLeaf, "a")
        XCTAssertEqual(tree.leafCount, 3)
    }

    // MARK: insertSplit

    func testInsertSplitReplacesTheFocusedLeafWithAnEvenTwoChildSplit() {
        let tree = SplitNode.leaf("a")
        let split = tree.insertSplit(focused: "a", axis: .horizontal, newLeaf: "b", newLeafTrailing: true)
        XCTAssertEqual(split, .split(axis: .horizontal, fraction: 0.5, first: .leaf("a"), second: .leaf("b")))
        XCTAssertEqual(split.leafIDs, ["a", "b"])
    }

    func testInsertSplitLeadingPlacesTheNewLeafFirst() {
        let split = SplitNode.leaf("a").insertSplit(focused: "a", axis: .vertical, newLeaf: "b", newLeafTrailing: false)
        XCTAssertEqual(split, .split(axis: .vertical, fraction: 0.5, first: .leaf("b"), second: .leaf("a")))
        XCTAssertEqual(split.leafIDs, ["b", "a"])
    }

    func testInsertSplitOnAnUnknownFocusedIdLeavesTheTreeUnchanged() {
        let tree = SplitNode.split(axis: .horizontal, fraction: 0.5, first: .leaf("a"), second: .leaf("b"))
        XCTAssertEqual(tree.insertSplit(focused: "z", axis: .vertical, newLeaf: "c", newLeafTrailing: true), tree)
    }

    func testInsertSplitDeepDownPreservesTheSiblings() {
        let tree = SplitNode.split(axis: .horizontal, fraction: 0.4, first: .leaf("a"), second: .leaf("b"))
        let split = tree.insertSplit(focused: "b", axis: .vertical, newLeaf: "c", newLeafTrailing: true)
        XCTAssertEqual(split, .split(axis: .horizontal, fraction: 0.4,
                                     first: .leaf("a"),
                                     second: .split(axis: .vertical, fraction: 0.5, first: .leaf("b"), second: .leaf("c"))))
        XCTAssertEqual(split.leafIDs, ["a", "b", "c"])
    }

    // MARK: remove

    func testRemovingALeafCollapsesItsLoneSiblingIntoTheParentSlot() {
        let tree = SplitNode.split(axis: .horizontal, fraction: 0.3, first: .leaf("a"), second: .leaf("b"))
        XCTAssertEqual(tree.remove("a"), .leaf("b"))
        XCTAssertEqual(tree.remove("b"), .leaf("a"))
    }

    func testRemovingTheOnlyLeafReturnsNil() {
        XCTAssertNil(SplitNode.leaf("a").remove("a"))
    }

    func testRemovingAnUnknownIdLeavesTheTreeUnchanged() {
        let tree = SplitNode.split(axis: .vertical, fraction: 0.5, first: .leaf("a"), second: .leaf("b"))
        XCTAssertEqual(tree.remove("z"), tree)
    }

    func testRemovingADeepLeafCollapsesOnlyThatBranch() {
        let tree = SplitNode.split(axis: .horizontal, fraction: 0.5,
                                   first: .leaf("a"),
                                   second: .split(axis: .vertical, fraction: 0.5, first: .leaf("b"), second: .leaf("c")))
        // Dropping "b" collapses the inner split to its lone sibling "c", which takes the inner slot.
        XCTAssertEqual(tree.remove("b"), .split(axis: .horizontal, fraction: 0.5, first: .leaf("a"), second: .leaf("c")))
        XCTAssertEqual(tree.remove("b")?.leafIDs, ["a", "c"])
    }

    // MARK: focus navigation (⌘] / ⌘[)

    func testFocusNeighborCyclesNextAndPreviousAndWraps() {
        let tree = SplitNode.split(axis: .horizontal, fraction: 0.5,
                                   first: .leaf("a"),
                                   second: .split(axis: .vertical, fraction: 0.5, first: .leaf("b"), second: .leaf("c")))
        XCTAssertEqual(tree.focusNeighbor(of: "a", .next), "b")
        XCTAssertEqual(tree.focusNeighbor(of: "b", .next), "c")
        XCTAssertEqual(tree.focusNeighbor(of: "c", .next), "a")   // wraps forward
        XCTAssertEqual(tree.focusNeighbor(of: "a", .previous), "c")   // wraps back
        XCTAssertEqual(tree.focusNeighbor(of: "b", .previous), "a")
    }

    func testFocusNeighborOnASingleLeafIsANoOp() {
        let tree = SplitNode.leaf("a")
        XCTAssertNil(tree.focusNeighbor(of: "a", .next))
        XCTAssertNil(tree.focusNeighbor(of: "a", .previous))
    }

    func testFocusNeighborOfAnUnknownIdIsNil() {
        let tree = SplitNode.split(axis: .vertical, fraction: 0.5, first: .leaf("a"), second: .leaf("b"))
        XCTAssertNil(tree.focusNeighbor(of: "z", .next))
    }

    // MARK: frames

    private let rect = SplitRect(minX: 0, minY: 0, width: 1000, height: 800)
    private let divider: Double = 6

    func testFramesForASingleLeafFillTheRect() {
        let frames = SplitNode.leaf("a").frames(in: rect, divider: divider)
        XCTAssertEqual(frames.count, 1)
        XCTAssertEqual(frames[0].0, "a")
        XCTAssertEqual(frames[0].1, rect)
    }

    func testFramesSplitSideBySideReserveTheDividerGap() {
        // .horizontal = side by side: divide the width, first on the left, second on the right.
        let tree = SplitNode.split(axis: .horizontal, fraction: 0.5, first: .leaf("a"), second: .leaf("b"))
        let frames = Dictionary(uniqueKeysWithValues: tree.frames(in: rect, divider: divider))
        let a = frames["a"]!, b = frames["b"]!
        XCTAssertEqual(a.height, 800, accuracy: 1e-9)
        XCTAssertEqual(b.height, 800, accuracy: 1e-9)
        XCTAssertEqual(a.minX, 0, accuracy: 1e-9)
        XCTAssertEqual(b.minX, a.width + divider, accuracy: 1e-9)
        XCTAssertEqual(a.width + divider + b.width, rect.width, accuracy: 1e-9)
    }

    func testFramesStackedSplitDivideTheHeight() {
        // .vertical = stacked: divide the height, first on top, second below.
        let tree = SplitNode.split(axis: .vertical, fraction: 0.5, first: .leaf("a"), second: .leaf("b"))
        let frames = Dictionary(uniqueKeysWithValues: tree.frames(in: rect, divider: divider))
        let a = frames["a"]!, b = frames["b"]!
        XCTAssertEqual(a.width, 1000, accuracy: 1e-9)
        XCTAssertEqual(b.width, 1000, accuracy: 1e-9)
        XCTAssertEqual(a.minY, 0, accuracy: 1e-9)
        XCTAssertEqual(b.minY, a.height + divider, accuracy: 1e-9)
        XCTAssertEqual(a.height + divider + b.height, rect.height, accuracy: 1e-9)
    }

    func testFramesHonorTheFraction() {
        let tree = SplitNode.split(axis: .horizontal, fraction: 0.4, first: .leaf("a"), second: .leaf("b"))
        let frames = Dictionary(uniqueKeysWithValues: tree.frames(in: rect, divider: divider))
        // The first child gets `fraction` of the width left after the divider gap.
        XCTAssertEqual(frames["a"]!.width, (rect.width - divider) * 0.4, accuracy: 1e-9)
    }

    func testFramesClampSideBySidePanesToTheWidthFloor() {
        // A tiny fraction can't shrink a side-by-side pane below minPane (the width floor).
        let tree = SplitNode.split(axis: .horizontal, fraction: 0.01, first: .leaf("a"), second: .leaf("b"))
        let frames = Dictionary(uniqueKeysWithValues: tree.frames(in: rect, divider: divider))
        XCTAssertEqual(frames["a"]!.width, SplitLayout.minPane, accuracy: 1e-9)
        XCTAssertGreaterThanOrEqual(frames["b"]!.width, SplitLayout.minPane - 1e-9)
    }

    func testFramesClampStackedPanesToTheHeightFloor() {
        // The axis-aware floor: a *stacked* pane is bounded by rows (minTerminalHeight = 120), far
        // below the side-by-side width floor (minPane = 220). Proves the floor follows the axis.
        let tree = SplitNode.split(axis: .vertical, fraction: 0.01, first: .leaf("a"), second: .leaf("b"))
        let frames = Dictionary(uniqueKeysWithValues: tree.frames(in: rect, divider: divider))
        XCTAssertEqual(frames["a"]!.height, SplitLayout.minTerminalHeight, accuracy: 1e-9)
        XCTAssertLessThan(SplitLayout.minTerminalHeight, SplitLayout.minPane)   // the two floors differ
    }

    func testFramesNestAndStayWithinTheParentRect() {
        let tree = SplitNode.split(axis: .horizontal, fraction: 0.6,
                                   first: .split(axis: .vertical, fraction: 0.4, first: .leaf("a"), second: .leaf("b")),
                                   second: .leaf("c"))
        for (_, frame) in tree.frames(in: rect, divider: divider) {
            XCTAssertGreaterThanOrEqual(frame.minX, rect.minX - 1e-9)
            XCTAssertGreaterThanOrEqual(frame.minY, rect.minY - 1e-9)
            XCTAssertLessThanOrEqual(frame.minX + frame.width, rect.minX + rect.width + 1e-9)
            XCTAssertLessThanOrEqual(frame.minY + frame.height, rect.minY + rect.height + 1e-9)
            XCTAssertGreaterThan(frame.width, 0)
            XCTAssertGreaterThan(frame.height, 0)
        }
    }

    // MARK: dividers

    func testDividerCountEqualsTheNumberOfSplits() {
        XCTAssertEqual(SplitNode.leaf("a").dividers(in: rect, divider: divider).count, 0)
        let one = SplitNode.split(axis: .horizontal, fraction: 0.5, first: .leaf("a"), second: .leaf("b"))
        XCTAssertEqual(one.dividers(in: rect, divider: divider).count, 1)
        let two = SplitNode.split(axis: .horizontal, fraction: 0.5,
                                  first: .leaf("a"),
                                  second: .split(axis: .vertical, fraction: 0.5, first: .leaf("b"), second: .leaf("c")))
        XCTAssertEqual(two.dividers(in: rect, divider: divider).count, 2)
    }

    func testDividerCarriesItsPathAxisExtentAndSeamRect() {
        let tree = SplitNode.split(axis: .horizontal, fraction: 0.5, first: .leaf("a"), second: .leaf("b"))
        let d = tree.dividers(in: rect, divider: divider)[0]
        XCTAssertEqual(d.path, [])                      // the root split's divider
        XCTAssertEqual(d.axis, .horizontal)
        XCTAssertEqual(d.extent, rect.width - divider, accuracy: 1e-9)   // span used to convert a drag to a fraction
        XCTAssertEqual(d.rect.width, divider, accuracy: 1e-9)           // the seam strip is divider-thick
        let frames = Dictionary(uniqueKeysWithValues: tree.frames(in: rect, divider: divider))
        XCTAssertEqual(d.rect.minX, frames["a"]!.width, accuracy: 1e-9) // sits at the seam
    }

    func testNestedDividerPathsMatchTheChildSlots() {
        let tree = SplitNode.split(axis: .horizontal, fraction: 0.5,
                                   first: .leaf("a"),
                                   second: .split(axis: .vertical, fraction: 0.5, first: .leaf("b"), second: .leaf("c")))
        let paths = Set(tree.dividers(in: rect, divider: divider).map(\.path))
        XCTAssertEqual(paths, [[], [1]])   // root divider at [], the inner split (second child) at [1]
    }

    // MARK: setFraction

    func testSetFractionUpdatesTheTargetedNodeAndClampsToTheUnitRange() {
        let tree = SplitNode.split(axis: .horizontal, fraction: 0.5, first: .leaf("a"), second: .leaf("b"))
        XCTAssertEqual(tree.setFraction(at: [], to: 0.3),
                       .split(axis: .horizontal, fraction: 0.3, first: .leaf("a"), second: .leaf("b")))
        XCTAssertEqual(tree.setFraction(at: [], to: 1.5),
                       .split(axis: .horizontal, fraction: 1.0, first: .leaf("a"), second: .leaf("b")))
        XCTAssertEqual(tree.setFraction(at: [], to: -0.2),
                       .split(axis: .horizontal, fraction: 0.0, first: .leaf("a"), second: .leaf("b")))
    }

    func testSetFractionDescendsThePathToANestedNode() {
        let tree = SplitNode.split(axis: .horizontal, fraction: 0.5,
                                   first: .leaf("a"),
                                   second: .split(axis: .vertical, fraction: 0.7, first: .leaf("b"), second: .leaf("c")))
        XCTAssertEqual(tree.setFraction(at: [1], to: 0.2),
                       .split(axis: .horizontal, fraction: 0.5,
                              first: .leaf("a"),
                              second: .split(axis: .vertical, fraction: 0.2, first: .leaf("b"), second: .leaf("c"))))
    }

    func testFractionAtReadsTheNodeSetFractionWrites() {
        let tree = SplitNode.split(axis: .horizontal, fraction: 0.5,
                                   first: .leaf("a"),
                                   second: .split(axis: .vertical, fraction: 0.7, first: .leaf("b"), second: .leaf("c")))
        XCTAssertEqual(tree.fraction(at: []), 0.5)
        XCTAssertEqual(tree.fraction(at: [1]), 0.7)
        XCTAssertNil(tree.fraction(at: [0]), "the first child is a leaf, not a split")
        XCTAssertNil(SplitNode.leaf("a").fraction(at: []))
    }

    func testSetFractionAtAPathThatRunsIntoALeafLeavesTheTreeUnchanged() {
        let tree = SplitNode.split(axis: .horizontal, fraction: 0.5, first: .leaf("a"), second: .leaf("b"))
        XCTAssertEqual(tree.setFraction(at: [0, 0, 0], to: 0.3), tree)
        XCTAssertEqual(SplitNode.leaf("a").setFraction(at: [0], to: 0.3), .leaf("a"))
    }

    // MARK: mapLeaves / compacted (the restore re-key + connection-deleted prune)

    func testMapLeavesPreservesStructureAndTransformsPayloads() {
        let tree = SplitNode.split(axis: .vertical, fraction: 0.4,
                                   first: .leaf(1),
                                   second: .split(axis: .horizontal, fraction: 0.6, first: .leaf(2), second: .leaf(3)))
        let mapped = tree.mapLeaves { "#\($0)" }
        XCTAssertEqual(mapped, .split(axis: .vertical, fraction: 0.4,
                                      first: .leaf("#1"),
                                      second: .split(axis: .horizontal, fraction: 0.6, first: .leaf("#2"), second: .leaf("#3"))))
    }

    func testMapLeavesVisitsEachLeafOnceInLeafOrder() {
        let tree = SplitNode.split(axis: .horizontal, fraction: 0.5,
                                   first: .leaf("a"),
                                   second: .split(axis: .vertical, fraction: 0.5, first: .leaf("b"), second: .leaf("c")))
        var visited: [String] = []
        _ = tree.mapLeaves { visited.append($0); return $0 }
        XCTAssertEqual(visited, tree.leafIDs)
    }

    func testCompactedDropsNilLeavesAndCollapsesTheTree() {
        // A leaf whose payload couldn't be resolved (a deleted connection on restore) is dropped and
        // its sibling collapses up — exactly like `remove`.
        let tree = SplitNode.split(axis: .horizontal, fraction: 0.5,
                                   first: .leaf(Optional(1)),
                                   second: .split(axis: .vertical, fraction: 0.5,
                                                  first: .leaf(Optional<Int>.none), second: .leaf(Optional(3))))
        XCTAssertEqual(tree.compacted(), .split(axis: .horizontal, fraction: 0.5, first: .leaf(1), second: .leaf(3)))
    }

    func testCompactedReturnsNilWhenEveryLeafIsNil() {
        let tree = SplitNode.split(axis: .horizontal, fraction: 0.5,
                                   first: .leaf(Optional<Int>.none), second: .leaf(Optional<Int>.none))
        XCTAssertNil(tree.compacted())
    }

    // MARK: Codable

    func testCodableRoundTripsLeafAndNestedTrees() throws {
        let trees: [SplitNode<String>] = [
            .leaf("solo"),
            .split(axis: .horizontal, fraction: 0.45,
                   first: .leaf("a"),
                   second: .split(axis: .vertical, fraction: 0.6, first: .leaf("b"), second: .leaf("c"))),
        ]
        for tree in trees {
            let data = try JSONEncoder().encode(tree)
            let decoded = try JSONDecoder().decode(SplitNode<String>.self, from: data)
            XCTAssertEqual(decoded, tree)
        }
    }
}
