import Accelerate
import AVFoundation
import CoreGraphics
import CWebP
import Foundation
import ImageIO
import QuickLookThumbnailing

/// What ingesting a picture produced, ready to be written to its `media` row.
public enum PreparedMedia: Sendable {
    case failed
    case ready(ReadyMedia)
}

public struct ReadyMedia: Sendable {
    public let contentHash: String
    public let displayPath: String
    public let thumbPath: String
    public let width: Int
    public let height: Int
    public let phash: String
    public let palette: String
    public let kind: String
}

/// Turns a video into one picture to stand for it.
public struct VideoPosters: Sendable {
    public var poster: @Sendable (URL) -> Data?

    public init(poster: @escaping @Sendable (URL) -> Data?) { self.poster = poster }

    public static let standard = VideoPosters { MediaIngest.videoFrame($0) }
}

/// The local media cache: a display copy and a thumbnail per picture, stored by content hash
/// so the same picture saved three times is stored once. See media.py.
public enum MediaIngest {
    public static let displayEdge = 1600
    public static let thumbEdge = 320
    private static let maxPixels = 200_000_000
    private static let videoSuffixes: Set<String> = [".mp4", ".mov", ".m4v", ".webm"]
    private static let previewTimeout: TimeInterval = 20

    public static func prepare(_ data: Data, kind: String, name: String?, isPoster: Bool = false, library: LibraryWriter, video: VideoPosters = .standard) -> PreparedMedia {
        var data = data
        var kind = kind
        if isPoster {
            kind = "video"
        } else if kind == "video" || name.map({ videoSuffixes.contains(PipelineText.suffix($0)) }) == true {
            let suffix = name.map(PipelineText.suffix).flatMap { $0.isEmpty ? nil : $0 } ?? ".mp4"
            let file = FileManager.default.temporaryDirectory.appending(path: "topograph-\(UUID().uuidString)\(suffix)")
            defer { try? FileManager.default.removeItem(at: file) }
            guard (try? data.write(to: file)) != nil, let poster = video.poster(file) else { return .failed }
            data = poster
            kind = "video"
        }

        let digest = PipelineText.sha256(data)
        let shard = library.mediaFolder.appending(path: String(digest.prefix(2)), directoryHint: .isDirectory)
        let display = shard.appending(path: "\(digest)-d.webp"), thumb = shard.appending(path: "\(digest)-t.webp")
        guard let image = decode(data) else { return .failed }

        let large = fitted(image, edge: displayEdge)
        let small = fitted(large, edge: thumbEdge)
        let manager = FileManager.default
        if !manager.fileExists(atPath: display.path) || !manager.fileExists(atPath: thumb.path) {
            guard (try? manager.createDirectory(at: shard, withIntermediateDirectories: true)) != nil,
                  let largeBytes = webp(large, quality: 82), let smallBytes = webp(small, quality: 76),
                  (try? largeBytes.write(to: display, options: .atomic)) != nil,
                  (try? smallBytes.write(to: thumb, options: .atomic)) != nil else { return .failed }
        }
        return .ready(ReadyMedia(contentHash: digest, displayPath: "media/\(digest.prefix(2))/\(digest)-d.webp",
                                 thumbPath: "media/\(digest.prefix(2))/\(digest)-t.webp", width: image.width, height: image.height,
                                 phash: perceptualHash(small), palette: palette(small), kind: kind))
    }

    public struct Picture: Sendable {
        var rgb: [UInt8]
        var width: Int
        var height: Int
    }

    /// Upright, in sRGB, with anything see-through placed on white.
    public static func decode(_ data: Data) -> Picture? {
        guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              CGImageSourceGetCount(source) > 0,
              let image = CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCache: false] as CFDictionary),
              image.width > 0, image.height > 0, image.width * image.height <= maxPixels,
              let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        let orientation = (properties?[kCGImagePropertyOrientation] as? NSNumber)?.intValue ?? 1
        let sideways = orientation >= 5 && orientation <= 8
        let width = sideways ? image.height : image.width, height = sideways ? image.width : image.height
        var rgba = [UInt8](repeating: 255, count: width * height * 4)
        let drawn: Bool = rgba.withUnsafeMutableBytes { bytes in
            guard let context = CGContext(data: bytes.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                          space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
            context.interpolationQuality = .none
            let w = CGFloat(width), h = CGFloat(height)
            switch orientation {
            case 2: context.concatenate(CGAffineTransform(a: -1, b: 0, c: 0, d: 1, tx: w, ty: 0))
            case 3: context.concatenate(CGAffineTransform(a: -1, b: 0, c: 0, d: -1, tx: w, ty: h))
            case 4: context.concatenate(CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: h))
            case 5: context.concatenate(CGAffineTransform(a: 0, b: -1, c: -1, d: 0, tx: w, ty: h))
            case 6: context.concatenate(CGAffineTransform(a: 0, b: -1, c: 1, d: 0, tx: 0, ty: h))
            case 7: context.concatenate(CGAffineTransform(a: 0, b: 1, c: 1, d: 0, tx: 0, ty: 0))
            case 8: context.concatenate(CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: w, ty: 0))
            default: break
            }
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
            return true
        }
        guard drawn else { return nil }
        var rgb = [UInt8](repeating: 0, count: width * height * 3)
        rgba.withUnsafeBufferPointer { source in
            rgb.withUnsafeMutableBufferPointer { out in
                for pixel in 0..<(width * height) {
                    out[pixel * 3] = source[pixel * 4]
                    out[pixel * 3 + 1] = source[pixel * 4 + 1]
                    out[pixel * 3 + 2] = source[pixel * 4 + 2]
                }
            }
        }
        return Picture(rgb: rgb, width: width, height: height)
    }

    /// The size Pillow's `thumbnail` picks: fits inside the square, never larger than it was.
    static func fittedSize(width: Int, height: Int, edge: Int) -> (width: Int, height: Int) {
        if edge >= width, edge >= height { return (width, height) }
        let aspect = Double(width) / Double(height)
        func rounded(_ number: Double, closeness: (Int) -> Double) -> Int {
            let low = Int(number.rounded(.down)), high = Int(number.rounded(.up))
            return max(closeness(low) <= closeness(high) ? low : high, 1)
        }
        let side = Double(edge)
        if aspect <= 1 {
            return (rounded(side * aspect) { abs(aspect - Double($0) / side) }, edge)
        }
        return (edge, rounded(side / aspect) { $0 == 0 ? 0 : abs(aspect - side / Double($0)) })
    }

    static func fitted(_ image: Picture, edge: Int, filter: Resampler.Filter = .lanczos) -> Picture {
        let size = fittedSize(width: image.width, height: image.height, edge: edge)
        if size == (image.width, image.height) { return image }
        return Picture(rgb: Resampler.resize(image.rgb, width: image.width, height: image.height, toWidth: size.width, toHeight: size.height, filter: filter),
                       width: size.width, height: size.height)
    }

    static func webp(_ image: Picture, quality: Float) -> Data? {
        var output: UnsafeMutablePointer<UInt8>?
        let size = image.rgb.withUnsafeBufferPointer {
            WebPEncodeRGB($0.baseAddress, Int32(image.width), Int32(image.height), Int32(image.width * 3), quality, &output)
        }
        defer { if let output { WebPFree(output) } }
        guard size > 0, let output else { return nil }
        return Data(bytes: output, count: size)
    }

    /// `imagehash.phash`: the sign of the low frequencies of a 32 × 32 gray copy, as hex.
    public static func perceptualHash(_ image: Picture) -> String {
        let count = image.width * image.height
        var gray = [UInt8](repeating: 0, count: count * 3)
        for pixel in 0..<count {
            // Pillow's `convert("L")`.
            let luma = (Int(image.rgb[pixel * 3]) * 19595 + Int(image.rgb[pixel * 3 + 1]) * 38470 + Int(image.rgb[pixel * 3 + 2]) * 7471 + 0x8000) >> 16
            gray[pixel * 3] = UInt8(clamping: luma)
            gray[pixel * 3 + 1] = gray[pixel * 3]
            gray[pixel * 3 + 2] = gray[pixel * 3]
        }
        let side = 32, low = 8
        let small = Resampler.resize(gray, width: image.width, height: image.height, toWidth: side, toHeight: side, filter: .lanczos)
        var cosines = [Double](repeating: 0, count: side * low)
        for k in 0..<low {
            for n in 0..<side { cosines[k * side + n] = cos(.pi * Double(k) * Double(2 * n + 1) / Double(2 * side)) }
        }
        // Down the columns, then across the rows, keeping only the frequencies that are used.
        var columns = [Double](repeating: 0, count: low * side)
        for k in 0..<low {
            for x in 0..<side {
                var sum = 0.0
                for y in 0..<side { sum += Double(small[(y * side + x) * 3]) * cosines[k * side + y] }
                columns[k * side + x] = 2 * sum
            }
        }
        var frequencies = [Double](repeating: 0, count: low * low)
        for y in 0..<low {
            for k in 0..<low {
                var sum = 0.0
                for x in 0..<side { sum += columns[y * side + x] * cosines[k * side + x] }
                frequencies[y * low + k] = 2 * sum
            }
        }
        let ordered = frequencies.sorted()
        let median = (ordered[low * low / 2 - 1] + ordered[low * low / 2]) / 2
        var bits: UInt64 = 0
        for value in frequencies { bits = bits << 1 | (value > median ? 1 : 0) }
        return String(format: "%016llx", bits)
    }

    /// Dominant colors as JSON, `[[hex, weight], ...]`, heaviest first: Pillow's median cut.
    public static func palette(_ image: Picture, colors: Int = 5) -> String {
        let small = fitted(image, edge: 96, filter: .bicubic)
        var counts: [UInt32: Int] = [:]
        for pixel in 0..<(small.width * small.height) {
            let color = UInt32(small.rgb[pixel * 3]) << 16 | UInt32(small.rgb[pixel * 3 + 1]) << 8 | UInt32(small.rgb[pixel * 3 + 2])
            counts[color, default: 0] += 1
        }
        struct Box {
            var entries: [(color: UInt32, count: Int)]
            var total: Int
            var volume: Int
        }
        func channel(_ color: UInt32, _ axis: Int) -> Int { Int(color >> UInt32(16 - axis * 8) & 0xFF) }
        func range(_ entries: [(color: UInt32, count: Int)], _ axis: Int) -> Int {
            var low = 255, high = 0
            for entry in entries {
                let value = channel(entry.color, axis)
                low = min(low, value)
                high = max(high, value)
            }
            return high - low
        }
        func volume(_ entries: [(color: UInt32, count: Int)]) -> Int {
            (range(entries, 0) + 1) * (range(entries, 1) + 1) * (range(entries, 2) + 1)
        }
        let all = counts.map { (color: $0.key, count: $0.value) }.sorted { $0.color < $1.color }
        var boxes = [Box(entries: all, total: small.width * small.height, volume: volume(all))]
        while boxes.count < colors {
            // The box with the most pixels that still holds more than one color, along its
            // widest channel as the eye weighs them.
            guard let index = boxes.indices.filter({ boxes[$0].volume > 1 }).max(by: { boxes[$0].total < boxes[$1].total }) else { break }
            let box = boxes.remove(at: index)
            let reach = [range(box.entries, 0) * 77, range(box.entries, 1) * 150, range(box.entries, 2) * 29]
            var axis = 0
            for candidate in 1..<3 where reach[axis] < reach[candidate] { axis = candidate }
            let sorted = box.entries.sorted { (channel($0.color, axis), $0.color) < (channel($1.color, axis), $1.color) }
            var left = 0, cut = 0
            while cut < sorted.count {
                left += sorted[cut].count
                cut += 1
                if left * 2 > box.total { break }
            }
            // A split never falls between two pixels with the same value on this channel.
            if cut < sorted.count {
                let value = channel(sorted[cut - 1].color, axis)
                while cut < sorted.count, channel(sorted[cut].color, axis) == value {
                    left += sorted[cut].count
                    cut += 1
                }
            }
            if cut == sorted.count {
                // All on one side: take off the last value instead.
                var back = sorted.count - 1
                let value = channel(sorted[back].color, axis)
                while back > 0, channel(sorted[back - 1].color, axis) == value { back -= 1 }
                cut = max(back, 1)
                left = sorted[..<cut].reduce(0) { $0 + $1.count }
            }
            let first = Array(sorted[..<cut]), second = Array(sorted[cut...])
            boxes.append(Box(entries: first, total: left, volume: volume(first)))
            boxes.append(Box(entries: second, total: box.total - left, volume: volume(second)))
        }
        let centers = boxes.map { box -> [Int] in
            var sums = [0, 0, 0]
            for entry in box.entries {
                for axis in 0..<3 { sums[axis] += channel(entry.color, axis) * entry.count }
            }
            return sums.map { Int(Double($0) / Double(max(box.total, 1)) + 0.5) }
        }
        // Each pixel counts for the color it's nearest to, which isn't always its own box's.
        var totals = [Int](repeating: 0, count: boxes.count)
        for (color, count) in all {
            let parts = (0..<3).map { channel(color, $0) }
            var best = Int.max, nearest = 0
            for (index, center) in centers.enumerated() {
                let distance = (0..<3).reduce(0) { $0 + (parts[$1] - center[$1]) * (parts[$1] - center[$1]) }
                if distance < best {
                    best = distance
                    nearest = index
                }
            }
            totals[nearest] += count
        }
        let everything = max(totals.reduce(0, +), 1)
        let order = boxes.indices.filter { totals[$0] > 0 }.sorted { (totals[$0], $0) > (totals[$1], $1) }
        let pairs = order.prefix(colors).map { index -> String in
            let parts = centers[index]
            let hex = String(format: "#%02x%02x%02x", parts[0], parts[1], parts[2])
            let weight = (Double(totals[index]) / Double(everything) * 1000).rounded() / 1000
            return "[\"\(hex)\", \(weight)]"
        }
        return "[" + pairs.joined(separator: ", ") + "]"
    }

    private final class Box<Value>: @unchecked Sendable {
        var value: Value?
    }

    /// A frame a second in, or the first if there's no such frame, as JPEG.
    public static func videoFrame(_ file: URL) -> Data? {
        let asset = AVURLAsset(url: file)
        for seconds in [1.0, 0.0] {
            let generator = AVAssetImageGenerator(asset: asset)
            generator.appliesPreferredTrackTransform = true
            generator.requestedTimeToleranceBefore = .zero
            generator.requestedTimeToleranceAfter = CMTime(seconds: 0.5, preferredTimescale: 600)
            let done = DispatchSemaphore(value: 0)
            let frame = Box<CGImage>()
            generator.generateCGImageAsynchronously(for: CMTime(seconds: seconds, preferredTimescale: 600)) { image, _, _ in
                frame.value = image
                done.signal()
            }
            guard done.wait(timeout: .now() + 60) == .success else {
                generator.cancelAllCGImageGeneration()
                return quickLook(file)
            }
            if let image = frame.value, let data = jpeg(image) { return data }
        }
        return quickLook(file)
    }

    private static func jpeg(_ image: CGImage) -> Data? {
        let out = NSMutableData()
        guard let target = CGImageDestinationCreateWithData(out, "public.jpeg" as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(target, image, [kCGImageDestinationLossyCompressionQuality: 0.9] as CFDictionary)
        return CGImageDestinationFinalize(target) ? out as Data : nil
    }

    private static func png(_ image: CGImage) -> Data? {
        let out = NSMutableData()
        guard let target = CGImageDestinationCreateWithData(out, "public.png" as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(target, image, nil)
        return CGImageDestinationFinalize(target) ? out as Data : nil
    }

    /// Quick Look draws previews of PSD, AI, Sketch, PDF, STL, 3MF and more. A hang or a crash
    /// in one means no preview, never a failed import.
    public static func quickLook(_ file: URL, size: Int = 1600) -> Data? {
        let request = QLThumbnailGenerator.Request(fileAt: file, size: CGSize(width: size, height: size), scale: 1, representationTypes: .thumbnail)
        let done = DispatchSemaphore(value: 0)
        let result = Box<Data>()
        QLThumbnailGenerator.shared.generateBestRepresentation(for: request) { thumbnail, _ in
            if let image = thumbnail?.cgImage { result.value = png(image) }
            done.signal()
        }
        guard done.wait(timeout: .now() + previewTimeout) == .success else {
            QLThumbnailGenerator.shared.cancel(request)
            return nil
        }
        return result.value
    }

    /// A picture to stand for any file: the file itself, a video frame or a Quick Look preview.
    public static func preview(of file: URL) -> (data: Data?, kind: String) {
        let suffix = PipelineText.suffix(file.lastPathComponent)
        if videoSuffixes.contains(suffix) { return (videoFrame(file), "video") }
        if suffix != ".svg", let source = CGImageSourceCreateWithURL(file as CFURL, nil), CGImageSourceGetCount(source) > 0,
           CGImageSourceGetStatus(source) == .statusComplete, let data = try? Data(contentsOf: file) {
            return (data, "image")
        }
        return (quickLook(file), "image")
    }
}
