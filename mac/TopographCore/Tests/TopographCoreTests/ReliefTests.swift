import CoreGraphics
import simd
import XCTest
@testable import TopographCore

final class ReliefTests: XCTestCase {
    private let size = CGSize(width: 1200, height: 800)

    func testStraightDownOnFlatGroundIsTheFlatMap() {
        let flat = MapTransform(k: 2.5, x: -300, y: -120)
        let camera = OrbitCamera(above: flat, viewSize: size)
        let back = camera.transform(viewSize: size)
        XCTAssertEqual(back.k, flat.k, accuracy: 1e-9)
        XCTAssertEqual(back.x, flat.x, accuracy: 1e-9)
        XCTAssertEqual(back.y, flat.y, accuracy: 1e-9)

        // Every spot on the ground lands where the flat map puts it.
        let projection = camera.projection(viewSize: size)
        for (mx, my) in [(200.0, 100.0), (260.0, 330.0), (150.0, 290.0)] {
            let at = projection.project(SIMD3(Float(mx), 0, Float(my)))!
            XCTAssertEqual(at.point.x, mx * flat.k + flat.x, accuracy: 0.05)
            XCTAssertEqual(at.point.y, my * flat.k + flat.y, accuracy: 0.05)
            XCTAssertEqual(at.scale, flat.k, accuracy: 1e-3)
        }
    }

    func testTheSpotCircledStaysInTheMiddle() {
        let camera = OrbitCamera(x: 420, y: 610, ground: 30, distance: 500, yaw: 0.7, pitch: 0.6)
        let at = camera.projection(viewSize: size).project(SIMD3(420, 30, 610))!
        XCTAssertEqual(at.point.x, 600, accuracy: 0.01)
        XCTAssertEqual(at.point.y, 400, accuracy: 0.01)
    }

    func testFarAwayIsHigherUpTheScreenAndSmaller() {
        let camera = OrbitCamera(x: 500, y: 500, distance: 800, pitch: 0.7)
        let projection = camera.projection(viewSize: size)
        let near = projection.project(SIMD3(500, 0, 700))!, far = projection.project(SIMD3(500, 0, 300))!
        XCTAssertLessThan(far.point.y, near.point.y)
        XCTAssertLessThan(far.scale, near.scale)
        XCTAssertGreaterThan(far.depth, near.depth)
    }

    func testOnScreenKeepsTheNearestNotTheFirst() {
        // A row running away from a low camera, listed farthest first, as resonance might list it.
        let items = (0..<8).map { MapItem(x: 500, y: Float(300 + $0 * 50), resonance: 1) }
        let visible = (0..<8).map(Int32.init)
        let points = ReliefPoints(items: items, visible: visible, field: DensityField(items: items, visible: visible, fullPeak: 1))
        let projection = OrbitCamera(x: 500, y: 500, distance: 600, pitch: 0.25).projection(viewSize: size)
        let found = points.onScreen(visible, projection: projection, rise: 0, margin: 80, minimumScale: 0, limit: 3)
        XCTAssertEqual(points.onScreen(visible, projection: projection, rise: 0, margin: 80, minimumScale: 0, limit: 8).count, 8)
        XCTAssertEqual(found.map(\.index), [5, 6, 7], "the three nearest the eye, in the order given")
        let ranked = points.onScreen(visible, projection: projection, rise: 0, margin: 80, minimumScale: 0, limit: 3) { index, _ in
            index == 7 ? 0 : 1
        }
        XCTAssertEqual(ranked.map(\.index), [0, 1, 2], "by the rank given, ties to the earlier")
    }

    func testPanningStraightDownMatchesTheFlatMap() {
        let flat = MapTransform(k: 1.5, x: 40, y: 10)
        let camera = OrbitCamera(above: flat, viewSize: size).panned(dx: 30, dy: -45, viewSize: size)
        let expected = flat.panned(dx: 30, dy: -45)
        let back = camera.transform(viewSize: size)
        XCTAssertEqual(back.x, expected.x, accuracy: 1e-6)
        XCTAssertEqual(back.y, expected.y, accuracy: 1e-6)
    }

    func testAPointOnScreenFindsItsGround() {
        let camera = OrbitCamera(x: 500, y: 500, distance: 900, yaw: -0.4, pitch: 0.8)
        let projection = camera.projection(viewSize: size)
        let at = projection.project(SIMD3(380, 0, 560))!
        let found = projection.ground(at: at.point)!
        XCTAssertEqual(found.x, 380, accuracy: 0.05)
        XCTAssertEqual(found.y, 560, accuracy: 0.05)
    }

    func testTurningGoesTheShortWayRound() {
        let a = OrbitCamera(x: 0, y: 0, distance: 100, yaw: 3.0), b = OrbitCamera(x: 0, y: 0, distance: 400, yaw: -3.0)
        let half = a.interpolated(to: b, t: 0.5)
        XCTAssertEqual(abs(half.yaw), .pi, accuracy: 0.01)
        XCTAssertEqual(half.distance, 200, accuracy: 1e-9)
    }

    func testHeightFollowsTheFieldAndIsZeroOffIt() {
        let items = [MapItem(x: 500, y: 500, resonance: 4)]
        let field = DensityField(items: items)
        let peak = Relief.height(field, x: 500, y: 500)
        XCTAssertGreaterThan(peak, Relief.height * 0.8)
        XCTAssertLessThan(Relief.height(field, x: 560, y: 500), peak)
        XCTAssertEqual(Relief.height(field, x: -400, y: 500), 0)
    }
}
