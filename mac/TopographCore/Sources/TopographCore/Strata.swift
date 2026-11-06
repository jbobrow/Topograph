import CoreGraphics
import Foundation

/// Calendar months from the first time to the last, on your local calendar.
public struct MonthAxis: Sendable, Equatable {
    /// The start of each month, plus the end of the last. Unix seconds.
    public let edges: [Int]

    public init?(times: some Sequence<Int>, calendar: Calendar = .current) {
        var low: Int?, high: Int?
        for time in times {
            low = min(low ?? time, time)
            high = max(high ?? time, time)
        }
        guard let low, let high else { return nil }
        func monthStart(_ time: Int) -> Date {
            let date = Date(timeIntervalSince1970: TimeInterval(time))
            return calendar.date(from: calendar.dateComponents([.year, .month], from: date))!
        }
        var edges: [Int] = []
        var date = monthStart(low)
        let last = monthStart(high)
        while date <= last {
            edges.append(Int(date.timeIntervalSince1970))
            date = calendar.date(byAdding: .month, value: 1, to: date)!
        }
        edges.append(Int(date.timeIntervalSince1970))
        self.edges = edges
    }

    public var count: Int { edges.count - 1 }
    public var start: Int { edges.first! }
    public var end: Int { edges.last! }

    /// The month holding a time.
    public func index(of time: Int) -> Int? {
        guard time >= start, time < end else { return nil }
        var low = 0, high = count
        while high - low > 1 {
            let middle = (low + high) / 2
            if edges[middle] <= time { low = middle } else { high = middle }
        }
        return low
    }

    /// Where a time falls along the axis, from 0 to 1.
    public func fraction(of time: Int) -> Double {
        Double(time - start) / Double(max(end - start, 1))
    }

    public func time(atFraction fraction: Double) -> Int {
        start + Int((min(max(fraction, 0), 1) * Double(end - start)).rounded())
    }

    /// The start of each calendar year on the axis, with its number.
    public func years(calendar: Calendar = .current) -> [(year: Int, time: Int)] {
        var out: [(Int, Int)] = []
        for edge in edges.dropLast() {
            let parts = calendar.dateComponents([.year, .month], from: Date(timeIntervalSince1970: TimeInterval(edge)))
            if parts.month == 1 { out.append((parts.year!, edge)) }
        }
        return out
    }

    public func counts(of times: some Sequence<Int>) -> [Int] {
        var counts = [Int](repeating: 0, count: count)
        for time in times {
            if let index = index(of: time) { counts[index] += 1 }
        }
        return counts
    }
}

/// Regions stacked as layers through time: each layer's thickness is its resonance per
/// month. A port of `drawStrata` in viewer/app.js, with d3's wiggle offset and inside-out
/// order so the result sits the same way up.
public struct StrataModel: Sendable {
    public struct Layer: Sendable, Identifiable {
        /// nil for items not placed on the map yet.
        public let region: Int?
        /// Unsmoothed, per month, for readouts.
        public let raw: [Double]
        public let bottom: [Double]
        public let top: [Double]
        public var id: Int { region ?? -1 }
    }

    public let axis: MonthAxis
    /// From the bottom of the stack up.
    public let layers: [Layer]
    public let low: Double
    public let high: Double

    public init(map: LibraryMap, visible: [Int32], axis: MonthAxis) {
        let cut = map.regions.strataLayers()
        var layerOf: [Int: Int] = [:]
        func mark(_ id: Int, as layer: Int) {
            layerOf[id] = layer
            map.regions.regions[id]?.children.forEach { mark($0, as: layer) }
        }
        for (layer, id) in cut.enumerated() { mark(id, as: layer) }

        var table = [[Double]](repeating: [Double](repeating: 0, count: axis.count), count: cut.count)
        for index in visible {
            let item = map.items[Int(index)]
            guard let time = item.time, let region = item.region, let layer = layerOf[region],
                  let month = axis.index(of: time) else { continue }
            table[layer][month] += Double(item.resonance)
        }
        var keys: [Int?] = cut
        if !map.waitingTimes.isEmpty {
            keys.append(nil)
            table.append(axis.counts(of: map.waitingTimes).map(Double.init))
        }

        // Light smoothing so layers read as strata rather than noise.
        let smooth = table.map(Self.smoothed)
        let stacked = Self.stack(smooth)
        layers = stacked.map { (index, bottom, top) in
            Layer(region: keys[index], raw: table[index], bottom: bottom, top: top)
        }
        low = layers.flatMap(\.bottom).min() ?? 0
        high = layers.flatMap(\.top).max() ?? 1
        self.axis = axis
    }

    static func smoothed(_ values: [Double]) -> [Double] {
        let kernel: [Double] = [1, 2, 3, 2, 1]
        return values.indices.map { i in
            var sum = 0.0, weight = 0.0
            for (j, w) in kernel.enumerated() where values.indices.contains(i + j - 2) {
                sum += w * values[i + j - 2]
                weight += w
            }
            return sum / weight
        }
    }

    /// `d3.stack` with `stackOrderInsideOut` and `stackOffsetWiggle`. Returns each
    /// series' original index with its bottom and top edges, bottom of the stack first.
    static func stack(_ series: [[Double]]) -> [(index: Int, bottom: [Double], top: [Double])] {
        guard let months = series.first?.count, months > 0 else { return [] }
        let order = insideOut(series)

        // Wiggle: choose a baseline that minimizes how much the layers slope.
        var baseline = [Double](repeating: 0, count: months)
        var y = 0.0
        for j in 1..<max(months, 1) {
            var s1 = 0.0, s2 = 0.0
            for (i, si) in order.enumerated() {
                let now = series[si][j], before = series[si][j - 1]
                var s3 = (now - before) / 2
                for k in 0..<i {
                    let sk = order[k]
                    s3 += series[sk][j] - series[sk][j - 1]
                }
                s1 += now
                s2 += s3 * now
            }
            baseline[j - 1] = y
            if s1 != 0 { y -= s2 / s1 }
        }
        baseline[months - 1] = y

        var out: [(Int, [Double], [Double])] = []
        var below = baseline
        for index in order {
            var top = below
            for j in 0..<months { top[j] += series[index][j] }
            out.append((index, below, top))
            below = top
        }
        return out
    }

    /// Series that peak earliest go nearest the middle, alternating above and below.
    private static func insideOut(_ series: [[Double]]) -> [Int] {
        let peaks = series.map { values -> Int in
            var best = 0
            var high = -Double.infinity
            for (j, value) in values.enumerated() where value > high {
                high = value
                best = j
            }
            return best
        }
        let sums = series.map { $0.reduce(0, +) }
        let appearance = series.indices.sorted { peaks[$0] != peaks[$1] ? peaks[$0] < peaks[$1] : $0 < $1 }
        var top = 0.0, bottom = 0.0
        var tops: [Int] = [], bottoms: [Int] = []
        for j in appearance {
            if top < bottom {
                top += sums[j]
                tops.append(j)
            } else {
                bottom += sums[j]
                bottoms.append(j)
            }
        }
        return bottoms.reversed() + tops
    }
}

/// `d3.curveBasis`, as a smooth line through a series of points.
public enum BasisCurve {
    /// Adds the curve to `path`. It continues from the current point when `joined`.
    public static func append(_ points: [CGPoint], to path: CGMutablePath, joined: Bool) {
        guard let first = points.first else { return }
        if joined { path.addLine(to: first) } else { path.move(to: first) }
        guard points.count > 1 else { return }
        var p0 = first, p1 = points[1]
        func curve(_ x: CGPoint) {
            path.addCurve(to: CGPoint(x: (p0.x + 4 * p1.x + x.x) / 6, y: (p0.y + 4 * p1.y + x.y) / 6),
                          control1: CGPoint(x: (2 * p0.x + p1.x) / 3, y: (2 * p0.y + p1.y) / 3),
                          control2: CGPoint(x: (p0.x + 2 * p1.x) / 3, y: (p0.y + 2 * p1.y) / 3))
        }
        if points.count == 2 {
            path.addLine(to: p1)
            return
        }
        path.addLine(to: CGPoint(x: (5 * p0.x + p1.x) / 6, y: (5 * p0.y + p1.y) / 6))
        for point in points.dropFirst(2) {
            curve(point)
            p0 = p1
            p1 = point
        }
        curve(p1)
        path.addLine(to: p1)
    }
}
