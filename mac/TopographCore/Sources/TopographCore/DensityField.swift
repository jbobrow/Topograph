import Accelerate
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

    /// `items` at their positions. The elevation is scaled by `fullPeak` when it's given,
    /// so a filtered map keeps the same contour heights as the whole one.
    public init(items: [MapItem], visible: [Int32]? = nil, fullPeak: Double? = nil) {
        let n = Int(Self.mapSize + Self.origin * 2) >> 2
        var values = [Float](repeating: 0, count: n * n)
        let origin = Float(Self.origin), toCell = Float(1 / Self.cellSize)
        values.withUnsafeMutableBufferPointer { cells in
            items.withUnsafeBufferPointer { items in
                func add(_ item: borrowing MapItem) {
                    let cx = (item.x + origin) * toCell, cy = (item.y + origin) * toCell
                    guard cx >= 0, cy >= 0, cx < Float(n), cy < Float(n) else { return }
                    let weight = item.resonance > 0 ? item.resonance : 1
                    let x0 = Int(cx), y0 = Int(cy)
                    let tx = cx - Float(x0) - 0.5, ty = cy - Float(y0) - 0.5
                    let x1 = min(x0 + 1, n - 1), y1 = min(y0 + 1, n - 1)
                    cells[x0 + y0 * n] += (1 - tx) * (1 - ty) * weight
                    cells[x1 + y0 * n] += tx * (1 - ty) * weight
                    cells[x1 + y1 * n] += tx * ty * weight
                    cells[x0 + y1 * n] += (1 - tx) * ty * weight
                }
                if let visible {
                    for index in visible { add(items[Int(index)]) }
                } else {
                    for index in items.indices { add(items[index]) }
                }
            }
        }

        Self.blur(&values, side: n, bandwidth: Self.bandwidth)

        let unit = Float(Self.cellSize * Self.cellSize)
        let highest = vDSP.maximum(values) / unit
        let scale = Float(fullPeak ?? 0) > 0 ? Float(fullPeak!) : highest
        width = n
        height = n
        peak = Double(highest)
        elevation = scale > 0 ? values.map { $0 / unit / scale } : values
    }

    /// Cells across the grid, which is square.
    public static var side: Int { Int(mapSize + origin * 2) >> 2 }

    /// `bandwidth` map units of blur over a grid of `side` × `side` cells, in place.
    ///
    /// This runs for every step of the timeline as it plays, so it has to be quick.
    /// Three blurs across then three down, each copying from one buffer to the other,
    /// which leaves the result back in `values`.
    static func blur(_ values: inout [Float], side n: Int, bandwidth: Double) {
        var scratch = values
        let radius = (sqrt(4 * bandwidth * bandwidth + 1) - 1) / 2
        let blur = Blur(radius: radius / cellSize, count: n)
        values.withUnsafeMutableBufferPointer { first in
            scratch.withUnsafeMutableBufferPointer { second in
                nonisolated(unsafe) let a = first.baseAddress!
                nonisolated(unsafe) let b = second.baseAddress!
                for pass in 0..<6 {
                    let across = pass < 3
                    let (source, target) = pass % 2 == 0 ? (a, b) : (b, a)
                    nonisolated(unsafe) let from = source
                    nonisolated(unsafe) let to = target
                    DispatchQueue.concurrentPerform(iterations: n) { line in
                        if across {
                            blur.run(from: from, to: to, start: line * n, step: 1)
                        } else {
                            blur.run(from: from, to: to, start: line, step: n)
                        }
                    }
                }
            }
        }
    }

    /// A box blur with a fractional radius (`d3.blur2`): whole cells inside the
    /// radius count fully, the next one out in proportion, and edges repeat.
    private struct Blur: Sendable {
        let whole: Int
        let fraction: Double
        let scale: Double
        let count: Int
        /// Where each position's edges fall, with the ends repeated: the cell leaving the
        /// box, the one just inside its lower edge, and the one just past its upper edge.
        let below: [Int32]
        let leaving: [Int32]
        let above: [Int32]

        init(radius: Double, count: Int) {
            let whole = Int(radius.rounded(.down))
            self.whole = whole
            fraction = radius - Double(whole)
            scale = 1 / (2 * radius + 1)
            self.count = count
            let last = count - 1
            below = (0..<count).map { Int32(max($0 - whole - 1, 0)) }
            leaving = (0..<count).map { Int32(max($0 - whole, 0)) }
            above = (0..<count).map { Int32(min($0 + whole + 1, last)) }
        }

        func run(from source: UnsafePointer<Float>, to target: UnsafeMutablePointer<Float>, start: Int, step: Int) {
            let last = count - 1
            var sum = 0.0
            for i in -whole...whole { sum += Double(source[start + min(max(i, 0), last) * step]) }
            below.withUnsafeBufferPointer { below in
                leaving.withUnsafeBufferPointer { leaving in
                    above.withUnsafeBufferPointer { above in
                        for i in 0..<count {
                            let high = Double(source[start + Int(above[i]) * step])
                            let low = Double(source[start + Int(below[i]) * step])
                            target[start + i * step] = Float((sum + fraction * (low + high)) * scale)
                            sum += high - Double(source[start + Int(leaving[i]) * step])
                        }
                    }
                }
            }
        }
    }
}
