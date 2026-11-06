import AppKit
import SwiftUI
import TopographCore

/// Regions as geological layers through time, each in its own 1-bit pattern.
struct StrataScreen: View {
    let model: AppModel
    let theme: Theme
    @State private var strata: StrataModel?
    @State private var tip: StrataTip?

    var body: some View {
        ZStack(alignment: .topLeading) {
            if let strata, let map = model.map {
                StrataCanvas(model: strata, map: map, range: model.filter.range, theme: theme,
                             onTip: { tip = $0 },
                             onPick: { model.openRegion($0) })
            }
            if let tip {
                Text(tip.text)
                    .font(PlexMono.font(.regular, size: 11))
                    .foregroundStyle(theme.ink.color)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
                    .background(theme.surface.color)
                    .overlay(RoundedRectangle(cornerRadius: 3).strokeBorder(theme.ink.color, lineWidth: 1))
                    .frame(maxWidth: 260, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .offset(x: tip.x, y: tip.y)
                    .allowsHitTesting(false)
            }
        }
        .background(theme.ground.color)
        .task(id: model.scene?.id) {
            guard let scene = model.scene, let axis = model.axis else { return }
            strata = await Task.detached(priority: .userInitiated) {
                StrataModel(map: scene.map, visible: scene.visible, axis: axis)
            }.value
        }
    }
}

struct StrataTip: Equatable {
    let text: String
    let x: Double
    let y: Double
}

private struct StrataCanvas: NSViewRepresentable {
    let model: StrataModel
    let map: LibraryMap
    let range: ClosedRange<Int>?
    let theme: Theme
    let onTip: (StrataTip?) -> Void
    let onPick: (Int) -> Void

    func makeNSView(context: Context) -> StrataNSView { StrataNSView() }

    func updateNSView(_ view: StrataNSView, context: Context) {
        view.onTip = onTip
        view.onPick = onPick
        view.update(model: model, map: map, range: range, theme: theme)
    }
}

final class StrataNSView: NSView {
    private var model: StrataModel?
    private var map: LibraryMap?
    private var range: ClosedRange<Int>?
    private var theme = Theme.light
    private var patternOf: [Int: Int] = [:]
    private var paths: [CGPath] = []
    private var hovered: Int?
    private var tiles: [CGImage] = []
    private var waitingTile: CGImage?
    private var tilesFor: (theme: RGB, scale: Double)?
    private var tracking: NSTrackingArea?
    private var builtFor: CGSize = .zero

    var onTip: ((StrataTip?) -> Void)?
    var onPick: ((Int) -> Void)?

    private let margin = NSEdgeInsets(top: 24, left: 24, bottom: 28, right: 24)

    override var isFlipped: Bool { true }

    func update(model: StrataModel, map: LibraryMap, range: ClosedRange<Int>?, theme: Theme) {
        self.model = model
        self.map = map
        self.range = range
        self.theme = theme
        patternOf = Dictionary(map.regions.strataLayers().enumerated().map { ($1, $0) }, uniquingKeysWith: { a, _ in a })
        builtFor = .zero
        needsDisplay = true
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        tracking = area
    }

    // MARK: Geometry

    private func x(_ time: Int, axis: MonthAxis) -> Double {
        margin.left + axis.fraction(of: time) * (bounds.width - margin.left - margin.right)
    }

    private func y(_ value: Double, model: StrataModel) -> Double {
        let top = margin.top, bottom = bounds.height - margin.bottom
        let span = max(model.high - model.low, 1e-9)
        return bottom + (value - model.low) / span * (top - bottom)
    }

    private func buildPaths() {
        guard let model, builtFor != bounds.size else { return }
        builtFor = bounds.size
        let axis = model.axis
        paths = model.layers.map { layer in
            let tops = (0..<axis.count).map { CGPoint(x: x(axis.edges[$0], axis: axis), y: y(layer.top[$0], model: model)) }
            let bottoms = (0..<axis.count).reversed().map { CGPoint(x: x(axis.edges[$0], axis: axis), y: y(layer.bottom[$0], model: model)) }
            let path = CGMutablePath()
            BasisCurve.append(tops, to: path, joined: false)
            BasisCurve.append(bottoms, to: path, joined: true)
            path.closeSubpath()
            return path
        }
    }

    // MARK: Patterns

    /// Screens, hatches, rules and checks, from light to dark. In points, y down.
    private static let patterns: [(w: Int, h: Int, rects: [CGRect], lines: [(CGPoint, CGPoint)], stroke: Double)] = [
        (4, 4, [CGRect(x: 0, y: 0, width: 1, height: 1)], [], 0),
        (6, 6, [], [(CGPoint(x: 0, y: 6), CGPoint(x: 6, y: 0))], 1),
        (4, 3, [], [(CGPoint(x: 0, y: 0.5), CGPoint(x: 4, y: 0.5))], 1),
        (3, 3, [CGRect(x: 0, y: 0, width: 1, height: 1)], [], 0),
        (6, 6, [], [(CGPoint(x: 0, y: 6), CGPoint(x: 6, y: 0)), (CGPoint(x: 0, y: 0), CGPoint(x: 6, y: 6))], 0.8),
        (3, 4, [], [(CGPoint(x: 0.5, y: 0), CGPoint(x: 0.5, y: 4))], 1),
        (4, 4, [CGRect(x: 0, y: 0, width: 2, height: 2), CGRect(x: 2, y: 2, width: 2, height: 2)], [], 0),
        (5, 5, [], [(CGPoint(x: 0, y: 0), CGPoint(x: 5, y: 5))], 1),
        (6, 6, [CGRect(x: 1, y: 1, width: 2, height: 2)], [], 0),
        (8, 4, [], [(CGPoint(x: 0, y: 0.5), CGPoint(x: 4, y: 0.5))], 1),
        (2, 2, [CGRect(x: 0, y: 0, width: 1, height: 1), CGRect(x: 1, y: 1, width: 1, height: 1)], [], 0),
        (4, 4, [CGRect(x: 0, y: 0, width: 3, height: 1), CGRect(x: 0, y: 2, width: 1, height: 1)], [], 0),
    ]

    private func tile(w: Int, h: Int, scale: Double, ink: CGColor, draw: (CGContext) -> Void) -> CGImage? {
        let pw = Int(Double(w) * scale), ph = Int(Double(h) * scale)
        guard let c = CGContext(data: nil, width: pw, height: ph, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        c.translateBy(x: 0, y: CGFloat(ph))
        c.scaleBy(x: scale, y: -scale)
        c.setFillColor(theme.ground.cg)
        c.fill(CGRect(x: 0, y: 0, width: w, height: h))
        c.setFillColor(ink)
        c.setStrokeColor(ink)
        draw(c)
        return c.makeImage()
    }

    private func buildTiles(scale: Double) {
        if let done = tilesFor, done.scale == scale, done.theme.red == theme.ink.red { return }
        tilesFor = (theme.ink, scale)
        tiles = Self.patterns.compactMap { pattern in
            tile(w: pattern.w, h: pattern.h, scale: scale, ink: theme.ink.cg) { c in
                c.setShouldAntialias(false)
                c.fill(pattern.rects)
                if !pattern.lines.isEmpty {
                    c.setLineWidth(pattern.stroke)
                    for (a, b) in pattern.lines {
                        c.move(to: a)
                        c.addLine(to: b)
                    }
                    c.strokePath()
                }
            }
        }
        waitingTile = tile(w: 8, h: 8, scale: scale, ink: theme.secondary.cg) { c in
            c.fill(CGRect(x: 0, y: 0, width: 1, height: 1))
        }
    }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        guard let model, let c = NSGraphicsContext.current?.cgContext else { return }
        let scale = window?.backingScaleFactor ?? 2
        buildTiles(scale: scale)
        buildPaths()
        let axis = model.axis
        c.setFillColor(theme.ground.cg)
        c.fill(bounds)

        if let range {
            let left = x(range.lowerBound, axis: axis), right = x(range.upperBound, axis: axis)
            c.setFillColor(theme.ink.cg.copy(alpha: 0.07) ?? theme.ink.cg)
            c.fill(CGRect(x: left, y: margin.top - 8, width: max(1, right - left), height: bounds.height - margin.top - margin.bottom + 8))
        }

        for (index, layer) in model.layers.enumerated() {
            let tile: CGImage? = layer.region.flatMap { patternOf[$0] }.map { tiles[$0 % tiles.count] } ?? waitingTile
            c.saveGState()
            if let hovered, hovered != index { c.setAlpha(0.22) }
            c.saveGState()
            c.addPath(paths[index])
            c.clip()
            if let tile {
                c.draw(tile, in: CGRect(x: 0, y: 0, width: Double(tile.width) / scale, height: Double(tile.height) / scale), byTiling: true)
            }
            c.restoreGState()
            c.addPath(paths[index])
            c.setStrokeColor(theme.ink.cg)
            c.setLineWidth(0.75)
            c.strokePath()
            c.restoreGState()
        }
        drawNames(model: model)
        drawAxis(c, axis: axis)
    }

    /// Name each layer where the whole name fits inside it: the stretch of months under
    /// the label must all be at least a line tall.
    private func drawNames(model: StrataModel) {
        guard let map else { return }
        let axis = model.axis
        let step = (bounds.width - margin.left - margin.right) / max(1, Double(axis.count - 1))
        var candidates: [(best: Double, month: Int, layer: StrataModel.Layer, name: String)] = []
        for layer in model.layers {
            guard let id = layer.region, let name = map.regions.regions[id]?.label else { continue }
            let half = Int((((Double(name.count) * 6.8 + 10) / 2) / step).rounded(.up))
            var best = -1.0, at = -1
            if half < axis.count - half {
                for i in half..<(axis.count - half) {
                    var lowest = Double.infinity
                    for j in (i - half)...(i + half) {
                        lowest = min(lowest, y(layer.bottom[j], model: model) - y(layer.top[j], model: model))
                    }
                    if lowest > best {
                        best = lowest
                        at = i
                    }
                }
            }
            if at >= 0, best >= 14 { candidates.append((best, at, layer, name)) }
        }
        var placed: [CGRect] = []
        let font = NSFont(name: "IBMPlexMono-Medium", size: 11) ?? .monospacedSystemFont(ofSize: 11, weight: .medium)
        for candidate in candidates.sorted(by: { $0.best > $1.best }) {
            let middle = (y(candidate.layer.bottom[candidate.month], model: model) + y(candidate.layer.top[candidate.month], model: model)) / 2
            let fill = NSAttributedString(string: candidate.name, attributes: [.font: font, .foregroundColor: NSColor(cgColor: theme.ink.cg) ?? .black])
            let size = fill.size()
            let rect = CGRect(x: x(axis.edges[candidate.month], axis: axis) - size.width / 2, y: middle - size.height / 2,
                              width: size.width, height: size.height)
            if placed.contains(where: { $0.intersects(rect) }) { continue }
            placed.append(rect)
            let halo = NSAttributedString(string: candidate.name, attributes: [
                .font: font, .strokeColor: NSColor(cgColor: theme.ground.cg) ?? .white, .strokeWidth: 36,
            ])
            halo.draw(in: rect)
            fill.draw(in: rect)
        }
    }

    private func drawAxis(_ c: CGContext, axis: MonthAxis) {
        let top = bounds.height - margin.bottom
        c.setStrokeColor(theme.ink.cg)
        c.setLineWidth(1)
        c.move(to: CGPoint(x: margin.left, y: top + 0.5))
        c.addLine(to: CGPoint(x: bounds.width - margin.right, y: top + 0.5))
        let font = NSFont(name: "IBMPlexMono-Regular", size: 10) ?? .monospacedSystemFont(ofSize: 10, weight: .regular)
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor(cgColor: theme.secondary.cg) ?? .gray]
        for year in axis.years() {
            let at = x(year.time, axis: axis).rounded() + 0.5
            c.move(to: CGPoint(x: at, y: top))
            c.addLine(to: CGPoint(x: at, y: top + 5))
            let text = NSAttributedString(string: String(year.year), attributes: attributes)
            text.draw(at: CGPoint(x: at - text.size().width / 2, y: top + 7))
        }
        c.strokePath()
    }

    // MARK: Pointer

    private func layerIndex(at point: CGPoint) -> Int? {
        paths.indices.reversed().first { paths[$0].contains(point) }
    }

    override func mouseMoved(with event: NSEvent) {
        guard let model, let map else { return }
        let point = convert(event.locationInWindow, from: nil)
        let index = layerIndex(at: point)
        if index != hovered {
            hovered = index
            needsDisplay = true
        }
        guard let index else {
            onTip?(nil)
            return
        }
        let layer = model.layers[index]
        let axis = model.axis
        let fraction = (point.x - margin.left) / (bounds.width - margin.left - margin.right)
        let time = axis.time(atFraction: fraction)
        let month = axis.index(of: time)
        let raw = month.map { layer.raw[$0] } ?? 0
        let name = layer.region.flatMap { map.regions.regions[$0]?.label } ?? "not yet mapped (links waiting for images)"
        let amount = layer.region == nil ? "\(Int(raw)) links" : "resonance \(String(format: "%.1f", raw))"
        onTip?(StrataTip(text: "\(name)  \(Format.month(time))  \(amount)",
                         x: min(point.x + 12, bounds.width - 270), y: point.y + 12))
    }

    override func mouseExited(with event: NSEvent) {
        hovered = nil
        onTip?(nil)
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        guard let model, let index = layerIndex(at: convert(event.locationInWindow, from: nil)),
              let region = model.layers[index].region else { return }
        onPick?(region)
    }
}
