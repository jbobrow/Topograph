import XCTest
@testable import TopographCore

final class MapFilterTests: XCTestCase {
    private let items = [
        MapItem(id: "a", x: 10, y: 10, resonance: 1, groups: .liked, platform: "x", author: "ann", text: "Foggy Coastline", time: 100),
        MapItem(id: "b", x: 500, y: 500, resonance: 1, groups: .made, platform: "files", text: nil, time: nil),
        MapItem(id: "c", x: 900, y: 900, resonance: 1, groups: [.liked, .kept], platform: "instagram", time: 500),
        MapItem(id: "d", x: 50, y: 50, resonance: 1, groups: [], platform: "files", time: 900),
    ]

    private var search: SearchIndex { SearchIndex(items: items) }

    func testIgnoringTimeKeepsEverythingElse() {
        var filter = MapFilter()
        filter.range = 1...2
        filter.hiddenPlatforms = ["x"]
        filter.groups = .creation
        XCTAssertNil(filter.ignoringTime.range)
        XCTAssertEqual(filter.ignoringTime.hiddenPlatforms, ["x"])
        XCTAssertEqual(filter.ignoringTime.groups, .creation)
    }

    func testImageAndTextSplitByPicture() {
        let items = [
            MapItem(id: "p", x: 0, y: 0, resonance: 1, groups: .liked, thumb: "media/ab/p-t.webp"),
            MapItem(id: "w", x: 0, y: 0, resonance: 1, groups: .liked, text: "just words"),
        ]
        var filter = MapFilter()
        XCTAssertEqual(filter.visible(in: items, search: SearchIndex(items: items)), [0, 1])
        filter.kinds = .image
        XCTAssertEqual(filter.visible(in: items, search: SearchIndex(items: items)), [0])
        filter.kinds = .text
        XCTAssertEqual(filter.visible(in: items, search: SearchIndex(items: items)), [1])
    }

    func testTimeSlicerShowsWhatTheFilterShows() {
        var items: [MapItem] = []
        for index in 0..<200 {
            items.append(MapItem(id: "\(index)", x: 0, y: 0, resonance: 1, groups: index % 3 == 0 ? .made : .liked,
                                 platform: index % 2 == 0 ? "x" : "files", time: index % 17 == 0 ? nil : 1000 + (index * 37) % 500))
        }
        let search = SearchIndex(items: items)
        var filter = MapFilter()
        filter.hiddenPlatforms = ["files"]
        let slicer = TimeSlicer(filter: filter, items: items, search: search)
        XCTAssertEqual(slicer.visible(in: nil), filter.visible(in: items, search: search))
        for range in [1000...1499, 1100...1200, 1037...1037, 2000...3000, 0...999] {
            filter.range = range
            XCTAssertEqual(Set(slicer.visible(in: range)), Set(filter.visible(in: items, search: search)), "\(range)")
        }
        XCTAssertEqual(slicer.times, slicer.times.sorted())
    }

    func testCreationAndConsumptionSplitWhatYouDid() {
        func shows(_ item: ActionGroups, in position: ActionGroups) -> Bool {
            var filter = MapFilter()
            filter.groups = position
            return filter.matches(MapItem(x: 0, y: 0, resonance: 1, groups: item, platform: "x"))
        }
        XCTAssertTrue(shows(.made, in: .creation))
        XCTAssertFalse(shows(.made, in: .consumption))
        XCTAssertTrue(shows(.liked, in: .consumption))
        XCTAssertTrue(shows(.kept, in: .consumption))
        XCTAssertFalse(shows(.kept, in: .creation))
        XCTAssertTrue(shows([.made, .liked], in: .creation))
        XCTAssertTrue(shows([.made, .liked], in: .consumption))
        XCTAssertTrue(shows(.liked, in: .all))
        // A video you only watched is something you took in.
        XCTAssertTrue(shows(ActionGroups(types: ["view"]), in: .consumption))
        XCTAssertFalse(shows(ActionGroups(types: ["view"]), in: .creation))
        // Opening a file is still no group, so it shows either way.
        XCTAssertEqual(ActionGroups(types: ["open"]), [])
    }

    func testSearchListsEachItemOnceAndNeverMatchesAcrossItems() {
        let repeated = [MapItem(x: 0, y: 0, resonance: 1, text: "fog fog fog"), MapItem(x: 0, y: 0, resonance: 1, text: "end"),
                        MapItem(x: 0, y: 0, resonance: 1, text: "start"), MapItem(x: 0, y: 0, resonance: 1, text: "Über fog")]
        let index = SearchIndex(items: repeated)
        XCTAssertEqual(index.matches("fog"), [0, 3])
        XCTAssertEqual(index.matches("endstart"), [])
        XCTAssertEqual(index.matches("ÜBER"), [3])
    }

    func testEverythingShowsByDefault() {
        XCTAssertEqual(MapFilter().visible(in: items, search: search), [0, 1, 2, 3])
    }

    func testPlatforms() {
        var filter = MapFilter()
        filter.hiddenPlatforms = ["files"]
        XCTAssertEqual(filter.visible(in: items, search: search), [0, 2])
    }

    func testGroupsHideOnlyWhenEveryActionIsOff() {
        var filter = MapFilter()
        filter.groups = [.kept]
        XCTAssertEqual(filter.visible(in: items, search: search), [2, 3], "an item with no group to turn off stays")
        filter.groups = []
        XCTAssertEqual(filter.visible(in: items, search: search), [3])
    }

    func testQueryFindsWordsAndAuthorsIgnoringCase() {
        var filter = MapFilter()
        filter.query = "foggy coast"
        XCTAssertEqual(filter.visible(in: items, search: search), [0])
        filter.query = "@ann"
        XCTAssertEqual(filter.visible(in: items, search: search), [0])
        filter.query = "nowhere"
        XCTAssertEqual(filter.visible(in: items, search: search), [])
    }

    func testRangeHidesItemsWithNoTime() {
        var filter = MapFilter()
        filter.range = 100...500
        XCTAssertEqual(filter.visible(in: items, search: search), [0, 2])
    }

    func testNearestFindsTheClosestWithinRadiusAmongVisible() {
        let index = SpatialIndex(items: items, visible: [0, 2, 3])
        XCTAssertEqual(index.nearest(x: 20, y: 20, radius: 50), 0)
        XCTAssertEqual(index.nearest(x: 45, y: 45, radius: 50), 3)
        XCTAssertNil(index.nearest(x: 500, y: 500, radius: 50), "b exists but isn't visible")
        XCTAssertNil(index.nearest(x: 300, y: 300, radius: 5))
    }

    func testFilteredFieldKeepsTheWholeMapsContourHeights() {
        let whole = DensityField(items: items)
        let part = DensityField(items: items, visible: [0], fullPeak: whole.peak)
        XCTAssertEqual(whole.elevation.max()!, 1, accuracy: 1e-5)
        XCTAssertEqual(part.elevation.max()! * Float(whole.peak), Float(part.peak), accuracy: 1e-5)
        XCTAssertEqual(DensityField(items: [], fullPeak: whole.peak).elevation.max(), 0)
    }
}
