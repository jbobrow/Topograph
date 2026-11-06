import XCTest
@testable import TopographCore

final class TerrainStyleTests: XCTestCase {
    func testThresholdsRiseFromViewerRange() {
        let t = TerrainStyle.thresholds
        XCTAssertEqual(t.count, 13)
        XCTAssertEqual(t.first!, 0.025, accuracy: 1e-5)
        XCTAssertEqual(t.last!, 0.92, accuracy: 1e-5)
        XCTAssertEqual(t, t.sorted())
    }

    func testBayerUsesEveryValueOnce() {
        XCTAssertEqual(TerrainStyle.bayer.sorted(), (0..<64).map(Float.init))
        XCTAssertEqual(Array(TerrainStyle.bayer[0..<4]), [0, 32, 8, 40])
    }

    func testDitherStaysWellBelowSolid() {
        XCTAssertEqual(TerrainStyle.ditherDensity.first!, 0.03, accuracy: 1e-5)
        XCTAssertEqual(TerrainStyle.ditherDensity.last!, 0.34, accuracy: 1e-5)
    }
}
