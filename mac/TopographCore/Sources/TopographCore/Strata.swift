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

/// Colors sorted into a few named bands, for following color through time: twelve hues
/// around the wheel, and white, gray and black for what has little color of its own.
public enum ColorBands {
    public static let names = ["reds", "oranges", "yellows", "limes", "greens", "teals", "cyans", "azures",
                               "blues", "violets", "magentas", "roses", "whites", "grays", "blacks"]
    public static var count: Int { names.count }
    /// Cool colors, then the neutrals, then warm ones, so each layer sits beside its kin.
    static let stackOrder = [7, 6, 5, 4, 3, 8, 14, 13, 12, 2, 1, 0, 11, 10, 9]

    public static func band(of rgb: UInt32) -> Int {
        let r = Double((rgb >> 16) & 0xff) / 255, g = Double((rgb >> 8) & 0xff) / 255, b = Double(rgb & 0xff) / 255
        let high = max(r, g, b), low = min(r, g, b), chroma = high - low
        if chroma < 0.12 {
            let lightness = (high + low) / 2
            return lightness > 0.75 ? 12 : lightness < 0.25 ? 14 : 13
        }
        var hue: Double
        if high == r { hue = (g - b) / chroma } else if high == g { hue = (b - r) / chroma + 2 } else { hue = (r - g) / chroma + 4 }
        if hue < 0 { hue += 6 }
        // Each band is centered on its hue: red runs from just under 0 to just over.
        return Int((hue * 2 + 0.5).rounded(.down)) % 12
    }

    /// What's showing in a band, most resonant first.
    public static func items(in band: Int, map: LibraryMap, visible: [Int32]) -> [Int32] {
        visible.filter { index in map.items[Int(index)].color.map { Self.band(of: $0) == band } ?? false }
            .sorted {
                let a = map.items[Int($0)], b = map.items[Int($1)]
                return a.resonance != b.resonance ? a.resonance > b.resonance : $0 < $1
            }
    }

    /// Each band's average color across `items`, so the bands look like what's in them.
    public static func colors(of items: [MapItem]) -> [SIMD3<Float>] {
        var sums = [SIMD3<Double>](repeating: .zero, count: count)
        var tallies = [Double](repeating: 0, count: count)
        for item in items {
            guard let rgb = item.color else { continue }
            let band = band(of: rgb)
            sums[band] += SIMD3(Double((rgb >> 16) & 0xff), Double((rgb >> 8) & 0xff), Double(rgb & 0xff)) / 255
            tallies[band] += 1
        }
        return (0..<count).map { band in
            guard tallies[band] > 0 else { return .zero }
            let mean = sums[band] / tallies[band]
            return SIMD3(Float(mean.x), Float(mean.y), Float(mean.z))
        }
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
    /// Each key's layer, as a position in `layers`. Keys are regions, or for color, bands.
    private let layerOfKey: [Int: Int]
    private let keyOfItem: @Sendable (MapItem) -> Int?
    /// Whether thickness is a part of each month rather than an amount.
    public let isShare: Bool

    /// `order` keeps the layers in a set order, from `stackingOrder`. Without it they're
    /// ordered by what's in `visible`, which would swap them around as a time range moves.
    /// With `waiting`, links still waiting for their pictures get a layer of their own; the
    /// order must have been made the same way.
    public init(map: LibraryMap, visible: [Int32], axis: MonthAxis, order: [Int]? = nil, waiting: Bool = false) {
        let (keys, table) = Self.table(map: map, visible: visible, axis: axis, waiting: waiting)

        // Light smoothing so layers read as strata rather than noise.
        let smooth = table.map(Self.smoothed)
        let stacked = Self.stack(smooth, order: order)
        layers = stacked.map { (index, bottom, top) in
            Layer(region: keys[index], raw: table[index], bottom: bottom, top: top)
        }
        var layerOf: [Int: Int] = [:]
        for (position, layer) in stacked.enumerated() {
            guard let id = keys[layer.index] else { continue }
            func mark(_ id: Int) {
                layerOf[id] = position
                map.regions.regions[id]?.children.forEach(mark)
            }
            mark(id)
        }
        layerOfKey = layerOf
        keyOfItem = { $0.region }
        isShare = false
        low = layers.flatMap(\.bottom).min() ?? 0
        high = layers.flatMap(\.top).max() ?? 1
        self.axis = axis
    }

    /// Color through time: a layer for each band of `ColorBands`, thick where you kept
    /// that color, in a set order so neighboring layers are neighboring colors.
    ///
    /// With `share`, thickness is the band's part of that month rather than its amount, so a
    /// month of bulk imports doesn't flatten every other year.
    public init(colorsOf map: LibraryMap, visible: [Int32], axis: MonthAxis, share: Bool = false) {
        var table = [[Double]](repeating: [Double](repeating: 0, count: axis.count), count: ColorBands.count)
        for index in visible {
            let item = map.items[Int(index)]
            guard let time = item.time, let color = item.color, let month = axis.index(of: time) else { continue }
            table[ColorBands.band(of: color)][month] += Double(item.resonance)
        }
        var smooth = table.map(Self.smoothed)
        if share {
            for month in 0..<axis.count {
                let total = smooth.reduce(0) { $0 + $1[month] }
                guard total > 0 else { continue }
                for band in smooth.indices { smooth[band][month] /= total }
            }
        }
        // Every month adds up to the same, so there's no slope for the wiggle to even out, and
        // it would only make sparse months jump. Each month is simply centered.
        let stacked = Self.stack(smooth, order: ColorBands.stackOrder, centered: share)
        layers = stacked.map { (index, bottom, top) in
            Layer(region: index, raw: table[index], bottom: bottom, top: top)
        }
        layerOfKey = Dictionary(uniqueKeysWithValues: stacked.enumerated().map { ($1.index, $0) })
        keyOfItem = { $0.color.map(ColorBands.band(of:)) }
        isShare = share
        low = layers.flatMap(\.bottom).min() ?? 0
        high = layers.flatMap(\.top).max() ?? 1
        self.axis = axis
    }

    /// The order to stack layers in for everything a filter shows, across all of time.
    public static func stackingOrder(map: LibraryMap, visible: [Int32], axis: MonthAxis, waiting: Bool = false) -> [Int] {
        insideOut(table(map: map, visible: visible, axis: axis, waiting: waiting).values.map(smoothed))
    }

    /// Each layer's resonance per month, with which region each layer is.
    private static func table(map: LibraryMap, visible: [Int32], axis: MonthAxis, waiting: Bool) -> (keys: [Int?], values: [[Double]]) {
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
        if waiting, !map.waitingTimes.isEmpty {
            keys.append(nil)
            table.append(axis.counts(of: map.waitingTimes).map(Double.init))
        }
        return (keys, table)
    }

    /// Where an item belongs on the chart: its time, and the height of the middle of its
    /// layer then, in the same units as `low` and `high`. No height if it's in no layer.
    public func place(of item: MapItem) -> (time: Int, height: Double?)? {
        guard let time = item.time, let month = axis.index(of: time) else { return nil }
        guard let key = keyOfItem(item), let position = layerOfKey[key] else { return (time, nil) }
        let span = Double(axis.edges[month + 1] - axis.edges[month])
        let at = Double(month) + Double(time - axis.edges[month]) / span
        let layer = layers[position]
        return (time, (BasisCurve.value(layer.top, at: at) + BasisCurve.value(layer.bottom, at: at)) / 2)
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
    static func stack(_ series: [[Double]], order given: [Int]? = nil, centered: Bool = false) -> [(index: Int, bottom: [Double], top: [Double])] {
        guard let months = series.first?.count, months > 0 else { return [] }
        let order = given ?? insideOut(series)

        // Wiggle: choose a baseline that minimizes how much the layers slope.
        var baseline = [Double](repeating: 0, count: months)
        var y = 0.0
        for j in 1..<max(months, 1) where !centered {
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
        if centered {
            baseline = (0..<months).map { j in -series.reduce(0) { $0 + $1[j] } / 2 }
        }

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
    /// The height of the curve through `values` at a fractional position along them, so a
    /// point can sit on what `append` draws rather than on the straight line between months.
    public static func value(_ values: [Double], at position: Double) -> Double {
        guard let last = values.indices.last, last > 0 else { return values.first ?? 0 }
        let clamped = min(max(position, 0), Double(last))
        let i = min(Int(clamped), last - 1)
        let t = clamped - Double(i)
        func point(_ index: Int) -> Double { values[min(max(index, 0), last)] }
        let (a, b, c, d) = (point(i - 1), point(i), point(i + 1), point(i + 2))
        let t2 = t * t, t3 = t2 * t
        return ((1 - t) * (1 - t) * (1 - t) * a + (3 * t3 - 6 * t2 + 4) * b + (-3 * t3 + 3 * t2 + 3 * t + 1) * c + t3 * d) / 6
    }

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

/// A part of the time axis, as fractions of the axis from 0 to 1: the time you've selected,
/// or what a chart shows.
public struct StrataWindow: Sendable, Equatable {
    public let start: Double
    public let end: Double

    public static let whole = StrataWindow(start: 0, end: 1)

    public init(start: Double, end: Double) {
        let low = min(max(start, 0), 1), high = min(max(end, 0), 1)
        self.start = min(low, high)
        self.end = max(max(low, high), min(low, high) + 1e-6)
    }

    public var span: Double { end - start }
    public var isWhole: Bool { span >= 1 - 1e-6 }

    /// The chart keeps a little room at its sides for the whole axis, and runs to the edges
    /// once it's zoomed in, so what's selected meets the sides of the canvas.
    public func inset(_ full: Double) -> Double {
        full * max(0, 1 - (1 / span - 1) / 0.25)
    }

    public func x(ofFraction fraction: Double, width: Double, inset full: Double) -> Double {
        let side = inset(full)
        return side + (fraction - start) / span * (width - 2 * side)
    }

    public func fraction(atX x: Double, width: Double, inset full: Double) -> Double {
        let side = inset(full)
        return start + (x - side) / max(width - 2 * side, 1) * span
    }

    /// Slid and trimmed to fit inside `limit`.
    public func clamped(to limit: StrataWindow) -> StrataWindow {
        Self.fitted(start: start, span: span, in: limit)
    }

    /// A window of `span` starting as near `start` as `limit` allows. Sliding it keeps its size,
    /// where the plain initializer would trim whatever ran past the axis.
    public static func fitted(start: Double, span: Double, in limit: StrataWindow) -> StrataWindow {
        guard span < limit.span else { return limit }
        let at = min(max(start, limit.start), limit.end - span)
        return StrataWindow(start: at, end: at + span)
    }

    /// Bigger factors zoom in. The moment of time at `x` stays at `x`.
    public func zoomed(by factor: Double, atX x: Double, width: Double, inset full: Double,
                       minSpan: Double, limit: StrataWindow) -> StrataWindow {
        let held = fraction(atX: x, width: width, inset: full)
        let next = min(max(span / factor, min(minSpan, span)), limit.span)
        let sized = StrataWindow(start: 0, end: next)
        let side = sized.inset(full)
        let share = (x - side) / max(width - 2 * side, 1)
        return Self.fitted(start: held - share * next, span: next, in: limit)
    }

    /// For a selection on a chart of all time, where what's under the pointer is `fraction`
    /// and it's the selection that changes around it.
    public func zoomed(by factor: Double, aroundFraction fraction: Double, minSpan: Double) -> StrataWindow {
        let next = min(max(span / factor, min(minSpan, span)), 1)
        let scale = next / span
        return Self.fitted(start: fraction - (fraction - start) * scale, span: next, in: .whole)
    }

    public func panned(byX dx: Double, width: Double, inset full: Double, limit: StrataWindow) -> StrataWindow {
        let shift = -dx / max(width - 2 * inset(full), 1) * span
        return Self.fitted(start: start + shift, span: span, in: limit)
    }

    public func centered(at fraction: Double, limit: StrataWindow) -> StrataWindow {
        Self.fitted(start: fraction - span / 2, span: span, in: limit)
    }
}
