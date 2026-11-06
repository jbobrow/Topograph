import XCTest
@testable import TopographCore

final class DensityFieldTests: XCTestCase {
    func testGridMatchesD3() {
        let field = DensityField(items: [])
        XCTAssertEqual(field.width, 273)
        XCTAssertEqual(field.height, 273)
        XCTAssertEqual(field.peak, 0)
    }

    /// The peak and a contour point, from running the viewer's d3 on these same items.
    func testMatchesD3OnAFixture() {
        let items = [(100, 100, 1), (120, 130, 2.5), (500, 500, 4), (505, 490, 1),
                     (900, 850, 3), (47, 952, 0.5), (333, 777, 1.5)].map {
            MapItem(x: Float($0.0), y: Float($0.1), resonance: Float($0.2), mine: false)
        }
        let field = DensityField(items: items)
        XCTAssertEqual(field.peak, 0.0022233747877180576, accuracy: 1e-8)

        let (x, y) = (124.88734904573226, 135.47656821925364)
        let cx = (x + DensityField.origin) / DensityField.cellSize - 0.5
        let cy = (y + DensityField.origin) / DensityField.cellSize - 0.5
        let x0 = Int(cx), y0 = Int(cy), tx = cx - Double(x0), ty = cy - Double(y0)
        func at(_ i: Int, _ j: Int) -> Double { Double(field.elevation[j * field.width + i]) }
        let elevation = at(x0, y0) * (1 - tx) * (1 - ty) + at(x0 + 1, y0) * tx * (1 - ty)
            + at(x0, y0 + 1) * (1 - tx) * ty + at(x0 + 1, y0 + 1) * tx * ty
        XCTAssertEqual(elevation, 0.5, accuracy: 1e-4)
    }

    func testMassIsConserved() {
        let items = [MapItem(x: 500, y: 500, resonance: 3, mine: false)]
        let field = DensityField(items: items)
        let total = field.elevation.reduce(0) { $0 + Double($1) } * field.peak
        // Mass per square map unit, summed over cells of 16 square units.
        XCTAssertEqual(total * 16, 3, accuracy: 0.001)
    }

    func testNoInteractionsStillWeighOne() {
        let none = DensityField(items: [MapItem(x: 500, y: 500, resonance: 0, mine: false)])
        let one = DensityField(items: [MapItem(x: 500, y: 500, resonance: 1, mine: false)])
        XCTAssertEqual(none.peak, one.peak)
    }

    func testPeakSitsOverThePointAndIsOne() throws {
        let field = DensityField(items: [MapItem(x: 300, y: 700, resonance: 1, mine: false)])
        let index = try XCTUnwrap(field.elevation.firstIndex(of: 1))
        let cell = DensityField.cellSize, origin = DensityField.origin
        XCTAssertEqual((Double(index % field.width) + 0.5) * cell - origin, 300, accuracy: cell)
        XCTAssertEqual((Double(index / field.width) + 0.5) * cell - origin, 700, accuracy: cell)
    }

    func testPointsOffTheGridAreIgnored() {
        XCTAssertEqual(DensityField(items: [MapItem(x: -500, y: 2000, resonance: 1, mine: false)]).peak, 0)
    }
}
