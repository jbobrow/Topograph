// Draws the app icon: white contour lines on black. It writes two forms:
//
// - AppIcon.icon, Apple's layered format, for macOS 26 and later. It's just the lines,
//   full bleed; icon.json sets the black fill and macOS applies the shape. A classic icon
//   gets boxed inside a gray plate on these systems.
// - AppIcon.appiconset for earlier systems. Each size is drawn on its own, with fewer and
//   relatively heavier lines as it gets smaller, so it still reads at 16px.
//
//   swiftc -O mac/tools/make_icon.swift -o /tmp/make_icon && /tmp/make_icon mac/Topograph

import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Depth below the summits, in a square from -1 to 1, y down. It grows at a steady rate
/// with distance from them, which is what keeps the contours evenly spaced. The ridge
/// between the two summits is a smooth blend, and a slow wobble keeps it from looking drawn.
func depth(_ mapX: Double, _ y: Double) -> Double {
    let x = mapX + 0.04     // far enough left that no line runs along the right edge
    func distance(_ cx: Double, _ cy: Double, _ sx: Double, _ sy: Double, _ angle: Double) -> Double {
        let dx = x - cx, dy = y - cy
        let u = (dx * cos(angle) + dy * sin(angle)) / sx, v = (-dx * sin(angle) + dy * cos(angle)) / sy
        return (u * u + v * v + 0.0004).squareRoot()
    }
    let blend = 0.2
    let summits = -blend * log(exp(-distance(-0.24, 0.2, 1.25, 0.85, -0.55) / blend)
                               + exp(-(distance(0.36, -0.3, 1, 0.8, 0.5) + 0.03) / blend))
    return summits + 0.035 * sin(2.6 * x + 1.1 * y + 0.7) + 0.03 * sin(3.1 * y - 1.4 * x + 2.1)
}

/// Above 0 inside Apple's icon shape, in pixels from the edge: a rounded square.
func inside(_ x: Double, _ y: Double, half: Double) -> Double {
    let radius = 185.4 / 412
    let qx = abs(x) - 1 + radius, qy = abs(y) - 1 + radius
    let outside = (max(qx, 0) * max(qx, 0) + max(qy, 0) * max(qy, 0)).squareRoot() + min(max(qx, qy), 0)
    return (radius - outside) * half
}

/// With `layer`, only the lines on transparent, filling the canvas. Otherwise the whole
/// classic icon: black, rounded, inside Apple's grid of 824 of 1024.
func render(size: Int, spacing: Double, line: Double, layer: Bool = false) -> CGImage {
    let canvas = Double(size)
    let half = layer ? canvas / 2 : canvas * 412 / 1024
    var pixels = [UInt8](repeating: 0, count: size * size * 4)
    let ground = 0.067                  // the design language's ink, #111
    let step = 1.0 / half

    for row in 0..<size {
        for col in 0..<size {
            let x = (Double(col) + 0.5 - canvas / 2) / half
            let y = (Double(row) + 0.5 - canvas / 2) / half
            let alpha = layer ? 1 : min(max(inside(x, y, half: half) + 0.5, 0), 1)
            guard alpha > 0 else { continue }

            let f = depth(x, y)
            let gx = (depth(x + step, y) - depth(x - step, y)) / 2
            let gy = (depth(x, y + step) - depth(x, y - step)) / 2
            let slope = max((gx * gx + gy * gy).squareRoot(), 1e-6)
            // The nearest contour, leaving the summits themselves open.
            let nearest = max((f / spacing).rounded(), 1) * spacing
            let ink = min(max(line / 2 + 0.5 - abs(f - nearest) / slope, 0), 1)
            let value = layer ? ink : (ground + (1 - ground) * ink) * alpha   // premultiplied
            let i = (row * size + col) * 4
            pixels[i] = UInt8(value * 255 + 0.5)
            pixels[i + 1] = pixels[i]
            pixels[i + 2] = pixels[i]
            pixels[i + 3] = UInt8((layer ? ink : alpha) * 255 + 0.5)
        }
    }
    let context = CGContext(data: &pixels, width: size, height: size, bitsPerComponent: 8, bytesPerRow: size * 4,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    return context.makeImage()!
}

func write(_ image: CGImage, to url: URL) {
    let out = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(out, image, nil)
    CGImageDestinationFinalize(out)
}

let folder = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
write(render(size: 1024, spacing: 0.21, line: 16, layer: true),
      to: folder.appending(path: "AppIcon.icon/Assets/contours.png"))
// Pixels, the depth between contours, and how wide they are in pixels.
let sizes: [(Int, Double, Double)] = [
    (16, 0.5, 1.1), (32, 0.36, 1.4), (64, 0.3, 2), (128, 0.22, 2.6),
    (256, 0.21, 4), (512, 0.21, 6.5), (1024, 0.21, 12.5),
]
for (size, spacing, line) in sizes {
    write(render(size: size, spacing: spacing, line: line),
          to: folder.appending(path: "Assets.xcassets/AppIcon.appiconset/icon_\(size).png"))
}
