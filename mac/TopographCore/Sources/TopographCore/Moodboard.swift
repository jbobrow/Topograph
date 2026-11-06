import CoreGraphics
import CoreText
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// A region's pictures as one sheet, in color, to take elsewhere. The file goes only
/// where you save it.
public enum Moodboard {
    /// The most resonant pictures in a region.
    public static func picks(region: Int, map: LibraryMap, count: Int = 24) -> [Int32] {
        Array(map.regions.members(of: region)
            .filter { map.items[Int($0)].thumb != nil }
            .sorted {
                let a = map.items[Int($0)], b = map.items[Int($1)]
                return a.resonance != b.resonance ? a.resonance > b.resonance : $0 < $1
            }
            .prefix(count))
    }

    /// `title` above a grid of `files`, cropped to squares, as PNG data.
    public static func render(title: String, files: [URL], columns: Int = 6, cell: Int = 400, gap: Int = 16, margin: Int = 64) -> Data? {
        let rows = max(1, Int((Double(files.count) / Double(columns)).rounded(.up)))
        let header = 120
        let width = margin * 2 + columns * cell + (columns - 1) * gap
        let height = margin * 2 + header + rows * cell + (rows - 1) * gap
        guard let c = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        c.setFillColor(CGColor(srgbRed: 0.914, green: 0.914, blue: 0.902, alpha: 1))
        c.fill(CGRect(x: 0, y: 0, width: width, height: height))

        let font = CTFontCreateWithName("IBMPlexMono-SemiBold" as CFString, 40, nil)
        let ink = CGColor(srgbRed: 0.067, green: 0.067, blue: 0.067, alpha: 1)
        let attributes: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): ink,
        ]
        c.textPosition = CGPoint(x: margin, y: height - margin - 44)
        CTLineDraw(CTLineCreateWithAttributedString(NSAttributedString(string: title, attributes: attributes)), c)

        for (position, url) in files.enumerated() {
            let column = position % columns, row = position / columns
            let rect = CGRect(x: margin + column * (cell + gap),
                              y: height - margin - header - (row + 1) * cell - row * gap,
                              width: cell, height: cell)
            guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                  let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                      kCGImageSourceCreateThumbnailFromImageAlways: true,
                      kCGImageSourceThumbnailMaxPixelSize: cell * 2,
                      kCGImageSourceCreateThumbnailWithTransform: true,
                  ] as CFDictionary) else {
                c.setFillColor(CGColor(srgbRed: 0.957, green: 0.957, blue: 0.945, alpha: 1))
                c.fill(rect)
                continue
            }
            // Crop to a square from the middle.
            let side = min(image.width, image.height)
            let crop = CGRect(x: (image.width - side) / 2, y: (image.height - side) / 2, width: side, height: side)
            if let square = image.cropping(to: crop) { c.draw(square, in: rect) }
        }
        guard let image = c.makeImage() else { return nil }
        let data = NSMutableData()
        guard let out = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(out, image, nil)
        return CGImageDestinationFinalize(out) ? data as Data : nil
    }
}
