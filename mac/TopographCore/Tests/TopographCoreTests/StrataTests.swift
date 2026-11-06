import XCTest
@testable import TopographCore

final class StrataTests: XCTestCase {
    private let utc: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }()

    /// From running the viewer's d3 on these same rows.
    func testStackMatchesD3() {
        let series: [[Double]] = [[1, 3, 5, 2, 0, 1], [0, 1, 4, 6, 2, 1], [2, 0, 1, 3, 8, 1]]
        let stacked = StrataModel.stack(series)
        XCTAssertEqual(stacked.map(\.index), [2, 0, 1])
        func check(_ actual: [Double], _ expected: [Double]) {
            for (a, e) in zip(actual, expected) { XCTAssertEqual(a, e, accuracy: 1e-5) }
        }
        check(stacked[0].bottom, [0, 0.625, -2.225, -2.588636, -4.788636, 0.711364])
        check(stacked[0].top, [2, 0.625, -1.225, 0.411364, 3.211364, 1.711364])
        check(stacked[1].top, [3, 3.625, 3.775, 2.411364, 3.211364, 2.711364])
        check(stacked[2].top, [3, 4.625, 7.775, 8.411364, 5.211364, 3.711364])
    }

    func testSmoothingKeepsEdgesFair() {
        XCTAssertEqual(StrataModel.smoothed([9, 0, 0, 0, 0, 0, 0])[0], 9.0 * 3 / 6, accuracy: 1e-9)
        XCTAssertEqual(StrataModel.smoothed([0, 0, 0, 9, 0, 0, 0])[3], 3, accuracy: 1e-9)
    }

    func testAxisRunsWholeMonthsAndFindsThem() throws {
        // 2020-01-15 and 2020-03-02.
        let axis = try XCTUnwrap(MonthAxis(times: [1579046400, 1583107200], calendar: utc))
        XCTAssertEqual(axis.count, 3)
        XCTAssertEqual(axis.start, 1577836800)
        XCTAssertEqual(axis.end, 1585699200)
        XCTAssertEqual(axis.index(of: 1579046400), 0)
        XCTAssertEqual(axis.index(of: 1580515200), 1, "the first second of February")
        XCTAssertEqual(axis.index(of: 1583107200), 2)
        XCTAssertNil(axis.index(of: 1585699200))
        XCTAssertEqual(axis.years(calendar: utc).map(\.year), [2020])
        XCTAssertEqual(axis.counts(of: [1579046400, 1579046401, 1583107200]), [2, 0, 1])
        XCTAssertNil(MonthAxis(times: [Int]()))
    }

    func testLayersFollowResonanceAndWaitingItemsGetTheirOwn() throws {
        let t0 = 1579046400
        let items = [MapItem(x: 1, y: 1, resonance: 3, region: 1, time: t0), MapItem(x: 2, y: 2, resonance: 2, region: 2, time: t0)]
        let tree = RegionTree(records: [.init(id: 1, label: "a", x: 1, y: 1, r: 4), .init(id: 2, label: "b", x: 2, y: 2, r: 4)], items: items)
        let map = LibraryMap(items: items, regions: tree, waitingTimes: [t0], waiting: 1)
        let axis = try XCTUnwrap(MonthAxis(times: [t0], calendar: utc))
        let model = StrataModel(map: map, visible: [0], axis: axis)
        XCTAssertEqual(model.layers.count, 3)
        XCTAssertEqual(model.layers.first { $0.region == 1 }?.raw, [3])
        XCTAssertEqual(model.layers.first { $0.region == 2 }?.raw, [0], "not visible")
        XCTAssertEqual(model.layers.first { $0.region == nil }?.raw, [1])
    }

    func testBasisCurveStartsAndEndsOnItsPoints() {
        let path = CGMutablePath()
        let points = [CGPoint(x: 0, y: 0), CGPoint(x: 10, y: 10), CGPoint(x: 20, y: 0), CGPoint(x: 30, y: 10)]
        BasisCurve.append(points, to: path, joined: false)
        XCTAssertEqual(path.currentPoint, points.last)
        XCTAssertTrue(path.boundingBoxOfPath.contains(CGPoint(x: 15, y: 5)))
    }

    func testTheCurveValueIsWhatTheDrawnCurvePassesThrough() {
        let values = [0.0, 4, 2, 8, 1]
        // A knot of the curve sits at (a + 4b + c) / 6.
        XCTAssertEqual(BasisCurve.value(values, at: 2), (4 + 4 * 2 + 8) / 6, accuracy: 1e-9)
        // Between knots it stays continuous.
        XCTAssertEqual(BasisCurve.value(values, at: 2.999_999), BasisCurve.value(values, at: 3), accuracy: 1e-4)
        XCTAssertEqual(BasisCurve.value([5], at: 0), 5)
    }

    func testAnItemSitsInsideItsLayerAtItsTime() throws {
        let t0 = 1_579_046_400
        var items: [MapItem] = []
        for month in 0..<24 {
            for region in 1...2 {
                items.append(MapItem(id: "\(month)-\(region)", x: 0, y: 0, resonance: 2, region: region, time: t0 + month * 30 * 86400))
            }
        }
        let tree = RegionTree(records: [.init(id: 1, label: "a", x: 1, y: 1, r: 4), .init(id: 2, label: "b", x: 2, y: 2, r: 4)], items: items)
        let map = LibraryMap(items: items, regions: tree)
        let axis = try XCTUnwrap(MonthAxis(times: items.compactMap(\.time), calendar: utc))
        let model = StrataModel(map: map, visible: items.indices.map(Int32.init), axis: axis)
        let item = items[24]
        let place = try XCTUnwrap(model.place(of: item))
        XCTAssertEqual(place.time, item.time)
        let height = try XCTUnwrap(place.height)
        let month = try XCTUnwrap(axis.index(of: item.time!))
        let layer = try XCTUnwrap(model.layers.first { $0.region == item.region })
        XCTAssertGreaterThan(height, min(layer.bottom[month], layer.bottom[month + 1]) - 0.5)
        XCTAssertLessThan(height, max(layer.top[month], layer.top[month + 1]) + 0.5)
        var outside = item
        outside.time = t0 - 400 * 86400
        XCTAssertNil(model.place(of: outside))
        var unplaced = item
        unplaced.region = nil
        XCTAssertNil(try XCTUnwrap(model.place(of: unplaced)).height)
    }

    func testLayersKeepTheirOrderAsATimeRangeMoves() throws {
        let t0 = 1_579_046_400
        var items: [MapItem] = []
        // Three regions that each peak at a different time.
        for (region, peak) in [(1, 2), (2, 14), (3, 26)] {
            for month in 0..<30 {
                let amount = max(1, 12 - abs(month - peak))
                for copy in 0..<amount {
                    items.append(MapItem(id: "\(region)-\(month)-\(copy)", x: 0, y: 0, resonance: 1, region: region, time: t0 + month * 30 * 86400))
                }
            }
        }
        let records = (1...3).map { RegionTree.Record(id: $0, label: "r\($0)", x: 1, y: 1, r: 4) }
        let map = LibraryMap(items: items, regions: RegionTree(records: records, items: items))
        let axis = try XCTUnwrap(MonthAxis(times: items.compactMap(\.time), calendar: utc))
        let all = items.indices.map(Int32.init)
        let order = StrataModel.stackingOrder(map: map, visible: all, axis: axis)
        // With everything showing, the set order is what it would have chosen anyway.
        XCTAssertEqual(StrataModel(map: map, visible: all, axis: axis, order: order).layers.map(\.region),
                       StrataModel(map: map, visible: all, axis: axis).layers.map(\.region))
        func stack(months: Range<Int>) -> [Int?] {
            let range = (t0 + months.lowerBound * 30 * 86400)...(t0 + months.upperBound * 30 * 86400)
            let visible = all.filter { range.contains(items[Int($0)].time!) }
            return StrataModel(map: map, visible: visible, axis: axis, order: order).layers.map(\.region)
        }
        XCTAssertEqual(stack(months: 0..<6), stack(months: 12..<18))
        XCTAssertEqual(stack(months: 12..<18), stack(months: 24..<30))
    }

    func testColorBandsSortColorsByHueAndNeutralsByLight() {
        XCTAssertEqual(ColorBands.names[ColorBands.band(of: 0xff0000)], "reds")
        XCTAssertEqual(ColorBands.names[ColorBands.band(of: 0xff0010)], "reds", "just past red, around the wheel")
        XCTAssertEqual(ColorBands.names[ColorBands.band(of: 0xff0010 - 0x10 + 0x0020)], "reds")
        XCTAssertEqual(ColorBands.names[ColorBands.band(of: 0x00ff00)], "greens")
        XCTAssertEqual(ColorBands.names[ColorBands.band(of: 0x0000ff)], "blues")
        XCTAssertEqual(ColorBands.names[ColorBands.band(of: 0xfafafa)], "whites")
        XCTAssertEqual(ColorBands.names[ColorBands.band(of: 0x808080)], "grays")
        XCTAssertEqual(ColorBands.names[ColorBands.band(of: 0x0a0a0a)], "blacks")
        XCTAssertEqual(Set(ColorBands.stackOrder), Set(0..<ColorBands.count))
    }

    func testColorStrataFollowsColorThroughTime() throws {
        let t0 = 1_579_046_400
        var items: [MapItem] = []
        for month in 0..<6 {
            items.append(MapItem(id: "r\(month)", x: 0, y: 0, resonance: 2, time: t0 + month * 30 * 86400, color: 0xff0000))
        }
        items.append(MapItem(id: "none", x: 0, y: 0, resonance: 5, time: t0))
        let map = LibraryMap(items: items, regions: RegionTree(records: [], items: items))
        let axis = try XCTUnwrap(MonthAxis(times: items.compactMap(\.time), calendar: utc))
        let model = StrataModel(colorsOf: map, visible: items.indices.map(Int32.init), axis: axis)
        let reds = try XCTUnwrap(model.layers.first { $0.region == 0 })
        XCTAssertEqual(reds.raw.reduce(0, +), 12, "what has no color isn't counted")
        XCTAssertEqual(model.layers.count, ColorBands.count)
        let place = try XCTUnwrap(model.place(of: items[2]))
        XCTAssertNotNil(place.height)
        XCTAssertNil(try XCTUnwrap(model.place(of: items[6])).height)
    }

    func testABandHoldsWhatsShowingInThatColorBestFirst() {
        let items = [
            MapItem(id: "quiet red", x: 0, y: 0, resonance: 1, color: 0xff0000),
            MapItem(id: "blue", x: 0, y: 0, resonance: 9, color: 0x0000ff),
            MapItem(id: "loud red", x: 0, y: 0, resonance: 5, color: 0xee1010),
            MapItem(id: "no color", x: 0, y: 0, resonance: 9),
            MapItem(id: "hidden red", x: 0, y: 0, resonance: 7, color: 0xff0000),
        ]
        let map = LibraryMap(items: items, regions: RegionTree(records: [], items: items))
        let reds = ColorBands.band(of: 0xff0000)
        XCTAssertEqual(ColorBands.items(in: reds, map: map, visible: [0, 1, 2, 3]), [2, 0])
    }

    func testColorShareFillsEveryMonthWithAnythingInIt() throws {
        let t0 = 1_579_046_400
        let items = [
            MapItem(id: "a", x: 0, y: 0, resonance: 50, time: t0, color: 0xff0000),
            MapItem(id: "b", x: 0, y: 0, resonance: 1, time: t0 + 300 * 86400, color: 0x0000ff),
        ]
        let map = LibraryMap(items: items, regions: RegionTree(records: [], items: items))
        let axis = try XCTUnwrap(MonthAxis(times: items.compactMap(\.time), calendar: utc))
        let model = StrataModel(colorsOf: map, visible: [0, 1], axis: axis, share: true)
        let top = try XCTUnwrap(model.layers.last), bottom = try XCTUnwrap(model.layers.first)
        XCTAssertEqual(top.top[0] - bottom.bottom[0], 1, accuracy: 1e-9, "a busy month")
        XCTAssertEqual(top.top[axis.count - 1] - bottom.bottom[axis.count - 1], 1, accuracy: 1e-9, "a quiet one")
        XCTAssertEqual(top.top[0], 0.5, accuracy: 1e-9, "centered, not wandering")
        XCTAssertEqual(bottom.bottom[axis.count - 1], -0.5, accuracy: 1e-9)
    }

    func testAWindowZoomsAroundThePointer() {
        let width = 1000.0, inset = 24.0
        var window = StrataWindow.whole
        for (factor, x) in [(1.5, 300.0), (2, 300.0), (1.3, 300.0)] {
            let before = window.fraction(atX: x, width: width, inset: inset)
            window = window.zoomed(by: factor, atX: x, width: width, inset: inset, minSpan: 0.02, limit: .whole)
            XCTAssertEqual(window.fraction(atX: x, width: width, inset: inset), before, accuracy: 1e-9)
        }
        XCTAssertEqual(window.span, 1 / 3.9, accuracy: 1e-9)
    }

    func testAWindowStaysInsideItsLimit() {
        let limit = StrataWindow(start: 0.25, end: 0.5)
        let zoomedOut = limit.zoomed(by: 0.1, atX: 200, width: 1000, inset: 24, minSpan: 0.02, limit: limit)
        XCTAssertEqual(zoomedOut, limit)
        let inside = limit.zoomed(by: 4, atX: 0, width: 1000, inset: 24, minSpan: 0.02, limit: limit)
        XCTAssertEqual(inside.start, 0.25, accuracy: 1e-9)
        XCTAssertEqual(inside.panned(byX: 5000, width: 1000, inset: 24, limit: limit).start, 0.25, accuracy: 1e-9)
        XCTAssertEqual(inside.panned(byX: -5000, width: 1000, inset: 24, limit: limit).end, 0.5, accuracy: 1e-9)
        XCTAssertEqual(StrataWindow(start: 0, end: 0.1).clamped(to: limit).start, 0.25, accuracy: 1e-9)
        XCTAssertEqual(StrataWindow.whole.clamped(to: limit), limit)
        // A zoom can't go tighter than the smallest allowed, unless the selection already is.
        XCTAssertEqual(StrataWindow.whole.zoomed(by: 1000, atX: 500, width: 1000, inset: 24, minSpan: 0.1, limit: .whole).span, 0.1, accuracy: 1e-9)
        let tiny = StrataWindow(start: 0.5, end: 0.51)
        XCTAssertEqual(tiny.zoomed(by: 2, atX: 500, width: 1000, inset: 24, minSpan: 0.1, limit: tiny).span, 0.01, accuracy: 1e-9)
    }

    func testASelectionGrowsAndShrinksAroundThePointerOnAChartOfAllTime() {
        let selection = StrataWindow(start: 0.2, end: 0.4)
        let tighter = selection.zoomed(by: 2, aroundFraction: 0.3, minSpan: 0.01)
        XCTAssertEqual(tighter.start, 0.25, accuracy: 1e-9)
        XCTAssertEqual(tighter.end, 0.35, accuracy: 1e-9)
        XCTAssertTrue(selection.zoomed(by: 0.01, aroundFraction: 0.3, minSpan: 0.01).isWhole)
        // Zooming in never widens one that's already narrower than the usual smallest.
        let tiny = StrataWindow(start: 0.5, end: 0.51)
        XCTAssertEqual(tiny.zoomed(by: 2, aroundFraction: 0.5, minSpan: 0.1).span, 0.01, accuracy: 1e-9)
    }

    func testMovingAWindowPastTheEndsKeepsItsSize() {
        let window = StrataWindow(start: 0.1, end: 0.3)
        XCTAssertEqual(window.centered(at: 0, limit: .whole).span, 0.2, accuracy: 1e-9)
        XCTAssertEqual(window.centered(at: 1, limit: .whole).end, 1, accuracy: 1e-9)
        XCTAssertEqual(window.centered(at: 1, limit: .whole).span, 0.2, accuracy: 1e-9)
        XCTAssertEqual(window.panned(byX: 5000, width: 1000, inset: 24, limit: .whole).span, 0.2, accuracy: 1e-9)
        XCTAssertEqual(window.zoomed(by: 0.5, atX: 0, width: 1000, inset: 24, minSpan: 0.01, limit: .whole).span, 0.4, accuracy: 1e-9)
    }

    func testASelectionMeetsTheSidesOfTheCanvas() {
        let window = StrataWindow(start: 0.2, end: 0.4)
        XCTAssertEqual(window.x(ofFraction: 0.2, width: 1000, inset: 24), 0, accuracy: 1e-9)
        XCTAssertEqual(window.x(ofFraction: 0.4, width: 1000, inset: 24), 1000, accuracy: 1e-9)
        // The whole axis keeps its margins.
        XCTAssertEqual(StrataWindow.whole.x(ofFraction: 0, width: 1000, inset: 24), 24, accuracy: 1e-9)
        XCTAssertEqual(StrataWindow.whole.x(ofFraction: 1, width: 1000, inset: 24), 976, accuracy: 1e-9)
    }
}
