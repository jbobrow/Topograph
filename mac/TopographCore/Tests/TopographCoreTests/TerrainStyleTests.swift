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

    func testIn3DResonanceDecidesUntilPicturesComeClose() {
        let far = TerrainStyle.standingNear * 0.5, close = TerrainStyle.standingNear * 2
        XCTAssertGreaterThan(TerrainStyle.standingRank(size: far, resonance: 5), TerrainStyle.standingRank(size: TerrainStyle.standingNear, resonance: 1),
                             "a resonant picture far off still shows before a plain one nearer")
        XCTAssertGreaterThan(TerrainStyle.standingRank(size: close, resonance: 0.3), TerrainStyle.standingRank(size: far, resonance: 12),
                             "close up, nothing is missing, however plain")
        XCTAssertGreaterThan(TerrainStyle.standingRank(size: close, resonance: 3), TerrainStyle.standingRank(size: close * 1.2, resonance: 1),
                             "among the close, resonance decides again")
    }
}
