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
