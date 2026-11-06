import CoreGraphics
import Foundation
import ImageIO
@preconcurrency import Metal
import TopographCore

/// Decodes thumbnails off the main thread into textures, at the size they're drawn,
/// and keeps a bounded number of them. Until a sharper copy is ready, any smaller one
/// stands in.
@MainActor
final class ThumbnailStore {
    private struct Key: Hashable {
        let item: Int32
        let tier: Int
        let dither: Bool
    }

    private struct Request {
        let key: Key
        let url: URL
    }

    private static let tiers = [96, 192, 320]
    /// Bytes of textures to keep. A second store for another view gets a smaller share.
    private let budget: Int
    private static let parallel = max(ProcessInfo.processInfo.activeProcessorCount - 2, 2)

    private let device: MTLDevice
    private let queue: MTLCommandQueue
    private let root: URL
    private var textures: [Key: MTLTexture] = [:]
    private var lastUsed: [Key: UInt64] = [:]
    private var clock: UInt64 = 0
    private var bytes = 0
    private var working: Set<Key> = []
    private var failed: Set<Key> = []
    /// What the latest frame wanted, most wanted last.
    private var wanted: [Request] = []
    /// Called when a new picture is ready to draw.
    var onReady: (() -> Void)?

    init(device: MTLDevice, queue: MTLCommandQueue, root: URL, budget: Int = 768 * 1024 * 1024) {
        self.budget = budget
        self.device = device
        self.queue = queue
        self.root = root
    }

    /// Call before a frame asks for textures: only what this frame needs gets queued.
    func beginFrame() {
        wanted.removeAll(keepingCapacity: true)
        clock += 1
    }

    /// Call after: starts decoding the most wanted.
    func endFrame() {
        pump()
    }

    func texture(item: Int32, path: String, pixels: Double, dither: Bool) -> MTLTexture? {
        let tier = Self.tiers.first { Double($0) >= pixels } ?? Self.tiers.last!
        let key = Key(item: item, tier: tier, dither: dither)
        if let texture = textures[key] {
            lastUsed[key] = clock
            return texture
        }
        if !working.contains(key) && !failed.contains(key) {
            wanted.append(Request(key: key, url: root.appending(path: path)))
        }
        for other in Self.tiers where other != tier {
            let stand = Key(item: item, tier: other, dither: dither)
            if let texture = textures[stand] {
                lastUsed[stand] = clock
                return texture
            }
        }
        return nil
    }

    private func pump() {
        while working.count < Self.parallel, let next = wanted.popLast() {
            guard !working.contains(next.key) else { continue }
            working.insert(next.key)
            let (device, queue) = (self.device, self.queue)
            Task.detached(priority: .userInitiated) { [weak self] in
                let texture = Self.decode(next.url, tier: next.key.tier, dither: next.key.dither, device: device, queue: queue)
                await self?.finish(next.key, texture)
            }
        }
    }

    private func finish(_ key: Key, _ texture: MTLTexture?) {
        working.remove(key)
        guard let texture else {
            failed.insert(key)
            pump()
            return
        }
        textures[key] = texture
        lastUsed[key] = clock
        bytes += Self.cost(texture)
        evict()
        onReady?()
    }

    private func evict() {
        guard bytes > budget else { return }
        // Oldest first, never what the current frame is using.
        for key in lastUsed.sorted(by: { $0.value < $1.value }).map(\.key) where bytes > budget * 9 / 10 {
            guard lastUsed[key] != clock, let texture = textures.removeValue(forKey: key) else { continue }
            lastUsed[key] = nil
            bytes -= Self.cost(texture)
        }
    }

    private static func cost(_ texture: MTLTexture) -> Int {
        texture.width * texture.height * 4 * (texture.mipmapLevelCount > 1 ? 4 : 3) / 3
    }

    private nonisolated static func decode(_ url: URL, tier: Int, dither: Bool, device: MTLDevice, queue: MTLCommandQueue) -> MTLTexture? {
        guard let image = PictureFile.image(at: url, longEdge: tier) else { return nil }
        let (width, height) = (image.width, image.height)
        guard var pixels = PictureFile.rgba(image) else { return nil }
        if dither { Atkinson.apply(&pixels, width: width, height: height) }

        // 1-bit dots should stay exact, so they get no mipmaps.
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba8Unorm, width: width, height: height, mipmapped: !dither)
        descriptor.usage = .shaderRead
        guard let texture = device.makeTexture(descriptor: descriptor) else { return nil }
        pixels.withUnsafeBytes {
            texture.replace(region: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0,
                            withBytes: $0.baseAddress!, bytesPerRow: width * 4)
        }
        if !dither, let commands = queue.makeCommandBuffer(), let blit = commands.makeBlitCommandEncoder() {
            blit.generateMipmaps(for: texture)
            blit.endEncoding()
            commands.commit()
        }
        return texture
    }
}

/// Reading pictures from the library.
enum PictureFile {
    /// Decoded no larger than `longEdge` pixels.
    static func image(at url: URL, longEdge: Int) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: longEdge,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }

    /// sRGB, 8 bits a channel, opaque on white.
    static func rgba(_ image: CGImage) -> [UInt8]? {
        var pixels = [UInt8](repeating: 255, count: image.width * image.height * 4)
        let made = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(data: buffer.baseAddress, width: image.width, height: image.height, bitsPerComponent: 8,
                                          bytesPerRow: image.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
            return true
        }
        return made ? pixels : nil
    }
}

/// 1-bit with Atkinson dithering, as in viewer/app.js. Pixels come out pure black or white.
enum Atkinson {
    static func apply(_ pixels: inout [UInt8], width: Int, height: Int) {
        var luminance = [Float](repeating: 0, count: width * height)
        for i in 0..<(width * height) {
            luminance[i] = 0.2126 * Float(pixels[i * 4]) + 0.7152 * Float(pixels[i * 4 + 1]) + 0.0722 * Float(pixels[i * 4 + 2])
        }
        let spread = [(1, 0), (2, 0), (-1, 1), (0, 1), (1, 1), (0, 2)]
        for y in 0..<height {
            for x in 0..<width {
                let i = y * width + x
                let old = luminance[i], value: Float = old < 128 ? 0 : 255
                let error = (old - value) / 8
                luminance[i] = value
                for (dx, dy) in spread {
                    let nx = x + dx, ny = y + dy
                    if nx >= 0, nx < width, ny < height { luminance[ny * width + nx] += error }
                }
                pixels[i * 4] = UInt8(value)
                pixels[i * 4 + 1] = UInt8(value)
                pixels[i * 4 + 2] = UInt8(value)
            }
        }
    }
}
