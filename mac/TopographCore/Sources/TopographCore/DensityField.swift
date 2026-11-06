import Foundation

/// The terrain's elevation: a resonance-weighted density of the items on a grid.
///
/// A port of `d3.contourDensity` as the viewer configures it (cell size 4, bandwidth
/// 16 over the 1000 × 1000 map): each item is split between its four nearest cells,
/// then the grid gets three box blurs each way. A value at index `i` sits at map
/// coordinate `(i + 0.5) * cellSize - origin`.
public struct DensityField: Sendable {
    public static let mapSize = 1000.0
    public static let cellSize = 4.0
    public static let bandwidth = 16.0

    /// The blur radius in map units, chosen so three passes have this bandwidth.
    public static let radius = (sqrt(4 * bandwidth * bandwidth + 1) - 1) / 2
    /// How far the grid extends past the map on each side.
    public static let origin = radius * 3

    public let width: Int
    public let height: Int
    /// Rows from the top of the map, scaled so the highest point is 1.
    public let elevation: [Float]
    /// The highest point in d3's units, before scaling.
    public let peak: Double

    public init(items: [MapItem]) {
        let n = Int(Self.mapSize + Self.origin * 2) >> 2
        var values = [Float](repeating: 0, count: n * n)
        let origin = Float(Self.origin), toCell = Float(1 / Self.cellSize)
        for item in items {
            let cx = (item.x + origin) * toCell, cy = (item.y + origin) * toCell
            guard cx >= 0, cy >= 0, cx < Float(n), cy < Float(n) else { continue }
            let weight = item.resonance > 0 ? item.resonance : 1
            let x0 = Int(cx), y0 = Int(cy)
            let tx = cx - Float(x0) - 0.5, ty = cy - Float(y0) - 0.5
            let x1 = min(x0 + 1, n - 1), y1 = min(y0 + 1, n - 1)
            values[x0 + y0 * n] += (1 - tx) * (1 - ty) * weight
            values[x1 + y0 * n] += tx * (1 - ty) * weight
            values[x1 + y1 * n] += tx * ty * weight
            values[x0 + y1 * n] += (1 - tx) * ty * weight
        }

        var scratch = values
        let radius = Self.radius / Self.cellSize
        for pass in 0..<3 {
            for row in 0..<n {
                if pass % 2 == 0 {
                    Self.boxBlur(radius, from: values, to: &scratch, start: row * n, count: n, step: 1)
                } else {
                    Self.boxBlur(radius, from: scratch, to: &values, start: row * n, count: n, step: 1)
                }
            }
        }
        // After three passes the latest copy is in `scratch`.
        for pass in 0..<3 {
            for column in 0..<n {
                if pass % 2 == 0 {
                    Self.boxBlur(radius, from: scratch, to: &values, start: column, count: n, step: n)
                } else {
                    Self.boxBlur(radius, from: values, to: &scratch, start: column, count: n, step: n)
                }
            }
        }
        // And after three more it is in `values`.

        let highest = values.max() ?? 0
        width = n
        height = n
        peak = Double(highest) / (Self.cellSize * Self.cellSize)
        elevation = highest > 0 ? values.map { $0 / highest } : values
    }

    /// A box blur with a fractional radius (`d3.blur2`): whole cells inside the
    /// radius count fully, the next one out in proportion, and edges repeat.
    private static func boxBlur(_ radius: Double, from source: [Float], to target: inout [Float],
                                start: Int, count: Int, step: Int) {
        let whole = Int(radius.rounded(.down))
        let fraction = radius - Double(whole)
        let scale = 1 / (2 * radius + 1)
        let last = count - 1
        @inline(__always) func at(_ i: Int) -> Double { Double(source[start + min(max(i, 0), last) * step]) }

        var sum = 0.0
        for i in -whole...whole { sum += at(i) }
        for i in 0...last {
            target[start + i * step] = Float((sum + fraction * (at(i - whole - 1) + at(i + whole + 1))) * scale)
            sum += at(i + whole + 1) - at(i - whole)
        }
    }
}
