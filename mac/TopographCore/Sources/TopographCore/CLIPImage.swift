import CoreGraphics
import Foundation
import ImageIO

/// A picture to the numbers CLIP reads, the way OpenCLIP prepares it: shortest edge to 224
/// with Pillow's bicubic, a center crop, then the model's mean and spread for each color.
public enum CLIPImage {
    public static let size = 224
    private static let mean: [Float] = [0.48145466, 0.4578275, 0.40821073]
    private static let spread: [Float] = [0.26862954, 0.26130258, 0.27577711]

    /// Red, green and blue planes, 3 × 224 × 224.
    public static func pixels(rgb: [UInt8], width: Int, height: Int) -> [Float] {
        // Same rounding as torchvision: truncate the long edge, round the crop (half to even).
        let (newWidth, newHeight) = width <= height
            ? (size, size * height / width)
            : (size * width / height, size)
        let resized = Resampler.resize(rgb, width: width, height: height, toWidth: newWidth, toHeight: newHeight)
        let left = Int((Double(newWidth - size) / 2).rounded(.toNearestOrEven))
        let top = Int((Double(newHeight - size) / 2).rounded(.toNearestOrEven))
        var out = [Float](repeating: 0, count: 3 * size * size)
        for y in 0..<size {
            for x in 0..<size {
                let source = ((y + top) * newWidth + x + left) * 3
                for channel in 0..<3 {
                    let value = Float(resized[source + channel]) / 255
                    out[(channel * size + y) * size + x] = (value - mean[channel]) / spread[channel]
                }
            }
        }
        return out
    }

    /// Eight-bit red, green, blue with no color conversion, ignoring any alpha like
    /// Pillow's `convert("RGB")`. Library pictures carry no color profile.
    public static func decode(_ url: URL) -> (rgb: [UInt8], width: Int, height: Int)? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCache: false] as CFDictionary) else { return nil }
        let (width, height) = (image.width, image.height)
        guard width > 0, height > 0, let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        var rgba = [UInt8](repeating: 0, count: width * height * 4)
        let drawn: Void? = rgba.withUnsafeMutableBytes { bytes in
            guard let context = CGContext(data: bytes.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                          space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
            context.setBlendMode(.copy)
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return ()
        }
        guard drawn != nil else { return nil }
        var rgb = [UInt8](repeating: 0, count: width * height * 3)
        for pixel in 0..<(width * height) {
            let alpha = Int(rgba[pixel * 4 + 3])
            for channel in 0..<3 {
                let value = Int(rgba[pixel * 4 + channel])
                // Undo what drawing did to partly transparent pixels.
                rgb[pixel * 3 + channel] = alpha == 255 || alpha == 0 ? UInt8(value) : UInt8(min(255, (value * 255 + alpha / 2) / alpha))
            }
        }
        return (rgb, width, height)
    }
}

/// Pillow's resampling for 8-bit pictures, fixed-point rounding included, so a Swift vector
/// and a Python vector start from the same numbers.
enum Resampler {
    enum Filter {
        case bicubic, lanczos

        var support: Double { self == .bicubic ? 2 : 3 }

        func weight(_ distance: Double) -> Double {
            switch self {
            case .bicubic: Resampler.bicubic(distance)
            case .lanczos: Resampler.lanczos(distance)
            }
        }
    }

    private static let precisionBits = 32 - 8 - 2

    private struct Kernel {
        var starts: [Int] = []
        var counts: [Int] = []
        var weights: [Int32] = []
        var stride = 0
    }

    private static func bicubic(_ distance: Double) -> Double {
        let a = -0.5
        let x = abs(distance)
        if x < 1 { return ((a + 2) * x - (a + 3)) * x * x + 1 }
        if x < 2 { return (((x - 5) * x + 8) * x - 4) * a }
        return 0
    }

    private static func sinc(_ x: Double) -> Double {
        x == 0 ? 1 : sin(x * .pi) / (x * .pi)
    }

    private static func lanczos(_ x: Double) -> Double {
        abs(x) < 3 ? sinc(x) * sinc(x / 3) : 0
    }

    private static func kernel(from inSize: Int, to outSize: Int, filter: Filter) -> Kernel {
        let scale = Double(inSize) / Double(outSize)
        let filterScale = max(scale, 1)
        let support = filter.support * filterScale
        let stride = Int(support.rounded(.up)) * 2 + 1
        var kernel = Kernel(stride: stride)
        kernel.starts.reserveCapacity(outSize)
        kernel.counts.reserveCapacity(outSize)
        kernel.weights = [Int32](repeating: 0, count: outSize * stride)
        var weights = [Double](repeating: 0, count: stride)
        for out in 0..<outSize {
            let center = (Double(out) + 0.5) * scale
            let low = max(Int(center - support + 0.5), 0)
            let count = min(Int(center + support + 0.5), inSize) - low
            var total = 0.0
            for index in 0..<count {
                weights[index] = filter.weight((Double(index + low) - center + 0.5) / filterScale)
                total += weights[index]
            }
            for index in 0..<count {
                let weight = total != 0 ? weights[index] / total : weights[index]
                let scaled = weight * Double(1 << precisionBits)
                kernel.weights[out * stride + index] = Int32(scaled < 0 ? scaled - 0.5 : scaled + 0.5)
            }
            kernel.starts.append(low)
            kernel.counts.append(count)
        }
        return kernel
    }

    @inline(__always)
    private static func clip(_ value: Int32) -> UInt8 {
        UInt8(clamping: value >> Int32(precisionBits))
    }

    static func resize(_ rgb: [UInt8], width: Int, height: Int, toWidth: Int, toHeight: Int, filter: Filter = .bicubic) -> [UInt8] {
        if width == toWidth, height == toHeight { return rgb }
        let across = kernel(from: width, to: toWidth, filter: filter)
        let down = kernel(from: height, to: toHeight, filter: filter)
        let half = Int32(1) << Int32(precisionBits - 1)

        // Across first, only for the rows that the second pass reads.
        let firstRow = down.starts[0]
        let lastRow = down.starts[toHeight - 1] + down.counts[toHeight - 1]
        let rows = lastRow - firstRow
        var middle = [UInt8](repeating: 0, count: rows * toWidth * 3)
        rgb.withUnsafeBufferPointer { source in
            across.weights.withUnsafeBufferPointer { weights in
                middle.withUnsafeMutableBufferPointer { out in
                    for row in 0..<rows {
                        let line = (row + firstRow) * width * 3
                        for x in 0..<toWidth {
                            let start = across.starts[x]
                            let offset = x * across.stride
                            for channel in 0..<3 {
                                var sum = half
                                for index in 0..<across.counts[x] {
                                    sum &+= Int32(source[line + (start + index) * 3 + channel]) &* weights[offset + index]
                                }
                                out[(row * toWidth + x) * 3 + channel] = clip(sum)
                            }
                        }
                    }
                }
            }
        }

        var result = [UInt8](repeating: 0, count: toHeight * toWidth * 3)
        let lineBytes = toWidth * 3
        middle.withUnsafeBufferPointer { source in
            down.weights.withUnsafeBufferPointer { weights in
                result.withUnsafeMutableBufferPointer { out in
                    for y in 0..<toHeight {
                        let start = down.starts[y] - firstRow
                        let offset = y * down.stride
                        for byte in 0..<lineBytes {
                            var sum = half
                            for index in 0..<down.counts[y] {
                                sum &+= Int32(source[(start + index) * lineBytes + byte]) &* weights[offset + index]
                            }
                            out[y * lineBytes + byte] = clip(sum)
                        }
                    }
                }
            }
        }
        return result
    }
}
