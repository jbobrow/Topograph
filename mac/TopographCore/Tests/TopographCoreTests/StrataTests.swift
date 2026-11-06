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
}
