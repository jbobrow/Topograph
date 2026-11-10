import Foundation

/// How elevation is drawn, from `renderTerrain` and `ditherPatterns` in viewer/app.js.
public enum TerrainStyle {
    public static let levels = 13

    /// Elevations of the contour lines, spaced evenly in ratio, where the highest
    /// point of the map is 1.
    public static let thresholds: [Float] = (0..<levels).map { i in
        Float(0.025 * pow(0.92 / 0.025, Double(i) / Double(levels - 1)))
    }

    /// How much of each band is inked. Capped well below solid so thumbnails and
    /// labels stay readable on the peaks.
    public static let ditherDensity: [Float] = (0..<levels).map { i in
        Float(0.03 + 0.31 * pow(Double(i) / Double(levels - 1), 1.3))
    }

    /// Every fourth contour is an index contour, heavier and darker.
    public static func isIndexContour(_ level: Int) -> Bool { level % 4 == 3 }

    /// The 8 × 8 ordered dither matrix, row by row, values 0 to 63.
    public static let bayer: [Float] = {
        var m: [[Int]] = [[0]]
        for _ in 0..<3 {
            let s = m.count
            var out = [[Int]](repeating: [Int](repeating: 0, count: s * 2), count: s * 2)
            for y in 0..<s {
                for x in 0..<s {
                    let v = m[y][x] * 4
                    out[y][x] = v
                    out[y][x + s] = v + 2
                    out[y + s][x] = v + 3
                    out[y + s][x + s] = v + 1
                }
            }
            m = out
        }
        return m.flatMap { $0.map(Float.init) }
    }()

    /// A marker's size before zoom: `screen radius = base * sqrt(k)`, in points.
    public static func markerBase(resonance: Float) -> Float { 1 + resonance.squareRoot() * 0.5 }

    /// From this zoom the most resonant pictures show as thumbnails, and everything
    /// else is a small dot.
    public static let thumbnailZoom: Double = 2.4
    /// That dot's radius in points.
    public static let dotRadius: Float = 1.8

    /// With markers hidden, the points around the pointer where they show, fading from its
    /// middle.
    public static let markerReveal: Float = 160

    /// A thumbnail's long edge in points before resonance. It grows with zoom, up to a limit.
    public static func thumbnailSize(k: Double) -> Double { min(150, 6.5 * pow(k, 0.9)) }

    /// How much larger a resonant thumbnail is drawn.
    public static func thumbnailScale(resonance: Float) -> Double { 0.7 + 0.15 * Double(min(resonance, 4)) }

    /// In 3D, from how large on screen (a thumbnail's long edge before resonance, in points)
    /// nearness starts to count in which pictures show. It counts fully at twice this.
    public static let standingNear: Double = 60

    /// In 3D, which pictures show when there are more than can be drawn: the most resonant,
    /// however far, until pictures come near enough to be drawn large. Those show whatever their
    /// resonance, so nothing close by is missing, and among them resonance decides again.
    public static func standingRank(size: Double, resonance: Float) -> Double {
        let t = min(max((size - standingNear) / standingNear, 0), 1)
        return Double(resonance) + 100 * t * t * (3 - 2 * t)
    }
}
