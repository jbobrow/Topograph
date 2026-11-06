import CoreGraphics
import Foundation

/// Map coordinates to view points: `view = map * k + (x, y)`, y down.
public struct MapTransform: Sendable, Equatable {
    public static let zoomRange = 0.3...80.0

    public var k: Double
    public var x: Double
    public var y: Double

    public init(k: Double, x: Double, y: Double) {
        self.k = k
        self.x = x
        self.y = y
    }

    /// The whole map, centered, with a margin.
    public static func fit(_ size: CGSize, padding: Double = 40) -> MapTransform {
        let map = DensityField.mapSize
        let k = min((size.width - padding * 2) / map, (size.height - padding * 2) / map)
        let clamped = min(max(k, zoomRange.lowerBound), zoomRange.upperBound)
        return MapTransform(k: clamped, x: (size.width - map * clamped) / 2, y: (size.height - map * clamped) / 2)
    }

    public func panned(dx: Double, dy: Double) -> MapTransform {
        MapTransform(k: k, x: x + dx, y: y + dy)
    }

    /// Zoom by `factor`, keeping the map under `anchor` (view points) where it is.
    public func zoomed(by factor: Double, around anchor: CGPoint) -> MapTransform {
        let next = min(max(k * factor, Self.zoomRange.lowerBound), Self.zoomRange.upperBound)
        let ratio = next / k
        return MapTransform(k: next, x: anchor.x - (anchor.x - x) * ratio, y: anchor.y - (anchor.y - y) * ratio)
    }

    /// Part of the way to `other`: zoom moves evenly in ratio and the center of the
    /// view moves in step with it, so the map doesn't swing during a zoom.
    public func interpolated(to other: MapTransform, t: Double, viewSize: CGSize) -> MapTransform {
        let halfW = viewSize.width / 2, halfH = viewSize.height / 2
        let k0 = k, k1 = other.k
        let cx0 = (halfW - x) / k0, cy0 = (halfH - y) / k0
        let cx1 = (halfW - other.x) / k1, cy1 = (halfH - other.y) / k1
        let next = k0 * pow(k1 / k0, t)
        // Where the center is, as a share of the way, tracks the zoom's own progress.
        let share = k1 == k0 ? t : (1 / k0 - 1 / next) / (1 / k0 - 1 / k1)
        let cx = cx0 + (cx1 - cx0) * share, cy = cy0 + (cy1 - cy0) * share
        return MapTransform(k: next, x: halfW - cx * next, y: halfH - cy * next)
    }
}
