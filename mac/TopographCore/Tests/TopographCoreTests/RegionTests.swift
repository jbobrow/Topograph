import CoreGraphics
import XCTest
@testable import TopographCore

final class RegionTests: XCTestCase {
    /// A top region of 3 items holding a fine one of 2, and a second top region of 1.
    private func tree() -> (RegionTree, [MapItem]) {
        let items = [
            MapItem(x: 100, y: 100, resonance: 1, region: 2),
            MapItem(x: 110, y: 100, resonance: 1, region: 2),
            MapItem(x: 120, y: 100, resonance: 1, region: 1),
            MapItem(x: 800, y: 800, resonance: 1, region: 3),
        ]
        let records = [
            RegionTree.Record(id: 1, label: "top", x: 110, y: 100, r: 20),
            RegionTree.Record(id: 2, label: "fine", parent: 1, x: 105, y: 100, r: 10),
            RegionTree.Record(id: 3, label: "other", x: 800, y: 800, r: 5),
        ]
        return (RegionTree(records: records, items: items), items)
    }

    func testTreeKnowsPathsCountsAndMembers() {
        let (tree, items) = tree()
        XCTAssertEqual(tree.roots, [1, 3])
        XCTAssertEqual(tree.regions[2]?.path, [1, 2])
        XCTAssertEqual(tree.regions[2]?.depth, 1)
        XCTAssertEqual(tree.regions[1]?.count, 3)
        XCTAssertEqual(tree.members(of: 1).sorted(), [0, 1, 2])
        XCTAssertEqual(tree.counts(items: items, visible: [0, 3]), [1: 1, 2: 1, 3: 1])
    }

    func testMissingAnchorsComeFromMembers() {
        let items = [MapItem(x: 10, y: 10, resonance: 1, region: 1), MapItem(x: 20, y: 10, resonance: 1, region: 1),
                     MapItem(x: 30, y: 10, resonance: 1, region: 1)]
        let region = RegionTree(records: [.init(id: 1, label: "old")], items: items).regions[1]!
        XCTAssertEqual(region.x, 20)
        XCTAssertEqual(region.y, 10)
        XCTAssertGreaterThanOrEqual(region.r, 4)
    }

    private let screen = CGSize(width: 1000, height: 800)
    private func width(_ text: String, _ size: Double) -> Double { Double(text.count) * size * 0.6 }

    func testRegionHandsOverToWhatsInsideOnceLarge() {
        let (tree, items) = tree()
        let counts = tree.counts(items: items, visible: [0, 1, 2, 3])
        var planner = LabelPlanner()

        let far = MapTransform(k: 0.8, x: 0, y: 0)
        XCTAssertEqual(Set(planner.named(tree: tree, counts: counts, transform: far, size: screen)), [1, 3])
        XCTAssertTrue(planner.expanded.isEmpty)

        // Radius 20 at k 13 is 260 points, past 0.3 of the short side.
        let close = MapTransform(k: 13, x: -1000, y: -900)
        XCTAssertEqual(planner.named(tree: tree, counts: counts, transform: close, size: screen), [2])
        XCTAssertEqual(planner.expanded, [1])
    }

    func testHysteresisKeepsANameFromFlickering() {
        let (tree, items) = tree()
        let counts = tree.counts(items: items, visible: [0, 1, 2, 3])
        var planner = LabelPlanner()
        let open = MapTransform(k: 13, x: -1000, y: -900)
        _ = planner.named(tree: tree, counts: counts, transform: open, size: screen)
        // Just under the threshold, but within the margin, it stays open.
        let slightlyLess = MapTransform(k: 11.5, x: -900, y: -800)
        _ = planner.named(tree: tree, counts: counts, transform: slightlyLess, size: screen)
        XCTAssertEqual(planner.expanded, [1])
    }

    func testRegionsWithNothingShowingGetNoName() {
        let (tree, _) = tree()
        var planner = LabelPlanner()
        let names = planner.named(tree: tree, counts: [3: 1], transform: MapTransform(k: 1, x: 0, y: 0), size: screen)
        XCTAssertEqual(names, [3])
    }

    func testOverlappingNamesGiveWayToTheBigger() {
        let items = [MapItem(x: 100, y: 100, resonance: 1, region: 1), MapItem(x: 100, y: 100, resonance: 1, region: 1),
                     MapItem(x: 101, y: 100, resonance: 1, region: 2)]
        let tree = RegionTree(records: [.init(id: 1, label: "big", x: 100, y: 100, r: 5),
                                        .init(id: 2, label: "small", x: 101, y: 100, r: 5)], items: items)
        var planner = LabelPlanner()
        let labels = planner.plan(tree: tree, counts: [1: 2, 2: 1], transform: MapTransform(k: 1, x: 0, y: 0),
                                  size: screen, width: width)
        XCTAssertEqual(labels.map(\.id), [1])
    }

    func testLabelGeometryMatchesTheViewer() {
        let label = PlacedLabel.geometry(id: 1, x: 100, y: 50, top: true, count: 3, nameWidth: 40, countWidth: 6)
        XCTAssertEqual(label.fontSize, 12)
        XCTAssertEqual(label.box, CGRect(x: 95, y: 41, width: 69, height: 18))
    }

    func testStrataSplitsLargestRegionsWhileItFits() {
        let (tree, _) = tree()
        // Swapping a region for its one child still fits in two layers.
        XCTAssertEqual(Set(tree.strataLayers(maxLayers: 2)), [2, 3])
        // With room for only one layer, nothing can be split.
        XCTAssertEqual(tree.strataLayers(maxLayers: 1), [1, 3])
    }
}
