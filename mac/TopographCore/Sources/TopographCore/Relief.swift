import CoreGraphics
import Foundation
import simd

/// The terrain as a landscape you can fly over: the elevation field stood up as height.
///
/// World coordinates are `(map x, height, map y)`, so looking straight down with no turn,
/// the map reads as it does flat: x to the right and y down the screen.
public enum Relief {
    /// Map units at the highest point. The map is 1000 across.
    public static let height: Float = 150
    /// Elevation is raised to this before scaling, so the lowlands have shape as well as the peaks.
    public static let exponent: Float = 0.6

    public static func height(elevation: Float, rise: Float = 1) -> Float {
        rise * height * pow(max(elevation, 0), exponent)
    }

    /// The field's elevation at a spot on the map, smoothed with the same cubic B-spline as
    /// `sampleField` in Terrain.metal, so what stands on the ground sits where the shader drew it.
    public static func elevation(_ field: DensityField, x: Double, y: Double) -> Float {
        let cx = (x + DensityField.origin) / DensityField.cellSize - 0.5
        let cy = (y + DensityField.origin) / DensityField.cellSize - 0.5
        let width = field.width, height = field.height
        guard cx >= -2, cy >= -2, cx <= Double(width) + 1, cy <= Double(height) + 1 else { return 0 }
        let wx = floor(cx), wy = floor(cy)
        func weights(_ t: Double) -> (Double, Double, Double, Double) {
            let r = 1 - t, t2 = t * t, t3 = t2 * t
            return (r * r * r / 6, (3 * t3 - 6 * t2 + 4) / 6, (-3 * t3 + 3 * t2 + 3 * t + 1) / 6, t3 / 6)
        }
        let ax = weights(cx - wx), ay = weights(cy - wy)
        let xs = [ax.0, ax.1, ax.2, ax.3], ys = [ay.0, ay.1, ay.2, ay.3]
        let bx = Int(wx), by = Int(wy)
        var value = 0.0
        for j in 0..<4 {
            let row = min(max(by + j - 1, 0), height - 1) * width
            for i in 0..<4 {
                let column = min(max(bx + i - 1, 0), width - 1)
                value += xs[i] * ys[j] * Double(field.elevation[row + column])
            }
        }
        return Float(value)
    }

    /// How high the ground stands at a spot on the map.
    public static func height(_ field: DensityField, x: Double, y: Double, rise: Float = 1) -> Float {
        height(elevation: elevation(field, x: x, y: y), rise: rise)
    }
}

/// Where each item stands on the relief, worked out once for a scene.
public struct ReliefPoints: Sendable {
    /// Per item, in the map's order: map x, ground height when fully risen, map y.
    public let positions: [SIMD3<Float>]

    public init(items: [MapItem], visible: [Int32], field: DensityField) {
        var positions = [SIMD3<Float>](repeating: .zero, count: items.count)
        for index in visible {
            let item = items[Int(index)]
            positions[Int(index)] = SIMD3(item.x, Relief.height(field, x: Double(item.x), y: Double(item.y)), item.y)
        }
        self.positions = positions
    }

    public func position(_ index: Int32, rise: Float) -> SIMD3<Float> {
        let p = positions[Int(index)]
        return SIMD3(p.x, p.y * rise, p.z)
    }

    /// Of `candidates`, in their order, those that land on screen and are seen at least
    /// `minimumScale` points per map unit, up to `limit`.
    public func onScreen(_ candidates: [Int32], projection: Projection, rise: Float, margin: Double,
                         minimumScale: Double, limit: Int) -> [(index: Int32, at: Projection.Projected)] {
        var out: [(Int32, Projection.Projected)] = []
        out.reserveCapacity(min(limit, candidates.count))
        let bounds = CGRect(origin: .zero, size: projection.size).insetBy(dx: -margin, dy: -margin)
        for index in candidates {
            guard let at = projection.project(position(index, rise: rise)),
                  at.scale >= minimumScale, bounds.contains(at.point) else { continue }
            out.append((index, at))
            if out.count == limit { break }
        }
        return out
    }

    /// The item drawn nearest a point on screen, within `radius` points. Nearer the eye wins a tie.
    public func nearest(_ candidates: [Int32], to point: CGPoint, projection: Projection, rise: Float, radius: Double) -> Int32? {
        var best: Int32?, bestScore = Double.infinity
        let r2 = radius * radius
        for index in candidates {
            guard let at = projection.project(position(index, rise: rise)) else { continue }
            let dx = at.point.x - point.x, dy = at.point.y - point.y
            let d2 = dx * dx + dy * dy
            guard d2 <= r2 else { continue }
            let score = d2 + Double(at.depth) * 1e-3
            if score < bestScore {
                bestScore = score
                best = index
            }
        }
        return best
    }
}

/// A camera circling a spot on the map: turned by `yaw`, tilted by `pitch` above the ground
/// (a quarter turn is straight down) and `distance` away.
public struct OrbitCamera: Sendable, Equatable {
    public static let fieldOfView = 36.0 * Double.pi / 180
    public static let pitchRange = (12.0 * Double.pi / 180)...(Double.pi / 2)
    public static let distanceRange = 12.0...4500.0
    /// How far it tilts on the way into 3D.
    public static let tilt = 50.0 * Double.pi / 180

    /// The spot circled, on the map, and the height of the ground there.
    public var x: Double
    public var y: Double
    public var ground: Double
    public var distance: Double
    public var yaw: Double
    public var pitch: Double

    public init(x: Double, y: Double, ground: Double = 0, distance: Double, yaw: Double = 0, pitch: Double = tilt) {
        self.x = x
        self.y = y
        self.ground = ground
        self.distance = distance
        self.yaw = yaw
        self.pitch = pitch
    }

    /// Points per map unit at a depth of one map unit.
    public static func focal(_ size: CGSize) -> Double { size.height / 2 / tan(fieldOfView / 2) }

    /// Straight down on flat ground, showing just what `transform` shows.
    public init(above transform: MapTransform, viewSize: CGSize) {
        self.init(x: (viewSize.width / 2 - transform.x) / transform.k, y: (viewSize.height / 2 - transform.y) / transform.k,
                  distance: Self.focal(viewSize) / transform.k, pitch: .pi / 2)
    }

    /// The flat map showing the same spot in the middle at the same scale.
    public func transform(viewSize: CGSize) -> MapTransform {
        let k = Self.focal(viewSize) / distance
        return MapTransform(k: k, x: viewSize.width / 2 - x * k, y: viewSize.height / 2 - y * k)
    }

    /// The whole map, turned and tilted, with a margin.
    public static func overview(viewSize: CGSize, yaw: Double = 0) -> OrbitCamera {
        let fit = MapTransform.fit(viewSize)
        return OrbitCamera(x: DensityField.mapSize / 2, y: DensityField.mapSize / 2,
                           distance: focal(viewSize) / fit.k * 0.9, yaw: yaw, pitch: tilt)
    }

    public var eye: SIMD3<Double> {
        SIMD3(x + distance * cos(pitch) * sin(yaw), ground + distance * sin(pitch), y + distance * cos(pitch) * cos(yaw))
    }

    /// From the eye toward the spot.
    var forward: SIMD3<Double> { -SIMD3(cos(pitch) * sin(yaw), sin(pitch), cos(pitch) * cos(yaw)) }
    var right: SIMD3<Double> { SIMD3(cos(yaw), 0, -sin(yaw)) }
    var up: SIMD3<Double> { simd_cross(right, forward) }

    public func projection(viewSize: CGSize) -> Projection {
        Projection(camera: self, size: viewSize)
    }

    /// Moves what's on screen by `dx`, `dy` points, as a pan moves the flat map.
    public func panned(dx: Double, dy: Double, viewSize: CGSize) -> OrbitCamera {
        let unit = distance / Self.focal(viewSize)
        // Up the screen reaches further across the ground the more the view is tilted.
        let along = unit / max(sin(pitch), 0.4)
        var next = self
        next.x += -cos(yaw) * dx * unit - sin(yaw) * dy * along
        next.y += sin(yaw) * dx * unit - cos(yaw) * dy * along
        next.x = min(max(next.x, -300), DensityField.mapSize + 300)
        next.y = min(max(next.y, -300), DensityField.mapSize + 300)
        return next
    }

    /// Closer by `factor`, keeping `toward` (a spot on the map) about where it is on screen.
    public func zoomed(by factor: Double, toward spot: SIMD2<Double>? = nil) -> OrbitCamera {
        var next = self
        next.distance = min(max(distance / factor, Self.distanceRange.lowerBound), Self.distanceRange.upperBound)
        if let spot {
            let share = 1 - next.distance / distance
            next.x += (spot.x - x) * share
            next.y += (spot.y - y) * share
        }
        return next
    }

    public func orbited(yaw dYaw: Double, pitch dPitch: Double) -> OrbitCamera {
        var next = self
        next.yaw = remainder(yaw + dYaw, 2 * .pi)
        next.pitch = min(max(pitch + dPitch, Self.pitchRange.lowerBound), Self.pitchRange.upperBound)
        return next
    }

    /// Part of the way to `other`: distance evenly in ratio, turning the short way round.
    public func interpolated(to other: OrbitCamera, t: Double) -> OrbitCamera {
        func mix(_ a: Double, _ b: Double) -> Double { a + (b - a) * t }
        return OrbitCamera(x: mix(x, other.x), y: mix(y, other.y), ground: mix(ground, other.ground),
                           distance: distance * pow(other.distance / distance, t),
                           yaw: yaw + remainder(other.yaw - yaw, 2 * .pi) * t, pitch: mix(pitch, other.pitch))
    }
}

/// A camera's view of the world for one frame, in view points with y down.
public struct Projection: Sendable {
    public let viewProjection: simd_float4x4
    public let size: CGSize
    /// Points per map unit at a depth of one map unit.
    public let focal: Double
    public let eye: SIMD3<Float>
    public let near: Double
    public let far: Double
    private let camera: OrbitCamera

    public struct Projected: Sendable {
        public let point: CGPoint
        /// Metal's depth, 0 at the near plane and 1 at the far one.
        public let depth: Float
        /// Points per map unit at this depth.
        public let scale: Double
    }

    init(camera: OrbitCamera, size: CGSize) {
        self.camera = camera
        self.size = size
        focal = OrbitCamera.focal(size)
        let e = camera.eye, f = camera.forward, r = camera.right, u = camera.up
        eye = SIMD3<Float>(e)
        near = max(0.5, camera.distance * 0.02)
        far = camera.distance * 6 + 3000

        let back = -f
        let view = simd_double4x4(columns: (
            SIMD4(r.x, u.x, back.x, 0), SIMD4(r.y, u.y, back.y, 0), SIMD4(r.z, u.z, back.z, 0),
            SIMD4(-simd_dot(r, e), -simd_dot(u, e), -simd_dot(back, e), 1)))
        let ys = 1 / tan(OrbitCamera.fieldOfView / 2), xs = ys * size.height / max(size.width, 1)
        let zs = far / (near - far)
        // Right-handed, into Metal's depth of 0 to 1.
        let lens = simd_double4x4(columns: (SIMD4(xs, 0, 0, 0), SIMD4(0, ys, 0, 0), SIMD4(0, 0, zs, -1), SIMD4(0, 0, zs * near, 0)))
        let m = lens * view
        viewProjection = simd_float4x4(columns: (SIMD4<Float>(m.columns.0), SIMD4<Float>(m.columns.1),
                                                 SIMD4<Float>(m.columns.2), SIMD4<Float>(m.columns.3)))
    }

    /// Where a point in the world lands on screen, or nil when it's behind the eye.
    public func project(_ world: SIMD3<Float>) -> Projected? {
        let clip = viewProjection * SIMD4(world, 1)
        guard clip.w > Float(near) * 0.5 else { return nil }
        let ndc = SIMD3(clip.x, clip.y, clip.z) / clip.w
        return Projected(point: CGPoint(x: Double(ndc.x + 1) / 2 * size.width, y: Double(1 - ndc.y) / 2 * size.height),
                         depth: ndc.z, scale: focal / Double(clip.w))
    }

    /// Where a line from the eye through a point on screen meets level ground at `height`.
    public func ground(at point: CGPoint, height: Double = 0) -> SIMD2<Double>? {
        let half = tan(OrbitCamera.fieldOfView / 2)
        let nx = (point.x / size.width * 2 - 1) * half * size.width / max(size.height, 1)
        let ny = (1 - point.y / size.height * 2) * half
        let direction = camera.forward + camera.right * nx + camera.up * ny
        let origin = camera.eye
        guard direction.y < -1e-6 else { return nil }
        let t = (height - origin.y) / direction.y
        guard t > 0 else { return nil }
        let hit = origin + direction * t
        return SIMD2(hit.x, hit.z)
    }
}
