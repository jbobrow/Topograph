import Accelerate
import Foundation

/// Searches, floating over the map rather than part of it: curiosity, not taste. Land builds
/// up over the years, but searches come in bursts, so they show as weather: where one season's
/// searches gather more than yours usually do.
public struct Clouds: Sendable {
    public struct Search: Sendable {
        public let x: Float
        public let y: Float
        public let time: Int
        public let text: String
        public let id: String
        /// The region of the picture it floats over most closely.
        public let region: Int
        public init(x: Float, y: Float, time: Int, text: String, id: String = "", region: Int = -1) {
            self.x = x
            self.y = y
            self.time = time
            self.text = text
            self.id = id
            self.region = region
        }
    }

    /// One cloud: a patch of weather, and the searches of its season that float inside it.
    public struct Cloud: Sendable {
        /// Newest first.
        public let searches: [Search]
        /// The season, as `weather(endingAt:)` worked it out.
        public let season: ClosedRange<Int>
    }

    /// Oldest first.
    public let searches: [Search]
    /// Where searches gather over all time, on `DensityField`'s grid, adding up to 1.
    let usual: [Float]

    /// How far back from the time shown the weather reaches.
    public static let season = 90 * 86_400
    /// Softer than the terrain, as weather is.
    static let bandwidth = 32.0
    /// Fewer than this in a season is no weather to speak of.
    static let fewest = 20

    public init(searches: [Search] = []) {
        self.searches = searches.sorted { $0.time < $1.time }
        usual = searches.isEmpty ? [] : Self.normalized(Self.density(self.searches[...]))
    }

    public var isEmpty: Bool { searches.isEmpty }

    /// The weather for the season ending at `end`, on `DensityField`'s grid: 0 is clear sky,
    /// 1 a cloud's edge and 2 its core. nil when there were too few searches to say.
    public func weather(endingAt end: Int) -> [Float]? {
        let from = searches.partitioningIndex { $0.time >= end - Self.season }
        let to = searches.partitioningIndex { $0.time > end }
        guard to - from >= Self.fewest, !usual.isEmpty else { return nil }
        let share = Self.normalized(Self.density(searches[from..<to]))

        // Only where this season's searches are thick enough to count, then how far above the
        // usual they are there. The floor under the usual keeps a stray search somewhere you
        // never search from looking like a storm.
        let floor = vDSP.maximum(usual) * 0.02
        let thick = Self.percentile(share, 0.5)
        var above = [Float](repeating: 0, count: share.count)
        for i in share.indices where share[i] > thick { above[i] = share[i] / (usual[i] + floor) }
        let edge = Self.percentile(above, 0.7), core = Self.percentile(above, 0.9)
        guard edge > 0, core > edge else { return nil }
        return above.map { value in
            value <= 0 ? 0 : value < edge ? value / edge : 1 + min((value - edge) / (core - edge), 1)
        }
    }

    /// The cloud over a spot on the map in `weather` (the season ending at `end`), or nil for
    /// clear sky. A cloud is all the weather joined to that spot inside its outer rule.
    public func cloud(at x: Double, _ y: Double, weather: [Float], endingAt end: Int) -> Cloud? {
        guard let patch = Self.patch(weather, at: x, y) else { return nil }
        let from = searches.partitioningIndex { $0.time >= end - Self.season }
        let to = searches.partitioningIndex { $0.time > end }
        let n = DensityField.side
        let inside = searches[from..<to].filter { search in
            guard let cell = Self.cell(Double(search.x), Double(search.y), side: n) else { return false }
            return patch[cell]
        }
        return Cloud(searches: inside.reversed(), season: (end - Self.season)...end)
    }

    /// Whether a spot on the map is under a cloud.
    public static func isCloudy(_ weather: [Float], at x: Double, _ y: Double) -> Bool {
        start(weather, at: x, y) != nil
    }

    /// The cell a spot falls in, or nil off the grid.
    static func cell(_ x: Double, _ y: Double, side n: Int) -> Int? {
        let cx = Int(((x + DensityField.origin) / DensityField.cellSize).rounded(.down))
        let cy = Int(((y + DensityField.origin) / DensityField.cellSize).rounded(.down))
        guard cx >= 0, cy >= 0, cx < n, cy < n else { return nil }
        return cx + cy * n
    }

    /// A cloudy cell at the spot, or beside it: the shader's smoothing draws the edge a little
    /// way from where the cells change.
    static func start(_ weather: [Float], at x: Double, _ y: Double) -> Int? {
        let n = DensityField.side
        guard weather.count == n * n, let center = cell(x, y, side: n) else { return nil }
        if weather[center] >= 1 { return center }
        let cx = center % n, cy = center / n
        for (dx, dy) in [(1, 0), (-1, 0), (0, 1), (0, -1)] {
            let x = cx + dx, y = cy + dy
            if x >= 0, y >= 0, x < n, y < n, weather[x + y * n] >= 1 { return x + y * n }
        }
        return nil
    }

    /// The cells of the cloud at a spot, joined at sides or corners, or nil for clear sky.
    static func patch(_ weather: [Float], at x: Double, _ y: Double) -> [Bool]? {
        guard let first = start(weather, at: x, y) else { return nil }
        let n = DensityField.side
        var inside = [Bool](repeating: false, count: weather.count)
        var stack = [first]
        inside[first] = true
        while let cell = stack.popLast() {
            let cx = cell % n, cy = cell / n
            for dy in -1...1 {
                for dx in -1...1 {
                    let x = cx + dx, y = cy + dy
                    guard x >= 0, y >= 0, x < n, y < n else { continue }
                    let next = x + y * n
                    if !inside[next], weather[next] >= 1 {
                        inside[next] = true
                        stack.append(next)
                    }
                }
            }
        }
        return inside
    }

    /// Searches spread over the terrain's grid and blurred.
    static func density(_ searches: ArraySlice<Search>) -> [Float] {
        let n = DensityField.side
        var values = [Float](repeating: 0, count: n * n)
        let origin = Float(DensityField.origin), toCell = Float(1 / DensityField.cellSize)
        for search in searches {
            let cx = (search.x + origin) * toCell, cy = (search.y + origin) * toCell
            guard cx >= 0, cy >= 0, cx < Float(n), cy < Float(n) else { continue }
            values[Int(cx) + Int(cy) * n] += 1
        }
        DensityField.blur(&values, side: n, bandwidth: bandwidth)
        return values
    }

    static func normalized(_ values: [Float]) -> [Float] {
        let total = vDSP.sum(values)
        return total > 0 ? vDSP.divide(values, total) : values
    }

    /// Roughly the given fraction of the way up the values above zero. Every seventh cell is
    /// plenty to judge by, and quick enough to run as the timeline plays.
    static func percentile(_ values: [Float], _ fraction: Double) -> Float {
        var sample: [Float] = []
        sample.reserveCapacity(values.count / 7 + 1)
        for i in stride(from: 0, to: values.count, by: 7) where values[i] > 0 { sample.append(values[i]) }
        guard !sample.isEmpty else { return 0 }
        sample.sort()
        return sample[min(Int(Double(sample.count - 1) * fraction), sample.count - 1)]
    }
}

extension Collection {
    /// The first index where `belongs` holds, for a collection where it holds for a tail.
    func partitioningIndex(where belongs: (Element) -> Bool) -> Index {
        var low = startIndex, count = self.count
        while count > 0 {
            let half = count / 2, middle = index(low, offsetBy: half)
            if belongs(self[middle]) {
                count = half
            } else {
                low = index(after: middle)
                count -= half + 1
            }
        }
        return low
    }
}
