import CoreGraphics
import Foundation

/// How the palette is being looked at. One unit is the radius of the wheel.
public struct PaletteCamera: Sendable, Equatable {
    public static let zoomRange = 0.5...80.0
    /// How far above and below the middle the cylinder reaches.
    public static let cylinderHeight = 0.85
    /// From the side and a little above, for when the cylinder first opens.
    public static let cylinderPitch = 1.05
    /// How far the camera stands from the middle, which sets the strength of perspective.
    private static let distance = 4.5

    public var zoom = 1.0
    /// Points on screen, added last.
    public var panX = 0.0
    public var panY = 0.0
    /// Around the upright axis, in radians.
    public var yaw = 0.0
    /// 0 looks straight down the axis, π/2 looks at the side.
    public var pitch = 0.0
    /// 0 is the flat wheel, 1 the cylinder, and in between it's on its way.
    public var solid = 0.0

    public init() {}

    private func pointsPerUnit(_ size: CGSize) -> Double {
        // The cylinder has height to fit as well as width.
        let fit = (min(size.width, size.height) / 2 - 36) * (1 - 0.36 * solid)
        return max(fit, 1) * zoom
    }

    /// A place in the space to a place on screen in points, how much nearer or farther it
    /// makes things look, and how near it is: more is nearer.
    public func project(x: Double, y: Double, z: Double, size: CGSize) -> (point: CGPoint, scale: Double, depth: Double) {
        let cosYaw = cos(yaw), sinYaw = sin(yaw), cosPitch = cos(pitch), sinPitch = sin(pitch)
        let turnedX = x * cosYaw - y * sinYaw, turnedY = x * sinYaw + y * cosYaw
        let upY = turnedY * cosPitch - z * sinPitch
        let depth = turnedY * sinPitch + z * cosPitch
        let scale = Self.distance / (Self.distance - depth)
        let unit = pointsPerUnit(size) * scale
        return (CGPoint(x: size.width / 2 + panX + turnedX * unit, y: size.height / 2 + panY + upY * unit), scale, depth)
    }

    public func panned(dx: Double, dy: Double) -> PaletteCamera {
        var next = self
        next.panX += dx
        next.panY += dy
        return next
    }

    /// Zoom by `factor`, keeping what's under `anchor` where it is.
    public func zoomed(by factor: Double, around anchor: CGPoint, size: CGSize) -> PaletteCamera {
        var next = self
        next.zoom = min(max(zoom * factor, Self.zoomRange.lowerBound), Self.zoomRange.upperBound)
        let ratio = next.zoom / zoom
        let centerX = size.width / 2, centerY = size.height / 2
        next.panX = anchor.x - centerX - (anchor.x - centerX - panX) * ratio
        next.panY = anchor.y - centerY - (anchor.y - centerY - panY) * ratio
        return next
    }

    /// Zoomed so a rectangle of the view fills it as far as its shape allows.
    public func zoomed(toFill box: CGRect, size: CGSize) -> PaletteCamera {
        guard box.width > 0, box.height > 0 else { return self }
        let factor = min(size.width / box.width, size.height / box.height)
        var next = zoomed(by: factor, around: CGPoint(x: box.midX, y: box.midY), size: size)
        // That kept the box's middle still; now bring it to the middle of the view.
        let ratio = next.zoom / zoom
        next.panX += (size.width / 2 - box.midX) * (ratio > 0 ? 1 : 0)
        next.panY += (size.height / 2 - box.midY) * (ratio > 0 ? 1 : 0)
        return next
    }

    /// On the flat wheel, the spot at the middle moves to `x`, `y`.
    public func centered(onX x: Double, y: Double, size: CGSize) -> PaletteCamera {
        var next = self
        let unit = pointsPerUnit(size)
        next.panX = -x * unit
        next.panY = -y * unit
        return next
    }

    /// What's showing of the flat wheel, in units from its middle.
    public func shownOnWheel(size: CGSize) -> CGRect {
        let unit = pointsPerUnit(size)
        return CGRect(x: (-size.width / 2 - panX) / unit, y: (-size.height / 2 - panY) / unit,
                      width: size.width / unit, height: size.height / unit)
    }

    public var isZoomedIn: Bool { zoom > 1.1 }

    /// Part of the way to `other`, zoom evenly in ratio and the rest in a straight line.
    public func interpolated(to other: PaletteCamera, t: Double) -> PaletteCamera {
        var next = other
        next.zoom = zoom * pow(other.zoom / zoom, t)
        next.panX = panX + (other.panX - panX) * t
        next.panY = panY + (other.panY - panY) * t
        next.yaw = yaw + (other.yaw - yaw) * t
        next.pitch = pitch + (other.pitch - pitch) * t
        next.solid = solid + (other.solid - solid) * t
        return next
    }
}

/// Every picture's place on the wheel and in the cylinder. Worked out once per map, so
/// filters and the timeline only have to choose among them.
public struct PaletteSpace: Sendable {
    public struct Place: Sendable {
        public let index: Int32
        public let wheel: SIMD2<Float>
        public let solid: SIMD3<Float>
        public let color: SIMD3<Float>
        public let resonance: Float
    }

    /// A place on screen, for this frame.
    public struct Dot: Sendable {
        public let place: Int32
        public let point: SIMD2<Float>
        public let scale: Float
        public let depth: Float
    }

    private let placeOfItem: [Int32]
    public let places: [Place]

    public init(items: [MapItem]) {
        var placeOfItem = [Int32](repeating: -1, count: items.count)
        var places: [Place] = []
        for (index, item) in items.enumerated() {
            guard let rgb = item.color else { continue }
            let wheel = PaletteLayout.position(rgb: rgb, seed: index)
            let solid = PaletteLayout.cylinder(rgb: rgb, seed: index)
            placeOfItem[index] = Int32(places.count)
            places.append(Place(
                index: Int32(index),
                wheel: SIMD2(Float(wheel.x), Float(wheel.y)),
                solid: SIMD3(Float(solid.x), Float(solid.y), Float(solid.z * PaletteCamera.cylinderHeight)),
                color: SIMD3(Float((rgb >> 16) & 0xff) / 255, Float((rgb >> 8) & 0xff) / 255, Float(rgb & 0xff) / 255),
                resonance: item.resonance))
        }
        self.placeOfItem = placeOfItem
        self.places = places
    }

    /// Which places are showing, most resonant first.
    public func showing(_ visible: [Int32]) -> [Int32] {
        visible.compactMap { index -> Int32? in
            let place = placeOfItem[Int(index)]
            return place >= 0 ? place : nil
        }.sorted { places[Int($0)].resonance != places[Int($1)].resonance ? places[Int($0)].resonance > places[Int($1)].resonance : $0 < $1 }
    }

    public func place(ofItem index: Int32) -> Int32? {
        let place = placeOfItem[Int(index)]
        return place >= 0 ? place : nil
    }

    public func position(of place: Place, solid: Double) -> SIMD3<Double> {
        let t = Float(solid)
        let flat = SIMD3(place.wheel.x, place.wheel.y, 0)
        let mixed = flat + (place.solid - flat) * t
        return SIMD3(Double(mixed.x), Double(mixed.y), Double(mixed.z))
    }

    /// Where the places fall on screen, farthest first so nearer ones draw over them.
    public func project(_ showing: [Int32], camera: PaletteCamera, size: CGSize) -> [Dot] {
        var dots: [Dot] = []
        dots.reserveCapacity(showing.count)
        for place in showing {
            let p = position(of: places[Int(place)], solid: camera.solid)
            let at = camera.project(x: p.x, y: p.y, z: p.z, size: size)
            dots.append(Dot(place: place, point: SIMD2(Float(at.point.x), Float(at.point.y)), scale: Float(at.scale), depth: Float(at.depth)))
        }
        // On the flat wheel everything is level, and the order from `showing` is kept.
        if camera.solid > 0 {
            dots.sort { $0.depth < $1.depth }
        } else {
            dots.reverse()
        }
        return dots
    }
}
