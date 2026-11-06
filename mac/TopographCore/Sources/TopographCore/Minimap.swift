import CoreGraphics
import Foundation

/// The whole map, small: the terrain's dither and index contours as a 1-bit picture.
public enum Minimap {
    /// A mask of `side` × `side` pixels, where ink is opaque. Dots are `dot` pixels
    /// across, so they stay crisp on a Retina screen.
    public static func mask(field: DensityField, side: Int, dot: Int = 1) -> [UInt8] {
        let thresholds = TerrainStyle.thresholds
        var bands = [Int8](repeating: -1, count: side * side)
        let toCell = DensityField.mapSize / Double(side) / DensityField.cellSize
        let offset = DensityField.origin / DensityField.cellSize - 0.5
        for row in 0..<side {
            let cy = (Double(row) + 0.5) * toCell + offset
            for column in 0..<side {
                let cx = (Double(column) + 0.5) * toCell + offset
                let value = sample(field, cx, cy)
                guard value >= thresholds[0] else { continue }
                var band = 0
                while band + 1 < thresholds.count, value >= thresholds[band + 1] { band += 1 }
                bands[row * side + column] = Int8(band)
            }
        }

        var out = [UInt8](repeating: 0, count: side * side)
        let density = TerrainStyle.ditherDensity
        for row in 0..<side {
            for column in 0..<side {
                let at = row * side + column
                let band = bands[at]
                if band >= 0, TerrainStyle.bayer[(row / dot) % 8 * 8 + (column / dot) % 8] < density[Int(band)] * 64 {
                    out[at] = 255
                }
                // A line where this crosses the outline or an index contour.
                let right = column + 1 < side ? bands[at + 1] : -1
                let below = row + 1 < side ? bands[at + side] : -1
                if crossesLine(band, right) || crossesLine(band, below) { out[at] = 255 }
            }
        }
        return out
    }

    private static func crossesLine(_ a: Int8, _ b: Int8) -> Bool {
        guard a != b else { return false }
        for level in (min(a, b) + 1)...max(a, b) where level == 0 || TerrainStyle.isIndexContour(Int(level)) {
            return true
        }
        return false
    }

    private static func sample(_ field: DensityField, _ cx: Double, _ cy: Double) -> Float {
        let x0 = min(max(Int(cx), 0), field.width - 2), y0 = min(max(Int(cy), 0), field.height - 2)
        let tx = Float(cx - Double(x0)), ty = Float(cy - Double(y0))
        let top = field.elevation[y0 * field.width + x0] * (1 - tx) + field.elevation[y0 * field.width + x0 + 1] * tx
        let bottom = field.elevation[(y0 + 1) * field.width + x0] * (1 - tx) + field.elevation[(y0 + 1) * field.width + x0 + 1] * tx
        return top * (1 - ty) + bottom * ty
    }

    /// The mask as an image SwiftUI can tint with the theme's ink.
    public static func image(mask: [UInt8], side: Int) -> CGImage? {
        guard mask.count == side * side, let provider = CGDataProvider(data: Data(mask) as CFData) else { return nil }
        return CGImage(maskWidth: side, height: side, bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: side,
                       provider: provider, decode: [1, 0], shouldInterpolate: false)
    }
}
