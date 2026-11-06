import CoreGraphics
import XCTest
@testable import TopographCore

final class MapTransformTests: XCTestCase {
    private let size = CGSize(width: 1200, height: 800)

    func testFitCentersTheMapWithAMargin() {
        let t = MapTransform.fit(size)
        XCTAssertEqual(t.k, 0.72, accuracy: 1e-9)
        XCTAssertEqual(t.x, 240, accuracy: 1e-9)
        XCTAssertEqual(t.y, 40, accuracy: 1e-9)
    }

    func testZoomingToABoxShowsWhatWasInIt() {
        let t = MapTransform.fit(size)
        let box = CGRect(x: 300, y: 200, width: 300, height: 100)
        let z = t.zoomed(toFill: box, viewSize: size)
        // The box is wide for its height compared with the view, so its width sets the zoom.
        XCTAssertEqual(z.k, t.k * 4, accuracy: 1e-9)
        // The box's center lands in the middle of the view.
        let mapX = (box.midX - t.x) / t.k, mapY = (box.midY - t.y) / t.k
        XCTAssertEqual(mapX * z.k + z.x, 600, accuracy: 1e-9)
        XCTAssertEqual(mapY * z.k + z.y, 400, accuracy: 1e-9)
        // All of it is in view.
        let shown = z.visibleRect(viewSize: size)
        XCTAssertLessThanOrEqual(shown.minX, (box.minX - t.x) / t.k + 1e-9)
        XCTAssertGreaterThanOrEqual(shown.maxX, (box.maxX - t.x) / t.k - 1e-9)
    }

    func testZoomingToABoxStopsAtTheLimit() {
        let t = MapTransform(k: 70, x: 0, y: 0)
        XCTAssertEqual(t.zoomed(toFill: CGRect(x: 10, y: 10, width: 20, height: 20), viewSize: size).k, 80)
    }

    func testCenteringKeepsTheZoom() {
        let t = MapTransform(k: 3, x: 5, y: 9).centered(onX: 100, y: 200, viewSize: size)
        XCTAssertEqual(t.k, 3)
        XCTAssertEqual(t.visibleRect(viewSize: size).midX, 100, accuracy: 1e-9)
        XCTAssertEqual(t.visibleRect(viewSize: size).midY, 200, accuracy: 1e-9)
    }

    func testOnlyCloserThanTheFitCountsAsZoomedIn() {
        let t = MapTransform.fit(size)
        XCTAssertFalse(t.isZoomedIn(viewSize: size))
        XCTAssertFalse(t.panned(dx: 50, dy: 0).isZoomedIn(viewSize: size))
        XCTAssertTrue(t.zoomed(by: 1.5, around: .zero).isZoomedIn(viewSize: size))
    }

    func testZoomKeepsTheAnchorStill() {
        let t = MapTransform.fit(size)
        let anchor = CGPoint(x: 300, y: 500)
        let z = t.zoomed(by: 3, around: anchor)
        XCTAssertEqual((anchor.x - t.x) / t.k, (anchor.x - z.x) / z.k, accuracy: 1e-9)
        XCTAssertEqual((anchor.y - t.y) / t.k, (anchor.y - z.y) / z.k, accuracy: 1e-9)
    }

    func testZoomStopsAtTheLimitsWithoutDrifting() {
        let t = MapTransform(k: 80, x: 10, y: 20)
        XCTAssertEqual(t.zoomed(by: 2, around: CGPoint(x: 500, y: 500)), t)
        XCTAssertEqual(MapTransform(k: 1, x: 0, y: 0).zoomed(by: 0.001, around: .zero).k, 0.3)
    }

    func testInterpolationEndsExactlyAndKeepsCenterOnAPureZoom() {
        let a = MapTransform.fit(size)
        let b = a.zoomed(by: 8, around: CGPoint(x: size.width / 2, y: size.height / 2))
        let start = a.interpolated(to: b, t: 0, viewSize: size)
        let end = a.interpolated(to: b, t: 1, viewSize: size)
        XCTAssertEqual(start.k, a.k, accuracy: 1e-9)
        XCTAssertEqual(end.k, b.k, accuracy: 1e-9)
        XCTAssertEqual(end.x, b.x, accuracy: 1e-6)
        XCTAssertEqual(end.y, b.y, accuracy: 1e-6)
        let mid = a.interpolated(to: b, t: 0.5, viewSize: size)
        XCTAssertEqual(mid.k, a.k * sqrt(8), accuracy: 1e-9)
        XCTAssertEqual((size.width / 2 - mid.x) / mid.k, 500, accuracy: 1e-6)
    }
}

final class MinimapTests: XCTestCase {
    func testInkSitsWhereTheItemsAre() {
        let field = DensityField(items: (0..<40).map { _ in MapItem(x: 250, y: 750, resonance: 2, mine: false) })
        let side = 200
        let mask = Minimap.mask(field: field, side: side)
        func inked(aroundMapX x: Int, y: Int) -> Int {
            let cx = x * side / 1000, cy = y * side / 1000
            var count = 0
            for row in (cy - 12)..<(cy + 12) {
                for column in (cx - 12)..<(cx + 12) where mask[row * side + column] > 0 { count += 1 }
            }
            return count
        }
        XCTAssertGreaterThan(inked(aroundMapX: 250, y: 750), 0)
        XCTAssertEqual(inked(aroundMapX: 750, y: 250), 0)
    }
}
