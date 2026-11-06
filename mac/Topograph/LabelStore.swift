import AppKit
import CoreText
@preconcurrency import Metal
import TopographCore

/// Draws region names into small bitmaps, once each, and measures text for placing them.
/// Boxed mono labels with a crosshair at the anchor; top-level names are inverted.
@MainActor
final class LabelStore {
    private struct Key: Hashable {
        let id: Int
        let count: Int
        let dark: Bool
        let scale: Int
    }

    private let device: MTLDevice
    private var textures: [Key: MTLTexture] = [:]
    private var widths: [String: Double] = [:]

    init(device: MTLDevice) {
        self.device = device
    }

    private func font(size: Double, weight: Int) -> CTFont {
        let name = weight >= 600 ? "IBMPlexMono-SemiBold" : weight >= 500 ? "IBMPlexMono-Medium" : "IBMPlexMono-Regular"
        return CTFontCreateWithName(name as CFString, size, nil)
    }

    private func line(_ text: String, font: CTFont, color: CGColor) -> CTLine {
        let attributes: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): color,
        ]
        return CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attributes))
    }

    /// Width in points: names at 12 and 11, counts at 10.
    func width(_ text: String, size: Double) -> Double {
        let key = "\(size)|\(text)"
        if let known = widths[key] { return known }
        let weight = size >= 12 ? 600 : size >= 11 ? 500 : 400
        let measured = CTLineGetTypographicBounds(line(text, font: font(size: size, weight: weight), color: .black), nil, nil, nil)
        widths[key] = measured
        return measured
    }

    func texture(label: PlacedLabel, name: String, theme: Theme, dark: Bool, scale: Double) -> MTLTexture? {
        let key = Key(id: label.id, count: label.count, dark: dark, scale: Int(scale))
        if let known = textures[key] { return known }
        guard let texture = draw(label: label, name: name, theme: theme, scale: scale) else { return nil }
        textures[key] = texture
        return texture
    }

    private func draw(label: PlacedLabel, name: String, theme: Theme, scale: Double) -> MTLTexture? {
        let width = Int((label.box.width * scale).rounded(.up)), height = Int((label.box.height * scale).rounded(.up))
        guard width > 0, height > 0 else { return nil }
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let c = CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                    space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            c.scaleBy(x: scale, y: scale)
            let w = label.box.width, h = label.box.height
            let ink = theme.ink.cg, surface = theme.surface.cg

            let rect = CGRect(x: 10, y: 0, width: w - 10, height: h)
            c.setFillColor(label.top ? ink : surface)
            c.fill(rect)
            c.setStrokeColor(ink)
            c.setLineWidth(1)
            c.stroke(rect.insetBy(dx: 0.5, dy: 0.5))
            c.move(to: CGPoint(x: 1, y: h / 2))
            c.addLine(to: CGPoint(x: 9, y: h / 2))
            c.move(to: CGPoint(x: 5, y: h / 2 - 4))
            c.addLine(to: CGPoint(x: 5, y: h / 2 + 4))
            c.strokePath()

            let nameLine = line(name, font: font(size: label.fontSize, weight: label.top ? 600 : 500), color: label.top ? surface : ink)
            let countLine = line(label.count.formatted(), font: font(size: 10, weight: 400), color: label.top ? surface : theme.secondary.cg)
            let nameWidth = CTLineGetTypographicBounds(nameLine, nil, nil, nil)
            let baseline = h / 2 - label.fontSize * 0.33
            c.textPosition = CGPoint(x: 13, y: baseline)
            CTLineDraw(nameLine, c)
            c.textPosition = CGPoint(x: 13 + nameWidth + 6, y: baseline)
            CTLineDraw(countLine, c)
            return true
        }
        guard drawn else { return nil }
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: width, height: height, mipmapped: false)
        descriptor.usage = .shaderRead
        let texture = device.makeTexture(descriptor: descriptor)
        pixels.withUnsafeBytes {
            texture?.replace(region: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0,
                             withBytes: $0.baseAddress!, bytesPerRow: width * 4)
        }
        return texture
    }
}
