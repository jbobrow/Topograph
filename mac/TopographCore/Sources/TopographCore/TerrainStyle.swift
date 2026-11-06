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

    /// The zoom at which the viewer hands markers over to thumbnails. Markers stop
    /// growing here so they don't overwhelm the map.
    public static let markerZoomLimit: Double = 2.4
}
